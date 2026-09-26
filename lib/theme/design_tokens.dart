import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Design tokens for the Job Details area (Job Details, its four tabs, the
/// Estimate / Change Orders / Invoice screens and the manual-entry forms).
/// [AppTheme.light] owns the Material 3 `ColorScheme` (seeded from the brand
/// green) and the font families; this file owns everything that used to be a
/// one-off per widget: spacing, radii, elevation, surfaces, the type scale,
/// and semantic status colors. New UI in this area should use these instead
/// of literal numbers/colors.

/// 4-point spacing scale.
abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}

abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double pill = 999;

  static final BorderRadius card = BorderRadius.circular(lg);
  static final BorderRadius tile = BorderRadius.circular(md);
}

/// Surface scale: page < card < nested tile. Cards lift off the page with a
/// soft shadow rather than a border; nested tiles (a line item inside a card)
/// use a faint neutral fill instead.
abstract final class AppSurfaces {
  static const Color page = AppColors.background;
  static const Color card = AppColors.surface;
  static const Color tile = Color(0xFFF6F7F9);
  static const Color outline = AppColors.borderGrey;
}

abstract final class AppShadows {
  /// Resting card: a wide soft shadow plus a tight contact shadow.
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x0F101828), blurRadius: 18, offset: Offset(0, 6)),
    BoxShadow(color: Color(0x0A101828), blurRadius: 2, offset: Offset(0, 1)),
  ];

  /// Emphasized card (the job header).
  static const List<BoxShadow> raised = [
    BoxShadow(color: Color(0x1A101828), blurRadius: 24, offset: Offset(0, 10)),
    BoxShadow(color: Color(0x0D101828), blurRadius: 3, offset: Offset(0, 1)),
  ];

  /// Sticky bottom bars — shadow cast upward over scrolling content.
  static const List<BoxShadow> bottomBar = [
    BoxShadow(color: Color(0x14101828), blurRadius: 16, offset: Offset(0, -4)),
  ];
}

abstract final class AppDecorations {
  static BoxDecoration card({List<BoxShadow> shadow = AppShadows.card}) =>
      BoxDecoration(color: AppSurfaces.card, borderRadius: AppRadius.card, boxShadow: shadow);

  static BoxDecoration tile() => BoxDecoration(color: AppSurfaces.tile, borderRadius: AppRadius.tile);
}

/// Type scale. Font family comes from the theme's text theme (Inter), which
/// these merge into via DefaultTextStyle.
abstract final class AppText {
  /// Screen-level headline (job customer name, screen titles in the body).
  static const TextStyle headline = TextStyle(
    fontSize: 21,
    fontWeight: FontWeight.w800,
    color: AppColors.textDark,
    height: 1.2,
  );

  /// Card / section title.
  static const TextStyle title = TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textDark);

  /// Primary body copy.
  static const TextStyle body = TextStyle(fontSize: 14, color: AppColors.textDark, height: 1.35);

  /// Secondary / supporting copy.
  static const TextStyle bodyMuted = TextStyle(fontSize: 13, color: AppColors.neutralGrey, height: 1.35);

  /// Small caps-ish overline for section labels.
  static const TextStyle overline = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    color: AppColors.neutralGrey,
    letterSpacing: 0.4,
  );

  /// Money figures on a row.
  static const TextStyle amount = TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textDark);

  /// A card's headline total (dark green: 5.4:1 on white, readable outdoors).
  static const TextStyle total = TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.primaryGreenDark);
}

/// Semantic status colors, defined once and used for every status chip in
/// this area (change-order approval, invoice payment status, ...). Text
/// tones are contrast-checked against their tints (all >= 5.3:1).
enum StatusTone {
  pending(AppColors.statusAmberText, AppColors.statusAmberTint, Icons.schedule_rounded),
  approved(AppColors.statusGreenText, AppColors.greenTint, Icons.check_circle_rounded),
  declined(AppColors.statusRedText, AppColors.statusRedTint, Icons.cancel_rounded),
  neutral(AppColors.neutralGrey, AppColors.statusGreyTint, Icons.remove_circle_outline_rounded);

  const StatusTone(this.foreground, this.background, this.icon);

  final Color foreground;
  final Color background;
  final IconData icon;
}

/// One pill for every status in this area.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.tone, required this.label, this.icon});

  final StatusTone tone;
  final String label;

  /// Defaults to the tone's own icon.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: tone.background, borderRadius: BorderRadius.circular(AppRadius.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon ?? tone.icon, size: 13, color: tone.foreground),
          const SizedBox(width: AppSpacing.xxs),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tone.foreground, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
