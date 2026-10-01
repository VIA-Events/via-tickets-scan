import 'package:flutter_test/flutter_test.dart';
import 'package:via_tickets_scan/hub/hub_rules.dart';

void main() {
  group('decideCheckin (Spiegel von /scan/checkins)', () {
    test('Einlass auf gültiges Ticket', () {
      final d = decideCheckin('valid', 'in', reentry: false);
      expect(d.outcome, 'ok');
      expect(d.newStatus, 'checked_in');
    });
    test('Doppelscan ist Konflikt', () {
      expect(decideCheckin('checked_in', 'in', reentry: true).outcome, 'conflict');
      expect(decideCheckin('checked_in', 'manual_in', reentry: false).outcome, 'conflict');
    });
    test('Auslass nur aus checked_in, unabhängig vom Reentry-Flag', () {
      expect(decideCheckin('checked_in', 'out', reentry: false).newStatus, 'checked_out');
      final d = decideCheckin('valid', 'out', reentry: true);
      expect(d.outcome, 'invalid');
      expect(d.reason, 'not_checked_in');
    });
    test('Wiedereinlass hängt am Reentry-Flag', () {
      expect(decideCheckin('checked_out', 'in', reentry: true).newStatus, 'checked_in');
      final d = decideCheckin('checked_out', 'in', reentry: false);
      expect(d.outcome, 'invalid');
      expect(d.reason, 'reentry_disabled');
    });
    test('Storniert wird immer abgelehnt', () {
      for (final a in ['in', 'out', 'manual_in']) {
        final d = decideCheckin('cancelled', a, reentry: true);
        expect(d.outcome, 'invalid');
        expect(d.reason, 'cancelled');
      }
    });
    test('Unbekannte Aktion zählt als Einlass', () {
      expect(decideCheckin('valid', 'xyz', reentry: false).newStatus, 'checked_in');
    });
  });

  group('isUuid', () {
    test('akzeptiert gültige UUIDs', () {
      expect(isUuid('0f0e4c2a-1111-4222-8333-444455556666'), isTrue);
      expect(isUuid('0F0E4C2A-1111-4222-8333-444455556666'), isTrue);
    });
    test('lehnt alles andere ab', () {
      expect(isUuid(''), isFalse);
      expect(isUuid('0f0e4c2a-1111-4222-8333'), isFalse);
      expect(isUuid('zzzzzzzz-1111-4222-8333-444455556666'), isFalse);
    });
  });
}
