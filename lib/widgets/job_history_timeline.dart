import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/mock_history_event.dart';
import '../theme/app_theme.dart';

String _formatTime(DateTime dt) {
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  final suffix = dt.hour >= 12 ? 'PM' : 'AM';
  return '$hour12:$minute $suffix';
}

/// A vertical icon-and-connector timeline of a job's activity, used both
/// inline in the job detail screen's History section and on the standalone
/// [JobHistoryScreen].
class JobHistoryTimeline extends StatelessWidget {
  const JobHistoryTimeline({super.key, required this.events});

  final List<MockHistoryEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'No activity recorded yet',
            style: TextStyle(color: AppColors.neutralGrey, fontSize: 14),
          ),
        ),
      );
    }

    return Column(
      children: [
        for (var i = 0; i < events.length; i++)
          _TimelineTile(event: events[i], isLast: i == events.length - 1, index: i),
      ],
    );
  }
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({required this.event, required this.isLast, required this.index});

  final MockHistoryEvent event;
  final bool isLast;
  final int index;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
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
                child: Icon(event.type.icon, size: 17, color: AppColors.primaryGreen),
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
                  Text(
                    event.description,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textDark),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatTime(event.timestamp),
                    style: const TextStyle(fontSize: 12.5, color: AppColors.neutralGreyLight),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ).animate(delay: (50 * index).ms).fadeIn(duration: 300.ms).slideX(begin: 0.05, end: 0, duration: 300.ms);
  }
}
