import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/mock_job.dart';
import '../providers/auth_provider.dart';
import '../providers/job_runtime_provider.dart';
import '../providers/jobs_provider.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';
import '../theme/responsive.dart';
import '../widgets/app_components.dart';
import '../widgets/job_card.dart';
import 'job_detail_screen.dart';

const List<String> _weekdayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

const List<String> _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _formatFriendlyDate(DateTime date) {
  final weekday = _weekdayNames[date.weekday - 1];
  final month = _monthNames[date.month - 1];
  return '$weekday, $month ${date.day}';
}

String _greeting(DateTime now) {
  if (now.hour < 12) return 'Good morning';
  if (now.hour < 17) return 'Good afternoon';
  return 'Good evening';
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final technician = ref.watch(authControllerProvider).value;
    if (technician == null) return const Scaffold(body: SizedBox.shrink());

    final jobsAsync = ref.watch(todaysJobsProvider);

    // Large tablets / landscape: two job cards per row in a wider column.
    // Otherwise a single readable-width column, never cards stretched edge
    // to edge. The header shares the cap so its edges line up with the
    // cards'.
    final columns = context.windowSize.isExpanded && (jobsAsync.valueOrNull?.length ?? 0) > 1 ? 2 : 1;
    final maxContentWidth = columns > 1 ? ContentWidth.wide : ContentWidth.reading;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        color: AppColors.primaryGreen,
        onRefresh: () => ref.refresh(todaysJobsQueryProvider.future),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _DashboardHeader(
                firstName: technician.fullName.split(' ').first,
                maxContentWidth: maxContentWidth,
              ),
            ),
            SliverSafeArea(
              top: false,
              sliver: SliverToBoxAdapter(
                child: MaxWidthBox(
                  maxWidth: maxContentWidth,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.lg, AppSpacing.md, AppSpacing.xl),
                    child: jobsAsync.when(
                      data: (jobs) => jobs.isEmpty ? const _NoJobsToday() : _TodaysJobs(jobs: jobs, columns: columns),
                      loading: () => const Padding(
                        padding: EdgeInsets.only(top: AppSpacing.xl * 2),
                        child: Center(child: CircularProgressIndicator(color: AppColors.primaryGreen)),
                      ),
                      error: (error, stackTrace) => const ScreenMessage(
                        icon: Icons.cloud_off_rounded,
                        title: "Couldn't load today's jobs",
                        message: 'Check your connection, then pull down to try again.',
                        tone: StatusTone.neutral,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Greeting + date + an at-a-glance summary of today, on the deep-green
/// dashboard header.
class _DashboardHeader extends ConsumerWidget {
  const _DashboardHeader({required this.firstName, required this.maxContentWidth});

  final String firstName;
  final double maxContentWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // All of today's jobs (including ones already completed today), with
    // each job's LIVE status — so the counts move as the day progresses.
    final todays = ref.watch(todaysJobsQueryProvider).valueOrNull ?? const <MockJob>[];
    var onSite = 0;
    var done = 0;
    for (final job in todays) {
      final status = ref.watch(jobRuntimeProvider(job.id)).status;
      if (status == JobStatus.onSite) onSite++;
      if (!activeJobStatuses.contains(status)) done++;
    }
    final now = DateTime.now();

    return Container(
      decoration: const BoxDecoration(
        gradient: AppColors.dashboardHeaderGradient,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(AppRadius.xl + 8),
          bottomRight: Radius.circular(AppRadius.xl + 8),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxContentWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md + 4, AppSpacing.md, AppSpacing.md + 4, AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _formatFriendlyDate(now).toUpperCase(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xxs),
                            Text(
                              '${_greeting(now)}, $firstName',
                              style: const TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w800),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          firstName.isNotEmpty ? firstName[0].toUpperCase() : '?',
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: [
                      Expanded(
                        child: HeaderStat(value: todays.length, label: 'Today', icon: Icons.event_note_rounded),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: HeaderStat(value: onSite, label: 'On site', icon: Icons.location_on_rounded),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: HeaderStat(value: done, label: 'Done', icon: Icons.task_alt_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).animate().fadeIn(duration: 250.ms);
  }
}

class _TodaysJobs extends StatelessWidget {
  const _TodaysJobs({required this.jobs, required this.columns});

  final List<MockJob> jobs;
  final int columns;

  void _open(BuildContext context, MockJob job) =>
      Navigator.of(context).push(FadeSlidePageRoute(builder: (_) => JobDetailScreen(jobId: job.id)));

  @override
  Widget build(BuildContext context) {
    final single = jobs.length == 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          single ? 'Up next' : "Today's jobs",
          trailing: single ? null : Text('${jobs.length}', style: AppText.overline),
        ),
        ResponsiveCardGrid(
          columns: columns,
          children: [
            for (var i = 0; i < jobs.length; i++)
              JobCard(job: jobs[i], index: i, fillHeight: columns > 1, onTap: () => _open(context, jobs[i])),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        const _VoiceTip(),
      ],
    );
  }
}

class _NoJobsToday extends StatelessWidget {
  const _NoJobsToday();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader('Today'),
        AppCard(
          child: ScreenMessage(
            icon: Icons.beach_access_rounded,
            title: 'No jobs scheduled today',
            message: 'New jobs assigned to you will show up here. Pull down to refresh.',
          ),
        ),
      ],
    );
  }
}

/// Contextual help below the list — gives short job lists a finished,
/// intentional bottom instead of empty space.
class _VoiceTip extends StatelessWidget {
  const _VoiceTip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.greenTint,
        borderRadius: AppRadius.card,
        border: Border.all(color: AppColors.primaryGreen.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.mic_rounded, color: AppColors.statusGreenText, size: 22),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Hands full? ',
                    style: AppText.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.statusGreenText),
                  ),
                  TextSpan(
                    text: 'Open a job and say "FieldLoop" to talk to your assistant.',
                    style: AppText.body.copyWith(color: AppColors.statusGreenText),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 200.ms, duration: 250.ms);
  }
}
