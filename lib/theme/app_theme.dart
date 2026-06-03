import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Centralised colors and theme for the Cardiogram app.
class AppColors {
  AppColors._();

  static const Color background = Color(0xFF000000);
  static const Color surface = Color(0xFF0E0E0E);
  static const Color card = Color(0xFF141414);

  static const Color accentPink = Color(0xFFF8385A);
  static const Color accentPinkDark = Color(0xFFD81E40);

  static const Color connectedGreen = Color(0xFF34C759);
  static const Color ringGreen = Color(0xFF49E06A);
  static const Color ringBlue = Color(0xFF2BB6FF);
  static const Color ecgBlue = Color(0xFF2E8BFF);

  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF8A8A8E);
  static const Color textTertiary = Color(0xFF5A5A5E);

  static const Color divider = Color(0xFF1F1F1F);

  /// Subtle green glow used behind the home headline.
  static const Color homeGlow = Color(0xFF0F3D1E);
}

class AppTheme {
  AppTheme._();

  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: base.colorScheme.copyWith(
        surface: AppColors.background,
        primary: AppColors.accentPink,
        secondary: AppColors.connectedGreen,
      ),
      textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      ),
      splashFactory: InkRipple.splashFactory,
    );
  }
}
