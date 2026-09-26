import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/mock_job.dart';
import '../providers/job_runtime_provider.dart';
import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';
import 'app_components.dart';
import 'status_pill.dart';

enum JobCardVariant {
  /// Home — today's work: scheduled time and a "View Job" action.
  active,

  /// History — past work: date and a quieter "Details" action.
  completed,
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _time(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour >= 12 ? 'PM' : 'AM'}';
}

String _date(DateTime t) => '${_months[t.month - 1]} ${t.day}, ${t.year}';

/// The job card used on Home and History. Customer name is the title (the
/// person the technician is visiting); the job code is secondary metadata;
/// trade is a tag; address sits by a location icon; the live runtime status
/// is a chip top-right. The whole card is tappable AND has an explicit
/// action button — both call [onTap] (same destination as before).
class JobCard extends ConsumerWidget {
  const JobCard({
    super.key,
    required this.job,
    required this.index,
    required this.onTap,
    this.variant = JobCardVariant.active,
    this.fillHeight = false,
  });

  final MockJob job;
  final int index;
  final VoidCallback onTap;
  final JobCardVariant variant;

  /// Stretch to the height it is given, pinning the footer to the bottom —
  /// for side-by-side cards in a [ResponsiveCardGrid] row. Only valid with a
  /// bounded height.
  final bool fillHeight;

  IconData get _tradeIcon {
    final trade = job.tradeCategory.toLowerCase();
    if (trade.contains('plumb')) return Icons.plumbing_rounded;
    if (trade.contains('electr')) return Icons.electrical_services_rounded;
    if (trade.contains('hvac') || trade.contains('cool') || trade.contains('heat')) {
      return Icons.thermostat_rounded;
    }
    if (trade.contains('roof')) return Icons.roofing_rounded;
    if (trade.contains('paint')) return Icons.format_paint_rounded;
    return Icons.handyman_rounded;
  }

  /// Trade icon, customer name over job code/time, and the status pill.
  Widget _header(String meta, JobStatus status, bool completed, {required bool pillBeside}) {
    final pill = StatusPill(status: status.wireValue);
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: completed ? AppSurfaces.tile : AppColors.greenTint,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(
            _tradeIcon,
            color: completed ? AppColors.neutralGrey : AppColors.primaryGreenDark,
            size: 22,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The real customer name; the fallback reads as
              // "missing", never as if it were a name.
              if (job.hasCustomerName)
                Text(
                  job.customerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.title,
                )
              else
                Text(
                  'Customer not on file',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.title.copyWith(
                    color: AppColors.neutralGrey,
                    fontStyle: FontStyle.italic,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(height: 2),
              Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyMuted.copyWith(fontSize: 12.5)),
            ],
          ),
        ),
        if (pillBeside) ...[const SizedBox(width: AppSpacing.xs), pill],
      ],
    );
    if (pillBeside) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [row, const SizedBox(height: AppSpacing.xs), pill],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(jobRuntimeProvider(job.id)).status;
    final completed = variant == JobCardVariant.completed;
    final meta = [
      if (job.hasJobCode) job.jobIdPublic,
      completed ? _date(job.scheduledStart) : _time(job.scheduledStart),
    ].join('  ·  ');

    return AppCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Grid cards are measured by IntrinsicHeight, which a
                // LayoutBuilder can't answer — and at grid widths the pill
                // always fits beside the name anyway.
                if (fillHeight)
                  _header(meta, status, completed, pillBeside: true)
                else
                  LayoutBuilder(
                    builder: (context, constraints) => _header(
                      meta,
                      status,
                      completed,
                      // Beside the name when there's room, under it on a
                      // narrow phone at a large text size.
                      pillBeside: constraints.maxWidth >= 64 + MediaQuery.textScalerOf(context).scale(190),
                    ),
                  ),
                const SizedBox(height: AppSpacing.sm),
                if (isProvided(job.tradeCategory)) ...[
                  _TradeTag(icon: _tradeIcon, label: job.tradeCategory),
                  const SizedBox(height: AppSpacing.xs),
                ],
                if (job.description.trim().isNotEmpty) ...[
                  Text(
                    job.description.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(fontSize: 13.5, color: AppColors.neutralGrey),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 1),
                      child: Icon(Icons.location_on_rounded, size: 16, color: AppColors.primaryGreenDark),
                    ),
                    const SizedBox(width: AppSpacing.xxs + 2),
                    Expanded(
                      child: Text(
                        isProvided(job.serviceAddress) ? job.serviceAddress : 'No address on file',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(fontSize: 13.5),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (fillHeight) const Spacer(),
          const Divider(height: 1, thickness: 1, color: AppSurfaces.outline),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.xs, AppSpacing.xs),
            child: Row(
              children: [
                Icon(
                  completed ? Icons.event_available_rounded : Icons.schedule_rounded,
                  size: 16,
                  color: AppColors.neutralGrey,
                ),
                const SizedBox(width: AppSpacing.xxs + 2),
                Expanded(
                  child: Text(
                    completed ? _date(job.scheduledStart) : 'Scheduled ${_time(job.scheduledStart)}',
                    style: AppText.bodyMuted.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                ),
                if (completed)
                  TextButton.icon(
                    onPressed: onTap,
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.chevron_right_rounded, size: 18),
                    label: const Text('Details'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.primaryGreenDark,
                      minimumSize: const Size(0, 44),
                      textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                    ),
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed: onTap,
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: const Text('View Job'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.greenTint,
                      foregroundColor: AppColors.statusGreenText,
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                      textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ).animate(delay: (50 * index).ms).fadeIn(duration: 260.ms, curve: Curves.easeOut).slideY(
      begin: 0.06,
      end: 0,
      duration: 260.ms,
      curve: Curves.easeOut,
    );
  }
}

class _TradeTag extends StatelessWidget {
  const _TradeTag({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: 3),
      decoration: BoxDecoration(color: AppSurfaces.tile, borderRadius: BorderRadius.circular(AppRadius.sm)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.statusGreyText),
          const SizedBox(width: AppSpacing.xxs),
          Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.statusGreyText),
          ),
        ],
      ),
    );
  }
}
