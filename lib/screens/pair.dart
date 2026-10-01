/// Pairing per QR (Konzept 4.2): QR enthält {v, type:"viat-pair", url, event_id, code}.
/// POST /scan/pair liefert Gerätetoken + Event-Secret + Stammdaten.
/// Erfolg wird direkt nach dem lokalen Speichern gemeldet; das Manifest lädt
/// anschließend asynchron mit Fortschrittsanzeige.
library;
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../api.dart';
import '../db.dart';
import '../sync.dart';

enum _Phase { scanning, pairing, loadingManifest, done, manifestFailed, error }

class PairScreen extends StatefulWidget {
  const PairScreen({super.key});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  _Phase _phase = _Phase.scanning;
  final TextEditingController _nameCtrl = TextEditingController(text: 'Scanner');

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }
  String _title = '';
  int _ticketCount = 0;
  String? _error;

  Future<void> _handle(String raw) async {
    if (_phase != _Phase.scanning) return;
    setState(() {
      _phase = _Phase.pairing;
      _error = null;
    });

    try {
      final data = jsonDecode(raw);
      if (data is! Map || data['type'] != 'viat-pair') {
        throw const FormatException('Kein VIA-Pairing-QR.');
      }
      final baseUrl = data['url'];
      final code = data['code'];
      if (baseUrl is! String || baseUrl.isEmpty || code is! String) {
        throw const FormatException('Pairing-QR unvollständig (url/code).');
      }

      final res = await ScanApi.pair(baseUrl, code, name: _nameCtrl.text.trim());
      final eventMap = res['event'];
      final token = res['device_token'];
      final secret = res['hmac_secret'];
      if (eventMap is! Map || token is! String || secret is! String) {
        throw const FormatException('Antwort des Shops unvollständig.');
      }

      final localId = await AppDb.saveEvent(
        baseUrl: baseUrl,
        event: Map<String, dynamic>.from(eventMap),
        deviceToken: token,
        hmacSecret: secret,
      );
      // Gerätename (Eingang) merken – vom Hub ggf. ergänzt; Platzanzeige aus den Einstellungen.
      final assigned = res['device_name'];
      await AppDb.setDeviceName(localId, assigned is String && assigned.isNotEmpty ? assigned : _nameCtrl.text.trim());
      final settings = res['settings'];
      if (settings is Map && settings.containsKey('show_seat')) {
        await AppDb.setShowSeat(localId, settings['show_seat'] == true);
      }
      final event = await AppDb.eventById(localId);
      if (event == null) {
        throw StateError('Event konnte lokal nicht gespeichert werden.');
      }

      // Erfolg sofort melden – das Gerät ist gekoppelt.
      if (!mounted) return;
      setState(() {
        _phase = _Phase.loadingManifest;
        _title = event.title;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Gekoppelt: ${event.title}')));

      // Manifest asynchron nachladen (vor Einlass, Konzept 4.3).
      try {
        final n = await SyncService(event).fullSync();
        if (!mounted) return;
        setState(() {
          _phase = _Phase.done;
          _ticketCount = n;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _phase = _Phase.manifestFailed;
          _error = describePairError(e);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = describePairError(e);
      });
    }
  }

  /// Verständliche deutsche Fehlermeldung für Pairing und Manifest.
  static String describePairError(Object e) {
    final code = ScanApi.errorCode(e);
    final status = ScanApi.statusCode(e);
    if (code == 'viat_https_required') {
      return 'Der Shop erlaubt das Koppeln nur über HTTPS. Bitte den Shop mit '
          'SSL-Zertifikat (https://…) betreiben und den Pairing-QR neu erzeugen.';
    }
    if (code == 'viat_pair_invalid') {
      return 'Pairing-Code ungültig oder abgelaufen (10 Minuten gültig). '
          'Im Shop-Backend einen neuen Pairing-QR erzeugen.';
    }
    if (code == 'viat_unauthorized' || status == 401) {
      return 'Gerät nicht autorisiert – Token widerrufen oder abgelaufen. '
          'Bitte neu koppeln.';
    }
    if (status == 404) {
      return 'Event im Shop nicht gefunden (gelöscht oder falsche Shop-URL).';
    }
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return 'Shop nicht erreichbar (Netzwerk oder Zeitüberschreitung).';
        case DioExceptionType.badCertificate:
          return 'SSL-Zertifikat des Shops ungültig.';
        default:
          if (status != null) return 'Der Shop antwortet mit HTTP $status.';
          return 'Netzwerkfehler beim Verbinden mit dem Shop.';
      }
    }
    if (e is FormatException) return e.message;
    return e.toString();
  }

  Widget _statusPanel() {
    switch (_phase) {
      case _Phase.pairing:
        return _panel(
          child: const CircularProgressIndicator(),
          text: 'Gerät wird gekoppelt …',
        );
      case _Phase.loadingManifest:
        return _panel(
          child: const CircularProgressIndicator(),
          text: 'Gekoppelt: $_title\n\nTicketliste wird geladen …',
        );
      case _Phase.done:
        return _panel(
          child: const Icon(Icons.check_circle, size: 72, color: Colors.green),
          text: 'Gekoppelt: $_title\n\n$_ticketCount Tickets geladen.',
          action: FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Weiter'),
          ),
        );
      case _Phase.manifestFailed:
        return _panel(
          child: const Icon(Icons.warning_amber, size: 72, color: Colors.orange),
          text: 'Gekoppelt: $_title\n\nTicketliste konnte noch nicht geladen '
              'werden:\n${_error ?? ''}\n\nSie wird beim Öffnen des Events '
              'automatisch nachgeladen.',
          action: FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Weiter'),
          ),
        );
      case _Phase.error:
        return _panel(
          child: const Icon(Icons.error_outline, size: 72, color: Colors.redAccent),
          text: 'Pairing fehlgeschlagen:\n${_error ?? ''}',
          action: FilledButton.tonal(
            onPressed: () => setState(() {
              _phase = _Phase.scanning;
              _error = null;
            }),
            child: const Text('Erneut scannen'),
          ),
        );
      case _Phase.scanning:
        return const SizedBox.shrink();
    }
  }

  Widget _panel({required Widget child, required String text, Widget? action}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            child,
            const SizedBox(height: 24),
            Text(text, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16)),
            if (action != null) ...[
              const SizedBox(height: 24),
              action,
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scanning = _phase == _Phase.scanning;
    return Scaffold(
      appBar: AppBar(title: const Text('Gerät koppeln')),
      body: scanning
          ? Column(
              children: [
                Expanded(
                  child: MobileScanner(
                    onDetect: (capture) {
                      final code = capture.barcodes.firstOrNull?.rawValue;
                      if (code != null) _handle(code);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: TextField(
                    controller: _nameCtrl,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Name dieses Geräts (z. B. Eingang Süd)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Text(
                    'Pairing-QR scannen: aus dem Shop-Backend (Event → Scangeräte → „Gerät koppeln") oder vom Hub-Gerät im WLAN.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            )
          : _statusPanel(),
    );
  }
}
