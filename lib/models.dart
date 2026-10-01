/// Datenmodelle der Scanner-App.
library;
import 'secure_store.dart';

/* ------------------------------------------------ defensive JSON-Helfer */

/// Liest einen Integer aus JSON/SQLite, egal ob als int, double oder String
/// geliefert. Typfremde Werte ergeben null statt eines Absturzes.
int? asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// Liest einen String; Zahlen werden umgewandelt, Listen/Maps verworfen.
String? asStr(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return null;
}

/// Liest ein Bool (JSON true, 1, "1", "true").
bool asBool(Object? v) =>
    v == true || v == 1 || v == '1' || v == 'true';

/* ------------------------------------------------------------- Events */

class PairedEvent {
  final int localId; // lokale Zeilen-ID (ein Gerät kann mehrere Events koppeln)
  final String baseUrl; // Shop-URL, z. B. https://shop.example.de
  final int eventId;
  final String title;
  final String? venueName;
  final String? startsAt; // "yyyy-MM-dd HH:mm:ss" (WP-Lokalzeit des Shops)
  final String? endsAt;
  final bool reentry;
  final bool youthMode;
  final String deviceToken; // aus Secure Storage, nicht aus SQLite
  final String hmacSecret; // aus Secure Storage, nicht aus SQLite
  final int cursor; // Manifest-Delta-Cursor (opaker, monoton steigender Integer)
  final bool isHub; // Dieses Gerät betreibt den lokalen Hub für das Event
  final String deviceName; // Name dieses Geräts (z. B. „Eingang Süd")
  final bool showSeat; // Platz nach dem Scan groß anzeigen (Hub-Einstellung / Shop)

  PairedEvent({
    required this.localId,
    required this.baseUrl,
    required this.eventId,
    required this.title,
    this.venueName,
    this.startsAt,
    this.endsAt,
    required this.reentry,
    required this.youthMode,
    required this.deviceToken,
    required this.hmacSecret,
    this.cursor = 0,
    this.isHub = false,
    this.deviceName = '',
    this.showSeat = false,
  });

  /// Lädt ein Event aus einer SQLite-Zeile und holt Token und Secret
  /// asynchron aus dem Secure Storage. Ist dort (noch) nichts hinterlegt,
  /// greift der Klartextwert aus SQLite (Altbestand vor der Migration).
  static Future<PairedEvent> load(Map<String, Object?> r) async {
    final id = asInt(r['id']) ?? 0;
    final token = await SecureStore.token(id);
    final secret = await SecureStore.secret(id);
    return PairedEvent(
      localId: id,
      baseUrl: asStr(r['base_url']) ?? '',
      eventId: asInt(r['event_id']) ?? 0,
      title: asStr(r['title']) ?? '',
      venueName: asStr(r['venue_name']),
      startsAt: asStr(r['starts_at']),
      endsAt: asStr(r['ends_at']),
      reentry: asInt(r['reentry']) == 1,
      youthMode: asInt(r['youth_mode']) == 1,
      deviceToken: (token != null && token.isNotEmpty)
          ? token
          : (asStr(r['device_token']) ?? ''),
      hmacSecret: (secret != null && secret.isNotEmpty)
          ? secret
          : (asStr(r['hmac_secret']) ?? ''),
      cursor: asInt(r['cursor']) ?? 0,
      isHub: asInt(r['is_hub']) == 1,
      deviceName: asStr(r['device_name']) ?? '',
      showSeat: asInt(r['show_seat']) == 1,
    );
  }
}

/* ------------------------------------------------------------ Tickets */

class Ticket {
  final String uuid;
  final String no;
  final String status; // valid | checked_in | checked_out | cancelled
  final String? type;
  final String? name;
  final int? orderId;
  final List<String> options;
  final int? age;
  final String ampel; // green | yellow | red
  final String? curfewEnd; // "HH:MM"
  final bool muttizettel;
  final String? table;
  final String? seat;

  Ticket({
    required this.uuid,
    required this.no,
    required this.status,
    this.type,
    this.name,
    this.orderId,
    this.options = const [],
    this.age,
    this.ampel = 'red',
    this.curfewEnd,
    this.muttizettel = false,
    this.table,
    this.seat,
  });

  static const _ampelValues = {'green', 'yellow', 'red'};

  static List<String> _options(Object? v) {
    if (v is! List) return const [];
    return v
        .map((e) => asStr(e) ?? '')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  /// Defensives Parsen eines Manifest-Eintrags. Fehlt die UUID, ist der
  /// Eintrag unbrauchbar (null); jedes andere fehlende oder typfremde Feld
  /// wird übersprungen und durch den Standardwert ersetzt.
  static Ticket? tryFromJson(Map<String, dynamic> j) {
    final uuid = asStr(j['uuid']);
    if (uuid == null || uuid.isEmpty) return null;
    final ampel = asStr(j['ampel']);
    return Ticket(
      uuid: uuid,
      no: asStr(j['no']) ?? '',
      status: asStr(j['status']) ?? 'valid',
      type: asStr(j['type']),
      name: asStr(j['name']),
      orderId: asInt(j['order_id']),
      options: _options(j['options']),
      age: asInt(j['age']),
      ampel: (ampel != null && _ampelValues.contains(ampel)) ? ampel : 'red',
      curfewEnd: asStr(j['curfew_end']),
      muttizettel: asBool(j['muttizettel']),
      table: asStr(j['table']),
      seat: asStr(j['seat']),
    );
  }

  factory Ticket.fromRow(Map<String, Object?> r) => Ticket(
        uuid: asStr(r['uuid']) ?? '',
        no: asStr(r['no']) ?? '',
        status: asStr(r['status']) ?? 'valid',
        type: asStr(r['type']),
        name: asStr(r['name']),
        orderId: asInt(r['order_id']),
        options: (asStr(r['options']) ?? '')
            .split('|')
            .where((s) => s.isNotEmpty)
            .toList(),
        age: asInt(r['age']),
        ampel: asStr(r['ampel']) ?? 'red',
        curfewEnd: asStr(r['curfew_end']),
        muttizettel: asInt(r['muttizettel']) == 1,
        table: asStr(r['table_name']),
        seat: asStr(r['seat']),
      );

  /// SQLite-Zeile für `tickets`.
  Map<String, Object?> toRow(int localEventId) => {
        'local_event_id': localEventId,
        'uuid': uuid,
        'no': no,
        'status': status,
        'type': type,
        'name': name,
        'order_id': orderId,
        'options': options.join('|'),
        'age': age,
        'ampel': ampel,
        'curfew_end': curfewEnd,
        'muttizettel': muttizettel ? 1 : 0,
        'table_name': table,
        'seat': seat,
      };
}

/* ------------------------------------------------------- Scan-Ergebnis */

/// Ergebnis eines Scans für die Vollbild-Anzeige.
enum ScanVerdict {
  ok,
  alreadyIn,
  checkedOut, // Gast war draußen – Wiedereinlass anbieten
  invalid,
  forged,
  cancelled,
  wrongEvent,
}

class ScanResult {
  final ScanVerdict verdict;
  final Ticket? ticket;
  final String? message;
  ScanResult(this.verdict, {this.ticket, this.message});
}

/* ---------------------------------------------------------- Sync-Alarm */

/// Vom Server gemeldete Abweichung zu einem lokal bereits gebuchten Scan:
/// Doppelscan (`conflict`), Ablehnung (`invalid`) oder Serverfehler (`error`).
/// Wird lokal gesammelt und muss vom Personal quittiert werden.
class SyncAlert {
  final int id;
  final int localEventId;
  final String ticketUuid;
  final String kind; // conflict | invalid | error
  final String message;
  final String createdAt;
  final bool acknowledged;

  SyncAlert({
    required this.id,
    required this.localEventId,
    required this.ticketUuid,
    required this.kind,
    required this.message,
    required this.createdAt,
    required this.acknowledged,
  });

  factory SyncAlert.fromRow(Map<String, Object?> r) => SyncAlert(
        id: asInt(r['id']) ?? 0,
        localEventId: asInt(r['local_event_id']) ?? 0,
        ticketUuid: asStr(r['ticket_uuid']) ?? '',
        kind: asStr(r['kind']) ?? 'error',
        message: asStr(r['message']) ?? '',
        createdAt: asStr(r['created_at']) ?? '',
        acknowledged: asInt(r['acknowledged']) == 1,
      );

  String get title {
    switch (kind) {
      case 'conflict':
        return 'DOPPELSCAN';
      case 'invalid':
        return 'VOM SERVER ABGELEHNT';
      default:
        return 'SERVERFEHLER';
    }
  }
}
