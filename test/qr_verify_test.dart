import 'package:flutter_test/flutter_test.dart';
import 'package:via_tickets_scan/demo.dart';
import 'package:via_tickets_scan/qr_verify.dart';

void main() {
  group('QR-Payload', () {
    test('Demo-Payload lässt sich parsen und verifizieren', () {
      const uuid = '0f0e4c2a-1111-4222-8333-444455556666';
      final raw = demoPayload(uuid);
      final p = parsePayload(raw);
      expect(p, isNotNull);
      expect(p!.eventId, demoEventId);
      expect(p.uuid, uuid);
      expect(p.sig.length, sigLength);
      expect(verifySig(p, demoSecret), isTrue);
    });
    test('Manipulierte Signatur fällt durch', () {
      const uuid = '0f0e4c2a-1111-4222-8333-444455556666';
      final raw = demoPayload(uuid);
      final parts = raw.split('.');
      parts[3] = parts[3].substring(0, sigLength - 1) + (parts[3].endsWith('A') ? 'B' : 'A');
      expect(verifySig(parsePayload(parts.join('.'))!, demoSecret), isFalse);
    });
    test('Falsches Secret fällt durch', () {
      final p = parsePayload(demoPayload('0f0e4c2a-1111-4222-8333-444455556666'))!;
      expect(verifySig(p, 'anderes-secret'), isFalse);
    });
    test('Fremde Strings sind kein Ticket', () {
      expect(parsePayload('https://example.org'), isNull);
      expect(parsePayload('VT1.x.y.z'), isNull);
      expect(parsePayload('VT2.1.u.s'), isNull);
    });
  });
}
