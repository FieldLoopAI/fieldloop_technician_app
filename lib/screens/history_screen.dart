import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/mock_job.dart';
import '../providers/jobs_provider.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../widgets/job_card.dart';
import 'job_detail_screen.dart';

/// Bottom-nav "History" tab: past jobs (complete/invoiced/paid).
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobsAsync = ref.watch(historyJobsProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(count: jobsAsync.valueOrNull?.length ?? 0),
            Expanded(
              child: jobsAsync.when(
                data: (jobs) => jobs.isEmpty ? const _EmptyState() : _HistoryList(jobs: jobs),
                loading: () => const _LoadingState(),
                error: (error, stackTrace) => const _ErrorState(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.28),
        const Center(child: CircularProgressIndicator(color: AppColors.primaryGreen)),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.18),
        const Center(
          child: Icon(Icons.cloud_off_rounded, size: 56, color: AppColors.neutralGreyLight),
        ),
        const SizedBox(height: 16),
        const Center(
          child: Text(
            "Couldn't load job history",
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textDark),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet = constraints.maxWidth > 600;
        return Padding(
          padding: EdgeInsets.fromLTRB(isTablet ? 32 : 20, 20, isTablet ? 32 : 20, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Job History',
                      style: Theme.of(
                        context,
                      ).textTheme.headlineMedium?.copyWith(fontSize: isTablet ? 28 : 24),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$count completed ${count == 1 ? 'job' : 'jobs'}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ).animate().fadeIn(duration: 300.ms);
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.18),
        const Center(
          child: Icon(Icons.inbox_rounded, size: 56, color: AppColors.neutralGreyLight),
        ),
        const SizedBox(height: 16),
        const Center(
          child: Text(
            'No completed jobs yet',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textDark),
          ),
        ),
      ],
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.jobs});

  final List<MockJob> jobs;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 700;
        final horizontalPadding = isWide ? 32.0 : 16.0;

        if (isWide) {
          return GridView.builder(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              mainAxisExtent: 160,
            ),
            itemCount: jobs.length,
            itemBuilder: (context, index) {
              final job = jobs[index];
              return JobCard(
                job: job,
                index: index,
                onTap: () => Navigator.of(context).push(
                  FadeSlidePageRoute(builder: (_) => JobDetailScreen(jobId: job.id)),
                ),
              );
            },
          );
        }

        return ListView.separated(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 16),
          itemCount: jobs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final job = jobs[index];
            return JobCard(
              job: job,
              index: index,
              onTap: () => Navigator.of(context).push(
                FadeSlidePageRoute(builder: (_) => JobDetailScreen(jobId: job.id)),
              ),
            );
          },
        );
      },
    );
  }
}
