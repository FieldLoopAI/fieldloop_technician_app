import 'package:flutter/material.dart';

import '../mock_data.dart';
import '../models/mock_job.dart';
import '../theme/app_theme.dart';
import '../widgets/job_history_timeline.dart';

/// Full-screen version of a job's activity timeline, reachable from the
/// "View Full Timeline" action in the job detail screen's History section.
class JobHistoryScreen extends StatelessWidget {
  const JobHistoryScreen({super.key, required this.job});

  final MockJob job;

  @override
  Widget build(BuildContext context) {
    // MOCK DATA - replace with Supabase query (history_events table, filtered by job_id)
    final events = mockHistoryByJobId[job.id] ?? const [];

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('${job.jobIdPublic} · History'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isTablet = constraints.maxWidth > 600;
            final horizontalPadding = isTablet ? constraints.maxWidth * 0.18 : 20.0;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(horizontalPadding, 20, horizontalPadding, 32),
              child: JobHistoryTimeline(events: events),
            );
          },
        ),
      ),
    );
  }
}
