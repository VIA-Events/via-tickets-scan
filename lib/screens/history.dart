/// Scan-Verlauf (Design „Ticketscanner"): Zähler Gültig / Bereits eingelöst / Ungültig und
/// die Liste der Scans dieses Geräts – auf dem Hub aller Geräte – aus dem lokalen Journal.
library;
import 'package:flutter/material.dart';

import '../db.dart';
import '../models.dart';
import '../theme.dart';

class HistoryScreen extends StatelessWidget {
  final PairedEvent event;
  const HistoryScreen({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(4, 4, 12, 12),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Via.border))),
              child: Row(children: [
                IconButton(
                  tooltip: 'Zurück',
                  icon: const Icon(Icons.chevron_left, color: Via.dunkelblau, size: 28),
                  onPressed: () => Navigator.pop(context),
                ),
                Text('Scan-Verlauf', style: Via.h(22, color: Via.dunkelblau)),
              ]),
            ),
            Expanded(
              child: FutureBuilder<List<Map<String, Object?>>>(
                future: AppDb.historyRows(event.localId, 300),
                builder: (context, snap) {
                  final rows = snap.data ?? const <Map<String, Object?>>[];
                  final ok = rows.where((r) => r['result'] == 'ok').length;
                  final used = rows.where((r) => r['result'] == 'conflict').length;
                  final bad = rows.where((r) => r['result'] == 'invalid' || r['result'] == 'error').length;
                  return Column(children: [
                    Container(
                      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Via.border))),
                      child: Row(children: [
                        _counter('$ok', 'Gültig', Via.positive),
                        _counter('$used', 'Bereits eingelöst', const Color(0xFFB87A1C), left: true),
                        _counter('$bad', 'Ungültig', Via.negative, left: true),
                      ]),
                    ),
                    Expanded(
                      child: rows.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(48),
                              child: Text('Noch keine Scans an diesem Gerät.', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: Via.fg2)),
                            )
                          : ListView.builder(
                              itemCount: rows.length,
                              itemBuilder: (context, i) => _row(rows[i]),
                            ),
                    ),
                  ]);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _counter(String value, String label, Color color, {bool left = false}) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(border: left ? const Border(left: BorderSide(color: Via.border)) : null),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: Via.h(26, weight: FontWeight.w800, color: color, height: 1)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 13, color: Via.fg2)),
          ]),
        ),
      );

  Widget _row(Map<String, Object?> r) {
    final result = asStr(r['result']) ?? '';
    final action = asStr(r['action']) ?? 'in';
    final Color bg;
    final Color fg;
    final IconData icon;
    final String what;
    if (result == 'ok') {
      bg = Via.positive;
      fg = Colors.white;
      icon = action == 'out' ? Icons.logout : Icons.check;
      what = action == 'out' ? 'Auslass' : (action == 'manual_in' ? 'Manuell eingelassen' : 'Eingelassen');
    } else if (result == 'conflict') {
      bg = Via.attention;
      fg = Via.ink;
      icon = Icons.replay;
      what = 'Bereits eingelöst';
    } else {
      bg = Via.negative;
      fg = Colors.white;
      icon = Icons.close;
      what = 'Abgelehnt';
    }
    final name = asStr(r['name']);
    final no = asStr(r['no']) ?? '';
    final type = asStr(r['type']) ?? '';
    final device = asStr(r['device_name']) ?? '';
    final ts = asStr(r['scanned_at']) ?? '';
    final sub = [what, if (type.isNotEmpty) type, if (no.isNotEmpty) no, if (device.isNotEmpty) device].join(' · ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Via.border))),
      child: Row(children: [
        Container(width: 40, height: 40, color: bg, child: Icon(icon, color: fg, size: 20)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((name != null && name.isNotEmpty) ? name : (no.isNotEmpty ? no : 'Unbekannter Code'),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: Via.h(17, color: Via.ink, height: 1.25)),
            Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, color: Via.fg2, height: 1.35)),
          ]),
        ),
        const SizedBox(width: 8),
        Text(ts.length >= 16 ? ts.substring(11, 16) : ts, style: Via.h(15, color: Via.fg2)),
      ]),
    );
  }
}
