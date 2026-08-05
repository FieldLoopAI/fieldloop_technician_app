import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../theme/app_theme.dart';
import 'primary_button.dart';

/// The "soft ask before the hard ask" card, plus its denied/permanently-
/// denied counterparts — one shared, presentational widget for all three
/// permission contexts (camera+mic, location). Callers decide the copy and
/// which action to wire up (request again vs. open Settings); this widget
/// only renders it.
///
/// [compact] renders a small inline banner (used where the surrounding
/// screen must stay fully usable, e.g. the Voice Assistant screen's mic
/// banner) instead of the larger standalone card (used to replace a gated
/// control outright, e.g. Photo Capture's camera preview area, or the first
/// "soft ask" moment).
class PermissionCard extends StatelessWidget {
  const PermissionCard({
    super.key,
    required this.icons,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    this.actionIcon,
    this.compact = false,
  });

  final List<IconData> icons;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;
  final IconData? actionIcon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return compact ? _buildCompact(context) : _buildFull(context);
  }

  Widget _buildCompact(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icons.first, color: AppColors.amber, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textDark),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: const TextStyle(fontSize: 12, color: AppColors.neutralGrey, height: 1.35),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: onAction,
                  child: Text(
                    actionLabel,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primaryGreenDark,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 250.ms);
  }

  Widget _buildFull(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final icon in icons)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AppColors.primaryGreen.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: AppColors.primaryGreen, size: 26),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textDark),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13.5, color: AppColors.neutralGrey, height: 1.45),
          ),
          const SizedBox(height: 20),
          PrimaryButton(label: actionLabel, icon: actionIcon, onPressed: onAction),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: 0.05, end: 0, duration: 300.ms);
  }
}
