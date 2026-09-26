import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  AppColors._();

  static const Color primaryGreen = Color(0xFF0F9D58);
  static const Color primaryGreenDark = Color(0xFF0B7A43);
  static const Color primaryGreenLight = Color(0xFF34B771);

  static const Color background = Color(0xFFF6FAF7);
  static const Color surface = Color(0xFFFFFFFF);

  static const Color neutralGrey = Color(0xFF6B7280);
  static const Color neutralGreyLight = Color(0xFF9CA3AF);
  static const Color borderGrey = Color(0xFFE5E7EB);
  static const Color textDark = Color(0xFF1F2933);
  static const Color error = Color(0xFFDC2626);
  static const Color amber = Color(0xFFD97706);
  static const Color blue = Color(0xFF2563EB);
  static const Color purple = Color(0xFF7C3AED);

  /// Soft brand tint for icon backdrops (empty states, pills).
  static const Color greenTint = Color(0xFFE3F5E9);

  /// Status-pill pairs (text on tint). The text tones are deliberately darker
  /// than [primaryGreen]/[amber]/[error]: those measure 3.1:1 / 2.9:1 / 4.0:1
  /// on their tints — below WCAG AA's 4.5:1 for small text, and much worse in
  /// outdoor sunlight. These measure 6.3:1 / 6.4:1 / 5.3:1.
  static const Color statusGreenText = Color(0xFF166534);
  static const Color statusAmberText = Color(0xFF92400E);
  static const Color statusAmberTint = Color(0xFFFEF3C7);
  static const Color statusRedText = Color(0xFFB91C1C);
  static const Color statusRedTint = Color(0xFFFEE2E2);
  static const Color statusGreyTint = Color(0xFFF3F4F6);
  static const Color statusGreyText = Color(0xFF4B5563);
  static const Color statusBlueText = Color(0xFF1D4ED8); // 5.5:1 on its tint
  static const Color statusBlueTint = Color(0xFFDBEAFE);
  static const Color statusPurpleText = Color(0xFF6D28D9); // 5.8:1 on its tint
  static const Color statusPurpleTint = Color(0xFFEDE3FB);
  static const Color statusSlateText = Color(0xFF374151); // 8.3:1 on its tint
  static const Color statusSlateTint = Color(0xFFE5E7EB);

  static const LinearGradient screenGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFFFFFF), Color(0xFFE7F5EC)],
  );

  /// Deeper header gradient for screens with small white text on it (Home's
  /// dashboard header): white on these is >= 5.4:1, where white on
  /// [primaryGreen] is only 3.5:1.
  static const LinearGradient dashboardHeaderGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF075C32), primaryGreenDark],
  );

  static const LinearGradient headerGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primaryGreenDark, primaryGreen],
  );
}

class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primaryGreen,
        brightness: Brightness.light,
      ).copyWith(primary: AppColors.primaryGreen, error: AppColors.error),
      scaffoldBackgroundColor: AppColors.background,
    );

    final textTheme = GoogleFonts.interTextTheme(base.textTheme).copyWith(
      headlineMedium: GoogleFonts.poppins(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        color: AppColors.textDark,
      ),
      titleLarge: GoogleFonts.poppins(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: AppColors.textDark,
      ),
      titleMedium: GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.textDark,
      ),
      bodyMedium: GoogleFonts.inter(fontSize: 14, color: AppColors.neutralGrey),
    );

    return base.copyWith(
      textTheme: textTheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.borderGrey),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.borderGrey),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.primaryGreen, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.error, width: 1.6),
        ),
      ),
      // Pill-shaped, with an unmistakable filled selected segment (the M3
      // default tint was too faint to read at a glance / in sunlight).
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          side: const WidgetStatePropertyAll(BorderSide(color: AppColors.borderGrey)),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? AppColors.primaryGreen : AppColors.surface,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? Colors.white : AppColors.neutralGrey,
          ),
          iconColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? Colors.white : AppColors.neutralGrey,
          ),
          textStyle: WidgetStatePropertyAll(GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: EdgeInsets.zero,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.primaryGreen.withValues(alpha: 0.12),
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return GoogleFonts.inter(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AppColors.primaryGreenDark : AppColors.neutralGrey,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? AppColors.primaryGreenDark : AppColors.neutralGrey,
          );
        }),
      ),
    );
  }
}
