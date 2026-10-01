/// Gerätetoken und Event-Secret liegen im Secure Storage des Betriebssystems
/// (iOS Keychain, Android EncryptedSharedPreferences), nicht in SQLite
/// (Konzept 9.3). Schlüssel: viat_<localEventId>_token / _secret.
library;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStore {
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String tokenKey(int localEventId) => 'viat_${localEventId}_token';
  static String secretKey(int localEventId) => 'viat_${localEventId}_secret';

  static Future<void> saveCredentials(
    int localEventId, {
    required String token,
    required String secret,
  }) async {
    await _storage.write(key: tokenKey(localEventId), value: token);
    await _storage.write(key: secretKey(localEventId), value: secret);
  }

  static Future<String?> token(int localEventId) async {
    try {
      return await _storage.read(key: tokenKey(localEventId));
    } catch (_) {
      return null;
    }
  }

  static Future<String?> secret(int localEventId) async {
    try {
      return await _storage.read(key: secretKey(localEventId));
    } catch (_) {
      return null;
    }
  }

  static Future<void> delete(int localEventId) async {
    try {
      await _storage.delete(key: tokenKey(localEventId));
      await _storage.delete(key: secretKey(localEventId));
    } catch (_) {
      // Best-effort: fehlender Eintrag ist kein Fehler.
    }
  }
}
