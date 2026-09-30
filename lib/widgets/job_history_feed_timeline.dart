import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/job_history_entry.dart';
import '../models/job_photo.dart';
import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';
import 'job_photo_thumbnail.dart';

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
///
/// [photos] — the job's already-loaded photo list (`jobPhotosProvider`, the
/// same one the photo strip and [onTapPhoto] resolve against). When a photo
/// entry's `s3ObjectKey` matches one, its node shows that photo's thumbnail
/// instead of a plain camera icon, so the history scans at a glance. Purely
/// presentational: no extra fetch, and entries without a match look as
/// before.
class JobHistoryFeedTimeline extends StatelessWidget {
  const JobHistoryFeedTimeline({super.key, required this.entries, this.onTapPhoto, this.photos = const []});

  final List<JobHistoryEntry> entries;
  final void Function(JobHistoryEntry entry)? onTapPhoto;
  final List<JobPhoto> photos;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Center(child: Text('No activity yet', style: AppText.bodyMuted)),
      );
    }

    JobPhoto? photoFor(JobHistoryEntry entry) {
      final key = entry.s3ObjectKey;
      if (key == null) return null;
      for (final photo in photos) {
        if (photo.s3Key == key) return photo;
      }
      return null;
    }

    return Column(
      children: [
        for (var i = 0; i < entries.length; i++)
          _TimelineTile(
            entry: entries[i],
            photo: photoFor(entries[i]),
            isFirst: i == 0,
            isLast: i == entries.length - 1,
            index: i,
            onTap: entries[i].isPhoto && onTapPhoto != null ? () => onTapPhoto!(entries[i]) : null,
          ),
      ],
    );
  }
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({
    required this.entry,
    required this.photo,
    required this.isFirst,
    required this.isLast,
    required this.index,
    this.onTap,
  });

  final JobHistoryEntry entry;
  final JobPhoto? photo;
  final bool isFirst;
  final bool isLast;
  final int index;
  final VoidCallback? onTap;

  static const double _nodeSize = 38;

  @override
  Widget build(BuildContext context) {
    final muted = entry.isVoided;
    final tile = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _nodeSize,
            child: Column(
              children: [
                _node(muted),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
                      decoration: BoxDecoration(
                        color: AppSurfaces.outline,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.md, top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          entry.description,
                          style: AppText.body.copyWith(
                            fontWeight: FontWeight.w600,
                            color: muted ? AppColors.neutralGrey : AppColors.textDark,
                          ),
                        ),
                      ),
                      if (entry.isVoided) ...[
                        const SizedBox(width: 6),
                        const StatusChip(tone: StatusTone.neutral, label: 'Voided', icon: Icons.block_rounded),
                      ],
                      if (onTap != null)
                        const Padding(
                          padding: EdgeInsets.only(left: 6, top: 1),
                          child: Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.neutralGrey),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(_formatTime(entry.timestamp), style: AppText.bodyMuted.copyWith(fontSize: 12.5)),
                  if (photo?.hasNote ?? false) ...[
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      '“${photo!.transcript!.trim()}”',
                      style: AppText.body.copyWith(fontSize: 13, fontStyle: FontStyle.italic),
                    ),
                  ],
                  if (entry.isVoided) ...[
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      'Void reason: ${entry.voidReason ?? '—'}',
                      style: AppText.bodyMuted.copyWith(fontSize: 12, fontStyle: FontStyle.italic),
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
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: tile,
      ),
    ).animate(delay: (40 * index).ms).fadeIn(duration: 220.ms).slideX(begin: 0.04, end: 0, duration: 220.ms);
  }

  /// The timeline node: the photo itself for a matched photo entry,
  /// otherwise the entry's icon in a ringed circle. The newest entry
  /// ([isFirst]) gets the filled brand accent.
  Widget _node(bool muted) {
    final matched = photo;
    if (matched != null) {
      return Container(
        width: _nodeSize,
        height: _nodeSize,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppSurfaces.card, width: 2),
          boxShadow: AppShadows.card,
        ),
        clipBehavior: Clip.antiAlias,
        child: JobPhotoThumbnail(photo: matched, iconSize: 14),
      );
    }
    final accent = isFirst && !muted;
    return Container(
      width: _nodeSize,
      height: _nodeSize,
      decoration: BoxDecoration(
        color: accent ? AppColors.primaryGreen : AppColors.greenTint,
        shape: BoxShape.circle,
        border: Border.all(color: AppSurfaces.card, width: 3),
        boxShadow: AppShadows.card,
      ),
      child: Icon(
        entry.icon,
        size: 17,
        color: accent ? Colors.white : (muted ? AppColors.neutralGrey : AppColors.primaryGreenDark),
      ),
    );
  }
}
