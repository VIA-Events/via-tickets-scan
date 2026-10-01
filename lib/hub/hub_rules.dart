/// Buchungsregeln des lokalen Hubs – identisch zu `/scan/checkins` im Shop-Plugin
/// (class-viat-rest-scan.php), damit Scanner am Hub dieselben Antworten bekommen
/// wie am Shop. Reine Funktion, ohne Datenbank (testbar).
library;

/// Ergebnis einer Buchungsentscheidung.
class HubDecision {
  /// ok | conflict | invalid
  final String outcome;

  /// Neuer Ticketstatus bei ok (checked_in | checked_out), sonst null.
  final String? newStatus;

  /// Grund bei invalid: cancelled | not_checked_in | reentry_disabled.
  final String? reason;

  const HubDecision(this.outcome, {this.newStatus, this.reason});

  bool get isOk => outcome == 'ok';
}

/// Entscheidung nach Aktion × Status × Reentry-Flag.
///
/// - Storniert: immer `invalid/cancelled`.
/// - `out`: nur aus `checked_in` erlaubt (Auslass ist unabhängig vom Reentry-Flag
///   immer möglich – Jugendschutz-Ausgangsliste), sonst `invalid/not_checked_in`.
/// - `in`/`manual_in`: `checked_in` ⇒ Konflikt (Doppelscan), `checked_out` ohne
///   Reentry ⇒ `invalid/reentry_disabled`, sonst Einlass.
HubDecision decideCheckin(String status, String action, {required bool reentry}) {
  final act = const {'in', 'out', 'manual_in'}.contains(action) ? action : 'in';
  if (status == 'cancelled') {
    return const HubDecision('invalid', reason: 'cancelled');
  }
  if (act == 'out') {
    if (status != 'checked_in') {
      return const HubDecision('invalid', reason: 'not_checked_in');
    }
    return const HubDecision('ok', newStatus: 'checked_out');
  }
  if (status == 'checked_in') {
    return const HubDecision('conflict');
  }
  if (status == 'checked_out' && !reentry) {
    return const HubDecision('invalid', reason: 'reentry_disabled');
  }
  return const HubDecision('ok', newStatus: 'checked_in');
}

/// Prüft eine UUID (36 Zeichen, 8-4-4-4-12, hex) wie `viat_is_uuid()` im Plugin.
bool isUuid(String s) =>
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(s.toLowerCase());
