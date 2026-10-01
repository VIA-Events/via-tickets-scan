// End-to-End-Test des lokalen Hubs ohne Geräte: echte SQLite (sqflite_common_ffi),
// echter HTTP-Server auf localhost, Scanner-Seite simuliert mit dart:io HttpClient.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:via_tickets_scan/db.dart';
import 'package:via_tickets_scan/demo.dart';
import 'package:via_tickets_scan/hub/hub_server.dart';
import 'package:via_tickets_scan/hub/hub_service.dart';

Future<Map<String, dynamic>> _json(HttpClientResponse r) async =>
    Map<String, dynamic>.from(jsonDecode(await utf8.decoder.bind(r).join()) as Map);

Future<HttpClientResponse> _call(String method, int port, String path,
    {Object? body, String? token}) async {
  final client = HttpClient();
  final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port/wp-json/via-tickets/v1/scan/$path'));
  req.headers.contentType = ContentType.json;
  if (token != null) req.headers.set('authorization', 'Bearer $token');
  if (body != null) req.write(jsonEncode(body));
  return req.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // flutter_test blockiert HttpClient (400) – hier läuft ein echter lokaler Server.
    HttpOverrides.global = null;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Secure Storage ohne Plattform: im Speicher halten.
    final store = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final key = args['key'] as String?;
        switch (call.method) {
          case 'write':
            store[key!] = args['value'] as String;
            return null;
          case 'read':
            return store[key];
          case 'delete':
            store.remove(key);
            return null;
          case 'containsKey':
            return store.containsKey(key);
          default:
            return null;
        }
      },
    );
    // Frische Test-Datenbank.
    final path = '${await getDatabasesPath()}/via_tickets_scan.db';
    if (File(path).existsSync()) File(path).deleteSync();
  });

  test('Hub: Pairing, Manifest, Scans, Doppelscan, Delta, Zähler', () async {
    final localId = await createDemoEvent();
    final event = (await AppDb.eventById(localId))!;
    final service = HubService(event, hubName: 'Hub Test');
    final server = HubServer(service);
    await server.start();
    addTearDown(server.stop);

    // Pairing mit falschem Code scheitert, mit richtigem Code klappt es.
    var r = await _call('POST', server.port, 'pair', body: {'code': 'FALSCH', 'name': 'Eingang Süd'});
    expect(r.statusCode, 403);
    r = await _call('POST', server.port, 'pair', body: {'code': service.code, 'name': 'Eingang Süd'});
    expect(r.statusCode, 200);
    final pair = await _json(r);
    final token = pair['device_token'] as String;
    expect(pair['hmac_secret'], demoSecret);
    expect((pair['event'] as Map)['id'], demoEventId);
    expect((pair['settings'] as Map)['show_seat'], isTrue);

    // Ohne Token kein Zugriff.
    r = await _call('GET', server.port, 'manifest');
    expect(r.statusCode, 401);

    // Voll-Manifest.
    r = await _call('GET', server.port, 'manifest', token: token);
    expect(r.statusCode, 200);
    final m1 = await _json(r);
    final tickets = (m1['tickets'] as List).cast<Map>();
    expect(tickets.length, 8);
    expect(m1['full'], isTrue);
    final cursor1 = m1['cursor'] as int;
    expect(cursor1, greaterThan(0));
    final valid = tickets.firstWhere((t) => t['status'] == 'valid');
    final cancelled = tickets.firstWhere((t) => t['status'] == 'cancelled');

    // Scanner bucht Einlass; zweiter Scanner (Hub selbst) bucht dasselbe Ticket → Konflikt.
    r = await _call('POST', server.port, 'checkins', token: token, body: [
      {'client_uuid': '11111111-1111-4111-8111-111111111111', 'ticket_uuid': valid['uuid'], 'action': 'in', 'scanned_at': '2026-10-01 10:00:00'},
      {'client_uuid': '22222222-2222-4222-8222-222222222222', 'ticket_uuid': cancelled['uuid'], 'action': 'in', 'scanned_at': '2026-10-01 10:00:01'},
      {'client_uuid': 'kaputt', 'ticket_uuid': valid['uuid'], 'action': 'in'},
    ]);
    final res1 = (await _json(r))['results'] as List;
    expect(res1[0]['result'], 'ok');
    expect(res1[0]['status'], 'checked_in');
    expect(res1[1]['result'], 'invalid');
    expect(res1[1]['reason'], 'cancelled');
    expect(res1[2]['result'], 'invalid');
    expect(res1[2]['reason'], 'missing_fields');

    final hubRes = await service.applyCheckins([
      {'client_uuid': '33333333-3333-4333-8333-333333333333', 'ticket_uuid': valid['uuid'], 'action': 'in', 'scanned_at': '2026-10-01 10:01:00'}
    ], deviceName: 'Hub Test');
    expect(hubRes.first['result'], 'conflict');
    expect((hubRes.first['conflict'] as Map)['device_name'], 'Eingang Süd');

    // Wiederholter Batch mit gleicher client_uuid ist idempotent.
    r = await _call('POST', server.port, 'checkins', token: token, body: [
      {'client_uuid': '11111111-1111-4111-8111-111111111111', 'ticket_uuid': valid['uuid'], 'action': 'in', 'scanned_at': '2026-10-01 10:00:00'},
    ]);
    final res2 = (await _json(r))['results'] as List;
    expect(res2.first['duplicate'], isTrue);

    // Delta-Manifest liefert nur das geänderte Ticket.
    r = await _call('GET', server.port, 'manifest?since=$cursor1', token: token);
    final m2 = await _json(r);
    final delta = (m2['tickets'] as List).cast<Map>();
    expect(delta.length, 1);
    expect(delta.first['uuid'], valid['uuid']);
    expect(delta.first['status'], 'checked_in');
    expect(m2['cursor'], greaterThan(cursor1));

    // Auslass + Wiedereinlass (Demo-Event erlaubt Reentry).
    r = await _call('POST', server.port, 'checkins', token: token, body: [
      {'client_uuid': '44444444-4444-4444-8444-444444444444', 'ticket_uuid': valid['uuid'], 'action': 'out', 'scanned_at': '2026-10-01 10:05:00'},
      {'client_uuid': '55555555-5555-4555-8555-555555555555', 'ticket_uuid': valid['uuid'], 'action': 'in', 'scanned_at': '2026-10-01 10:06:00'},
    ]);
    final res3 = (await _json(r))['results'] as List;
    expect(res3[0]['status'], 'checked_out');
    expect(res3[1]['status'], 'checked_in');

    // Zähler und Journal je Gerät; Queue an den Shop enthält alle gültigen Scans.
    final stats = await service.stats();
    expect(stats['in'], 1);
    final devices = (stats['devices'] as List).cast<Map>();
    expect(devices.any((d) => d['device_name'] == 'Eingang Süd' && d['ok'] == 2), isTrue);
    expect(await AppDb.pendingCount(localId), 3); // in, out, in

    // Widerruf: Token danach ungültig.
    r = await _call('POST', server.port, 'revoke-self', token: token);
    expect(r.statusCode, 200);
    r = await _call('GET', server.port, 'events', token: token);
    expect(r.statusCode, 401);
  });
}
