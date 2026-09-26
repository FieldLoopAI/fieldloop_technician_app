import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';

/// Shared building blocks for Home / History / Profile (and future screens):
/// one card, one section header, one grouped-list style, one stat tile, one
/// screen-level empty state — all on the [AppSpacing]/[AppRadius]/
/// [AppShadows]/[AppText] tokens, so screens stop re-declaring their own.

/// Whether a text field holds real data rather than a model's
/// "Not provided" display fallback.
bool isProvided(String? value) => value != null && value.trim().isNotEmpty && value.trim() != 'Not provided';

/// The standard elevated card. With [onTap] it gets an ink ripple clipped
/// to the card's corners.
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(AppSpacing.md), this.onTap});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: AppDecorations.card(),
      child: Material(
        color: Colors.transparent,
        borderRadius: AppRadius.card,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Small uppercase section label above a card or list ("SETTINGS",
/// "TODAY"), with an optional trailing widget (a count, an action).
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xxs, bottom: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(child: Text(title.toUpperCase(), style: AppText.overline)),
          ?trailing,
        ],
      ),
    );
  }
}

/// A grouped list inside one card, with hairline dividers between rows —
/// the Settings-style list.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: AppDecorations.card(),
      child: ClipRRect(
        borderRadius: AppRadius.card,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(height: 1, thickness: 1, indent: 68, color: AppSurfaces.outline),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// One row of a [SettingsGroup]: icon tile, title, optional subtitle, and a
/// chevron when tappable. [destructive] tints it red (e.g. Log Out).
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.destructive = false,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool destructive;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final accent = destructive ? AppColors.statusRedText : AppColors.primaryGreenDark;
    final tint = destructive ? AppColors.statusRedTint : AppColors.greenTint;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(AppRadius.md)),
                  child: Icon(icon, size: 20, color: accent),
                ),
                const SizedBox(width: AppSpacing.sm + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: AppText.body.copyWith(
                          fontWeight: FontWeight.w600,
                          color: destructive ? AppColors.statusRedText : AppColors.textDark,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!, style: AppText.bodyMuted.copyWith(fontSize: 12.5)),
                      ],
                    ],
                  ),
                ),
                if (trailing != null)
                  trailing!
                else if (onTap != null && !destructive)
                  const Icon(Icons.chevron_right_rounded, color: AppColors.neutralGrey),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact number + label tile for the dark-green dashboard header.
class HeaderStat extends StatelessWidget {
  const HeaderStat({super.key, required this.value, required this.label, required this.icon});

  final int value;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      // Three of these share one row, so on a small phone at a large text
      // size the icon gives its room to the number and label.
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            if (constraints.maxWidth >= MediaQuery.textScalerOf(context).scale(72)) ...[
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: AppSpacing.xs),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$value',
                    style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, height: 1.1),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A label on the left and a value (usually money, or a status badge) on
/// the right. The label takes whatever width is left and wraps; the value
/// keeps its natural size up to 60% of the row, past which it scales down
/// — so neither overflows on a small phone at a large text size.
class LabelValueRow extends StatelessWidget {
  const LabelValueRow({super.key, required this.label, required this.value});

  final Widget label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(child: label),
          const SizedBox(width: AppSpacing.sm),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.6),
            child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: value),
          ),
        ],
      ),
    );
  }
}

/// Cards in [columns] equal-width columns, each row as tall as its tallest
/// card; one column is a plain vertical list. Screens pick [columns] from
/// [WindowSize] — one on phones and small tablets, two once there's room
/// for two readable cards side by side.
class ResponsiveCardGrid extends StatelessWidget {
  const ResponsiveCardGrid({super.key, required this.children, this.columns = 1, this.spacing = AppSpacing.sm});

  final List<Widget> children;
  final int columns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < children.length; start += columns) {
      if (start > 0) rows.add(SizedBox(height: spacing));
      if (columns == 1) {
        rows.add(children[start]);
        continue;
      }
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = start; i < start + columns; i++) ...[
                if (i > start) SizedBox(width: spacing),
                Expanded(child: i < children.length ? children[i] : const SizedBox.shrink()),
              ],
            ],
          ),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

/// Screen-level empty/error state (inside a scrollable, so pull-to-refresh
/// still works): a tinted icon circle, a title, supporting text.
class ScreenMessage extends StatelessWidget {
  const ScreenMessage({super.key, required this.icon, required this.title, required this.message, this.tone});

  final IconData icon;
  final String title;
  final String message;

  /// Null = brand green; pass [StatusTone.neutral] for errors/empties that
  /// shouldn't read as positive.
  final StatusTone? tone;

  @override
  Widget build(BuildContext context) {
    final fg = tone?.foreground ?? AppColors.primaryGreenDark;
    final bg = tone?.background ?? AppColors.greenTint;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: Icon(icon, size: 34, color: fg),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(title, textAlign: TextAlign.center, style: AppText.title.copyWith(fontSize: 17)),
          const SizedBox(height: AppSpacing.xxs),
          Text(message, textAlign: TextAlign.center, style: AppText.bodyMuted),
        ],
      ),
    );
  }
}
