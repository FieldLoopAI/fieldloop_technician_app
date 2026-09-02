import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'job_runtime_provider.dart';
import 'visit_provider.dart';

/// Whether job [jobId] has anything logged that would make "mark complete"
/// unsurprising — any `job_estimates` row (any status) or any `field_events`
/// row with `event_type = 'photo'`. This never blocks completion outright;
/// it only decides which confirmation wording `_handleJobComplete`
/// (`job_voice_commands.dart`) and `_JobCompleteButton`
/// (`job_detail_screen.dart`) show before completing — see
/// [JobCompleteActionController.checkEvidence].
class JobCompleteEvidence {
  const JobCompleteEvidence({required this.hasEstimate, required this.hasPhoto});

  final bool hasEstimate;
  final bool hasPhoto;

  bool get hasAny => hasEstimate || hasPhoto;
}

/// Drives "mark this job complete": the real Supabase writes (`jobs.status`
/// + a `field_events` row), plus the evidence check that decides which
/// confirmation prompt to show first. Exposed as an [AsyncValue] so the
/// on-screen button can show a loading state and surface a real error
/// message if either write fails — same shape as `arrivalActionProvider` in
/// `arrival_provider.dart`, the direct model for this controller.
final jobCompleteActionProvider =
    StateNotifierProvider.family<JobCompleteActionController, AsyncValue<void>, String>(
      (ref, jobId) => JobCompleteActionController(ref, jobId),
    );

class JobCompleteActionController extends StateNotifier<AsyncValue<void>> {
  JobCompleteActionController(this._ref, this.jobId) : super(const AsyncData(null));

  final Ref _ref;
  final String jobId;

  /// See [JobCompleteEvidence]'s doc comment. A plain read, not cached —
  /// called fresh each time a completion is attempted, since the answer can
  /// change between attempts (e.g. a technician adds a photo after an
  /// initial cancel).
  Future<JobCompleteEvidence> checkEvidence() async {
    debugPrint('JOB COMPLETE: checking for job_estimates/photo evidence for job $jobId...');
    final supabase = Supabase.instance.client;
    final estimateRows = await supabase.from('job_estimates').select('id').eq('job_id', jobId).limit(1);
    final photoRows = await supabase
        .from('field_events')
        .select('id')
        .eq('job_id', jobId)
        .eq('event_type', 'photo')
        .limit(1);
    final evidence = JobCompleteEvidence(hasEstimate: estimateRows.isNotEmpty, hasPhoto: photoRows.isNotEmpty);
    debugPrint(
      'JOB COMPLETE: evidence for job $jobId — hasEstimate=${evidence.hasEstimate} '
      'hasPhoto=${evidence.hasPhoto}',
    );
    return evidence;
  }

  /// Marks the job complete for real, only ever called after an explicit
  /// confirm (voice or tap — see the two callers):
  ///  0. If this job has an OPEN visit (an arrive with no matching depart
  ///     yet — see [fetchOpenVisitArrivedAt]), auto-closes it with a
  ///     `gps_depart` event FIRST, before anything else here — the common
  ///     case of "technician taps Job Complete while still on site" should
  ///     never require a separate manual departure step, and the billable
  ///     hours computed in step 4 below need that final depart event to
  ///     already be in `field_events` when it runs.
  ///  1. Inserts a `field_events` row (`event_type = 'job_complete'`)
  ///     recording whether the no-evidence warning was shown — done FIRST,
  ///     WHILE the job is still active, deliberately not after the
  ///     `jobs.status` update below. If `field_events` INSERT is (or ever
  ///     becomes) RLS-scoped to "job still active" — the same idea as the
  ///     read-only-jobs hardening this pairs with (see
  ///     `photo_capture_screen.dart`'s "no new field_events for a finished
  ///     job" guard) — inserting after the status flip would make this
  ///     event log entry itself get rejected by the very policy it's
  ///     trying to comply with. This ordering sidesteps that entirely
  ///     rather than needing a per-event-type carve-out in such a policy.
  ///  2. `jobs.status = 'complete'` — checked for a silent 0-row RLS no-op
  ///     via `.select()` (same guard `job_photos_provider.dart` uses for
  ///     `field_events` updates; `arrival_provider.dart`'s equivalent
  ///     `jobs.status` write does NOT do this, which is a known gap there,
  ///     not a pattern to repeat here).
  ///  3. Syncs local [jobRuntimeProvider] state, which is what
  ///     `JobDetailScreen` reactively watches to flip into its read-only,
  ///     voice-disabled view immediately — see that screen's `ref.listen`
  ///     on `jobRuntimeProvider`.
  ///  4. Computes `billable_hours` from every `gps_arrive`/`gps_depart`
  ///     pair now logged for this job (see [computeBillableHours]) and
  ///     saves it to `jobs.billable_hours` — done last, after the status
  ///     flip, since it's a derived summary of everything above rather
  ///     than something completion depends on.
  Future<void> markComplete({required String technicianId, required JobCompleteEvidence evidence}) async {
    state = const AsyncLoading();
    final result = await AsyncValue.guard(() async {
      final supabase = Supabase.instance.client;
      final now = DateTime.now();
      final warningShown = !evidence.hasAny;

      debugPrint('JOB COMPLETE: checking for an open visit to close before completing job $jobId...');
      final openVisitArrivedAt = await fetchOpenVisitArrivedAt(jobId);
      if (openVisitArrivedAt != null) {
        debugPrint(
          'JOB COMPLETE: job $jobId has an open visit (arrived $openVisitArrivedAt) — '
          'auto-closing it before completion',
        );
        await insertDepartureEvent(jobId: jobId, technicianId: technicianId, source: 'job_complete');
        _ref.invalidate(openVisitProvider(jobId));
      } else {
        debugPrint('JOB COMPLETE: job $jobId has no open visit — nothing to auto-close');
      }

      debugPrint('JOB COMPLETE: inserting field_events (job_complete) for job $jobId (before status flip)...');
      await supabase.from('field_events').insert({
        'job_id': jobId,
        'technician_id': technicianId,
        'event_type': 'job_complete',
        'event_ts': now.toUtc().toIso8601String(),
        'metadata': {
          'warning_shown': warningShown,
          'had_estimate': evidence.hasEstimate,
          'had_photo': evidence.hasPhoto,
        },
      });
      debugPrint('JOB COMPLETE: field_events insert succeeded for job $jobId');

      debugPrint('JOB COMPLETE: updating jobs.status to complete for job $jobId...');
      final updated = await supabase.from('jobs').update({'status': 'complete'}).eq('id', jobId).select('id');
      if (updated.isEmpty) {
        debugPrint('JOB COMPLETE ERROR: jobs.status update matched 0 rows for job $jobId (RLS?)');
        throw StateError('Could not mark this job complete — please try again.');
      }
      debugPrint('JOB COMPLETE: jobs.status update succeeded for job $jobId');

      debugPrint('JOB COMPLETE: computing billable_hours for job $jobId...');
      final visitEvents = await supabase
          .from('field_events')
          .select('event_type, event_ts')
          .eq('job_id', jobId)
          .inFilter('event_type', ['gps_arrive', 'gps_depart']);
      // Merges in any of THIS job's visit events still sitting in the local
      // retry queue (see `pendingVisitEventRowsFor`'s doc comment) — covers
      // the auto-close depart just above landing in the queue rather than
      // field_events directly, so billable_hours is correct now rather than
      // only once that queue eventually drains.
      final pendingEvents = await pendingVisitEventRowsFor(jobId);
      if (pendingEvents.isNotEmpty) {
        debugPrint(
          'JOB COMPLETE: including ${pendingEvents.length} still-queued visit event(s) for job $jobId '
          'in the billable_hours calculation',
        );
      }
      final billableHours = computeBillableHours([...visitEvents, ...pendingEvents]);
      debugPrint('JOB COMPLETE: billable_hours calculated for job $jobId: $billableHours');
      await supabase.from('jobs').update({'billable_hours': billableHours}).eq('id', jobId);

      _ref.read(jobRuntimeProvider(jobId).notifier).markComplete();
      debugPrint('JOB COMPLETE: local jobRuntimeProvider synced to complete for job $jobId');
    });
    if (!mounted) return;
    state = result;
  }
}
