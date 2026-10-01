/// Hub-Bildschirm: lokalen Server starten, Pairing-QR zeigen, Scanner verwalten,
/// Zähler und Einstellungen (Platz groß anzeigen). Mit Vollbild-Zählertafel.
library;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../db.dart';
import '../hub/hub_server.dart';
import '../hub/hub_service.dart';
import '../models.dart';
import '../sync.dart';

/// Ein Hub-Server je Event, lebt über Bildschirmwechsel hinweg (App im Vordergrund).
class HubRegistry {
  static final Map<int, HubServer> _servers = {};
  static final Map<int, HubService> _services = {};

  static HubServer? server(int localEventId) => _servers[localEventId];
  static HubService? service(int localEventId) => _services[localEventId];

  static Future<HubServer> start(PairedEvent e, String hubName, void Function() onActivity) async {
    final existing = _servers[e.localId];
    if (existing != null && existing.running) return existing;
    final service = HubService(e, hubName: hubName);
    final server = HubServer(service, onActivity: onActivity);
    await server.start();
    _servers[e.localId] = server;
    _services[e.localId] = service;
    await AppDb.setHubFlag(e.localId, true);
    unawaited(WakelockPlus.enable());
    return server;
  }

  static Future<void> stop(int localEventId) async {
    await _servers[localEventId]?.stop();
    _servers.remove(localEventId);
    _services.remove(localEventId);
    await AppDb.setHubFlag(localEventId, false);
    if (_servers.isEmpty) unawaited(WakelockPlus.disable());
  }

  static bool isRunning(int localEventId) => _servers[localEventId]?.running ?? false;
}

class HubScreen extends StatefulWidget {
  final PairedEvent event;
  const HubScreen({super.key, required this.event});

  @override
  State<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends State<HubScreen> {
  late PairedEvent _event;
  late final TextEditingController _nameCtrl;
  List<String> _ips = const [];
  List<HubClient> _clients = const [];
  Map<String, dynamic> _stats = const {};
  Timer? _timer;
  String? _error;
  SyncState _shopState = SyncState.offline;
  SyncService? _shopSync;

  HubServer? get _server => HubRegistry.server(_event.localId);
  HubService? get _service => HubRegistry.service(_event.localId);

  @override
  void initState() {
    super.initState();
    _event = widget.event;
    _nameCtrl = TextEditingController(text: _event.deviceName.isNotEmpty ? _event.deviceName : 'Hub');
    _shopSync = SyncService(_event, onStatus: (s) {
      if (mounted) setState(() => _shopState = s);
    });
    _shopSync!.start();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_refresh()));
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _shopSync?.stop();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final e = await AppDb.eventById(_event.localId);
    if (e != null) _event = e;
    final ips = await HubServer.localAddresses();
    final svc = _service;
    final clients = svc != null ? await svc.clients() : const <HubClient>[];
    final stats = svc != null ? await svc.stats() : await HubService(_event, hubName: _nameCtrl.text).stats();
    if (!mounted) return;
    setState(() {
      _ips = ips;
      _clients = clients;
      _stats = stats;
    });
  }

  Future<void> _toggle() async {
    setState(() => _error = null);
    try {
      if (HubRegistry.isRunning(_event.localId)) {
        await HubRegistry.stop(_event.localId);
      } else {
        await AppDb.setDeviceName(_event.localId, _nameCtrl.text.trim());
        await HubRegistry.start(_event, _nameCtrl.text.trim().isEmpty ? 'Hub' : _nameCtrl.text.trim(), () => unawaited(_refresh()));
      }
    } catch (e) {
      setState(() => _error = e.toString());
    }
    await _refresh();
  }

  String? get _baseUrl {
    final s = _server;
    if (s == null || !s.running || _ips.isEmpty) return null;
    return 'http://${_ips.first}:${s.port}';
  }

  @override
  Widget build(BuildContext context) {
    final running = HubRegistry.isRunning(_event.localId);
    final svc = _service;
    final url = _baseUrl;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Hub · ${_event.title}', overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Zählertafel (Vollbild)',
            icon: const Icon(Icons.fullscreen),
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CounterBoardScreen(event: _event))),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(running ? Icons.wifi_tethering : Icons.wifi_tethering_off, color: running ? Colors.greenAccent : theme.disabledColor, size: 32),
                    const SizedBox(width: 12),
                    Expanded(child: Text(running ? 'Hub läuft' : 'Hub aus', style: theme.textTheme.titleLarge)),
                    FilledButton(onPressed: _toggle, child: Text(running ? 'Hub beenden' : 'Hub starten')),
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _nameCtrl,
                    enabled: !running,
                    decoration: const InputDecoration(labelText: 'Name dieses Hubs (z. B. Hub Einlass)', border: OutlineInputBorder()),
                  ),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
                  const SizedBox(height: 8),
                  Text(
                    'Der Hub verteilt die Gästeliste im WLAN an die Scanner, sammelt alle Scans und meldet sie '
                    'dem Shop, sobald er Internet hat. Dieses Gerät muss eingeschaltet und die App im Vordergrund bleiben.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  Row(children: [
                    Icon(_shopState == SyncState.online ? Icons.cloud_done : (_shopState == SyncState.offline ? Icons.cloud_off : Icons.link_off),
                        size: 18, color: _shopState == SyncState.online ? Colors.greenAccent : Colors.orangeAccent),
                    const SizedBox(width: 6),
                    Text(_shopState == SyncState.online
                        ? 'Shop erreichbar – Scans werden laufend gemeldet'
                        : (_shopState == SyncState.offline ? 'Shop nicht erreichbar – ${_stats['pending_to_shop'] ?? 0} Scans warten' : 'Gerät im Shop widerrufen – neu koppeln')),
                  ]),
                ],
              ),
            ),
          ),
          if (running && svc != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Text('Scanner koppeln', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (url == null)
                    const Text('Keine WLAN-Adresse gefunden. Gerät mit dem WLAN verbinden.', style: TextStyle(color: Colors.orangeAccent))
                  else ...[
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: QrImageView(data: svc.pairingPayload(url), size: 240, backgroundColor: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    Text('$url  ·  Code ${svc.code}', style: theme.textTheme.bodyMedium),
                    Text('Code gilt bis ${TimeOfDay.fromDateTime(svc.codeExpires).format(context)} Uhr. In der Scanner-App „Gerät koppeln" wählen und diesen QR scannen.', textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                    if (_ips.length > 1) Text('Weitere Adressen: ${_ips.skip(1).join(', ')}', style: theme.textTheme.bodySmall),
                    TextButton(onPressed: () => setState(svc.regenerateCode), child: const Text('Neuen Code erzeugen')),
                  ],
                ]),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Einstellungen für alle Scanner', style: theme.textTheme.titleMedium),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Platz groß anzeigen'),
                  subtitle: const Text('Scanner zeigen nach dem Scan Bereich, Reihe und Platz in großer Schrift (Jugendweihe).'),
                  value: _event.showSeat,
                  onChanged: (v) async {
                    await AppDb.setShowSeat(_event.localId, v);
                    await _refresh();
                  },
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          _countersCard(theme),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Gekoppelte Scanner (${_clients.where((c) => !c.revoked).length})', style: theme.textTheme.titleMedium),
                if (_clients.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Noch kein Scanner gekoppelt.')),
                for (final c in _clients)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(c.revoked ? Icons.phonelink_off : Icons.phone_android, color: c.revoked ? theme.disabledColor : null),
                    title: Text(c.name, style: c.revoked ? TextStyle(decoration: TextDecoration.lineThrough, color: theme.disabledColor) : null),
                    subtitle: Text('${c.scans} Scans · zuletzt ${_rel(c.lastSeen)}'),
                    trailing: c.revoked
                        ? null
                        : IconButton(
                            tooltip: 'Scanner trennen',
                            icon: const Icon(Icons.link_off),
                            onPressed: () async {
                              await _service?.revokeClient(c.id);
                              await _refresh();
                            },
                          ),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Hinweis: Im WLAN läuft die Verbindung unverschlüsselt. Ein eigener Router oder Hotspot ist dem offenen WLAN der Location vorzuziehen.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _countersCard(ThemeData theme) {
    final total = _stats['total'] ?? 0;
    final inCount = _stats['in'] ?? 0;
    final devices = (_stats['devices'] as List?) ?? const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Zähler', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _big('$inCount', 'eingecheckt', Colors.greenAccent),
            _big('${_stats['out'] ?? 0}', 'draußen', Colors.orangeAccent),
            _big('${_stats['open'] ?? 0}', 'erwartet', Colors.white70),
            _big('$total', 'Tickets', Colors.white70),
          ]),
          if (devices.isNotEmpty) ...[
            const Divider(height: 24),
            for (final d in devices)
              if (d is Map)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(child: Text(asStr(d['device_name']) ?? '–')),
                    Text('${d['ok'] ?? 0} Einlass · ${d['conflict'] ?? 0} Doppel · ${d['invalid'] ?? 0} abgelehnt'),
                  ]),
                ),
          ],
        ]),
      ),
    );
  }

  static Widget _big(String value, String label, Color color) => Column(children: [
        Text(value, style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ]);

  static String _rel(String? ts) {
    if (ts == null || ts.isEmpty) return 'nie';
    final t = DateTime.tryParse(ts);
    if (t == null) return ts;
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 20) return 'gerade eben';
    if (d.inMinutes < 1) return 'vor ${d.inSeconds} s';
    if (d.inHours < 1) return 'vor ${d.inMinutes} min';
    return 'um ${ts.substring(11, 16)} Uhr';
  }
}

/// Vollbild-Zählertafel für einen Monitor oder das Tablet am Eingang.
class CounterBoardScreen extends StatefulWidget {
  final PairedEvent event;
  const CounterBoardScreen({super.key, required this.event});

  @override
  State<CounterBoardScreen> createState() => _CounterBoardScreenState();
}

class _CounterBoardScreenState extends State<CounterBoardScreen> {
  Timer? _timer;
  Map<String, dynamic> _stats = const {};

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_load()));
    unawaited(_load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final svc = HubRegistry.service(widget.event.localId) ?? HubService(widget.event, hubName: 'Hub');
    final s = await svc.stats();
    if (mounted) setState(() => _stats = s);
  }

  @override
  Widget build(BuildContext context) {
    final total = (_stats['total'] ?? 0) as int;
    final inCount = (_stats['in'] ?? 0) as int;
    final pct = total > 0 ? (inCount / total * 100).round() : 0;
    final devices = (_stats['devices'] as List?) ?? const [];
    final recent = (_stats['recent'] as List?) ?? const [];
    return Scaffold(
      backgroundColor: const Color(0xFF00467A),
      body: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.event.title, style: const TextStyle(color: Colors.white70, fontSize: 28)),
                const Spacer(),
                Center(
                  child: Column(children: [
                    Text('$inCount', style: const TextStyle(color: Colors.white, fontSize: 160, fontWeight: FontWeight.bold, height: 1)),
                    Text('von $total eingecheckt · $pct %', style: const TextStyle(color: Color(0xFF00B1EB), fontSize: 36)),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: total > 0 ? inCount / total : 0, minHeight: 14, backgroundColor: Colors.white24, color: const Color(0xFF00B1EB)),
                  ]),
                ),
                const Spacer(),
                Wrap(spacing: 32, runSpacing: 8, children: [
                  for (final d in devices)
                    if (d is Map) Text('${asStr(d['device_name']) ?? '–'}: ${d['ok'] ?? 0}', style: const TextStyle(color: Colors.white, fontSize: 24)),
                ]),
                const SizedBox(height: 12),
                for (final r in recent.take(4))
                  if (r is Map)
                    Text('${(asStr(r['scanned_at']) ?? '').length >= 16 ? asStr(r['scanned_at'])!.substring(11, 16) : ''}  ${asStr(r['name']) ?? asStr(r['ticket_uuid']) ?? ''}  ·  ${asStr(r['device_name']) ?? ''}  ·  ${asStr(r['result']) ?? ''}',
                        style: const TextStyle(color: Colors.white54, fontSize: 18)),
                const SizedBox(height: 8),
                const Text('Tippen zum Schließen', style: TextStyle(color: Colors.white38)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
