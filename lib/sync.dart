/// Offline-First-Sync (Konzept 4.3):
/// - Voll-Manifest nach Pairing, danach Delta-Polling alle 5 s
/// - Batch-Push aller lokalen Scans (idempotent über client_uuid, 200 je Batch)
/// - Konflikte, Ablehnungen und Serverfehler landen als Sync-Alarme in SQLite
///   und werden dem Personal zum Quittieren angezeigt (F11/F12)
/// - 401/403 (Token widerrufen/abgelaufen) ist KEIN Offline-Zustand (F10)
library;
import 'dart:async';

import 'package:intl/intl.dart';

import 'api.dart';
import 'db.dart';
import 'models.dart';

enum SyncState { online, offline, unauthorized }

/// Batchgröße für POST /scan/checkins.
const int syncBatchSize = 200;

/// Deutsche Übersetzung der `invalid`-Gründe aus /scan/checkins.
String translateInvalidReason(String? reason) {
  switch (reason) {
    case 'cancelled':
      return 'Ticket ist storniert.';
    case 'unknown_ticket':
      return 'Ticket ist dem Server nicht bekannt.';
    case 'missing_fields':
      return 'Scan-Daten unvollständig übertragen.';
    case 'reentry_disabled':
      return 'Wiedereinlass ist bei diesem Event nicht erlaubt.';
    case 'not_checked_in':
      return 'Gast war laut Server nicht eingecheckt (Auslass abgelehnt).';
    case 'db_error':
      return 'Datenbankfehler im Shop.';
    default:
      return 'Unbekannter Grund${reason == null || reason.isEmpty ? '' : ' ($reason)'}.';
  }
}

class SyncService {
  final PairedEvent event;

  /// Neuer Alarm wurde in SQLite gespeichert (Anzeige aktualisieren).
  final void Function(SyncAlert alert)? onAlert;
  final void Function(SyncState state)? onStatus;

  /// Einstellungen vom Server/Hub haben sich geändert (z. B. Platzanzeige).
  final void Function()? onSettings;

  Timer? _timer;
  bool _busy = false;
  bool _unauthorized = false;
  int _cursor;

  SyncService(this.event, {this.onAlert, this.onStatus, this.onSettings})
      : _cursor = event.cursor;

  /// Demo-Event: kein Server, alles bleibt lokal.
  bool get _isDemo => event.baseUrl.startsWith('demo://');

  ScanApi get _api => ScanApi(event.baseUrl, token: event.deviceToken);

  bool get unauthorized => _unauthorized;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => tick());
    tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Volles Manifest laden. Liefert die Anzahl übernommener Tickets.
  Future<int> fullSync() async {
    final data = await _api.manifest();
    final tickets = _parseTickets(data);
    await AppDb.upsertTickets(event.localId, tickets);
    await _storeCursor(data);
    return tickets.length;
  }

  Future<void> tick() async {
    if (_busy || _unauthorized) return;
    if (_isDemo) {
      onStatus?.call(SyncState.online);
      return;
    }
    _busy = true;
    try {
      await pushPending();
      final data = await _api.manifest(since: _cursor);
      final tickets = _parseTickets(data);
      if (tickets.isNotEmpty) {
        await AppDb.upsertTickets(event.localId, tickets);
      }
      await _storeCursor(data);
      await _applySettings(data);
      onStatus?.call(SyncState.online);
    } catch (e) {
      if (ScanApi.isUnauthorized(e)) {
        // Gerät widerrufen oder Token abgelaufen: Polling einstellen,
        // lokal weiterscannen bleibt möglich, Scans bleiben in der Queue.
        _unauthorized = true;
        stop();
        onStatus?.call(SyncState.unauthorized);
      } else {
        // Offline ist ein Normalzustand – lokal weiterscannen, später syncen.
        onStatus?.call(SyncState.offline);
      }
    } finally {
      _busy = false;
    }
  }

  /// Einmaliger Hintergrund-Sync aller gekoppelten Events (App-Start).
  /// Best-effort: Fehler werden verschluckt, nichts blockiert die UI.
  static Future<void> syncAllOnce() async {
    try {
      final events = await AppDb.events();
      for (final e in events) {
        if (e.deviceToken.isEmpty || e.baseUrl.startsWith('demo://')) continue;
        await SyncService(e).tick();
      }
    } catch (_) {
      // bewusst still
    }
  }

  /* -------------------------------------------------------- intern */

  List<Ticket> _parseTickets(Map<String, dynamic> data) {
    final raw = data['tickets'];
    if (raw is! List) return const [];
    final out = <Ticket>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final t = Ticket.tryFromJson(Map<String, dynamic>.from(item));
      if (t != null) out.add(t);
    }
    return out;
  }

  /// Ab hier gilt ein gespeicherter Cursor als alter Unix-Timestamp (App 0.9.0);
  /// der Server antwortet darauf mit einem Vollabgleich und einem kleinen
  /// Versions-Cursor, der übernommen werden muss, obwohl er „kleiner" ist.
  static const int _legacyCursorMin = 1000000000;

  /// `settings.show_seat` aus Manifest (Hub oder Shop) lokal übernehmen.
  Future<void> _applySettings(Map<String, dynamic> data) async {
    final s = data['settings'];
    if (s is! Map || !s.containsKey('show_seat')) return;
    final want = asBool(s['show_seat']);
    final current = await AppDb.eventById(event.localId);
    if (current != null && current.showSeat != want) {
      await AppDb.setShowSeat(event.localId, want);
      onSettings?.call();
    }
  }

  Future<void> _storeCursor(Map<String, dynamic> data) async {
    // Cursor ist ein opaker, monoton steigender Integer; nie rückwärts.
    final c = asInt(data['cursor']);
    if (c == null) return;
    if (c < _cursor && _cursor < _legacyCursorMin) return;
    _cursor = c;
    await AppDb.setCursor(event.localId, _cursor);
  }

  /// Alle offenen Scans in Batches von [syncBatchSize] übertragen.
  /// Wirft bei Netzwerk-/Auth-Fehlern (Aufrufer entscheidet).
  Future<void> pushPending() async {
    final pending = await AppDb.pendingCheckins(event.localId);
    if (pending.isEmpty) return;

    for (var i = 0; i < pending.length; i += syncBatchSize) {
      final end = (i + syncBatchSize < pending.length)
          ? i + syncBatchSize
          : pending.length;
      await _pushBatch(pending.sublist(i, end));
    }
  }

  Future<void> _pushBatch(List<Map<String, Object?>> rows) async {
    final items = rows
        .map((r) => <String, dynamic>{
              'client_uuid': r['client_uuid'],
              'ticket_uuid': r['ticket_uuid'],
              'action': r['action'],
              'scanned_at': r['scanned_at'],
              if ((asStr(r['device_name']) ?? '').isNotEmpty) 'device_name': r['device_name'],
            })
        .toList();
    final byClient = {
      for (final it in items) (it['client_uuid'] as String?) ?? '': it
    };

    final results = await _api.pushCheckins(items);
    final done = <String>[];
    final now = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());

    for (final r in results) {
      if (r is! Map) continue;
      final m = Map<String, dynamic>.from(r);
      final clientUuid = asStr(m['client_uuid']) ?? '';
      final item = byClient[clientUuid];
      // Geister-Ergebnisse ohne bekannte client_uuid ignorieren.
      if (clientUuid.isEmpty || item == null) continue;

      final ticketUuid = asStr(item['ticket_uuid']) ?? '';
      final action = asStr(item['action']) ?? '';
      final result = asStr(m['result']);

      switch (result) {
        case 'ok':
          done.add(clientUuid);
          break;
        case 'conflict':
          done.add(clientUuid);
          final c = m['conflict'] is Map
              ? Map<String, dynamic>.from(m['conflict'] as Map)
              : const <String, dynamic>{};
          await _alert(
            ticketUuid: ticketUuid,
            kind: 'conflict',
            message: 'Bereits eingelassen um '
                '${_clock(asStr(c['first_scanned_at']))} an Gerät '
                '„${asStr(c['device_name']) ?? 'unbekannt'}". '
                'Gast prüfen: Ist die Person schon im Haus?',
            createdAt: now,
          );
          break;
        case 'invalid':
          done.add(clientUuid);
          // Der Server nennt den tatsächlichen Ticketstatus mit – lokal
          // übernehmen, damit die Anzeige der Serverwahrheit entspricht.
          final serverStatus = asStr(m['status']);
          if (serverStatus != null &&
              _ticketStatuses.contains(serverStatus) &&
              ticketUuid.isNotEmpty) {
            await AppDb.setTicketStatus(
                event.localId, ticketUuid, serverStatus);
          }
          await _alert(
            ticketUuid: ticketUuid,
            kind: 'invalid',
            message: '${_actionLabel(action)} vom Server abgelehnt: '
                '${translateInvalidReason(asStr(m['reason']))}',
            createdAt: now,
          );
          break;
        case 'error':
          // Serverseitiger Fehler beim Verbuchen. Der Scan wird aus der Queue
          // genommen (sonst Endlosschleife) und als Alarm gemeldet.
          done.add(clientUuid);
          final detail = asStr(m['reason']) ?? asStr(m['message']);
          await _alert(
            ticketUuid: ticketUuid,
            kind: 'error',
            message: '${_actionLabel(action)} konnte auf dem Server nicht '
                'verbucht werden'
                '${detail == null ? '.' : ' (${translateInvalidReason(detail)})'}'
                ' Ticket manuell im Backend prüfen.',
            createdAt: now,
          );
          break;
        default:
          // Unbekanntes Ergebnis: in der Queue lassen, nächster Tick.
          break;
      }
    }
    await AppDb.clearPending(done);
  }

  Future<void> _alert({
    required String ticketUuid,
    required String kind,
    required String message,
    required String createdAt,
  }) async {
    final id = await AppDb.addAlert(
      localEventId: event.localId,
      ticketUuid: ticketUuid,
      kind: kind,
      message: message,
      createdAt: createdAt,
    );
    onAlert?.call(SyncAlert(
      id: id,
      localEventId: event.localId,
      ticketUuid: ticketUuid,
      kind: kind,
      message: message,
      createdAt: createdAt,
      acknowledged: false,
    ));
  }

  static const Set<String> _ticketStatuses = {
    'valid',
    'checked_in',
    'checked_out',
    'cancelled',
  };

  static String _actionLabel(String action) {
    switch (action) {
      case 'out':
        return 'Auslass';
      case 'manual_in':
        return 'Manueller Einlass';
      default:
        return 'Einlass';
    }
  }

  /// "2026-08-15 20:29:55" → "20:29"; sonst der Rohwert oder "?".
  static String _clock(String? ts) {
    if (ts == null || ts.isEmpty) return '?';
    if (ts.length >= 16 && ts[10] == ' ') return ts.substring(11, 16);
    return ts;
  }
}
