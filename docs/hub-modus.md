# Hub-Modus (lokales Netz) – VIA Tickets Scan 1.0.0

Stand 01.10.2026. Ersetzt den TicketCreator-Betrieb „Rechner im Saal + Scanner im LAN" ohne zweites Programm:
Ein iPad oder iPhone mit der App ist der Hub.

## Ablauf am Veranstaltungstag

1. **Vorher (mit Internet, z. B. im Büro):** Hub-Gerät wie jeden Scanner mit dem Event koppeln (Pairing-QR aus dem
   Shop, Event → Scangeräte). Dabei lädt es die komplette Gästeliste. Gerätename z. B. „Hub Einlass".
2. **Vor Ort:** Alle Geräte ins selbe WLAN (eigener Router oder Hotspot empfohlen). Auf dem Hub-Gerät in der
   Eventliste das Hub-Symbol antippen → **Hub starten**. Der Bildschirm zeigt einen Pairing-QR mit der
   WLAN-Adresse (z. B. `http://192.168.0.12:8787`) und einem 10 Minuten gültigen Code.
3. **Scanner koppeln:** In der App „Gerät koppeln", Gerätename eintragen (z. B. „Eingang Süd"), den QR des Hubs
   scannen. Der Scanner bekommt die Gästeliste vom Hub und arbeitet ab jetzt gegen den Hub, nicht gegen den Shop.
   Bis zu sechs Scanner sind getestet; technisch sind es mehr.
4. **Einlass:** Jeder Scan geht an den Hub. Der Hub entscheidet wie der Shop (Doppelscan = Konflikt, Storno = abgelehnt,
   Auslass immer, Wiedereinlass nur wenn erlaubt) und verteilt Statusänderungen alle 5 Sekunden an alle Scanner.
   Fällt das WLAN kurz aus, scannen die Geräte offline weiter und reichen nach.
5. **Zählertafel:** Oben rechts im Hub-Bildschirm der Vollbild-Zähler („412 von 594 eingecheckt", Fortschritt,
   Zahlen je Eingang, letzte Scans). Eignet sich für ein zweites Tablet oder einen Monitor per Bildschirmspiegelung.
6. **Nachher:** Sobald das Hub-Gerät Internet hat (Hotspot, WLAN, Büro), meldet es alle Scans gesammelt an den Shop,
   auch die der Scanner. Im Hub-Bildschirm steht, wie viele Scans noch warten. Erst wenn „Shop erreichbar" und
   0 wartende Scans angezeigt werden, das Event auf dem Hub entfernen.

## Einstellungen im Hub

- **Platz groß anzeigen:** Scanner zeigen nach jedem Scan Bereich, Reihe und Platz in großer Schrift (Jugendweihe).
  Die Einstellung erreicht alle Scanner innerhalb von 5 Sekunden.
- **Scanner trennen:** Gerät aus der Liste entfernen; sein Token wird ungültig, offene Scans darauf bleiben lokal.
- **Neuer Code:** Pairing-Code vorzeitig erneuern.

## Technik

- Server im Gerät (`lib/hub/hub_server.dart`), Port 8787 (Ausweichen bis 8796), spricht exakt die Scan-API des Plugins
  (`/wp-json/via-tickets/v1/scan/pair|events|manifest|checkins|stats|revoke-self`). Scanner brauchen keinen Sonderfall.
- Buchungsregeln in `lib/hub/hub_rules.dart` sind der Spiegel von `Viat_Rest_Scan::checkins()`; Journal `checkin_log`,
  Scanner `hub_clients`, Delta-Cursor über `tickets.version` (DB-Version 3).
- Der Hub reicht fremde Scans unter seinem eigenen Gerätetoken an den Shop weiter; der Shop sieht alle Scans als
  Scans des Hubs, der Gerätename steht im Hub-Journal und in der Zählertafel.
- Verkehr im WLAN ist unverschlüsselt (HTTP). Pairing nur mit Code, danach Token je Scanner. Darum eigener Router oder
  Hotspot statt offenem Location-WLAN. iOS fragt beim ersten Start nach der Berechtigung „Lokales Netzwerk".
- Das Hub-Gerät bleibt wach (Wakelock), die App muss im Vordergrund bleiben; iOS beendet Server im Hintergrund.

## Geräteanforderungen

Flutter 3.47 setzt iOS 15 voraus: iPhone 6s/SE (1. Gen.) und neuer, iPad (5. Gen.) und neuer. iPhone 5, 5s und 6
können die App nicht installieren. Android ab 5.0 (minSdk 21).

## Demo-Modus

Ohne Shop: „Demo-Event ausprobieren" auf dem Startbildschirm legt ein lokales Beispiel-Event mit acht Tickets an
(gültig, storniert, Jugendschutz-Fälle, Plätze). Im Scan-Bildschirm: „Demo-Tickets" zeigt die QR-Codes zum Abscannen
mit einem zweiten Gerät, „Demo-Scan ausführen" wertet ohne Kamera aus. Für Schulung und App-Store-Prüfung gedacht;
Demo-Events sprechen nie mit einem Server.
