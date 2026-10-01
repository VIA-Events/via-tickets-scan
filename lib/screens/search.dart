/// Namenssuche (Konzept 4.4): Name, Ticket-Nr., Bestell-Nr. – lokal in SQLite,
/// Treffer manuell einchecken (als `manual_in` im Journal).
library;
import 'package:flutter/material.dart';

import '../db.dart';
import '../models.dart';

class SearchScreen extends StatefulWidget {
  final PairedEvent event;
  final Future<void> Function(Ticket) onManualCheckin;
  const SearchScreen(
      {super.key, required this.event, required this.onManualCheckin});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<Ticket> _results = const [];

  Future<void> _search(String q) async {
    if (q.trim().length < 2) {
      if (mounted) setState(() => _results = const []);
      return;
    }
    final r = await AppDb.searchTickets(widget.event.localId, q.trim());
    if (mounted) setState(() => _results = r);
  }

  static String _statusLabel(String status) {
    switch (status) {
      case 'checked_in':
        return 'eingecheckt';
      case 'checked_out':
        return 'ausgecheckt';
      case 'cancelled':
        return 'storniert';
      default:
        return 'gültig';
    }
  }

  Widget _trailing(BuildContext context, Ticket t) {
    if (t.status == 'cancelled') {
      return const Text('storniert', style: TextStyle(color: Colors.redAccent));
    }
    if (t.status == 'checked_in') {
      return const Icon(Icons.check, color: Colors.green);
    }
    if (t.status == 'checked_out' && !widget.event.reentry) {
      // Ohne Wiedereinlass lehnt der Server einen erneuten Einlass ab
      // (reentry_disabled) – Button gar nicht anbieten.
      return const Text('ausgecheckt',
          style: TextStyle(color: Colors.orangeAccent));
    }
    return FilledButton(
      onPressed: () async {
        await widget.onManualCheckin(t);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '${t.name?.isNotEmpty == true ? t.name : t.no} manuell eingecheckt.')));
        Navigator.pop(context);
      },
      child: Text(t.status == 'checked_out' ? 'Wiedereinlass' : 'Einchecken'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Namenssuche')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Name, Ticket-Nr. oder Bestell-Nr.',
                border: OutlineInputBorder(),
              ),
              onChanged: _search,
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: _results.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final t = _results[i];
                return ListTile(
                  title: Text(t.name?.isNotEmpty == true
                      ? t.name!
                      : '(ohne Namen)'),
                  subtitle: Text(
                    '${t.type ?? ''} · ${t.no}'
                    '${t.orderId != null ? ' · Bestellung ${t.orderId}' : ''}'
                    ' · ${_statusLabel(t.status)}',
                  ),
                  trailing: _trailing(context, t),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
