import 'package:flutter_test/flutter_test.dart';
import 'package:via_tickets_scan/screens/exit_list.dart';

void main() {
  // Event beginnt am 15.08.2026 um 19:00 Uhr.
  const startsAt = '2026-08-15 19:00:00';

  group('minutesUntilCurfew am Eventdatum verankert (F4)', () {
    test('22:00 vor Mitternacht: 21:30 → noch 30 Minuten', () {
      final now = DateTime(2026, 8, 15, 21, 30);
      expect(minutesUntilCurfew('22:00', startsAt: startsAt, now: now), 30);
    });

    test('22:00 nach Mitternacht: 00:30 → seit 150 Minuten überfällig', () {
      final now = DateTime(2026, 8, 16, 0, 30);
      expect(minutesUntilCurfew('22:00', startsAt: startsAt, now: now), -150);
    });

    test('00:30 gehört zum Folgetag: 23:00 → noch 90 Minuten', () {
      final now = DateTime(2026, 8, 15, 23, 0);
      expect(minutesUntilCurfew('00:30', startsAt: startsAt, now: now), 90);
    });

    test('00:30 am Folgetag um 00:45 → seit 15 Minuten überfällig', () {
      final now = DateTime(2026, 8, 16, 0, 45);
      expect(minutesUntilCurfew('00:30', startsAt: startsAt, now: now), -15);
    });

    test('24:00 ist Mitternacht des Folgetags: 23:30 → noch 30 Minuten', () {
      final now = DateTime(2026, 8, 15, 23, 30);
      expect(minutesUntilCurfew('24:00', startsAt: startsAt, now: now), 30);
    });

    test('24:00 um 00:10 des Folgetags → seit 10 Minuten überfällig', () {
      final now = DateTime(2026, 8, 16, 0, 10);
      expect(minutesUntilCurfew('24:00', startsAt: startsAt, now: now), -10);
    });

    test('Endzeit gleich Startzeit gilt als Eventtag', () {
      final now = DateTime(2026, 8, 15, 18, 0);
      expect(minutesUntilCurfew('19:00', startsAt: startsAt, now: now), 60);
    });

    test('Event am Vortag, Gerät am Folgetag 02:00: 22:00 bleibt Vortag', () {
      final now = DateTime(2026, 8, 16, 2, 0);
      expect(minutesUntilCurfew('22:00', startsAt: startsAt, now: now), -240);
    });
  });

  group('Fallback ohne startsAt (heutiges Datum)', () {
    test('22:00 um 21:30 → 30 Minuten', () {
      final now = DateTime(2026, 8, 15, 21, 30);
      expect(minutesUntilCurfew('22:00', now: now), 30);
    });

    test('00:30 um 23:00 → Folgetag, 90 Minuten', () {
      final now = DateTime(2026, 8, 15, 23, 0);
      expect(minutesUntilCurfew('00:30', now: now), 90);
    });

    test('24:00 um 23:30 → 30 Minuten', () {
      final now = DateTime(2026, 8, 15, 23, 30);
      expect(minutesUntilCurfew('24:00', now: now), 30);
    });

    test('unlesbares startsAt fällt auf heutiges Datum zurück', () {
      final now = DateTime(2026, 8, 15, 21, 30);
      expect(minutesUntilCurfew('22:00', startsAt: 'kein datum', now: now), 30);
    });
  });
}
