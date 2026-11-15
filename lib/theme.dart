import 'package:flutter/material.dart';

/// Nigraan TV brand theme: red #EF0017 + blue #3D5AFE (same as the
/// nigraantv.xyz house style), clean light professional UI.
class AudioBoxTheme {
  static const Color nigraanRed = Color(0xFFEF0017);
  static const Color nigraanBlue = Color(0xFF3D5AFE);
  static const Color nigraanDark = Color(0xFF1A1A2E);
  static const Color coinGold = Color(0xFFFFB300);

  static ThemeData get light {
    const colorScheme = ColorScheme.light(
      primary: nigraanRed,
      secondary: nigraanBlue,
      surface: Colors.white,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      primaryColor: nigraanRed,
      scaffoldBackgroundColor: const Color(0xFFF6F6F8),
      appBarTheme: const AppBarTheme(
        backgroundColor: nigraanRed,
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 2,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: nigraanRed,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: nigraanBlue,
          side: const BorderSide(color: nigraanBlue),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: Colors.white,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        selectedItemColor: nigraanRed,
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        showUnselectedLabels: true,
      ),
    );
  }
}
