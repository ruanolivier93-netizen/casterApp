import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/main_shell.dart';

class VideoCasterApp extends StatelessWidget {
  const VideoCasterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ruan Lelanie Caster',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: const MainShell(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final cs = isDark
        ? const ColorScheme(
            brightness: Brightness.dark,
            primary: Color(0xFF87C3FF),
            onPrimary: Color(0xFF0C2136),
            secondary: Color(0xFFA8C8B8),
            onSecondary: Color(0xFF112019),
            error: Color(0xFFFFB4AB),
            onError: Color(0xFF690005),
            surface: Color(0xFF111315),
            onSurface: Color(0xFFF3F4F6),
            surfaceContainerHighest: Color(0xFF23272B),
            onSurfaceVariant: Color(0xFFB8C0C7),
            outline: Color(0xFF7C8791),
            outlineVariant: Color(0xFF30363B),
            shadow: Colors.black,
            scrim: Colors.black,
            inverseSurface: Color(0xFFF3F4F6),
            onInverseSurface: Color(0xFF1A1C1E),
            inversePrimary: Color(0xFF275A87),
            surfaceTint: Color(0xFF87C3FF),
          )
        : const ColorScheme(
            brightness: Brightness.light,
            primary: Color(0xFF275A87),
            onPrimary: Colors.white,
            secondary: Color(0xFF46685A),
            onSecondary: Colors.white,
            error: Color(0xFFBA1A1A),
            onError: Colors.white,
            surface: Color(0xFFF5F1EA),
            onSurface: Color(0xFF191C20),
            surfaceContainerHighest: Color(0xFFE7E0D6),
            onSurfaceVariant: Color(0xFF5A6168),
            outline: Color(0xFF78828B),
            outlineVariant: Color(0xFFD1C8BC),
            shadow: Color(0x1F000000),
            scrim: Colors.black,
            inverseSurface: Color(0xFF2D3135),
            onInverseSurface: Color(0xFFF5F1EA),
            inversePrimary: Color(0xFF87C3FF),
            surfaceTint: Color(0xFF275A87),
          );

    final textTheme = const TextTheme(
      headlineSmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, height: 1.35),
      bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, height: 1.35),
      bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, height: 1.3),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      textTheme: textTheme,
      scaffoldBackgroundColor: cs.surface,
      canvasColor: cs.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: cs.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        shadowColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: cs.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        systemOverlayStyle: isDark
            ? const SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.light,
                systemNavigationBarColor: Colors.transparent,
              )
            : const SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.dark,
                systemNavigationBarColor: Colors.transparent,
              ),
      ),
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: isDark ? const Color(0xFF171A1D) : const Color(0xFFFFFCF7),
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: cs.outlineVariant, width: 1),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: isDark ? const Color(0xFF23272B) : const Color(0xFFE7E0D6),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cs.onSurface);
          }
          return TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: cs.onSurfaceVariant);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: cs.primary, size: 22);
          }
          return IconThemeData(color: cs.onSurfaceVariant, size: 22);
        }),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF171A1D) : const Color(0xFFFFFCF7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: cs.outlineVariant, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: cs.primary, width: 1.2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        hintStyle: TextStyle(color: cs.onSurfaceVariant),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: isDark ? const Color(0xFF171A1D) : const Color(0xFFFFFCF7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        side: BorderSide(color: cs.outlineVariant, width: 1),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: cs.onSurface,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          side: BorderSide(color: cs.outlineVariant, width: 1),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: cs.primary,
        inactiveTrackColor: cs.surfaceContainerHighest,
        thumbColor: cs.primary,
        overlayColor: cs.primary.withAlpha(24),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      ),
      listTileTheme: const ListTileThemeData(
        minLeadingWidth: 24,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: cs.inverseSurface,
      ),
      dividerTheme: DividerThemeData(
        color: cs.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(cs.outlineVariant),
        radius: const Radius.circular(8),
        thickness: WidgetStateProperty.all(3),
      ),
    );
  }
}
