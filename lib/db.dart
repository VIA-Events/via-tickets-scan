/// Lokale SQLite-DB: gekoppelte Events, Offline-Manifest, Scan-Queue,
/// Sync-Alarme. Gerätetoken und Event-Secret liegen NICHT hier, sondern im
/// Secure Storage (siehe secure_store.dart); die Spalten bleiben als leere
/// Platzhalter für die Migration von Version 1 erhalten.
library;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'secure_store.dart';

class AppDb {
  static Database? _db;

  static const _createSyncAlerts = '''
          CREATE TABLE IF NOT EXISTS sync_alerts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            local_event_id INTEGER NOT NULL,
            ticket_uuid TEXT NOT NULL DEFAULT '',
            kind TEXT NOT NULL,
            message TEXT NOT NULL,
            created_at TEXT NOT NULL,
            acknowledged INTEGER NOT NULL DEFAULT 0
          )''';

  static const _indexSyncAlerts = '''
          CREATE INDEX IF NOT EXISTS idx_sync_alerts_open
            ON sync_alerts(local_event_id, acknowledged, id)''';

  // v3 (Hub-Modus): gekoppelte Scanner und Scan-Journal des Hubs.
  static const _createHubClients = '''
          CREATE TABLE IF NOT EXISTS hub_clients(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            local_event_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            token TEXT NOT NULL,
            paired_at TEXT NOT NULL,
            last_seen TEXT,
            scans INTEGER NOT NULL DEFAULT 0,
            revoked INTEGER NOT NULL DEFAULT 0
          )''';
  static const _createCheckinLog = '''
          CREATE TABLE IF NOT EXISTS checkin_log(
            client_uuid TEXT PRIMARY KEY,
            local_event_id INTEGER NOT NULL,
            ticket_uuid TEXT NOT NULL,
            action TEXT NOT NULL,
            result TEXT NOT NULL,
            scanned_at TEXT NOT NULL,
            device_name TEXT NOT NULL DEFAULT ''
          )''';
  static const _indexCheckinLog = '''
          CREATE INDEX IF NOT EXISTS idx_checkin_log_ticket
            ON checkin_log(local_event_id, ticket_uuid, scanned_at)''';

  static Future<Database> get db async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'via_tickets_scan.db'),
      version: 3,
      onCreate: (d, v) async {
        await d.execute('''
          CREATE TABLE events(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            base_url TEXT NOT NULL,
            event_id INTEGER NOT NULL,
            title TEXT NOT NULL,
            venue_name TEXT,
            starts_at TEXT,
            ends_at TEXT,
            reentry INTEGER NOT NULL DEFAULT 0,
            youth_mode INTEGER NOT NULL DEFAULT 0,
            device_token TEXT NOT NULL DEFAULT '',
            hmac_secret TEXT NOT NULL DEFAULT '',
            cursor INTEGER NOT NULL DEFAULT 0,
            is_hub INTEGER NOT NULL DEFAULT 0,
            device_name TEXT NOT NULL DEFAULT '',
            show_seat INTEGER NOT NULL DEFAULT 0,
            hub_version INTEGER NOT NULL DEFAULT 0,
            UNIQUE(base_url, event_id)
          )''');
        await d.execute('''
          CREATE TABLE tickets(
            local_event_id INTEGER NOT NULL,
            uuid TEXT NOT NULL,
            no TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'valid',
            type TEXT, name TEXT, order_id INTEGER, options TEXT,
            age INTEGER, ampel TEXT, curfew_end TEXT,
            muttizettel INTEGER NOT NULL DEFAULT 0,
            table_name TEXT, seat TEXT,
            version INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(local_event_id, uuid)
          )''');
        await d.execute('''
          CREATE TABLE pending_checkins(
            client_uuid TEXT PRIMARY KEY,
            local_event_id INTEGER NOT NULL,
            ticket_uuid TEXT NOT NULL,
            action TEXT NOT NULL,
            scanned_at TEXT NOT NULL,
            device_name TEXT NOT NULL DEFAULT ''
          )''');
        await d.execute(_createSyncAlerts);
        await d.execute(_indexSyncAlerts);
        await d.execute(_createHubClients);
        await d.execute(_createCheckinLog);
        await d.execute(_indexCheckinLog);
      },
      onUpgrade: (d, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // v2: Bestellnummer im Manifest, Sync-Alarme (F11/F12).
          if (!await _hasColumn(d, 'tickets', 'order_id')) {
            await d.execute('ALTER TABLE tickets ADD COLUMN order_id INTEGER');
          }
          await d.execute(_createSyncAlerts);
          await d.execute(_indexSyncAlerts);
          // Cursor war in v1 ein Unix-Timestamp; ab v2 eine Versionsnummer.
          // 0 erzwingt beim nächsten Tick einen Vollabgleich.
          await d.update('events', {'cursor': 0});
        }
        if (oldVersion < 3) {
          // v3: Hub-Modus (Scanner, Journal, Ticketversionen), Gerätename, Platzanzeige.
          for (final col in const [
            ['events', 'is_hub', 'INTEGER NOT NULL DEFAULT 0'],
            ['events', 'device_name', "TEXT NOT NULL DEFAULT ''"],
            ['events', 'show_seat', 'INTEGER NOT NULL DEFAULT 0'],
            ['events', 'hub_version', 'INTEGER NOT NULL DEFAULT 0'],
            ['tickets', 'version', 'INTEGER NOT NULL DEFAULT 0'],
            ['pending_checkins', 'device_name', "TEXT NOT NULL DEFAULT ''"],
          ]) {
            if (!await _hasColumn(d, col[0], col[1])) {
              await d.execute('ALTER TABLE ${col[0]} ADD COLUMN ${col[1]} ${col[2]}');
            }
          }
          await d.execute(_createHubClients);
          await d.execute(_createCheckinLog);
          await d.execute(_indexCheckinLog);
        }
      },
    );
    return _db!;
  }

  static Future<bool> _hasColumn(
      Database d, String table, String column) async {
    final info = await d.rawQuery('PRAGMA table_info($table)');
    return info.any((r) => asStr(r['name']) == column);
  }

  /* ------------------------------------------------------------ Events */

  static Future<List<PairedEvent>> events() async {
    final rows = await (await db).query('events', orderBy: 'starts_at DESC');
    final out = <PairedEvent>[];
    for (final r in rows) {
      out.add(await PairedEvent.load(r));
    }
    return out;
  }

  static Future<PairedEvent?> eventById(int localEventId) async {
    final rows = await (await db)
        .query('events', where: 'id = ?', whereArgs: [localEventId], limit: 1);
    if (rows.isEmpty) return null;
    return PairedEvent.load(rows.first);
  }

  /// Speichert ein gekoppeltes Event. Re-Pairing derselben Kombination
  /// (base_url, event_id) aktualisiert die bestehende Zeile und behält die
  /// lokale ID – so bleiben Manifest und ungesyncte Scans dem Event zugeordnet.
  /// Token und Secret wandern in den Secure Storage; SQLite erhält nur ''.
  static Future<int> saveEvent({
    required String baseUrl,
    required Map<String, dynamic> event,
    required String deviceToken,
    required String hmacSecret,
  }) async {
    final d = await db;
    final eventId = asInt(event['id']) ?? 0;
    final values = <String, Object?>{
      'base_url': baseUrl,
      'event_id': eventId,
      'title': asStr(event['title']) ?? '',
      'venue_name': asStr(event['venue_name']),
      'starts_at': asStr(event['starts_at']),
      'ends_at': asStr(event['ends_at']),
      'reentry': asBool(event['reentry']) ? 1 : 0,
      'youth_mode': asBool(event['youth_mode']) ? 1 : 0,
      'show_seat': asBool(event['show_seat'] ?? event['seating']) ? 1 : 0,
      'device_token': '',
      'hmac_secret': '',
      'cursor': 0, // nach (Re-)Pairing wird das volle Manifest geladen
    };

    final existing = await d.query('events',
        columns: ['id'],
        where: 'base_url = ? AND event_id = ?',
        whereArgs: [baseUrl, eventId],
        limit: 1);

    int localId;
    if (existing.isNotEmpty) {
      localId = asInt(existing.first['id']) ?? 0;
      await d.update('events', values, where: 'id = ?', whereArgs: [localId]);
    } else {
      localId = await d.insert('events', values);
    }

    await SecureStore.saveCredentials(localId,
        token: deviceToken, secret: hmacSecret);
    return localId;
  }

  static Future<void> setCursor(int localEventId, int cursor) async {
    await (await db).update('events', {'cursor': cursor},
        where: 'id = ?', whereArgs: [localEventId]);
  }

  /// Löscht alle lokalen Daten des Events. Secure-Storage-Einträge räumt der
  /// Aufrufer vorher ab (main.dart), damit die Reihenfolge Widerruf →
  /// Secrets → SQLite eingehalten wird.
  static Future<void> removeEvent(int localEventId) async {
    final d = await db;
    await d.delete('tickets',
        where: 'local_event_id = ?', whereArgs: [localEventId]);
    await d.delete('pending_checkins',
        where: 'local_event_id = ?', whereArgs: [localEventId]);
    await d.delete('sync_alerts',
        where: 'local_event_id = ?', whereArgs: [localEventId]);
    await d.delete('events', where: 'id = ?', whereArgs: [localEventId]);
  }

  /// Einmalige Migration beim App-Start: Klartext-Token/-Secret aus
  /// SQLite (Version 1) in den Secure Storage überführen und in SQLite leeren.
  /// Idempotent – bereits geleerte Zeilen werden übersprungen.
  static Future<void> migrateCredentialsToSecureStorage() async {
    final d = await db;
    final rows = await d.query('events',
        columns: ['id', 'device_token', 'hmac_secret'],
        where: "device_token != '' OR hmac_secret != ''");
    for (final r in rows) {
      final id = asInt(r['id']);
      if (id == null) continue;
      final token = asStr(r['device_token']) ?? '';
      final secret = asStr(r['hmac_secret']) ?? '';
      // Bereits vorhandene Secure-Storage-Werte nicht überschreiben.
      final haveToken = await SecureStore.token(id);
      final haveSecret = await SecureStore.secret(id);
      await SecureStore.saveCredentials(id,
          token: (haveToken != null && haveToken.isNotEmpty) ? haveToken : token,
          secret: (haveSecret != null && haveSecret.isNotEmpty)
              ? haveSecret
              : secret);
      await d.update('events', {'device_token': '', 'hmac_secret': ''},
          where: 'id = ?', whereArgs: [id]);
    }
  }

  /* ----------------------------------------------------------- Tickets */

  static Future<void> upsertTickets(
      int localEventId, List<Ticket> tickets) async {
    if (tickets.isEmpty) return;
    final d = await db;
    // Jede Änderung bekommt eine neue lokale Version (Delta-Manifest für Scanner am Hub).
    final base = await _reserveVersions(d, localEventId, tickets.length);
    final batch = d.batch();
    var i = 0;
    for (final t in tickets) {
      final row = t.toRow(localEventId);
      row['version'] = base + (++i);
      batch.insert('tickets', row, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Alle Tickets eines Events ersetzen (Demo-Event).
  static Future<void> replaceTickets(int localEventId, List<Ticket> tickets) async {
    final d = await db;
    await d.delete('tickets', where: 'local_event_id = ?', whereArgs: [localEventId]);
    await d.delete('checkin_log', where: 'local_event_id = ?', whereArgs: [localEventId]);
    await d.delete('pending_checkins', where: 'local_event_id = ?', whereArgs: [localEventId]);
    await upsertTickets(localEventId, tickets);
  }

  /// Reserviert [count] aufeinanderfolgende Versionsnummern; liefert den Stand davor.
  static Future<int> _reserveVersions(Database d, int localEventId, int count) async {
    final rows = await d.query('events', columns: ['hub_version'], where: 'id = ?', whereArgs: [localEventId], limit: 1);
    final current = rows.isEmpty ? 0 : (asInt(rows.first['hub_version']) ?? 0);
    await d.update('events', {'hub_version': current + count}, where: 'id = ?', whereArgs: [localEventId]);
    return current;
  }

  static Future<int> hubVersion(int localEventId) async {
    final rows = await (await db).query('events', columns: ['hub_version'], where: 'id = ?', whereArgs: [localEventId], limit: 1);
    return rows.isEmpty ? 0 : (asInt(rows.first['hub_version']) ?? 0);
  }

  /// Ticketzeilen mit Version > since (since 0 = alle, ohne Stornos nur wenn … nein: alle, der Scanner braucht Stornos).
  static Future<List<Map<String, Object?>>> ticketRowsSince(int localEventId, int since) async {
    return (await db).query('tickets',
        where: 'local_event_id = ? AND version > ?', whereArgs: [localEventId, since], orderBy: 'version');
  }

  static Future<Ticket?> ticketByUuid(int localEventId, String uuid) async {
    final rows = await (await db).query('tickets',
        where: 'local_event_id = ? AND uuid = ?',
        whereArgs: [localEventId, uuid],
        limit: 1);
    return rows.isEmpty ? null : Ticket.fromRow(rows.first);
  }

  static Future<void> setTicketStatus(
      int localEventId, String uuid, String status, {bool bumpVersion = false}) async {
    final d = await db;
    final values = <String, Object?>{'status': status};
    if (bumpVersion) {
      values['version'] = await _reserveVersions(d, localEventId, 1) + 1;
    }
    await d.update('tickets', values,
        where: 'local_event_id = ? AND uuid = ?',
        whereArgs: [localEventId, uuid]);
  }

  /// Suche nach Name, Ticket-Nr., UUID oder Bestell-Nr.
  static Future<List<Ticket>> searchTickets(int localEventId, String q) async {
    final like = '%$q%';
    final rows = await (await db).query('tickets',
        where: 'local_event_id = ? AND (name LIKE ? OR no LIKE ? '
            'OR uuid LIKE ? OR CAST(order_id AS TEXT) LIKE ?)',
        whereArgs: [localEventId, like, like, like, like],
        orderBy: 'name',
        limit: 50);
    return rows.map(Ticket.fromRow).toList();
  }

  /// Jugendschutz-„Ausgang": anwesende Gäste mit Endzeit, sortiert.
  static Future<List<Ticket>> curfewList(int localEventId) async {
    final rows = await (await db).query('tickets',
        where:
            "local_event_id = ? AND status = 'checked_in' AND curfew_end IS NOT NULL",
        whereArgs: [localEventId],
        orderBy: 'curfew_end');
    return rows.map(Ticket.fromRow).toList();
  }

  static Future<Map<String, int>> counts(int localEventId) async {
    final d = await db;
    Future<int> c(String where) async => Sqflite.firstIntValue(await d.rawQuery(
            'SELECT COUNT(*) FROM tickets WHERE local_event_id = ? AND $where',
            [localEventId])) ??
        0;
    return {
      'total': await c("status != 'cancelled'"),
      'in': await c("status = 'checked_in'"),
      'out': await c("status = 'checked_out'"),
    };
  }

  /* -------------------------------------------------------- Scan-Queue */

  static Future<void> queueCheckin({
    required String clientUuid,
    required int localEventId,
    required String ticketUuid,
    required String action,
    required String scannedAt,
    String deviceName = '',
  }) async {
    await (await db).insert(
        'pending_checkins',
        {
          'client_uuid': clientUuid,
          'local_event_id': localEventId,
          'ticket_uuid': ticketUuid,
          'action': action,
          'scanned_at': scannedAt,
          'device_name': deviceName,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<int> pendingCount(int localEventId) async {
    return Sqflite.firstIntValue(await (await db).rawQuery(
            'SELECT COUNT(*) FROM pending_checkins WHERE local_event_id = ?', [localEventId])) ??
        0;
  }

  static Future<List<Map<String, Object?>>> pendingCheckins(
      int localEventId) async {
    return (await db).query('pending_checkins',
        where: 'local_event_id = ?',
        whereArgs: [localEventId],
        orderBy: 'scanned_at');
  }

  static Future<void> clearPending(List<String> clientUuids) async {
    if (clientUuids.isEmpty) return;
    final d = await db;
    final marks = List.filled(clientUuids.length, '?').join(',');
    await d.delete('pending_checkins',
        where: 'client_uuid IN ($marks)', whereArgs: clientUuids);
  }

  /* ------------------------------------------------------- Sync-Alarme */

  static Future<int> addAlert({
    required int localEventId,
    required String ticketUuid,
    required String kind,
    required String message,
    required String createdAt,
  }) async {
    return (await db).insert('sync_alerts', {
      'local_event_id': localEventId,
      'ticket_uuid': ticketUuid,
      'kind': kind,
      'message': message,
      'created_at': createdAt,
      'acknowledged': 0,
    });
  }

  /// Ältester unquittierter Alarm des Events (oder null).
  static Future<SyncAlert?> oldestOpenAlert(int localEventId) async {
    final rows = await (await db).query('sync_alerts',
        where: 'local_event_id = ? AND acknowledged = 0',
        whereArgs: [localEventId],
        orderBy: 'id ASC',
        limit: 1);
    return rows.isEmpty ? null : SyncAlert.fromRow(rows.first);
  }

  static Future<int> openAlertCount(int localEventId) async {
    final d = await db;
    return Sqflite.firstIntValue(await d.rawQuery(
            'SELECT COUNT(*) FROM sync_alerts '
            'WHERE local_event_id = ? AND acknowledged = 0',
            [localEventId])) ??
        0;
  }

  static Future<void> acknowledgeAlert(int alertId) async {
    await (await db).update('sync_alerts', {'acknowledged': 1},
        where: 'id = ?', whereArgs: [alertId]);
  }

  /* --------------------------------------------------- Event-Einstellungen */

  static Future<void> setHubFlag(int localEventId, bool on) async {
    await (await db).update('events', {'is_hub': on ? 1 : 0}, where: 'id = ?', whereArgs: [localEventId]);
  }

  static Future<void> setDeviceName(int localEventId, String name) async {
    await (await db).update('events', {'device_name': name}, where: 'id = ?', whereArgs: [localEventId]);
  }

  static Future<void> setShowSeat(int localEventId, bool on) async {
    await (await db).update('events', {'show_seat': on ? 1 : 0}, where: 'id = ?', whereArgs: [localEventId]);
  }

  /* ------------------------------------------------------ Hub: Scanner */

  static Future<int> addHubClient(int localEventId, {required String name, required String token, required String pairedAt}) async {
    return (await db).insert('hub_clients', {
      'local_event_id': localEventId,
      'name': name,
      'token': token,
      'paired_at': pairedAt,
      'last_seen': pairedAt,
    });
  }

  static Future<int> hubClientCount(int localEventId) async {
    return Sqflite.firstIntValue(await (await db)
            .rawQuery('SELECT COUNT(*) FROM hub_clients WHERE local_event_id = ?', [localEventId])) ??
        0;
  }

  static Future<Map<String, Object?>?> hubClientByToken(int localEventId, String token) async {
    final rows = await (await db).query('hub_clients',
        where: 'local_event_id = ? AND token = ?', whereArgs: [localEventId, token], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<List<Map<String, Object?>>> hubClientRows(int localEventId) async {
    return (await db).query('hub_clients', where: 'local_event_id = ?', whereArgs: [localEventId], orderBy: 'id');
  }

  static Future<void> touchHubClient(int id, String at) async {
    await (await db).update('hub_clients', {'last_seen': at}, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> countHubClientScan(int id) async {
    await (await db).rawUpdate('UPDATE hub_clients SET scans = scans + 1 WHERE id = ?', [id]);
  }

  static Future<void> revokeHubClient(int id) async {
    await (await db).update('hub_clients', {'revoked': 1}, where: 'id = ?', whereArgs: [id]);
  }

  /* ------------------------------------------------------ Hub: Journal */

  static Future<bool> checkinLogged(String clientUuid) async {
    final rows = await (await db).query('checkin_log', columns: ['client_uuid'], where: 'client_uuid = ?', whereArgs: [clientUuid], limit: 1);
    return rows.isNotEmpty;
  }

  static Future<void> logCheckin({
    required String clientUuid,
    required int localEventId,
    required String ticketUuid,
    required String action,
    required String result,
    required String scannedAt,
    required String deviceName,
  }) async {
    await (await db).insert(
        'checkin_log',
        {
          'client_uuid': clientUuid,
          'local_event_id': localEventId,
          'ticket_uuid': ticketUuid,
          'action': action,
          'result': result,
          'scanned_at': scannedAt,
          'device_name': deviceName,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Letzter erfolgreicher Einlass-Scan eines Tickets (Konfliktinfo).
  static Future<Map<String, Object?>?> lastOkEntry(int localEventId, String ticketUuid) async {
    final rows = await (await db).query('checkin_log',
        where: "local_event_id = ? AND ticket_uuid = ? AND result = 'ok' AND action IN ('in','manual_in')",
        whereArgs: [localEventId, ticketUuid],
        orderBy: 'scanned_at DESC',
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Scans je Gerät: ok / conflict / invalid.
  static Future<List<Map<String, Object?>>> scansPerDevice(int localEventId) async {
    return (await db).rawQuery('''
      SELECT device_name,
             SUM(CASE WHEN result = 'ok' AND action IN ('in','manual_in') THEN 1 ELSE 0 END) AS ok,
             SUM(CASE WHEN result = 'conflict' THEN 1 ELSE 0 END) AS conflict,
             SUM(CASE WHEN result = 'invalid' THEN 1 ELSE 0 END) AS invalid
      FROM checkin_log WHERE local_event_id = ?
      GROUP BY device_name ORDER BY ok DESC''', [localEventId]);
  }

  /// Verlauf für den Bildschirm „Scan-Verlauf" (mit Name, Nummer, Ticketart).
  static Future<List<Map<String, Object?>>> historyRows(int localEventId, int limit) async {
    return (await db).rawQuery('''
      SELECT l.client_uuid, l.scanned_at, l.device_name, l.result, l.action, l.ticket_uuid, t.name, t.no, t.type
      FROM checkin_log l LEFT JOIN tickets t ON t.local_event_id = l.local_event_id AND t.uuid = l.ticket_uuid
      WHERE l.local_event_id = ? ORDER BY l.scanned_at DESC, l.rowid DESC LIMIT ?''', [localEventId, limit]);
  }

  /// Letzte Journaleinträge mit Gastname.
  static Future<List<Map<String, Object?>>> recentLog(int localEventId, int limit) async {
    return (await db).rawQuery('''
      SELECT l.scanned_at, l.device_name, l.result, l.action, l.ticket_uuid, t.name
      FROM checkin_log l LEFT JOIN tickets t ON t.local_event_id = l.local_event_id AND t.uuid = l.ticket_uuid
      WHERE l.local_event_id = ? ORDER BY l.scanned_at DESC LIMIT ?''', [localEventId, limit]);
  }
}

