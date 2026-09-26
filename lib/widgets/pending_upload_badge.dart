import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/offline_upload_queue_provider.dart';
import '../theme/app_theme.dart';

/// "N photos pending upload" pill — shown wherever a job's photo
/// thumbnails are shown (Job Detail, Photo Capture) whenever
/// [pendingUploadCountForJobProvider] is non-zero for [jobId], updating
/// live as `OfflineUploadQueueService` enqueues and drains items. Renders
/// nothing when the count is zero.
class PendingUploadBadge extends ConsumerWidget {
  const PendingUploadBadge({super.key, required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingUploadCountForJobProvider(jobId));
    if (count == 0) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_upload_outlined, size: 13, color: AppColors.amber),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '$count photo${count == 1 ? '' : 's'} pending upload',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.amber),
            ),
          ),
        ],
      ),
    );
  }
}
