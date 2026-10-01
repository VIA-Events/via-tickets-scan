/// Demo-Modus: lokales Beispiel-Event ohne Shop, damit die App ohne Kopplung ausprobiert
/// werden kann (Schulung, App-Store-Prüfung). Tickets werden mit einem lokalen Secret
/// signiert; die QR-Codes lassen sich in der App anzeigen und von einem zweiten Gerät
/// scannen – oder per „Scan simulieren" direkt auswerten.
library;
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'db.dart';
import 'models.dart';
import 'qr_verify.dart';

const String demoBaseUrl = 'demo://via-tickets';
const int demoEventId = 900001;
const String demoSecret = 'demo-secret-via-tickets-scan';

bool isDemoEvent(PairedEvent e) => e.baseUrl == demoBaseUrl;

/// Signierte Demo-Payload (gleiches Verfahren wie Shop/App: HMAC-SHA256, Base32, 20 Zeichen).
String demoPayload(String uuid) {
  final msg = 'VT1.$demoEventId.$uuid';
  final mac = Hmac(sha256, utf8.encode(demoSecret)).convert(utf8.encode(msg));
  return '$msg.${base32NoPad(mac.bytes).substring(0, sigLength)}';
}

const List<Map<String, Object?>> _guests = [
  {'name': 'Anna Beispiel', 'type': 'Gästekarte Parkett vorn', 'table': 'Vorn Links', 'seat': 'Reihe 5 · Platz 6', 'age': 42, 'ampel': 'green'},
  {'name': 'Jonas Beispiel', 'type': 'Jugendweihe-Teilnehmer', 'table': 'Vorn Links', 'seat': 'Reihe 1 · Platz 3', 'age': 14, 'ampel': 'green'},
  {'name': 'Oma Erika', 'type': 'Gästekarte Parkett hinten', 'table': 'Hinten Links', 'seat': 'Reihe 18 · Platz 4', 'age': 71, 'ampel': 'green'},
  {'name': 'Max Mustermann', 'type': 'Gast', 'table': null, 'seat': null, 'age': 16, 'ampel': 'yellow', 'curfew_end': '24:00'},
  {'name': 'Lena Mustermann', 'type': 'Gast', 'table': null, 'seat': null, 'age': 15, 'ampel': 'red', 'curfew_end': '22:00'},
  {'name': 'Tim Testgast', 'type': 'Gast', 'table': null, 'seat': null, 'age': 18, 'ampel': 'green'},
  {'name': 'Storno Beispiel', 'type': 'Gast', 'table': null, 'seat': null, 'age': 20, 'ampel': 'green', 'status': 'cancelled'},
  {'name': 'Paul Pünktlich', 'type': 'Gästekarte Parkett vorn', 'table': 'Vorn Rechts', 'seat': 'Reihe 3 · Platz 14', 'age': 38, 'ampel': 'green'},
];

/// Demo-Event anlegen (oder zurücksetzen) und lokale ID liefern.
Future<int> createDemoEvent() async {
  final localId = await AppDb.saveEvent(
    baseUrl: demoBaseUrl,
    event: {
      'id': demoEventId,
      'title': 'Demo: Jugendweihe Musterstadt',
      'venue_name': 'Stadthalle Musterstadt',
      'starts_at': _today('10:00:00'),
      'ends_at': _today('12:30:00'),
      'reentry': true,
      'youth_mode': true,
      'show_seat': true,
    },
    deviceToken: '',
    hmacSecret: demoSecret,
  );
  final tickets = <Ticket>[];
  final rnd = Random(7);
  for (var i = 0; i < _guests.length; i++) {
    final g = _guests[i];
    final uuid = _uuidFor(i);
    tickets.add(Ticket(
      uuid: uuid,
      no: 'DEMO-${(i + 1).toString().padLeft(3, '0')}',
      status: (g['status'] as String?) ?? 'valid',
      type: g['type'] as String?,
      name: g['name'] as String?,
      orderId: 1000 + rnd.nextInt(900),
      age: g['age'] as int?,
      ampel: (g['ampel'] as String?) ?? 'green',
      curfewEnd: g['curfew_end'] as String?,
      muttizettel: (g['ampel'] == 'yellow'),
      table: g['table'] as String?,
      seat: g['seat'] as String?,
    ));
  }
  await AppDb.replaceTickets(localId, tickets);
  return localId;
}

String _today(String time) {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')} $time';
}

/// Deterministische Demo-UUIDs (gültiges Format).
String _uuidFor(int i) {
  final h = sha256.convert(utf8.encode('via-demo-$i')).toString();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-a${h.substring(17, 20)}-${h.substring(20, 32)}';
}

/// Zeigt die Demo-Tickets als QR-Codes zum Abscannen mit einem zweiten Gerät.
class DemoTicketsScreen extends StatelessWidget {
  final PairedEvent event;
  const DemoTicketsScreen({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Demo-Tickets')),
      body: FutureBuilder<List<Ticket>>(
        future: AppDb.searchTickets(event.localId, ''),
        builder: (context, snap) {
          final list = snap.data ?? const [];
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final t = list[i];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(6),
                      child: QrImageView(data: demoPayload(t.uuid), size: 120, backgroundColor: Colors.white),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t.name ?? t.no, style: Theme.of(context).textTheme.titleMedium),
                        Text('${t.type ?? ''} · ${t.no}'),
                        if (t.seat != null) Text('${t.table ?? ''} · ${t.seat}'),
                        Text('Status: ${t.status}${t.status == 'cancelled' ? ' (wird abgelehnt)' : ''}', style: Theme.of(context).textTheme.bodySmall),
                      ]),
                    ),
                  ]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
