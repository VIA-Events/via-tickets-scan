/// HTTP-Server des Hubs im WLAN. Spricht nach innen genau die Scan-API des Shop-Plugins
/// (`/wp-json/via-tickets/v1/scan/*`), deshalb braucht die Scanner-Seite keinen Sonderweg:
/// Ein Scanner koppelt sich mit `http://<hub-ip>:8787` genauso wie mit dem Shop.
///
/// Sicherheit: Pairing nur mit gültigem Code (10 Min.), danach Bearer-Token je Scanner,
/// Token widerrufbar. Der Verkehr läuft unverschlüsselt im lokalen Netz – deshalb
/// eigener Router/Hotspot empfohlen (Hinweis im Hub-Bildschirm).
library;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'hub_service.dart';

class HubServer {
  final HubService service;
  HttpServer? _server;
  int port = 8787;

  /// Aufrufer informieren (UI-Aktualisierung) – z. B. nach Pairing oder Scans.
  final void Function()? onActivity;

  HubServer(this.service, {this.onActivity});

  bool get running => _server != null;

  /// Startet auf 0.0.0.0; weicht auf Folgeports aus, wenn 8787 belegt ist.
  Future<void> start() async {
    if (_server != null) return;
    Object? lastError;
    for (var p = 8787; p < 8797; p++) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, p, shared: true);
        port = p;
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (_server == null) throw StateError('Kein freier Port (8787–8796): $lastError');
    _server!.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// IPv4-Adressen dieses Geräts im lokalen Netz (private Bereiche zuerst).
  static Future<List<String>> localAddresses() async {
    final out = <String>[];
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      for (final i in ifs) {
        for (final a in i.addresses) {
          out.add(a.address);
        }
      }
    } catch (_) {}
    int rank(String ip) {
      if (ip.startsWith('192.168.')) return 0;
      if (ip.startsWith('10.')) return 1;
      if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) return 2;
      if (ip.startsWith('169.254.')) return 9; // link-local (kein DHCP)
      return 5;
    }
    out.sort((a, b) => rank(a).compareTo(rank(b)));
    return out;
  }

  /* ---------------------------------------------------------- Routing */

  static const _prefix = '/wp-json/via-tickets/v1/scan/';

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.contentType = ContentType.json;
    res.headers.set('Cache-Control', 'no-store');
    try {
      final path = req.uri.path;
      if (!path.startsWith(_prefix)) {
        _error(res, 404, 'rest_no_route', 'Keine Route.');
        return;
      }
      final route = path.substring(_prefix.length);
      switch ('${req.method} $route') {
        case 'POST pair':
          await _pair(req, res);
          break;
        case 'GET events':
          if (await _auth(req, res) == null) return;
          _json(res, {'events': [await service.eventPayload()]});
          break;
        case 'GET manifest':
          if (await _auth(req, res) == null) return;
          final since = int.tryParse(req.uri.queryParameters['since'] ?? '') ?? 0;
          _json(res, await service.manifest(since));
          break;
        case 'POST checkins':
          final client = await _auth(req, res);
          if (client == null) return;
          final body = await _body(req);
          if (body is! List) {
            _error(res, 400, 'viat_bad_request', 'Array erwartet.');
            return;
          }
          if (body.length > 200) {
            _error(res, 400, 'viat_batch_too_large', 'Zu viele Scans in einem Batch (maximal 200).');
            return;
          }
          final results = await service.applyCheckins(body, deviceName: client.name, clientId: client.id);
          onActivity?.call();
          _json(res, {'results': results});
          break;
        case 'GET stats':
          if (await _auth(req, res) == null) return;
          _json(res, await service.stats());
          break;
        case 'POST revoke-self':
          final client = await _auth(req, res);
          if (client == null) return;
          await service.revokeClient(client.id);
          onActivity?.call();
          _json(res, {'revoked': true});
          break;
        default:
          _error(res, 404, 'rest_no_route', 'Keine Route.');
      }
    } catch (e) {
      try {
        _error(res, 500, 'viat_hub_error', 'Hub-Fehler: $e');
      } catch (_) {}
    }
  }

  Future<void> _pair(HttpRequest req, HttpResponse res) async {
    final body = await _body(req);
    final code = body is Map ? (body['code']?.toString() ?? '') : '';
    final name = body is Map ? (body['name']?.toString() ?? '') : '';
    final client = await service.redeem(code, name);
    if (client == null) {
      _error(res, 403, 'viat_pair_invalid', 'Pairing-Code ungültig oder abgelaufen.');
      return;
    }
    onActivity?.call();
    _json(res, {
      'device_token': client.token,
      'device_id': client.id,
      'device_name': client.name,
      'hmac_secret': service.event.hmacSecret,
      'event': await service.eventPayload(),
      'settings': await service.settings(),
      'hub': true,
    });
  }

  Future<HubClient?> _auth(HttpRequest req, HttpResponse res) async {
    final h = req.headers.value('authorization') ?? '';
    final token = h.toLowerCase().startsWith('bearer ') ? h.substring(7).trim() : '';
    final client = await service.clientByToken(token);
    if (client == null) {
      _error(res, 401, 'viat_unauthorized', 'Nicht autorisiert.');
      return null;
    }
    return client;
  }

  static Future<dynamic> _body(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    if (text.trim().isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static void _json(HttpResponse res, Object data) {
    res.statusCode = 200;
    res.write(jsonEncode(data));
    unawaited(res.close());
  }

  static void _error(HttpResponse res, int status, String code, String message) {
    res.statusCode = status;
    res.write(jsonEncode({'code': code, 'message': message, 'data': {'status': status}}));
    unawaited(res.close());
  }
}
