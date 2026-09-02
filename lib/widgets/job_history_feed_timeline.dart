import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/job_history_entry.dart';
import '../theme/app_theme.dart';

String _formatTime(DateTime dt) {
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  final suffix = dt.hour >= 12 ? 'PM' : 'AM';
  return '$hour12:$minute $suffix';
}

/// A vertical icon-and-connector timeline of a job's real activity feed
/// (`job_history_feed`) — [JobHistoryScreen]'s data source. Visually
/// matches `JobHistoryTimeline` (icon + connecting line) but works off live
/// [JobHistoryEntry] rows instead of mock data, and makes photo entries
/// tappable via [onTapPhoto].
class JobHistoryFeedTimeline extends StatelessWidget {
  const JobHistoryFeedTimeline({super.key, required this.entries, this.onTapPhoto});

  final List<JobHistoryEntry> entries;
  final void Function(JobHistoryEntry entry)? onTapPhoto;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'No activity yet',
            style: TextStyle(color: AppColors.neutralGrey, fontSize: 14),
          ),
        ),
      );
    }

    return Column(
      children: [
        for (var i = 0; i < entries.length; i++)
          _TimelineTile(
            entry: entries[i],
            isLast: i == entries.length - 1,
            index: i,
            onTap: entries[i].isPhoto && onTapPhoto != null ? () => onTapPhoto!(entries[i]) : null,
          ),
      ],
    );
  }
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({required this.entry, required this.isLast, required this.index, this.onTap});

  final JobHistoryEntry entry;
  final bool isLast;
  final int index;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tile = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.primaryGreen.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(entry.icon, size: 17, color: AppColors.primaryGreen),
              ),
              if (!isLast)
                Expanded(
                  child: Container(width: 2, color: AppColors.borderGrey, margin: const EdgeInsets.symmetric(vertical: 2)),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 20, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          entry.description,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textDark),
                        ),
                      ),
                      if (entry.isVoided) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF3F4F6),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'Voided',
                            style: TextStyle(color: AppColors.neutralGrey, fontSize: 11, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                      if (onTap != null)
                        const Padding(
                          padding: EdgeInsets.only(left: 6, top: 2),
                          child: Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.neutralGreyLight),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatTime(entry.timestamp),
                    style: const TextStyle(fontSize: 12.5, color: AppColors.neutralGreyLight),
                  ),
                  if (entry.isVoided) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Void reason: ${entry.voidReason ?? '—'}',
                      style: const TextStyle(fontSize: 12, color: AppColors.neutralGrey, fontStyle: FontStyle.italic),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: tile,
      ),
    ).animate(delay: (50 * index).ms).fadeIn(duration: 300.ms).slideX(begin: 0.05, end: 0, duration: 300.ms);
  }
}
