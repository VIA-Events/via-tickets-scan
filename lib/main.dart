/// VIA Tickets Scan – Einlass-Scanner (Konzept K5).
/// Eventliste beim Start; ein Gerät kann mehrere Events (auch verschiedener
/// Shops) gekoppelt haben. Personal braucht nur das Gerät, nie Zugangsdaten.
library;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'db.dart';
import 'demo.dart';
import 'models.dart';
import 'screens/hub.dart';
import 'screens/pair.dart';
import 'screens/scan.dart';
import 'secure_store.dart';
import 'sync.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Klartext-Token/-Secret aus SQLite (Version 1) in den Secure Storage
  // überführen. Best-effort: ein Fehler darf den Start nicht verhindern.
  try {
    await AppDb.migrateCredentialsToSecureStorage();
  } catch (_) {}
  // Offene Scans aller Events einmal nachreichen und Manifest-Delta holen –
  // im Hintergrund, blockiert die Oberfläche nicht.
  unawaited(SyncService.syncAllOnce());
  runApp(const ProviderScope(child: ViaScanApp()));
}

class ViaScanApp extends StatelessWidget {
  const ViaScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VIA Tickets Scan',
      theme: Via.theme(),
      home: const EventListScreen(),
    );
  }
}

final eventsProvider =
    FutureProvider<List<PairedEvent>>((ref) => AppDb.events());

class EventListScreen extends ConsumerWidget {
  const EventListScreen({super.key});

  /// Entfernen: Gerät im Shop abmelden (best-effort), Secrets löschen,
  /// dann lokale Daten entfernen.
  Future<void> _remove(PairedEvent e) async {
    if (HubRegistry.isRunning(e.localId)) {
      await HubRegistry.stop(e.localId);
    }
    if (e.deviceToken.isNotEmpty && !isDemoEvent(e)) {
      try {
        await ScanApi(e.baseUrl, token: e.deviceToken).revokeSelf();
      } catch (_) {
        // Offline oder bereits widerrufen – lokal trotzdem entfernen.
      }
    }
    await SecureStore.delete(e.localId);
    await AppDb.removeEvent(e.localId);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(eventsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('VIA Tickets Scan')),
      body: events.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Fehler: $e')),
        data: (list) => list.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'Noch kein Event gekoppelt.\n\nIm Shop-Backend unter „Scangeräte" einen Pairing-QR erzeugen und unten scannen – oder den QR eines Hubs im WLAN.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.school_outlined),
                        label: const Text('Demo-Event ausprobieren'),
                        onPressed: () async {
                          await createDemoEvent();
                          ref.invalidate(eventsProvider);
                        },
                      ),
                    ],
                  ),
                ),
              )
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final e = list[i];
                  final hubOn = HubRegistry.isRunning(e.localId);
                  return ListTile(
                    leading: Icon(hubOn ? Icons.wifi_tethering : (isDemoEvent(e) ? Icons.school_outlined : Icons.event),
                        color: hubOn ? Colors.greenAccent : null),
                    title: Text(e.title),
                    subtitle: Text([
                      '${e.venueName ?? ''}  ${e.startsAt ?? ''}'.trim(),
                      [
                        if (e.deviceName.isNotEmpty) 'Gerät: ${e.deviceName}',
                        if (hubOn) 'Hub läuft',
                        if (e.baseUrl.startsWith('http://')) 'über Hub ${Uri.tryParse(e.baseUrl)?.host ?? ''}',
                      ].join(' · '),
                    ].where((s) => s.isNotEmpty).join('\n')),
                    isThreeLine: true,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (!isDemoEvent(e) && !e.baseUrl.startsWith('http://'))
                        IconButton(
                          icon: Icon(Icons.wifi_tethering, color: hubOn ? Colors.greenAccent : null),
                          tooltip: 'Lokaler Hub (WLAN)',
                          onPressed: () async {
                            await Navigator.push(context,
                                MaterialPageRoute<void>(builder: (_) => HubScreen(event: e)));
                            ref.invalidate(eventsProvider);
                          },
                        ),
                      IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Event entfernen',
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Event entfernen?'),
                            content: const Text(
                                'Das Gerät wird im Shop abgemeldet (falls erreichbar). '
                                'Lokale Daten und noch nicht übertragene Scans dieses '
                                'Events werden gelöscht.'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(c, false),
                                  child: const Text('Abbrechen')),
                              TextButton(
                                  onPressed: () => Navigator.pop(c, true),
                                  child: const Text('Entfernen')),
                            ],
                          ),
                        );
                        if (ok == true) {
                          await _remove(e);
                          ref.invalidate(eventsProvider);
                        }
                      },
                    ),
                    ]),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                            builder: (_) => ScanScreen(event: e)),
                      );
                      ref.invalidate(eventsProvider);
                    },
                  );
                },
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Gerät koppeln'),
        onPressed: () async {
          await Navigator.push(
              context, MaterialPageRoute<void>(builder: (_) => const PairScreen()));
          ref.invalidate(eventsProvider);
        },
      ),
    );
  }
}
