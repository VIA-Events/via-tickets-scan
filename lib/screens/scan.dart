/// Scan-Bildschirm nach dem Claude-Design „Ticketscanner" (01.10.2026):
/// dunkle Kameraansicht, Kopf mit Baum-Kachel, Eventtitel und Gerätename, Zählerpanel
/// „Eingelassen x / y", Scanrahmen mit laufender Linie, zwei große Tasten (Nummer eingeben,
/// Verlauf). Ergebnis als Vollfläche: Grün = einlassen, Gelb = bereits eingelöst,
/// Rot = ungültig; darunter eine weiße Karte mit Name, Kategorie, Platz, Ticket.
///
/// Sperren (F5): Solange ein Ergebnis- oder Alarm-Overlay sichtbar ist, werden keine neuen
/// Codes verarbeitet. Nur Grün schließt sich von selbst (Countdown), alles andere wird angetippt.
library;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:uuid/uuid.dart';

import '../db.dart';
import '../demo.dart';
import '../models.dart';
import '../qr_verify.dart';
import '../sounds.dart';
import '../sync.dart';
import '../theme.dart';
import 'exit_list.dart';
import 'history.dart';
import 'hub.dart';
import 'search.dart';

class ScanScreen extends StatefulWidget {
  final PairedEvent event;
  const ScanScreen({super.key, required this.event});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with SingleTickerProviderStateMixin {
  static const Duration _autoCloseOk = Duration(seconds: 3);
  static const Duration _rescanBlock = Duration(seconds: 2);

  late final SyncService _sync;
  final Uuid _uuidGen = const Uuid();
  final MobileScannerController _cam = MobileScannerController();
  late final AnimationController _line;
  late PairedEvent _event;

  ScanResult? _result;
  DateTime? _resultAt;
  SyncAlert? _alert;
  Ticket? _alertTicket;
  int _openAlerts = 0;
  SyncState _state = SyncState.online;
  Map<String, int> _counts = const {'total': 0, 'in': 0, 'out': 0};
  Map<String, Object?>? _conflictInfo;

  bool _processing = false;
  bool _torch = false;
  Timer? _autoClose;
  Timer? _countdown;
  String? _lastRaw;
  DateTime _lastClosed = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _isDemo => isDemoEvent(widget.event);
  bool get _isHub => HubRegistry.isRunning(widget.event.localId);
  String get _deviceName => _event.deviceName.isNotEmpty ? _event.deviceName : (_isHub ? 'Hub' : 'Scanner');

  @override
  void initState() {
    super.initState();
    _event = widget.event;
    _line = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..repeat(reverse: true);
    _sync = SyncService(
      widget.event,
      onStatus: _onStatus,
      onAlert: (_) => unawaited(_loadAlerts()),
      onSettings: () => unawaited(_reloadEvent()),
    );
    _sync.start();
    unawaited(_refreshCounts());
    unawaited(_loadAlerts());
  }

  @override
  void dispose() {
    _autoClose?.cancel();
    _countdown?.cancel();
    _line.dispose();
    _sync.stop();
    _cam.dispose();
    super.dispose();
  }

  Future<void> _reloadEvent() async {
    final e = await AppDb.eventById(widget.event.localId);
    if (e != null && mounted) setState(() => _event = e);
  }

  /* ------------------------------------------------------ Sync-Status */

  void _onStatus(SyncState s) {
    if (!mounted) return;
    if (s != _state) setState(() => _state = s);
    unawaited(_refreshCounts());
  }

  Future<void> _refreshCounts() async {
    final c = await AppDb.counts(widget.event.localId);
    if (mounted) setState(() => _counts = c);
  }

  /* ------------------------------------------------------ Sync-Alarme */

  Future<void> _loadAlerts() async {
    final id = widget.event.localId;
    final a = await AppDb.oldestOpenAlert(id);
    final n = await AppDb.openAlertCount(id);
    final ticket = (a != null && a.ticketUuid.isNotEmpty) ? await AppDb.ticketByUuid(id, a.ticketUuid) : null;
    if (!mounted) return;
    final isNew = a != null && a.id != _alert?.id;
    setState(() {
      _alert = a;
      _alertTicket = ticket;
      _openAlerts = n;
    });
    if (isNew) {
      unawaited(HapticFeedback.vibrate());
      unawaited(Sounds.error());
    }
  }

  Future<void> _acknowledge(SyncAlert a) async {
    await AppDb.acknowledgeAlert(a.id);
    _lastClosed = DateTime.now();
    await _loadAlerts();
  }

  /* ------------------------------------------------------------ Scan */

  bool get _overlayVisible => _result != null || _alert != null;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_overlayVisible || _processing) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.isEmpty) return;
    if (raw == _lastRaw && DateTime.now().difference(_lastClosed) < _rescanBlock) return;
    _processing = true;
    try {
      await _evaluate(raw);
    } finally {
      _processing = false;
    }
  }

  Future<void> _evaluate(String raw) async {
    _lastRaw = raw;
    final payload = parsePayload(raw);
    if (payload == null) {
      await _reject(null, ScanVerdict.invalid, 'Kein VIA-Ticket-QR.');
      return;
    }
    if (payload.eventId != widget.event.eventId) {
      await _reject(null, ScanVerdict.wrongEvent, 'Ticket gehört zu einem anderen Event.');
      return;
    }
    if (!verifySig(payload, widget.event.hmacSecret)) {
      await _reject(null, ScanVerdict.forged, 'Signatur ungültig – Ticket nicht echt.');
      return;
    }
    final ticket = await AppDb.ticketByUuid(widget.event.localId, payload.uuid);
    if (!mounted) return;
    if (ticket == null) {
      await _reject(null, ScanVerdict.invalid, 'Ticket nicht in der Gästeliste. Sync abwarten oder Nummer eingeben.');
      return;
    }
    await _evaluateTicket(ticket, manual: false);
  }

  /// Entscheidung nach Ticketstatus – gemeinsamer Weg für Kamera-Scan und Nummerneingabe.
  Future<void> _evaluateTicket(Ticket ticket, {required bool manual}) async {
    switch (ticket.status) {
      case 'cancelled':
        await _reject(ticket, ScanVerdict.cancelled, 'Ticket wurde storniert.');
        return;
      case 'checked_in':
        _conflictInfo = await AppDb.lastOkEntry(widget.event.localId, ticket.uuid);
        await _reject(ticket, ScanVerdict.alreadyIn, 'Nicht einlassen – Einlassleitung rufen');
        return;
      case 'checked_out':
        if (!widget.event.reentry) {
          await _reject(ticket, ScanVerdict.invalid, 'Gast hat das Haus verlassen. Wiedereinlass ist bei diesem Event nicht erlaubt.');
          return;
        }
        _setResult(ScanResult(ScanVerdict.checkedOut, ticket: ticket, message: 'Gast war draußen. Wiedereinlass buchen?'));
        return;
      default:
        await _checkin(ticket, manual ? 'manual_in' : 'in');
        if (!mounted) return;
        _setResult(ScanResult(ScanVerdict.ok, ticket: ticket));
    }
  }

  /// Ablehnung anzeigen und im Verlauf protokollieren (Hub-Buchungen protokolliert der Hub selbst).
  Future<void> _reject(Ticket? ticket, ScanVerdict verdict, String message) async {
    unawaited(HapticFeedback.vibrate());
    if (ticket != null) {
      await AppDb.logCheckin(
        clientUuid: _uuidGen.v4(),
        localEventId: widget.event.localId,
        ticketUuid: ticket.uuid,
        action: 'in',
        result: verdict == ScanVerdict.alreadyIn ? 'conflict' : 'invalid',
        scannedAt: _now(),
        deviceName: _deviceName,
      );
    }
    _setResult(ScanResult(verdict, ticket: ticket, message: message));
  }

  static String _now() => DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());

  /// Scan lokal buchen (Queue + Status) und Sync anstoßen. Auf dem Hub über dessen Buchungslogik.
  Future<void> _checkin(Ticket ticket, String action) async {
    final clientUuid = _uuidGen.v4();
    final scannedAt = _now();
    final hub = HubRegistry.service(widget.event.localId);
    if (hub != null && _isHub) {
      await hub.applyCheckins([
        {'client_uuid': clientUuid, 'ticket_uuid': ticket.uuid, 'action': action, 'scanned_at': scannedAt}
      ], deviceName: _deviceName);
    } else {
      if (!_isDemo) {
        await AppDb.queueCheckin(
          clientUuid: clientUuid,
          localEventId: widget.event.localId,
          ticketUuid: ticket.uuid,
          action: action,
          scannedAt: scannedAt,
          deviceName: _deviceName,
        );
      }
      await AppDb.setTicketStatus(widget.event.localId, ticket.uuid, action == 'out' ? 'checked_out' : 'checked_in');
      await AppDb.logCheckin(
        clientUuid: clientUuid,
        localEventId: widget.event.localId,
        ticketUuid: ticket.uuid,
        action: action,
        result: 'ok',
        scannedAt: scannedAt,
        deviceName: _deviceName,
      );
    }
    unawaited(_refreshCounts());
    unawaited(_sync.tick());
  }

  void _setResult(ScanResult r) {
    _autoClose?.cancel();
    _countdown?.cancel();
    _autoClose = null;
    _countdown = null;
    _resultAt = DateTime.now();
    if (r.verdict == ScanVerdict.ok) {
      unawaited(HapticFeedback.lightImpact());
      unawaited(Sounds.ok());
      _autoClose = Timer(_autoCloseOk, _closeResult);
      _countdown = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() {});
      });
    } else if (r.verdict == ScanVerdict.checkedOut) {
      unawaited(Sounds.warn());
    } else {
      unawaited(Sounds.error());
    }
    if (!mounted) return;
    setState(() => _result = r);
  }

  void _closeResult() {
    _autoClose?.cancel();
    _countdown?.cancel();
    _autoClose = null;
    _countdown = null;
    _lastClosed = DateTime.now();
    _conflictInfo = null;
    if (!mounted) return;
    if (_result != null) setState(() => _result = null);
  }

  Future<void> _bookFromOverlay(Ticket t, String action, String done) async {
    await _checkin(t, action);
    if (!mounted) return;
    _closeResult();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$done: ${_displayName(t)}'), duration: const Duration(seconds: 2)));
  }

  static String _displayName(Ticket t) => (t.name != null && t.name!.isNotEmpty) ? t.name! : t.no;

  /* ------------------------------------------------- Nummer eingeben */

  Future<void> _openManual() async {
    final ctrl = TextEditingController();
    final no = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: Via.square,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 24, 20, 40 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Ticketnummer eingeben', style: Via.h(24, color: Via.dunkelblau))),
            IconButton(icon: const Icon(Icons.close, color: Via.fg2), onPressed: () => Navigator.pop(ctx)),
          ]),
          const SizedBox(height: 6),
          const Text('Die Nummer steht unter dem QR-Code auf dem Ticket, z. B. K7F2-9XQ4.', style: TextStyle(fontSize: 15, color: Via.fg2, height: 1.45)),
          const SizedBox(height: 18),
          TextField(
            controller: ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            style: Via.h(30, color: Via.ink).copyWith(letterSpacing: 2),
            decoration: const InputDecoration(
              hintText: 'XXXX-XXXX',
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: Via.dunkelblau, width: 2)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: Via.dunkelblau, width: 2)),
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              icon: const Icon(Icons.search),
              label: const Text('Ticket prüfen'),
              onPressed: () => Navigator.pop(ctx, ctrl.text),
            ),
          ),
        ]),
      ),
    );
    ctrl.dispose();
    final q = (no ?? '').trim().toUpperCase().replaceAll(' ', '');
    if (q.isEmpty || !mounted) return;
    final hits = await AppDb.searchTickets(widget.event.localId, q);
    final exact = hits.where((t) => t.no.toUpperCase() == q || t.no.toUpperCase().replaceAll('-', '') == q.replaceAll('-', '')).toList();
    final t = exact.isNotEmpty ? exact.first : (hits.length == 1 ? hits.first : null);
    if (!mounted) return;
    if (t == null) {
      _lastRaw = null;
      _setResult(ScanResult(ScanVerdict.invalid, message: hits.isEmpty ? 'Ticket „$q" nicht gefunden.' : 'Nummer nicht eindeutig – bitte vollständig eingeben.'));
      return;
    }
    await _evaluateTicket(t, manual: true);
  }

  /// Demo: nächstes Ticket „scannen", ohne Kamera.
  Future<void> _simulateScan() async {
    if (_overlayVisible || _processing) return;
    final all = await AppDb.searchTickets(widget.event.localId, '');
    if (all.isEmpty) return;
    all.sort((a, b) => (a.status == 'valid' ? 0 : 1).compareTo(b.status == 'valid' ? 0 : 1));
    _processing = true;
    try {
      await _evaluate(demoPayload(all.first.uuid));
    } finally {
      _processing = false;
    }
  }

  /* ---------------------------------------------------------- Aufbau */

  @override
  Widget build(BuildContext context) {
    final e = _event;
    final total = _counts['total'] ?? 0;
    final inCount = _counts['in'] ?? 0;
    final pct = total > 0 ? (inCount / total).clamp(0.0, 1.0) : 0.0;
    return Scaffold(
      backgroundColor: Via.scanDark,
      body: Stack(
        children: [
          Positioned.fill(child: MobileScanner(controller: _cam, onDetect: _onDetect)),
          // leichte Abdunklung über dem Kamerabild, damit die weiße Schrift trägt
          Positioned.fill(child: IgnorePointer(child: Container(color: Colors.black.withValues(alpha: .25)))),
          SafeArea(
            child: Column(
              children: [
                _header(e),
                if (_state == SyncState.unauthorized) _banner('Gerät widerrufen oder abgelaufen – neu koppeln. Scans werden lokal gespeichert, aber nicht übertragen.'),
                Container(
                  margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  color: Via.dunkelblau.withValues(alpha: .72),
                  child: Column(children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Expanded(child: Text('EINGELASSEN', style: TextStyle(fontSize: 14, letterSpacing: 1, color: Colors.white.withValues(alpha: .85)))),
                      Text.rich(TextSpan(children: [
                        TextSpan(text: '$inCount', style: Via.h(30, weight: FontWeight.w800, color: Colors.white, height: 1)),
                        TextSpan(text: ' / $total', style: Via.h(17, weight: FontWeight.w400, color: Colors.white.withValues(alpha: .7), height: 1)),
                      ])),
                    ]),
                    const SizedBox(height: 10),
                    Container(
                      height: 4,
                      color: Colors.white.withValues(alpha: .2),
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(widthFactor: pct, child: Container(color: Via.hellblau)),
                    ),
                    if (_state != SyncState.online || _isHub || _counts['out']! > 0) ...[
                      const SizedBox(height: 8),
                      Row(children: [
                        Icon(_stateIconData(), size: 14, color: Colors.white.withValues(alpha: .8)),
                        const SizedBox(width: 6),
                        Expanded(child: Text(_stateText(), style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: .8)))),
                      ]),
                    ],
                  ]),
                ),
                Expanded(child: Center(child: _frame())),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Row(children: [
                    Expanded(child: _bigButton('Nummer eingeben', Icons.keyboard, filled: true, onTap: _openManual)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _bigButton('Verlauf', Icons.history, filled: false,
                          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => HistoryScreen(event: e)))),
                    ),
                  ]),
                ),
              ],
            ),
          ),
          if (_result != null) _resultOverlay(_result!),
          if (_alert != null) _alertOverlay(_alert!),
        ],
      ),
    );
  }

  Widget _header(PairedEvent e) {
    final subtitle = [if (e.venueName != null && e.venueName!.isNotEmpty) e.venueName!, _deviceName, if (_isDemo) 'Demo'].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 12, 0),
      child: Row(children: [
        IconButton(
          tooltip: 'Zurück',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 44),
          icon: const Icon(Icons.chevron_left, color: Colors.white, size: 28),
          onPressed: () => Navigator.pop(context),
        ),
        Image.asset('assets/images/logo-tile.png', width: 40, height: 40, fit: BoxFit.cover),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Via.h(18, color: Colors.white)),
            Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: .75))),
          ]),
        ),
        _squareButton(
          Sounds.enabled ? Icons.volume_up : Icons.volume_off,
          'Ton und Vibration',
          () => setState(() => Sounds.enabled = !Sounds.enabled),
        ),
        const SizedBox(width: 6),
        _squareButton(_torch ? Icons.flashlight_on : Icons.flashlight_off, _torch ? 'Licht aus' : 'Licht an', () async {
          try {
            await _cam.toggleTorch();
            if (mounted) setState(() => _torch = !_torch);
          } catch (_) {}
        }),
        PopupMenuButton<String>(
          icon: Badge(
            isLabelVisible: _openAlerts > 0,
            label: Text('$_openAlerts'),
            child: const Icon(Icons.more_vert, color: Colors.white),
          ),
          color: Colors.white,
          shape: Via.square,
          onSelected: (v) {
            switch (v) {
              case 'search':
                Navigator.push(context, MaterialPageRoute<void>(builder: (_) => SearchScreen(event: e, onManualCheckin: (t) => _checkin(t, 'manual_in'))));
                break;
              case 'exit':
                Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ExitListScreen(event: e, onCheckout: (t) => _checkin(t, 'out'))));
                break;
              case 'alerts':
                unawaited(_loadAlerts());
                break;
              case 'demo':
                unawaited(_simulateScan());
                break;
              case 'demoqr':
                Navigator.push(context, MaterialPageRoute<void>(builder: (_) => DemoTicketsScreen(event: e)));
                break;
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'search', child: ListTile(leading: Icon(Icons.search), title: Text('Namenssuche'))),
            if (e.youthMode) const PopupMenuItem(value: 'exit', child: ListTile(leading: Icon(Icons.exit_to_app), title: Text('Ausgang (Jugendschutz)'))),
            PopupMenuItem(value: 'alerts', child: ListTile(leading: const Icon(Icons.warning_amber), title: Text('Offene Meldungen ($_openAlerts)'))),
            if (_isDemo) const PopupMenuItem(value: 'demo', child: ListTile(leading: Icon(Icons.play_circle_outline), title: Text('Demo-Scan ausführen'))),
            if (_isDemo) const PopupMenuItem(value: 'demoqr', child: ListTile(leading: Icon(Icons.qr_code_2), title: Text('Demo-Tickets (QR)'))),
          ],
        ),
      ]),
    );
  }

  Widget _squareButton(IconData icon, String tooltip, VoidCallback onTap) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(border: Border.all(color: Colors.white.withValues(alpha: .3)), color: Colors.black.withValues(alpha: .25)),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ),
      );

  Widget _banner(String text) => Container(
        margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        padding: const EdgeInsets.all(12),
        color: Via.negative,
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
      );

  Widget _bigButton(String label, IconData icon, {required bool filled, required VoidCallback onTap}) => Material(
        color: filled ? Colors.white : Colors.black.withValues(alpha: .3),
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 60,
            decoration: filled ? null : BoxDecoration(border: Border.all(color: Colors.white.withValues(alpha: .4))),
            alignment: Alignment.center,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 20, color: filled ? Via.dunkelblau : Colors.white),
              const SizedBox(width: 10),
              Text(label, style: Via.h(17, color: filled ? Via.dunkelblau : Colors.white)),
            ]),
          ),
        ),
      );

  Widget _frame() {
    const size = 264.0;
    const corner = 44.0;
    const stroke = 5.0;
    Widget c(Alignment a, {bool l = false, bool r = false, bool t = false, bool b = false}) => Align(
          alignment: a,
          child: Container(
            width: corner,
            height: corner,
            decoration: BoxDecoration(
              border: Border(
                left: l ? const BorderSide(color: Via.hellblau, width: stroke) : BorderSide.none,
                right: r ? const BorderSide(color: Via.hellblau, width: stroke) : BorderSide.none,
                top: t ? const BorderSide(color: Via.hellblau, width: stroke) : BorderSide.none,
                bottom: b ? const BorderSide(color: Via.hellblau, width: stroke) : BorderSide.none,
              ),
            ),
          ),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: size,
        height: size,
        child: Stack(children: [
          c(Alignment.topLeft, l: true, t: true),
          c(Alignment.topRight, r: true, t: true),
          c(Alignment.bottomLeft, l: true, b: true),
          c(Alignment.bottomRight, r: true, b: true),
          AnimatedBuilder(
            animation: _line,
            builder: (_, __) => Positioned(
              left: 14,
              right: 14,
              top: 16 + (size - 34) * Curves.easeInOut.transform(_line.value),
              child: Container(
                height: 2,
                decoration: BoxDecoration(color: Via.hellblau, boxShadow: [BoxShadow(color: Via.hellblau.withValues(alpha: .7), blurRadius: 14, spreadRadius: 2)]),
              ),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 22),
      Text('QR-Code in den Rahmen halten', style: Via.h(20, color: Colors.white)),
      const SizedBox(height: 4),
      Text(
        _isDemo ? 'Demo: Menü oben rechts → „Demo-Scan ausführen"' : 'Papier, PDF oder Wallet – es zählt der erste Scan',
        style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: .6)),
      ),
    ]);
  }

  IconData _stateIconData() {
    if (_isHub) return Icons.wifi_tethering;
    switch (_state) {
      case SyncState.online:
        return Icons.cloud_done;
      case SyncState.offline:
        return Icons.cloud_off;
      case SyncState.unauthorized:
        return Icons.link_off;
    }
  }

  String _stateText() {
    final out = _counts['out'] ?? 0;
    final parts = <String>[];
    if (_isHub) parts.add('Hub aktiv');
    switch (_state) {
      case SyncState.online:
        parts.add(_isDemo ? 'Demo – nur lokal' : (widget.event.baseUrl.startsWith('http://') ? 'Verbunden mit Hub' : 'Online – Sync läuft'));
        break;
      case SyncState.offline:
        parts.add('Offline – Scans werden nachgereicht');
        break;
      case SyncState.unauthorized:
        parts.add('Gerät widerrufen');
        break;
    }
    if (out > 0) parts.add('$out draußen');
    return parts.join(' · ');
  }

  /* ------------------------------------------------- Ergebnis-Overlay */

  Widget _resultOverlay(ScanResult r) {
    final ok = r.verdict == ScanVerdict.ok;
    final amber = r.verdict == ScanVerdict.alreadyIn || r.verdict == ScanVerdict.checkedOut;
    final Color bg = ok ? Via.positive : (amber ? Via.attention : Via.negative);
    final Color fg = amber ? Via.ink : Colors.white;
    final t = r.ticket;
    final title = switch (r.verdict) {
      ScanVerdict.ok => 'Gültig',
      ScanVerdict.alreadyIn => 'Bereits eingelöst',
      ScanVerdict.checkedOut => 'Wieder da',
      ScanVerdict.forged => 'Fälschung',
      ScanVerdict.cancelled => 'Storniert',
      ScanVerdict.wrongEvent => 'Falsches Event',
      ScanVerdict.invalid => 'Ungültig',
    };
    final instruction = switch (r.verdict) {
      ScanVerdict.ok => 'Person einlassen',
      ScanVerdict.checkedOut => r.message ?? '',
      ScanVerdict.alreadyIn => 'Nicht einlassen – Einlassleitung rufen',
      _ => 'Nicht einlassen – Einlassleitung rufen',
    };
    final icon = switch (r.verdict) {
      ScanVerdict.ok => Icons.check_circle,
      ScanVerdict.alreadyIn => Icons.warning_amber_rounded,
      ScanVerdict.checkedOut => Icons.meeting_room,
      _ => Icons.cancel,
    };

    // Fakten für die weiße Karte.
    final facts = <MapEntry<String, String>>[];
    if (t != null) {
      if (t.type != null && t.type!.isNotEmpty) facts.add(MapEntry('Kategorie', t.type!));
      facts.add(MapEntry('Ticket', t.no));
      if (t.orderId != null) facts.add(MapEntry('Bestellung', '#${t.orderId}'));
      if (t.options.isNotEmpty) facts.add(MapEntry('Optionen', t.options.join(', ')));
      if (r.verdict == ScanVerdict.alreadyIn && _conflictInfo != null) {
        final at = asStr(_conflictInfo!['scanned_at']) ?? '';
        facts.add(MapEntry('Eingelöst um', at.length >= 16 ? '${at.substring(11, 16)} Uhr' : at));
        final dev = asStr(_conflictInfo!['device_name']) ?? '';
        if (dev.isNotEmpty) facts.add(MapEntry('Eingang', dev));
      }
      if (widget.event.youthMode) {
        facts.add(MapEntry('Alter', t.age == null ? 'unbekannt – ausweisen lassen' : '${t.age} Jahre${t.ampel == 'red' ? ' – ausweisen lassen' : ''}'));
        if (t.curfewEnd != null && t.curfewEnd!.isNotEmpty) facts.add(MapEntry('Bleiben bis', '${t.curfewEnd} Uhr'));
        facts.add(MapEntry('Muttizettel', t.muttizettel ? 'liegt vor' : 'keiner'));
      }
    } else if (r.message != null) {
      facts.add(MapEntry('Grund', r.message!));
    }
    final seat = t == null ? '' : [if (t.table != null && t.table!.isNotEmpty) t.table!, if (t.seat != null && t.seat!.isNotEmpty) t.seat!].join(' · ');

    double remain = 0;
    if (ok && _resultAt != null) {
      final el = DateTime.now().difference(_resultAt!).inMilliseconds / _autoCloseOk.inMilliseconds;
      remain = (1 - el).clamp(0.0, 1.0);
    }
    final secs = (remain * _autoCloseOk.inSeconds).ceil().clamp(1, _autoCloseOk.inSeconds);

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _closeResult,
        child: Container(
          color: bg,
          child: SafeArea(
            child: Column(children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(icon, size: 76, color: fg),
                    const SizedBox(height: 12),
                    Text(title.toUpperCase(), style: Via.h(48, weight: FontWeight.w800, color: fg, height: 1)),
                    const SizedBox(height: 10),
                    Text(instruction, style: Via.h(24, color: fg, height: 1.25)),
                    if (t == null && r.message != null && r.verdict != ScanVerdict.invalid) ...[
                      const SizedBox(height: 6),
                      Text(r.message!, style: TextStyle(fontSize: 16, color: fg.withValues(alpha: .85))),
                    ],
                  ]),
                ),
              ),
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(20),
                color: Colors.white,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t != null ? 'TICKETINHABER' : 'GESCANNTER CODE', style: const TextStyle(fontSize: 13, letterSpacing: 1, color: Via.fg2)),
                  const SizedBox(height: 2),
                  Text(
                    t != null ? (t.name != null && t.name!.isNotEmpty ? t.name! : '(ohne Namen)') : (_lastRaw ?? '–'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Via.h(30, weight: FontWeight.w800, color: Via.dunkelblau, height: 1.1),
                  ),
                  if (seat.isNotEmpty) ...[
                    const Divider(height: 24),
                    const Text('Platz', style: TextStyle(fontSize: 13, color: Via.fg2)),
                    Text(seat, style: Via.h(_event.showSeat ? 30 : 18, weight: _event.showSeat ? FontWeight.w800 : FontWeight.w700, color: Via.ink, height: 1.15)),
                  ],
                  if (facts.isNotEmpty) ...[
                    const Divider(height: 24),
                    Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      children: [
                        for (final f in facts)
                          SizedBox(
                            width: (MediaQuery.of(context).size.width - 32 - 40 - 16) / 2,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(f.key, style: const TextStyle(fontSize: 13, color: Via.fg2)),
                              Text(f.value, style: Via.h(18, color: Via.ink, height: 1.2)),
                            ]),
                          ),
                      ],
                    ),
                  ],
                  if (t != null && r.verdict == ScanVerdict.alreadyIn) ...[
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.logout),
                      label: const Text('Auslass buchen (Gast geht)'),
                      onPressed: () => unawaited(_bookFromOverlay(t, 'out', 'Auslass gebucht')),
                    ),
                  ],
                  if (t != null && r.verdict == ScanVerdict.checkedOut) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      icon: const Icon(Icons.login),
                      label: const Text('Wiedereinlass buchen'),
                      onPressed: () => unawaited(_bookFromOverlay(t, 'in', 'Wiedereinlass gebucht')),
                    ),
                  ],
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
                child: Column(children: [
                  Container(
                    height: 5,
                    color: fg.withValues(alpha: amber ? .2 : .3),
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(widthFactor: ok ? remain : 1, child: Container(color: fg)),
                  ),
                  const SizedBox(height: 10),
                  Text(ok ? 'Tippen zum Weiterscannen · automatisch in $secs s' : 'Tippen zum Weiterscannen', style: TextStyle(fontSize: 15, color: fg)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /* --------------------------------------------------- Alarm-Overlay */

  /// Sync-Alarm (Doppelscan vom Server gemeldet, Ablehnung, Serverfehler) – muss quittiert werden.
  Widget _alertOverlay(SyncAlert a) {
    final t = _alertTicket;
    return Positioned.fill(
      child: Container(
        color: Via.negative,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Icon(Icons.sync_problem, size: 76, color: Colors.white),
              const SizedBox(height: 12),
              Text('MELDUNG', style: Via.h(40, weight: FontWeight.w800, color: Colors.white, height: 1)),
              const SizedBox(height: 8),
              Text(_openAlerts > 1 ? '$_openAlerts offene Meldungen – älteste zuerst' : 'Vom Server nach dem Sync gemeldet', style: const TextStyle(color: Colors.white70, fontSize: 15)),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(20),
                color: Colors.white,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (t != null) Text(_displayName(t), style: Via.h(26, weight: FontWeight.w800, color: Via.dunkelblau)),
                  if (t != null) Text('${t.type ?? ''} · ${t.no}', style: const TextStyle(color: Via.fg2)),
                  if (t != null) const SizedBox(height: 10),
                  Text(a.message, style: const TextStyle(fontSize: 17, color: Via.ink, height: 1.4)),
                  const SizedBox(height: 6),
                  Text('Gemeldet um ${a.createdAt.length >= 16 ? a.createdAt.substring(11, 16) : a.createdAt} Uhr', style: const TextStyle(fontSize: 13, color: Via.fg3)),
                ]),
              ),
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Via.negative, minimumSize: const Size.fromHeight(56)),
                onPressed: () => unawaited(_acknowledge(a)),
                child: const Text('Gesehen – weiter'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
