/// Akustische Rückmeldung beim Scannen (grün/rot/gelb) – kurze WAV-Töne aus assets/sounds.
/// Zusätzlich zur Vibration, damit das Personal auch ohne Blick aufs Display Bescheid weiß.
library;
import 'package:audioplayers/audioplayers.dart';

class Sounds {
  static final AudioPlayer _player = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
  static bool enabled = true;

  static Future<void> ok() => _play('sounds/ok.wav');
  static Future<void> error() => _play('sounds/error.wav');
  static Future<void> warn() => _play('sounds/warn.wav');

  static Future<void> _play(String asset) async {
    if (!enabled) return;
    try {
      await _player.stop();
      await _player.play(AssetSource(asset), volume: 1.0);
    } catch (_) {
      // Ton ist Komfort – nie den Scan blockieren.
    }
  }
}
