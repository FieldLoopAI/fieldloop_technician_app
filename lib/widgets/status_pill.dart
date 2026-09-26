import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class _StatusStyle {
  const _StatusStyle(this.foreground, this.background);
  final Color foreground;
  final Color background;
}

/// Job status chip (job cards, Job Details header). One color per state
/// family so status reads at a glance: grey = scheduled/draft, blue = en
/// route, amber = on site (in progress), green = complete/paid, purple =
/// invoiced, slate = closed. Every text/tint pair is contrast-checked (all
/// >= 5.3:1, readable outdoors) — the previous amber/green pairs were
/// below 3.1:1.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status});

  final String status;

  static const Map<String, _StatusStyle> _styles = {
    'draft': _StatusStyle(AppColors.statusGreyText, AppColors.statusGreyTint),
    'scheduled': _StatusStyle(AppColors.statusGreyText, AppColors.statusGreyTint),
    'en_route': _StatusStyle(AppColors.statusBlueText, AppColors.statusBlueTint),
    'on_site': _StatusStyle(AppColors.statusAmberText, AppColors.statusAmberTint),
    'complete': _StatusStyle(AppColors.statusGreenText, AppColors.greenTint),
    'invoiced': _StatusStyle(AppColors.statusPurpleText, AppColors.statusPurpleTint),
    'paid': _StatusStyle(AppColors.statusGreenText, AppColors.greenTint),
    'closed': _StatusStyle(AppColors.statusSlateText, AppColors.statusSlateTint),
  };

  String get _label => status
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  @override
  Widget build(BuildContext context) {
    final style = _styles[status] ?? const _StatusStyle(AppColors.statusGreyText, AppColors.statusGreyTint);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: style.background, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: style.foreground, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              _label.isEmpty ? 'Unknown' : _label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: style.foreground, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
