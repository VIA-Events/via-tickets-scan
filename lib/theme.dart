/// VIA-Design für die App – abgeleitet aus dem Claude-Design „Ticketscanner" und dem
/// VIA-Events-Design-System (Tokens colors/typography/spacing, Stand 01.10.2026):
/// Hellblau #00b1eb, Dunkelblau #00467a, Ink #1d2634, Statusfarben nur funktional,
/// strikt eckig (kein border-radius), Alegreya Sans für Überschriften (Ersatz für Flux),
/// Systemschrift für Fließtext (Calibri Light ist nicht frei verteilbar).
library;
import 'package:flutter/material.dart';

class Via {
  static const Color hellblau = Color(0xFF00B1EB);
  static const Color dunkelblau = Color(0xFF00467A);
  static const Color dunkelblauHover = Color(0xFF00365E);
  static const Color ink = Color(0xFF1D2634);
  static const Color hellblauTint = Color(0xFFE0F6FD);
  static const Color dunkelblauTint = Color(0xFFE6EEF4);
  static const Color bgSubtle = Color(0xFFF4F7FA);
  static const Color fg2 = Color(0xFF4A5568);
  static const Color fg3 = Color(0xFF8895A5);
  static const Color border = Color(0xFFD4DCE4);
  static const Color positive = Color(0xFF2F9E66);
  static const Color attention = Color(0xFFE6A23C);
  static const Color negative = Color(0xFFD14343);

  /// Dunkler Kamera-Hintergrund des Scan-Bildschirms.
  static const Color scanDark = Color(0xFF0E151C);
  static const Color scanDark2 = Color(0xFF1A242E);

  static const String display = 'AlegreyaSans';

  static const RoundedRectangleBorder square = RoundedRectangleBorder(borderRadius: BorderRadius.zero);

  /// Überschriften-Stil (Alegreya Sans).
  static TextStyle h(double size, {FontWeight weight = FontWeight.w700, Color? color, double height = 1.2}) =>
      TextStyle(fontFamily: display, fontSize: size, fontWeight: weight, color: color, height: height);

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: dunkelblau, primary: dunkelblau, secondary: hellblau, brightness: Brightness.light),
      scaffoldBackgroundColor: bgSubtle,
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineLarge: h(40, weight: FontWeight.w800, color: dunkelblau, height: 1.1),
        headlineMedium: h(28, color: dunkelblau),
        headlineSmall: h(24, color: dunkelblau),
        titleLarge: h(22, color: dunkelblau),
        titleMedium: h(18, color: ink),
        titleSmall: h(16, color: ink),
        bodyLarge: const TextStyle(fontSize: 16, height: 1.5, color: ink),
        bodyMedium: const TextStyle(fontSize: 15, height: 1.45, color: ink),
        bodySmall: const TextStyle(fontSize: 13, height: 1.4, color: fg2),
        labelLarge: h(16, color: Colors.white),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: dunkelblau,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: h(20, color: Colors.white),
      ),
      cardTheme: const CardThemeData(color: Colors.white, elevation: 0, shape: square, margin: EdgeInsets.zero, surfaceTintColor: Colors.transparent),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: dunkelblau,
          foregroundColor: Colors.white,
          shape: square,
          minimumSize: const Size(44, 52),
          textStyle: h(17),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: dunkelblau,
          side: const BorderSide(color: dunkelblau, width: 1.5),
          shape: square,
          minimumSize: const Size(44, 52),
          textStyle: h(17),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: dunkelblau, shape: square, textStyle: h(16)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: hellblau,
        foregroundColor: Colors.white,
        shape: square,
        extendedTextStyle: TextStyle(fontFamily: display, fontSize: 17, fontWeight: FontWeight.w700),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: hellblau, width: 2)),
        labelStyle: TextStyle(color: fg2),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : fg3),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? hellblau : border),
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 1, space: 1),
      listTileTheme: const ListTileThemeData(shape: square, tileColor: Colors.white),
      dialogTheme: const DialogThemeData(shape: square, backgroundColor: Colors.white),
      snackBarTheme: const SnackBarThemeData(shape: square, backgroundColor: ink, behavior: SnackBarBehavior.floating),
      bottomSheetTheme: const BottomSheetThemeData(shape: square, backgroundColor: Colors.white, surfaceTintColor: Colors.transparent),
    );
  }
}
