import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/mock_job.dart';
import '../providers/jobs_provider.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';
import '../theme/responsive.dart';
import '../widgets/app_components.dart';
import '../widgets/job_card.dart';
import 'job_detail_screen.dart';

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// How many jobs render before "Show more" — keeps a long history fast to
/// open; the rest are already loaded and revealed a page at a time.
const int _pageSize = 20;

/// Section label for a job's date: Today / Yesterday / weekday (this week) /
/// "Sep 12, 2026".
String _dayLabel(DateTime date, DateTime now) {
  final day = DateTime(date.year, date.month, date.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff > 1 && diff < 7) return _weekdays[date.weekday - 1];
  return '${_months[date.month - 1]} ${date.day}, ${date.year}';
}

/// Bottom-nav "History" tab: past jobs (complete/invoiced/paid/closed).
/// Data is re-queried each time this tab is selected — see
/// `RootShell.onDestinationSelected`, which invalidates
/// [historyJobsQueryProvider] on tab switch since this screen stays
/// mounted for the whole session inside `RootShell`'s `IndexedStack`.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  int _visible = _pageSize;

  @override
  Widget build(BuildContext context) {
    final jobsAsync = ref.watch(historyJobsProvider);

    // Same rule as Home: two cards per row only on expanded widths with more
    // than one job, otherwise one readable-width column.
    final columns = context.windowSize.isExpanded && (jobsAsync.valueOrNull?.length ?? 0) > 1 ? 2 : 1;
    final maxContentWidth = columns > 1 ? ContentWidth.wide : ContentWidth.reading;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        color: AppColors.primaryGreen,
        onRefresh: () => ref.refresh(historyJobsQueryProvider.future),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _Header(count: jobsAsync.valueOrNull?.length, maxContentWidth: maxContentWidth),
            ),
            SliverSafeArea(
              top: false,
              sliver: SliverToBoxAdapter(
                child: MaxWidthBox(
                  maxWidth: maxContentWidth,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.lg, AppSpacing.md, AppSpacing.xl),
                    child: jobsAsync.when(
                      data: (jobs) => jobs.isEmpty
                          ? const AppCard(
                              child: ScreenMessage(
                                icon: Icons.inventory_2_outlined,
                                title: 'No completed jobs yet',
                                message: "Jobs you finish will be listed here, newest first.",
                              ),
                            )
                          : _GroupedHistory(
                              jobs: jobs,
                              visible: _visible,
                              columns: columns,
                              onShowMore: () => setState(() => _visible += _pageSize),
                            ),
                      loading: () => const Padding(
                        padding: EdgeInsets.only(top: AppSpacing.xl * 2),
                        child: Center(child: CircularProgressIndicator(color: AppColors.primaryGreen)),
                      ),
                      error: (error, stackTrace) => const ScreenMessage(
                        icon: Icons.cloud_off_rounded,
                        title: "Couldn't load job history",
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

/// Compact version of Home's deep-green dashboard header.
class _Header extends StatelessWidget {
  const _Header({required this.count, required this.maxContentWidth});

  /// Null while loading.
  final int? count;
  final double maxContentWidth;

  @override
  Widget build(BuildContext context) {
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
              // A Wrap, not a Row: title and count sit at opposite ends when
              // they fit, and the count drops to its own line (instead of
              // crushing the title) on a small phone at a large text size.
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    const Text(
                      'Job History',
                      style: TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w800),
                    ),
                    if (count != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.task_alt_rounded, size: 16, color: Colors.white),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                '$count completed',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ).animate().fadeIn(duration: 250.ms);
  }
}

/// Completed jobs grouped under date headings (the list is already newest
/// first — see `historyJobsProvider`), first [visible] only, then a
/// "Show more" control.
class _GroupedHistory extends StatelessWidget {
  const _GroupedHistory({required this.jobs, required this.visible, required this.columns, required this.onShowMore});

  final List<MockJob> jobs;
  final int visible;
  final int columns;
  final VoidCallback onShowMore;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final shown = jobs.take(visible).toList();

    // Consecutive runs of jobs under the same day label (the list is
    // already newest first).
    final groups = <(String, List<(int, MockJob)>)>[];
    for (var i = 0; i < shown.length; i++) {
      final label = _dayLabel(shown[i].scheduledStart, now);
      if (groups.isEmpty || groups.last.$1 != label) groups.add((label, []));
      groups.last.$2.add((i, shown[i]));
    }

    final children = <Widget>[];
    for (final (label, entries) in groups) {
      if (children.isNotEmpty) children.add(const SizedBox(height: AppSpacing.lg - 4));
      children
        ..add(SectionHeader(label))
        ..add(
          ResponsiveCardGrid(
            columns: columns,
            children: [
              for (final (i, job) in entries)
                JobCard(
                  job: job,
                  index: i < _pageSize ? i : 0,
                  variant: JobCardVariant.completed,
                  fillHeight: columns > 1,
                  onTap: () =>
                      Navigator.of(context).push(FadeSlidePageRoute(builder: (_) => JobDetailScreen(jobId: job.id))),
                ),
            ],
          ),
        );
    }

    final remaining = jobs.length - shown.length;
    if (remaining > 0) {
      children
        ..add(const SizedBox(height: AppSpacing.md))
        ..add(
          MaxWidthBox(
            maxWidth: ContentWidth.form,
            child: OutlinedButton.icon(
              onPressed: onShowMore,
              icon: const Icon(Icons.expand_more_rounded),
              label: Text('Show ${remaining < _pageSize ? remaining : _pageSize} more  ·  $remaining left'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primaryGreenDark,
                side: const BorderSide(color: AppSurfaces.outline),
                backgroundColor: AppSurfaces.card,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                textStyle: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        );
    } else if (jobs.length > 3) {
      children
        ..add(const SizedBox(height: AppSpacing.lg))
        ..add(Center(child: Text("That's everything", style: AppText.bodyMuted)));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}
