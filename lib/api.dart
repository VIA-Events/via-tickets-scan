/// REST-Client für die Scan-API des Lizenznehmer-Shops (via-tickets/v1).
/// Die App kennt NUR den Shop – nie den Lizenzserver (Konzept K5→K2: keine Verbindung).
library;
import 'package:dio/dio.dart';

class ScanApi {
  final Dio _dio;
  final String baseUrl;
  final String? token;

  ScanApi(this.baseUrl, {this.token})
      : _dio = Dio(BaseOptions(
          baseUrl: '$baseUrl/wp-json/via-tickets/v1',
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 15),
        )) {
    if (token != null) {
      _dio.options.headers['Authorization'] = 'Bearer $token';
    }
  }

  /// Pairing: Einmalcode einlösen (ohne Token).
  static Future<Map<String, dynamic>> pair(String baseUrl, String code, {String name = ''}) async {
    final dio = Dio(BaseOptions(
        baseUrl: '$baseUrl/wp-json/via-tickets/v1',
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 15)));
    final res = await dio.post<dynamic>('/scan/pair', data: {'code': code, if (name.isNotEmpty) 'name': name});
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Manifest: ohne `since` (bzw. 0) die volle Ticketliste, sonst nur Tickets
  /// mit Version > `since`. Antwort enthält den neuen `cursor`.
  Future<Map<String, dynamic>> manifest({int since = 0}) async {
    final query = <String, dynamic>{};
    if (since > 0) query['since'] = since;
    final res = await _dio.get<dynamic>('/scan/manifest', queryParameters: query);
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<List<dynamic>> pushCheckins(List<Map<String, dynamic>> items) async {
    final res = await _dio.post<dynamic>('/scan/checkins', data: items);
    final data = res.data;
    if (data is Map && data['results'] is List) {
      return data['results'] as List;
    }
    return const [];
  }

  /// Gerät serverseitig abmelden (Token widerrufen).
  Future<void> revokeSelf() async {
    await _dio.post<dynamic>('/scan/revoke-self');
  }

  /* ---------------------------------------------------- Fehler-Helfer */

  /// HTTP-Status einer Dio-Ausnahme (null bei Netzwerkfehler/Timeout).
  static int? statusCode(Object e) =>
      e is DioException ? e.response?.statusCode : null;

  /// WP-REST-Fehlercode (`{"code": "viat_unauthorized", ...}`), falls vorhanden.
  static String? errorCode(Object e) {
    if (e is! DioException) return null;
    final d = e.response?.data;
    if (d is Map && d['code'] is String) return d['code'] as String;
    return null;
  }

  /// Token widerrufen oder abgelaufen (401 `viat_unauthorized`) bzw. Zugriff
  /// verweigert (403).
  static bool isUnauthorized(Object e) {
    final s = statusCode(e);
    return s == 401 || s == 403;
  }
}
