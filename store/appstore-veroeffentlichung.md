# VIA Tickets Scan – Weg in den App Store

Stand 01.10.2026. Die App ist in `app/` als Flutter-Projekt vorhanden (Code 0.9.1, bisher nicht kompiliert).
iOS-Apps lassen sich nur auf macOS bauen. Ohne eigenen Mac übernimmt das Codemagic (`app/codemagic.yaml`),
ein Build-Dienst mit Mac-Runnern, der direkt zu TestFlight und in den App Store hochlädt.

## Stammdaten

| | Wert |
|---|---|
| App-Name (Store) | VIA Tickets Scan |
| Bundle-ID | `de.via.tickets.scan` |
| Kategorie | Business (Zweitkategorie: Dienstprogramme) |
| Altersfreigabe | 4+ (keine bedenklichen Inhalte) |
| Preis | kostenlos |
| Verfügbarkeit | nur Deutschland reicht; die App ist ohne gekoppeltes Gerät nur im Demo-Modus nutzbar |
| Mindestversion | iOS 15 (Flutter 3.47) – iPhone 6s/SE und neuer; iPhone 5/5s/6 fallen weg |
| Anbieter | VIA Events GmbH, Grunaer Straße 25, 01069 Dresden |
| Support-URL | öffentliche Seite, z. B. `https://via-jugendweihe.de/tickets-scan` (muss vor der Einreichung existieren) |
| Datenschutz-URL | öffentliche Seite mit dem Text aus `datenschutz.md` |

## Reihenfolge

1. **Apple Developer**: Identifiers → App IDs → neue App-ID `de.via.tickets.scan`, Beschreibung „VIA Tickets Scan", keine
   besonderen Capabilities nötig (Kamera ist keine Capability, nur eine Info.plist-Berechtigung).
2. **App Store Connect** (appstoreconnect.apple.com): Meine Apps → Plus → Neue App: Plattform iOS, Name, Primärsprache Deutsch,
   Bundle-ID aus Schritt 1, SKU `via-tickets-scan`. Die Apple-ID der App (zehnstellige Zahl unter App-Informationen) in
   `codemagic.yaml` eintragen.
3. **App Store Connect API-Key**: Users and Access → Integrations → App Store Connect API → Team-Key erzeugen (Rolle App Manager),
   `.p8` herunterladen (nur einmal möglich), Key-ID und Issuer-ID notieren. Diese drei Werte werden in Codemagic hinterlegt, nicht im Repo.
4. **Repository**: Der Ordner `app/` muss in einem Git-Repository liegen, das Codemagic lesen darf (GitHub privat genügt).
   Vorher einmalig `flutter create .` ausführen, damit `android/` und `ios/` entstehen, und die Anpassungen aus `README.md`
   vornehmen (Bundle-ID, `NSCameraUsageDescription`, Android-Berechtigungen, minSdk 21, iOS 12.0).
5. **Codemagic** (codemagic.io, Anmeldung mit dem Git-Konto): App hinzufügen → Repository wählen → „codemagic.yaml" als
   Konfiguration. Integration `via_appstore` mit dem API-Key aus Schritt 3 anlegen. Build `ios-appstore` starten.
   Erster Build dauert etwa 20 Minuten; danach erscheint der Build in TestFlight.
6. **TestFlight**: In App Store Connect → TestFlight eine interne Testgruppe „VIA Einlass" anlegen, Teammitglieder per
   Apple-ID einladen. Sie installieren die TestFlight-App und darüber den Scanner. Hier den kompletten Ablauf testen:
   Pairing-QR aus dem Shop (nur HTTPS), Manifest laden, Scannen, Offline-Betrieb, Suche, Ausgangsliste, Gerät entfernen.
7. **Store-Eintrag** ausfüllen: Texte aus `beschreibung.md`, Screenshots (siehe unten), Datenschutz-Angaben
   („App-Datenschutz": siehe `datenschutz.md`, Abschnitt Apple-Fragebogen), Hinweise für die Prüfung (unten).
8. In `codemagic.yaml` `submit_to_app_store: true` setzen, Build erneut laufen lassen, dann in App Store Connect
   „Zur Prüfung einreichen". Prüfdauer meist 1–3 Tage.

## Screenshots

Pflicht: iPhone 6,7 Zoll (1290 × 2796) und 6,5 Zoll (1284 × 2778 oder 1242 × 2688); iPad nur, wenn iPad unterstützt wird
(in Xcode „iPhone only" einstellen, dann entfällt iPad). Fünf Motive reichen: Eventliste, Pairing, Scan grün, Scan rot
mit Grund, Suche. Aus dem Simulator oder dem TestFlight-Gerät aufnehmen; keine Personendaten, Testnamen verwenden.

## Hinweise für die App-Prüfung (App Review Notes)

Apple testet die App und braucht einen Weg hinein. Die App hat dafür einen **Demo-Modus**: Auf dem Startbildschirm
„Demo-Event ausprobieren" antippen, dann im Scan-Bildschirm „Demo-Scan ausführen" (Play-Symbol) – zeigt grün, Doppelscan,
Storno und Jugendschutz ohne Kamera und ohne Server. Das in den Notizen beschreiben; zusätzlich optional:

- Einen Test-Shop oder das Live-System mit einem Test-Event, darin ein Scangerät mit Pairing-Code; den Pairing-QR als
  Bild in die Review-Notizen hochladen und zusätzlich ein, zwei Test-Tickets als PDF beilegen, damit der Prüfer scannen kann.
  Der Pairing-Code läuft nach 10 Minuten ab, deshalb einen Code mit langer Gültigkeit erzeugen oder in den Notizen anbieten,
  auf Anfrage einen frischen Code zu liefern. Besser: für die Prüfung ein Gerät mit langlebigem Code vorsehen.
- Text (deutsch oder englisch), zum Beispiel:
  „Diese App dient dem Einlasspersonal unserer Veranstaltungen. Sie wird über einen QR-Code aus unserem Ticket-Shop mit einem
  Event gekoppelt; danach prüft sie Ticket-QR-Codes auch offline. Zum Testen: beigefügten Pairing-QR mit der App scannen,
  anschließend die beigefügten Test-Tickets scannen (erstes Scannen grün, zweites rot „bereits eingecheckt")."
- Kamera-Begründung ist im Info.plist-Text enthalten.

## Was bereits vorbereitet ist

- `app/codemagic.yaml` (iOS + Android), `app/assets/icon/icon.png` (1024 × 1024, Baum auf Weiß) und
  `icon-foreground.png` (Android adaptive), `flutter_launcher_icons`-Konfiguration in `pubspec.yaml`.
- Texte: `beschreibung.md` (Store-Eintrag), `datenschutz.md` (Datenschutzerklärung der App + Angaben für Apples Fragebogen).

## Noch offen

- Erledigt 01.10.2026: Flutter installiert, `flutter create .`, Analyse und 25 Tests fehlerfrei. Offen bleibt der Gerätetest über TestFlight.
- Git-Repository für `app/` (oder das Monorepo) bei GitHub anlegen.
- Öffentliche Support- und Datenschutzseite auf via-jugendweihe.de.
- Android: Google-Play-Konto (einmalig 25 USD) und Signatur-Keystore; bis dahin APK direkt verteilen.
