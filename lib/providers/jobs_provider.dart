import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/mock_job.dart';
import 'auth_provider.dart';
import 'job_runtime_provider.dart';

/// Every `jobs` column plus the customer's display name from the related
/// `customers` row — the customer name isn't a `jobs` column, which is why
/// job cards showed "Not provided" while it existed all along (the same
/// `customers(household_name)` relation the estimate SMS and invoice PDF
/// already read). See [MockJob.fromMap].
const _jobColumns = '*, customers(household_name)';

const _historyStatuses = {
  JobStatus.complete,
  JobStatus.invoiced,
  JobStatus.paid,
  JobStatus.closed,
};

/// Today's jobs for the signed-in technician, straight from the `jobs`
/// table: `lead_technician_id` matches the technician and `scheduled_start`
/// falls within today, ordered soonest first.
final todaysJobsQueryProvider = FutureProvider<List<MockJob>>((ref) async {
  final technician = ref.watch(authControllerProvider).value;
  if (technician == null) return const [];

  try {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));

    debugPrint('JOBS: querying today\'s jobs for technician ${technician.id}...');
    final rows = await Supabase.instance.client
        .from('jobs')
        .select(_jobColumns)
        .eq('lead_technician_id', technician.id)
        .gte('scheduled_start', startOfDay.toUtc().toIso8601String())
        .lt('scheduled_start', endOfDay.toUtc().toIso8601String())
        .order('scheduled_start', ascending: true);
    debugPrint('JOBS: today\'s jobs query returned ${rows.length} row(s)');

    return rows.map((row) => MockJob.fromMap(row)).toList();
  } catch (e, stackTrace) {
    debugPrint('JOBS ERROR (today\'s jobs): $e\n$stackTrace');
    rethrow;
  }
});

/// Completed/invoiced/paid/closed jobs for the signed-in technician, most
/// recent first.
final historyJobsQueryProvider = FutureProvider<List<MockJob>>((ref) async {
  final technician = ref.watch(authControllerProvider).value;
  if (technician == null) return const [];

  try {
    debugPrint('JOBS: querying job history for technician ${technician.id}...');
    final rows = await Supabase.instance.client
        .from('jobs')
        .select(_jobColumns)
        .eq('lead_technician_id', technician.id)
        .inFilter('status', ['complete', 'invoiced', 'paid', 'closed'])
        .order('scheduled_start', ascending: false);
    debugPrint('JOBS: job history query returned ${rows.length} row(s)');

    return rows.map((row) => MockJob.fromMap(row)).toList();
  } catch (e, stackTrace) {
    debugPrint('JOBS ERROR (job history): $e\n$stackTrace');
    rethrow;
  }
});

/// Today's active jobs (not yet complete), soonest first — powers the Home
/// tab. Reacts to [jobRuntimeProvider] so a job that gets marked complete on
/// the detail screen drops out of this list live.
final todaysJobsProvider = Provider<AsyncValue<List<MockJob>>>((ref) {
  final asyncJobs = ref.watch(todaysJobsQueryProvider);
  return asyncJobs.whenData((jobs) {
    return jobs.where((job) {
      final runtimeStatus = ref.watch(jobRuntimeProvider(job.id)).status;
      return !_historyStatuses.contains(runtimeStatus);
    }).toList();
  });
});

/// Completed/invoiced/paid/closed jobs, most recent first — powers the
/// History tab.
final historyJobsProvider = Provider<AsyncValue<List<MockJob>>>((ref) {
  final asyncJobs = ref.watch(historyJobsQueryProvider);
  return asyncJobs.whenData((jobs) {
    final past = jobs.where((job) {
      final runtimeStatus = ref.watch(jobRuntimeProvider(job.id)).status;
      return _historyStatuses.contains(runtimeStatus);
    }).toList();
    past.sort((a, b) => b.scheduledStart.compareTo(a.scheduledStart));
    return past;
  });
});

/// Looks up a job by id among whichever of today's/history jobs are already
/// loaded — sufficient since job detail screens are only reached by tapping
/// a card from one of those two lists.
final jobByIdProvider = Provider.family<MockJob?, String>((ref, jobId) {
  final todays = ref.watch(todaysJobsQueryProvider).valueOrNull ?? const [];
  final history = ref.watch(historyJobsQueryProvider).valueOrNull ?? const [];
  for (final job in [...todays, ...history]) {
    if (job.id == jobId) return job;
  }
  debugPrint('JOBS: jobByIdProvider found no cached job for id $jobId');
  return null;
});
