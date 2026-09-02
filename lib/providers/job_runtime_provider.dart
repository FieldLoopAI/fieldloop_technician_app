import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../mock_data.dart';
import '../models/mock_history_event.dart';
import '../models/mock_job.dart';
import 'jobs_provider.dart';

/// Statuses a technician can still act on for a job — the single, shared
/// definition of "finished" (anything NOT in this set:
/// complete/invoiced/paid/closed, i.e. `historyJobsQueryProvider`'s
/// statuses) a finished job is read-only for ANY new data, not just voice:
/// no wake-word mic/voice commands (`JobDetailScreen`'s `_voiceEligible`),
/// no "Add Photos" entry point (`_PhotoStrip`) and no camera
/// (`PhotoCaptureScreen`'s own initState guard, defense in depth against
/// reaching that screen some other way), no "Dictate Estimate"/"Add
/// Change Order" tap fallbacks (`_TabContent`'s `voiceEligible`). Every
/// one of those call sites imports this same constant rather than each
/// keeping its own copy, so they can never drift out of sync with each
/// other.
const activeJobStatuses = {JobStatus.scheduled, JobStatus.enRoute, JobStatus.onSite};

/// Live, in-session state for a job's on-site progress: current status plus
/// when the technician arrived/completed the job. Seeded from the job's
/// real status (from the `jobs` table) and mutated by the "I've Arrived" /
/// "Job Complete" actions on the job detail screen — this is what makes
/// those buttons feel real without a round trip on every tap.
class JobRuntimeState {
  const JobRuntimeState({required this.status, this.arrivedAt, this.completedAt});

  final JobStatus status;
  final DateTime? arrivedAt;
  final DateTime? completedAt;

  JobRuntimeState copyWith({JobStatus? status, DateTime? arrivedAt, DateTime? completedAt}) {
    return JobRuntimeState(
      status: status ?? this.status,
      arrivedAt: arrivedAt ?? this.arrivedAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }
}

final jobRuntimeProvider =
    StateNotifierProvider.family<JobRuntimeController, JobRuntimeState, String>(
      (ref, jobId) => JobRuntimeController(jobId, ref.read(jobByIdProvider(jobId))),
    );

class JobRuntimeController extends StateNotifier<JobRuntimeState> {
  JobRuntimeController(this.jobId, MockJob? job) : super(_initialStateFor(jobId, job));

  final String jobId;

  // MOCK DATA - replace with Supabase query (history_events table) once
  // that table exists; until then this only resolves for the mock job ids.
  static DateTime? _arrivalEventTimestamp(String jobId) {
    final events = mockHistoryByJobId[jobId];
    if (events == null) return null;
    for (final event in events) {
      if (event.type == HistoryEventType.arrival) return event.timestamp;
    }
    return null;
  }

  static JobRuntimeState _initialStateFor(String jobId, MockJob? job) {
    if (job == null) return const JobRuntimeState(status: JobStatus.scheduled);

    switch (job.status) {
      case JobStatus.scheduled:
      case JobStatus.enRoute:
        return JobRuntimeState(status: job.status);
      case JobStatus.onSite:
        return JobRuntimeState(
          status: job.status,
          arrivedAt: _arrivalEventTimestamp(jobId) ?? job.scheduledStart,
        );
      case JobStatus.complete:
      case JobStatus.invoiced:
      case JobStatus.paid:
      case JobStatus.closed:
        final arrivedAt = _arrivalEventTimestamp(jobId) ?? job.scheduledStart;
        return JobRuntimeState(
          status: job.status,
          arrivedAt: arrivedAt,
          completedAt: arrivedAt.add(const Duration(hours: 1)),
        );
    }
  }

  /// Applies a confirmed arrival — called by [ArrivalActionController] only
  /// after the real `field_events` insert + `jobs` status update succeed.
  void setArrived(DateTime arrivedAt) {
    if (state.status != JobStatus.scheduled && state.status != JobStatus.enRoute) return;
    state = state.copyWith(status: JobStatus.onSite, arrivedAt: arrivedAt);
  }

  /// Applies a confirmed completion — called by [JobCompleteActionController]
  /// (`job_complete_provider.dart`) only after the real `jobs` status
  /// update + `field_events` insert succeed. Unlike [setArrived], not
  /// gated on the current status: completion no longer requires having
  /// been on-site first (see `job_complete_provider.dart`'s doc comment —
  /// the only real precondition is an explicit confirm), so this always
  /// applies the transition rather than silently no-op'ing on an
  /// unexpected prior status.
  void markComplete() {
    state = state.copyWith(status: JobStatus.complete, completedAt: DateTime.now());
  }
}
