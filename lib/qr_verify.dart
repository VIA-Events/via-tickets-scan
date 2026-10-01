/// Offline-Prüfung der QR-Payload (Konzept Abschnitt 5):
/// VT1.<event_id>.<ticket_uuid>.<sig>
/// sig = base32(hmac_sha256(event_secret, "VT1.<event_id>.<ticket_uuid>"))[:20]
library;
import 'dart:convert';
import 'package:crypto/crypto.dart';

class QrPayload {
  final int eventId;
  final String uuid;
  final String sig;
  QrPayload(this.eventId, this.uuid, this.sig);
}

QrPayload? parsePayload(String raw) {
  final parts = raw.trim().split('.');
  if (parts.length != 4 || parts[0] != 'VT1') return null;
  final eventId = int.tryParse(parts[1]);
  if (eventId == null) return null;
  return QrPayload(eventId, parts[2], parts[3]);
}

const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// Länge der gekürzten Signatur (100 Bit).
const sigLength = 20;

String base32NoPad(List<int> bytes) {
  final bits = StringBuffer();
  for (final b in bytes) {
    bits.write(b.toRadixString(2).padLeft(8, '0'));
  }
  var s = bits.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i += 5) {
    var chunk = s.substring(i, i + 5 > s.length ? s.length : i + 5);
    chunk = chunk.padRight(5, '0');
    out.write(_alphabet[int.parse(chunk, radix: 2)]);
  }
  return out.toString();
}

/// Zeitkonstanter Vergleich: immer `sigLength` Bytes per XOR verknüpfen,
/// unabhängig davon, an welcher Stelle sich die Strings unterscheiden.
/// Längenabweichungen fließen in dasselbe Ergebnis ein.
bool constantTimeEquals(String a, String b) {
  final ab = utf8.encode(a);
  final bb = utf8.encode(b);
  var diff = ab.length ^ bb.length;
  for (var i = 0; i < sigLength; i++) {
    final x = i < ab.length ? ab[i] : 0;
    final y = i < bb.length ? bb[i] : 0;
    diff |= x ^ y;
  }
  return diff == 0;
}

/// HMAC-Prüfung – erkennt Fälschungen komplett offline.
bool verifySig(QrPayload p, String hmacSecretHexOrRaw) {
  final msg = 'VT1.${p.eventId}.${p.uuid}';
  final mac =
      Hmac(sha256, utf8.encode(hmacSecretHexOrRaw)).convert(utf8.encode(msg));
  final expected = base32NoPad(mac.bytes).substring(0, sigLength);
  return constantTimeEquals(expected, p.sig);
}
