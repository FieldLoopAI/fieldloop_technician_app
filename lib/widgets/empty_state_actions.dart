import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';

/// Shared empty state for the Estimate / Change Orders / Invoice surfaces:
/// a distinct icon, a short headline, muted supporting text, and (optionally)
/// ONE primary action — the manual-entry path. Voice dictation used to be a
/// second button here; it's removed until dictation is rebuilt on the Gemini
/// Live pipeline (the legacy handlers in `job_voice_commands.dart` are kept).
class EmptyStateActions extends StatelessWidget {
  const EmptyStateActions({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
    this.actionLabel,
    this.actionIcon = Icons.add_rounded,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String hint;
  final String? actionLabel;
  final IconData actionIcon;

  /// Null hides the button (e.g. a read-only finished job).
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.greenTint,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primaryGreen.withValues(alpha: 0.18), width: 6),
              ),
              child: Icon(icon, color: AppColors.primaryGreenDark, size: 32),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppText.title.copyWith(fontSize: 17),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: AppText.bodyMuted,
          ),
          if (onAction != null && actionLabel != null) ...[
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              onPressed: onAction,
              icon: Icon(actionIcon, size: 20),
              label: Text(actionLabel!),
              style: primaryActionButtonStyle,
            ),
          ],
        ],
      ),
    );
  }
}

/// The one primary action style for these surfaces — filled brand green,
/// 52dp tall so it's an easy one-handed / gloved target.
final primaryActionButtonStyle = FilledButton.styleFrom(
  backgroundColor: AppColors.primaryGreen,
  foregroundColor: Colors.white,
  minimumSize: const Size.fromHeight(52),
  shadowColor: AppColors.primaryGreenDark,
  padding: const EdgeInsets.symmetric(horizontal: 16),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
).copyWith(
  // Slight lift at rest that flattens on press — clear tap feedback on top of
  // the ripple. Disabled stays flat.
  elevation: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.pressed) || states.contains(WidgetState.disabled) ? 0 : 2,
  ),
);

/// Secondary action style — the existing green outline used across Job Detail.
final secondaryActionButtonStyle = OutlinedButton.styleFrom(
  foregroundColor: AppColors.primaryGreenDark,
  side: const BorderSide(color: AppColors.primaryGreen),
  minimumSize: const Size.fromHeight(48),
  padding: const EdgeInsets.symmetric(horizontal: 16),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
);
