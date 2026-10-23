import 'package:flutter/material.dart';

/// Shared equipment-style surfaces and a stable colour for each DSP module.
abstract final class StudioTheme {
  static const background = Color(0xff0c0f13);
  static const panel = Color(0xff151a20);
  static const line = Color(0xff2b333e);
  static const blue = Color(0xff66adff);
  static const nam = Color(0xffffa25c);
  static const ready = Color(0xff74e5bd);
  static const moduleColors = [
    Color(0xffe4bd69), // compressor
    Color(0xff91a9bf), // gate
    nam,
    Color(0xffc7b18d), // cabinet
    Color(0xff70d4ca), // modulation
    Color(0xff71aaff), // delay
    Color(0xffb99aee), // reverb
    Color(0xffef8f6b), // FX block (NAM firmware)
  ];

  static ThemeData get theme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: blue,
      brightness: Brightness.dark,
      surface: panel,
    ).copyWith(primary: blue, outlineVariant: line),
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'Roboto',
        fontSize: 17,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.4,
      ),
    ),
    cardTheme: const CardThemeData(
      color: panel,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        side: BorderSide(color: line),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: background,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    dividerTheme: const DividerThemeData(color: line),
  );
}
