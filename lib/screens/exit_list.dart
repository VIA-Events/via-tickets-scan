/// Jugendschutz-Reiter „Ausgang" (Konzept 4.5): alle anwesenden Gäste, deren
/// Endzeit in < 30 Min liegt oder überschritten ist, sortiert nach Endzeit.
/// Häkchen „hat Haus verlassen" = Check-out.
library;
import 'dart:async';

import 'package:flutter/material.dart';

import '../db.dart';
import '../models.dart';

/// Minuten bis zur Endzeit (negativ = überschritten).
///
/// Die Endzeit "HH:MM" wird am **Eventdatum** verankert (Datum aus
/// [startsAt], Format "yyyy-MM-dd HH:mm:ss"). Liegt die Endzeit-Uhrzeit vor
/// der Uhrzeit von [startsAt], gehört sie zum Folgetag (z. B. Event 19:00,
/// Endzeit 00:30). "24:00" ist Mitternacht des Folgetags. Nur wenn kein
/// [startsAt] vorliegt, wird auf das heutige Datum zurückgegriffen (F4).
int minutesUntilCurfew(String curfewEnd, {String? startsAt, DateTime? now}) {
  final current = now ?? DateTime.now();
  final parts = curfewEnd.trim().split(':');
  var hour = int.tryParse(parts[0]) ?? 0;
  final minute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
  var dayOffset = 0;
  if (hour >= 24) {
    hour -= 24;
    dayOffset = 1;
  }

  final start = startsAt == null ? null : DateTime.tryParse(startsAt.trim());
  DateTime end;
  if (start != null) {
    final endMinutes = hour * 60 + minute;
    final startMinutes = start.hour * 60 + start.minute;
    if (dayOffset == 0 && endMinutes < startMinutes) dayOffset = 1;
    end = DateTime(start.year, start.month, start.day + dayOffset, hour, minute);
  } else {
    // Fallback ohne Eventdatum: heutiges Datum, Endzeiten weit in der
    // Vergangenheit gelten als Folgetag (laufende Nacht).
    end = DateTime(
        current.year, current.month, current.day + dayOffset, hour, minute);
    if (end.isBefore(current.subtract(const Duration(hours: 12)))) {
      end = DateTime(end.year, end.month, end.day + 1, end.hour, end.minute);
    }
  }
  return end.difference(current).inMinutes;
}

class ExitListScreen extends StatefulWidget {
  final PairedEvent event;
  final Future<void> Function(Ticket) onCheckout;
  const ExitListScreen(
      {super.key, required this.event, required this.onCheckout});

  @override
  State<ExitListScreen> createState() => _ExitListScreenState();
}

class _ExitListScreenState extends State<ExitListScreen> {
  List<Ticket> _list = const [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await AppDb.curfewList(widget.event.localId);
    if (mounted) setState(() => _list = all);
  }

  int _minutesLeft(String curfewEnd) =>
      minutesUntilCurfew(curfewEnd, startsAt: widget.event.startsAt);

  @override
  Widget build(BuildContext context) {
    final urgent =
        _list.where((t) => _minutesLeft(t.curfewEnd ?? '') < 30).toList();
    final later =
        _list.where((t) => _minutesLeft(t.curfewEnd ?? '') >= 30).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Ausgang – Jugendschutz')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            if (urgent.isEmpty && later.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Keine anwesenden Gäste mit Endzeit.',
                    textAlign: TextAlign.center),
              ),
            if (urgent.isNotEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('Müssen jetzt / in < 30 Min raus',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.redAccent)),
              ),
            ...urgent.map((t) => _tile(t, urgentStyle: true)),
            if (later.isNotEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('Später',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ...later.map((t) => _tile(t)),
          ],
        ),
      ),
    );
  }

  Widget _tile(Ticket t, {bool urgentStyle = false}) {
    final m = _minutesLeft(t.curfewEnd ?? '');
    final overdue = m < 0;
    return ListTile(
      leading: Icon(
        overdue ? Icons.warning_amber : Icons.schedule,
        color: urgentStyle ? Colors.redAccent : null,
      ),
      title: Text(t.name?.isNotEmpty == true ? t.name! : t.no),
      subtitle: Text(
        'bis ${t.curfewEnd} Uhr'
        '${overdue ? ' – seit ${-m} Min überfällig' : ' – noch $m Min'}'
        '${t.age != null ? ' · ${t.age} Jahre' : ' · Alter unbekannt'}'
        '${t.muttizettel ? ' · Muttizettel liegt vor' : ''}',
      ),
      trailing: FilledButton.tonal(
        onPressed: () async {
          await widget.onCheckout(t);
          await _load();
        },
        child: const Text('Hat Haus verlassen'),
      ),
    );
  }
}
