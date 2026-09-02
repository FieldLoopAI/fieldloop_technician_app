import 'package:flutter/material.dart';

import '../providers/job_status_notifications_provider.dart';
import '../theme/app_theme.dart';

/// In-app banner for a [JobStatusNotification] — the visual half of the
/// banner+TTS pattern (see that class's doc comment for the trigger).
/// Shared by `ChangeOrdersScreen` and `EstimateScreen` so a remote
/// approval/decline looks and reads identically on both.
class StatusNotificationBanner extends StatelessWidget {
  const StatusNotificationBanner({super.key, required this.notification, required this.onDismiss});

  final JobStatusNotification notification;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final approved = notification.isApproved;
    final fg = approved ? AppColors.primaryGreenDark : AppColors.neutralGrey;
    final bg = approved ? const Color(0xFFE3F5E9) : const Color(0xFFF3F4F6);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(approved ? Icons.check_circle_rounded : Icons.cancel_rounded, color: fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(notification.bannerTitle, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13)),
                if (notification.summary.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    notification.summary,
                    style: const TextStyle(color: AppColors.neutralGrey, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.neutralGrey),
            onPressed: onDismiss,
            splashRadius: 16,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}
