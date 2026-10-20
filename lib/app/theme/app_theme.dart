import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_colors.dart';
import 'app_palette.dart';

abstract final class AppTheme {
  static ThemeData get light => lightFor();
  static ThemeData get dark => darkFor();
  static ThemeData lightFor({AppPalette palette = AppPalette.sanaaNight}) =>
      _build(Brightness.light, palette);
  static ThemeData darkFor({AppPalette palette = AppPalette.sanaaNight}) =>
      _build(Brightness.dark, palette);

  static ThemeData _build(Brightness brightness, AppPalette palette) {
    final dark = brightness == Brightness.dark;
    final surface = dark ? AppColors.darkSurface : AppColors.lightSurface;
    final ink = dark ? AppColors.darkText : AppColors.lightText;
    final muted = dark ? AppColors.darkMuted : AppColors.lightMuted;
    final primary = dark && palette == AppPalette.sanaaNight
        ? const Color(0xFFA5D3BB)
        : palette.colors.primary;
    final scheme = ColorScheme.fromSeed(
      seedColor: palette.colors.primary,
      brightness: brightness,
      primary: primary,
      onPrimary: dark ? AppColors.darkBackground : Colors.white,
      secondary: dark ? const Color(0xFFE0B98D) : palette.colors.secondary,
      surface: surface,
      onSurface: ink,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          dark ? AppColors.darkBackground : AppColors.lightBackground,
      fontFamily: 'BeINArabic',
    );
    final text = base.textTheme.apply(bodyColor: ink, displayColor: ink);
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(18));
    return base.copyWith(
      textTheme: text.copyWith(
        headlineLarge: text.headlineLarge?.copyWith(
          fontSize: 34,
          fontWeight: FontWeight.w700,
          height: 1.45,
        ),
        headlineMedium: text.headlineMedium?.copyWith(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          height: 1.45,
        ),
        headlineSmall: text.headlineSmall
            ?.copyWith(fontSize: 24, fontWeight: FontWeight.w700),
        titleLarge: text.titleLarge
            ?.copyWith(fontSize: 21, fontWeight: FontWeight.w700),
        titleMedium: text.titleMedium
            ?.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
        bodyLarge: text.bodyLarge?.copyWith(fontSize: 16, height: 1.65),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 14, height: 1.6),
        bodySmall:
            text.bodySmall?.copyWith(fontSize: 12, height: 1.6, color: muted),
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: base.scaffoldBackgroundColor,
        foregroundColor: ink,
        toolbarHeight: 76,
        titleSpacing: 8,
        titleTextStyle: text.titleLarge
            ?.copyWith(fontSize: 20, fontWeight: FontWeight.w700),
        systemOverlayStyle:
            dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? AppColors.darkSurfaceAlt : const Color(0xFFF5F6F2),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 19),
        labelStyle: TextStyle(color: muted, fontSize: 14),
        prefixIconColor: primary,
        suffixIconColor: muted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: ink.withValues(alpha: .07)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.error),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 54),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: shape,
          textStyle: const TextStyle(
            fontFamily: 'BeINArabic',
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 50),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: shape,
          side: BorderSide(color: primary.withValues(alpha: .22)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: shape,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: ink.withValues(alpha: .07)),
        ),
      ),
      chipTheme: ChipThemeData(
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        backgroundColor: primary.withValues(alpha: .08),
        labelStyle:
            TextStyle(color: primary, fontFamily: 'BeINArabic', fontSize: 11),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      ),
      dividerTheme:
          DividerThemeData(color: ink.withValues(alpha: .09), space: 28),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF174C43),
        contentTextStyle:
            const TextStyle(fontFamily: 'BeINArabic', color: Colors.white),
        shape: shape,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 78,
        indicatorColor: primary.withValues(alpha: .1),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? primary : muted,
            size: 24,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontFamily: 'BeINArabic',
            fontSize: 11,
            fontWeight: s.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w400,
            color: s.contains(WidgetState.selected) ? primary : muted,
          ),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: primary,
        unselectedLabelColor: muted,
        dividerColor: Colors.transparent,
        indicatorColor: primary,
        labelStyle: const TextStyle(
          fontFamily: 'BeINArabic',
          fontWeight: FontWeight.w700,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: primary),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
    );
  }
}
