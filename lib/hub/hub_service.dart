/// Lokaler Hub (Konzept „TicketCreator im Saal", 01.10.2026): Dieses Gerät verteilt die
/// Gästeliste eines gekoppelten Events an Scanner im WLAN, sammelt deren Scans,
/// verhindert Doppelnutzung über alle Geräte und reicht alle Scans gesammelt an
/// den Shop nach, sobald es wieder online ist (normale SyncService-Queue).
///
/// Datenhaltung:
/// - `tickets.version`      lokale, monoton steigende Version je Ticket → Delta-Manifest für Scanner
/// - `checkin_log`          append-only Journal aller Scans (Hub + Scanner), Idempotenz über client_uuid
/// - `hub_clients`          gekoppelte Scanner (Name, Token, zuletzt gesehen, Scans)
/// - `pending_checkins`     Queue an den Shop (bestehend), Hub schreibt auch fremde Scans hinein
library;
import 'dart:convert';
import 'dart:math';

import 'package:intl/intl.dart';

import '../db.dart';
import '../models.dart';
import 'hub_rules.dart';

class HubClient {
  final int id;
  final String name;
  final String token;
  final String pairedAt;
  final String? lastSeen;
  final int scans;
  final bool revoked;
  const HubClient({
    required this.id,
    required this.name,
    required this.token,
    required this.pairedAt,
    this.lastSeen,
    this.scans = 0,
    this.revoked = false,
  });

  factory HubClient.fromRow(Map<String, Object?> r) => HubClient(
        id: asInt(r['id']) ?? 0,
        name: asStr(r['name']) ?? '',
        token: asStr(r['token']) ?? '',
        pairedAt: asStr(r['paired_at']) ?? '',
        lastSeen: asStr(r['last_seen']),
        scans: asInt(r['scans']) ?? 0,
        revoked: asInt(r['revoked']) == 1,
      );
}

class HubService {
  final PairedEvent event;
  final String hubName;

  /// Pairing-Code (6 Zeichen, ohne verwechselbare Buchstaben) und Ablauf.
  String? _code;
  DateTime? _codeExpires;

  static const Duration codeValidity = Duration(minutes: 10);
  static final Random _rnd = Random.secure();
  static final DateFormat _fmt = DateFormat('yyyy-MM-dd HH:mm:ss');

  HubService(this.event, {required this.hubName});

  static String now() => _fmt.format(DateTime.now());

  /* ------------------------------------------------------------ Pairing */

  String get code {
    if (_code == null || _codeExpires == null || DateTime.now().isAfter(_codeExpires!)) {
      regenerateCode();
    }
    return _code!;
  }

  DateTime get codeExpires => _codeExpires ?? DateTime.now();

  void regenerateCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    _code = List.generate(6, (_) => alphabet[_rnd.nextInt(alphabet.length)]).join();
    _codeExpires = DateTime.now().add(codeValidity);
  }

  /// Pairing-Payload für den QR – gleiches Format wie der Shop (`viat-pair`),
  /// zusätzlich `hub` mit dem Hub-Namen.
  String pairingPayload(String baseUrl) => jsonEncode({
        'v': 1,
        'type': 'viat-pair',
        'url': baseUrl,
        'event_id': event.eventId,
        'code': code,
        'hub': hubName,
      });

  static String _token() {
    final bytes = List<int>.generate(32, (_) => _rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Code einlösen → neuer Client. Liefert null bei falschem/abgelaufenem Code.
  Future<HubClient?> redeem(String code, String name) async {
    if (_code == null || _codeExpires == null) return null;
    if (code.trim().toUpperCase() != _code || DateTime.now().isAfter(_codeExpires!)) {
      return null;
    }
    final token = _token();
    final label = name.trim().isEmpty ? 'Scanner ${await AppDb.hubClientCount(event.localId) + 1}' : name.trim();
    final id = await AppDb.addHubClient(event.localId, name: label, token: token, pairedAt: now());
    return HubClient(id: id, name: label, token: token, pairedAt: now());
  }

  Future<HubClient?> clientByToken(String token) async {
    if (token.isEmpty) return null;
    final row = await AppDb.hubClientByToken(event.localId, token);
    if (row == null) return null;
    final c = HubClient.fromRow(row);
    if (c.revoked) return null;
    await AppDb.touchHubClient(c.id, now());
    return c;
  }

  Future<List<HubClient>> clients() async =>
      (await AppDb.hubClientRows(event.localId)).map(HubClient.fromRow).toList();

  Future<void> revokeClient(int id) => AppDb.revokeHubClient(id);

  /* ------------------------------------------------------------- Event */

  /// Event-Daten wie `event_payload()` im Plugin, plus Hub-Einstellungen.
  Future<Map<String, dynamic>> eventPayload() async {
    final e = await AppDb.eventById(event.localId) ?? event;
    return {
      'id': e.eventId,
      'title': e.title,
      'venue_name': e.venueName,
      'starts_at': e.startsAt,
      'doors_at': null,
      'ends_at': e.endsAt,
      'timezone': 'Europe/Berlin',
      'reentry': e.reentry,
      'youth_mode': e.youthMode,
      'seating': true,
      'name_capture': 'optional',
      'show_seat': e.showSeat,
      'hub': hubName,
    };
  }

  Future<Map<String, dynamic>> settings() async {
    final e = await AppDb.eventById(event.localId) ?? event;
    return {'show_seat': e.showSeat, 'hub': hubName};
  }

  /* ---------------------------------------------------------- Manifest */

  /// Manifest für Scanner: alle Tickets (since = 0) oder Delta (version > since).
  Future<Map<String, dynamic>> manifest(int since) async {
    final cursor = await AppDb.hubVersion(event.localId);
    final rows = await AppDb.ticketRowsSince(event.localId, since);
    final tickets = rows.map((r) {
      final t = Ticket.fromRow(r);
      return {
        'uuid': t.uuid,
        'no': t.no,
        'status': t.status,
        'type': t.type,
        'name': t.name,
        'order_id': t.orderId,
        'options': t.options,
        'age': t.age,
        'ampel': t.ampel,
        'curfew_end': t.curfewEnd,
        'muttizettel': t.muttizettel,
        'table': t.table,
        'seat': t.seat,
        'version': asInt(r['version']) ?? 0,
      };
    }).toList();
    return {
      'event_id': event.eventId,
      'cursor': cursor,
      'full': since <= 0,
      'tickets': tickets,
      'settings': await settings(),
    };
  }

  /* ---------------------------------------------------------- Check-ins */

  /// Scans verbuchen (vom Hub selbst oder von einem Scanner). Antwortformat wie der Shop.
  /// Jeder Scan landet im Journal; gültige Scans ändern den Ticketstatus, erhöhen die
  /// Ticketversion und werden für den Shop in `pending_checkins` eingereiht.
  Future<List<Map<String, dynamic>>> applyCheckins(
    List<dynamic> items, {
    required String deviceName,
    int? clientId,
  }) async {
    final results = <Map<String, dynamic>>[];
    final e = await AppDb.eventById(event.localId) ?? event;
    for (final raw in items) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final clientUuid = (asStr(item['client_uuid']) ?? '').toLowerCase();
      final ticketUuid = (asStr(item['ticket_uuid']) ?? '').toLowerCase();
      final action = const {'in', 'out', 'manual_in'}.contains(item['action']) ? item['action'] as String : 'in';
      final scannedAt = _sanitizeScannedAt(asStr(item['scanned_at']));

      if (!isUuid(clientUuid) || !isUuid(ticketUuid)) {
        results.add({'client_uuid': clientUuid, 'result': 'invalid', 'reason': 'missing_fields'});
        continue;
      }
      if (await AppDb.checkinLogged(clientUuid)) {
        results.add({'client_uuid': clientUuid, 'result': 'ok', 'duplicate': true});
        continue;
      }
      final ticket = await AppDb.ticketByUuid(event.localId, ticketUuid);
      if (ticket == null) {
        results.add({'client_uuid': clientUuid, 'result': 'invalid', 'reason': 'unknown_ticket'});
        continue;
      }

      final d = decideCheckin(ticket.status, action, reentry: e.reentry);
      await AppDb.logCheckin(
        clientUuid: clientUuid,
        localEventId: event.localId,
        ticketUuid: ticketUuid,
        action: action,
        result: d.outcome,
        scannedAt: scannedAt,
        deviceName: deviceName,
      );
      if (clientId != null) await AppDb.countHubClientScan(clientId);

      if (d.outcome == 'conflict') {
        results.add({'client_uuid': clientUuid, 'result': 'conflict', 'conflict': await _conflictInfo(ticketUuid)});
        continue;
      }
      if (d.outcome == 'invalid') {
        results.add({'client_uuid': clientUuid, 'result': 'invalid', 'reason': d.reason, 'status': ticket.status});
        continue;
      }
      await AppDb.setTicketStatus(event.localId, ticketUuid, d.newStatus!, bumpVersion: true);
      // An den Shop weiterreichen, sobald der Hub online ist (gleiche Queue wie Scanner).
      await AppDb.queueCheckin(
        clientUuid: clientUuid,
        localEventId: event.localId,
        ticketUuid: ticketUuid,
        action: action,
        scannedAt: scannedAt,
        deviceName: deviceName,
      );
      results.add({'client_uuid': clientUuid, 'result': 'ok', 'status': d.newStatus});
    }
    return results;
  }

  Future<Map<String, dynamic>> _conflictInfo(String ticketUuid) async {
    final first = await AppDb.lastOkEntry(event.localId, ticketUuid);
    return {
      'first_scanned_at': first?['scanned_at'],
      'first_synced_at': first?['scanned_at'],
      'device_name': first?['device_name'],
    };
  }

  static String _sanitizeScannedAt(String? v) {
    if (v == null || !RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$').hasMatch(v)) {
      return now();
    }
    try {
      final t = _fmt.parseStrict(v);
      if (t.isAfter(DateTime.now().add(const Duration(minutes: 5)))) return now();
      return v;
    } catch (_) {
      return now();
    }
  }

  /* -------------------------------------------------------------- Stats */

  /// Zähler für die Zählertafel: gesamt, drin, draußen, offen, je Gerät.
  Future<Map<String, dynamic>> stats() async {
    final c = await AppDb.counts(event.localId);
    final perDevice = await AppDb.scansPerDevice(event.localId);
    final pending = await AppDb.pendingCount(event.localId);
    return {
      'total': c['total'],
      'in': c['in'],
      'out': c['out'],
      'open': (c['total'] ?? 0) - (c['in'] ?? 0) - (c['out'] ?? 0),
      'devices': perDevice,
      'pending_to_shop': pending,
      'recent': await AppDb.recentLog(event.localId, 8),
    };
  }
}
