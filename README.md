# VIA Tickets Scan (K5)

Flutter-App (iOS + Android, eine Codebasis) für den Einlass. Offline-first:
Manifest in SQLite, Scans werden lokal gepuffert und idempotent nachgereicht.
Version `1.0.0+3` (siehe `pubspec.yaml`). Betrieb online gegen den Shop oder im WLAN gegen einen Hub
(ein iPad/iPhone mit dieser App, siehe `docs/hub-modus.md`).

## Baubarkeit

Seit 01.10.2026 liegen `android/` und `ios/` im Repo (Bundle-ID `de.via.tickets.scan`, Kamera- und
Lokalnetz-Berechtigungen gesetzt, iOS-Ziel 15.0). Flutter 3.47.5 ist lokal unter `C:\src\flutter` installiert;
`flutter analyze` und `flutter test` (25 Tests, darunter ein Hub-End-to-End-Test über echten HTTP-Server und SQLite)
laufen dort. iOS-Builds über Codemagic (`codemagic.yaml`), siehe `store/appstore-veroeffentlichung.md`.
Hub-Modus: `docs/hub-modus.md`.

Falls die Plattform-Ordner einmal neu erzeugt werden müssen:

```bash
cd app
flutter create . --project-name via_tickets_scan --org de.via.tickets --platforms android,ios
flutter pub get
flutter analyze
flutter test
flutter run
```

`--org de.via.tickets` ergibt die Bundle-ID / Application-ID `de.via.tickets.via_tickets_scan`.
Soll die ID exakt `de.via.tickets.scan` lauten, nach dem Erzeugen anpassen:

- Android: `applicationId "de.via.tickets.scan"` in `android/app/build.gradle`
  (bzw. `build.gradle.kts`) und `namespace` gleichlautend.
- iOS: `PRODUCT_BUNDLE_IDENTIFIER = de.via.tickets.scan;` in
  `ios/Runner.xcodeproj/project.pbxproj` (drei Vorkommen: Debug/Release/Profile).

### Mindestversionen

| Plattform | Wert | Wo |
|---|---|---|
| Android | `minSdk = 21` (mobile_scanner, flutter_secure_storage) | `android/app/build.gradle` → `defaultConfig` |
| iOS | Deployment Target `12.0` | `ios/Podfile` (`platform :ios, '12.0'`) und Xcode → Runner → General |

### Berechtigungen (Kamera)

**iOS** – `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Die Kamera liest die QR-Codes der Tickets und den Pairing-Code aus dem Shop.</string>
```

**Android** – `android/app/src/main/AndroidManifest.xml` (oberhalb von `<application>`):

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-feature android:name="android.hardware.camera" android:required="true" />
```

`mobile_scanner` fordert die Laufzeit-Berechtigung selbst an.

### flutter_secure_storage

Gerätetoken und Event-Secret liegen im Secure Storage (iOS Keychain,
Android EncryptedSharedPreferences), nicht in SQLite.

- **Android:** `minSdk 21` reicht; für EncryptedSharedPreferences ist kein
  weiterer Eintrag nötig. Wird Auto-Backup genutzt, den Secure-Storage-Speicher
  vom Backup ausschließen (`android:allowBackup="false"` oder eine
  `backup_rules.xml`), sonst landen die Token in Google-Backups.
- **iOS:** Keychain Sharing ist nicht nötig. Damit Einträge nicht in
  iCloud-Keychain synchronisiert werden, ist `IOSOptions` auf dem Standard
  (`accessibility: unlocked`, kein `synchronizable`) belassen.
- Beim ersten Start nach dem Update von 0.9.0 werden Klartext-Token aus SQLite
  in den Secure Storage überführt und in SQLite geleert (`AppDb.migrateCredentialsToSecureStorage`).

### Analyse und Tests

`analysis_options.yaml` aktiviert `flutter_lints` plus `strict-casts`,
`strict-inference`, `prefer_single_quotes`, `unawaited_futures`.
`test/exit_list_test.dart` prüft die Mitternachtslogik der Ausgangsliste
(Endzeit 22:00 vor/nach Mitternacht, 00:30, 24:00).

## Architektur

| Datei | Zweck |
|---|---|
| `lib/hub/hub_rules.dart` | Buchungsregeln des Hubs (Spiegel von `/scan/checkins`), reine Funktion |
| `lib/hub/hub_service.dart` | Hub: Pairing-Codes, Scanner, Manifest mit Delta-Cursor, Journal, Zähler, Queue an den Shop |
| `lib/hub/hub_server.dart` | HTTP-Server (dart:io) mit der Scan-API des Plugins auf Port 8787 |
| `lib/screens/hub.dart` | Hub-Bildschirm (Start/Stop, QR, Scanner, Einstellungen) + Vollbild-Zählertafel |
| `lib/demo.dart` | Demo-Event ohne Shop (lokales Secret, QR-Liste, Scan-Simulation) |
| `lib/sounds.dart` | Scan-Töne (assets/sounds, erzeugt mit tools) |
| `lib/main.dart` | Eventliste (mehrere Kopplungen, auch verschiedener Shops); Entfernen = `revoke-self` (best-effort) + Secure Storage + SQLite löschen; Hintergrund-Sync aller Events beim Start |
| `lib/screens/pair.dart` | Pairing-QR scannen → `POST /scan/pair`; Erfolg sofort nach dem Speichern, Manifest lädt danach mit Fortschritt |
| `lib/screens/scan.dart` | Scan grün/rot, Wiedereinlass nach Status, Overlay-Sperre, Sync-Alarme mit Quittierung, Jugendschutz-Badge, Hinweisleiste bei widerrufenem Token |
| `lib/screens/search.dart` | Suche nach Name, Ticket-Nr., Bestell-Nr. + manueller Check-in (`manual_in`) |
| `lib/screens/exit_list.dart` | „Ausgang"-Liste (Endzeit < 30 Min / überfällig), am Eventdatum verankert |
| `lib/qr_verify.dart` | Offline-HMAC-Prüfung der QR-Payload (VT1…), zeitkonstanter Vergleich |
| `lib/sync.dart` | 5-s-Delta-Polling, Checkin-Batches (200), `SyncState` online/offline/unauthorized, Alarme |
| `lib/db.dart` | SQLite (sqflite, Schema-Version 2): events, tickets, pending_checkins, sync_alerts |
| `lib/secure_store.dart` | Gerätetoken + Event-Secret im OS-Secure-Storage |
| `lib/models.dart` | Datenmodelle, defensive JSON-Helfer |
| `lib/api.dart` | REST-Client `via-tickets/v1` (nur Shop, nie Lizenzserver) |

**Abweichung vom Konzept:** `sqflite` statt `drift` (kein Codegen/build_runner
nötig, identische Offline-Fähigkeit). `riverpod` und `dio` wie vorgesehen.

## Server-Vertrag (Stand 10.09.2026)

- Manifest ohne `dob`/`mz_guardian`; Felder `age`, `ampel`, `curfew_end`,
  `muttizettel`, `order_id`, `table`, `seat`.
- `cursor`/`since` ist eine monoton steigende Versionsnummer (opaker Integer);
  ein alter Timestamp-Cursor (≥ 1 000 000 000) löst serverseitig einen
  Vollabgleich aus.
- `/scan/checkins`: `result` ∈ `ok | conflict | invalid | error`; `invalid`-Gründe
  `reentry_disabled`, `not_checked_in`, `cancelled`, `unknown_ticket`, `missing_fields`.
- Widerrufenes/abgelaufenes Token ⇒ 401 `viat_unauthorized`: Polling stoppt,
  rote Leiste „Gerät widerrufen oder abgelaufen – neu koppeln"; lokal
  weiterscannen bleibt möglich, Scans bleiben in der Queue.
- Pairing über http ⇒ 403 `viat_https_required`.

## Verteilung (Konzept 4.1)

- Woche 3: iOS via TestFlight (interne Tester), Android als direkte APK
  (`flutter build apk --release`).
- Woche 6: App Store + Play Store („VIA Tickets Scan").
- Konten (Apple Developer, Google Play, Wallet-Issuer) sofort auf
  VIA Events GmbH beantragen – Vorlaufzeiten!

## App Store / Play Store (Stand 01.10.2026)

Vorbereitung liegt in `store/`: `appstore-veroeffentlichung.md` (Schritt-für-Schritt, Review-Hinweise, Screenshots),
`beschreibung.md` (Store-Texte), `datenschutz.md` (Datenschutzerklärung + Apple-Fragebogen). Cloud-Build ohne Mac über
Codemagic: `codemagic.yaml` (Workflows `ios-appstore` → TestFlight, `android-release` → APK/AAB). App-Icon in `assets/icon/`,
Erzeugung der Plattform-Icons mit `dart run flutter_launcher_icons`.

## Design (01.10.2026)

Die Oberfläche folgt dem Claude-Design „Ticketscanner" (Projekt `aa7a4995-6a32-458d-8bf6-52494831ee7c`,
Design-System „VIA Events Standard"): `lib/theme.dart` trägt die Tokens (Hellblau `#00b1eb`, Dunkelblau
`#00467a`, Ink `#1d2634`, Statusfarben nur funktional, strikt eckig). Überschriften in Alegreya Sans
(`assets/fonts`, SIL OFL), Fließtext in der Systemschrift (Calibri Light ist nicht frei verteilbar). Die
Kopfkachel ist das offizielle `baum-negativ.png` aus dem Design-System (`assets/images/logo-tile.png`).
Bewusste Abweichung wie im Design vermerkt: Statusfarben als Vollfläche im Ergebnis, weil am Einlass ein Blick genügen muss.

Repository: https://github.com/VIA-Events/via-tickets-scan (privat, Hauptzweig `main`, seit 01.10.2026). Push aus dem Ordner `app/` des Monorepos; der Ordner ist ein eigenständiges Git-Repository ohne den restlichen Monorepo-Inhalt.
