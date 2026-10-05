import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'job_runtime_provider.dart';
import 'visit_provider.dart';

/// Whether a manual/geofence arrival has already been logged for this job,
/// straight from `field_events` (`event_type = 'gps_arrive'`). This is the
/// source of truth the UI checks so it doesn't show the "I've Arrived"
/// button again for a job that's already been arrived at.
final arrivalEventProvider = FutureProvider.family<DateTime?, String>((ref, jobId) async {
  try {
    debugPrint('ARRIVAL: checking for an existing gps_arrive event for job $jobId...');
    final rows = await Supabase.instance.client
        .from('field_events')
        .select('event_ts')
        .eq('job_id', jobId)
        .eq('event_type', 'gps_arrive')
        .order('event_ts', ascending: true)
        .limit(1);
    debugPrint('ARRIVAL: gps_arrive lookup returned ${rows.length} row(s) for job $jobId');

    if (rows.isEmpty) return null;
    final raw = rows.first['event_ts'] as String?;
    return raw != null ? DateTime.parse(raw).toLocal() : null;
  } catch (e, stackTrace) {
    debugPrint('ARRIVAL ERROR (lookup): $e\n$stackTrace');
    rethrow;
  }
});

/// Drives the manual "I've Arrived" action: logs a `field_events` row, then
/// flips the job to `on_site`. Exposed as an [AsyncValue] so the UI can show
/// a loading state on the button and surface the real error message if
/// either write fails.
final arrivalActionProvider =
    StateNotifierProvider.family<ArrivalActionController, AsyncValue<void>, String>(
      (ref, jobId) => ArrivalActionController(ref, jobId),
    );

class ArrivalActionController extends StateNotifier<AsyncValue<void>> {
  ArrivalActionController(this._ref, this.jobId) : super(const AsyncData(null));

  final Ref _ref;
  final String jobId;

  /// [source] is stored on the `field_events` row's metadata so `'manual'`
  /// (the "I've Arrived" button / voice "arrived") and `'automatic'`
  /// (geofence trigger) can be told apart later.
  ///
  /// Serialized with every other arrive/depart write for this job and
  /// re-checked against a FRESH read first (see `visit_provider.dart`'s
  /// "Duplicate-arrival protection") — never the cached
  /// [arrivalEventProvider], which still says "not arrived" while another
  /// caller's insert is in flight. Returns [VisitWriteOutcome.alreadyLogged]
  /// without writing if this job already has an arrival, `null` on failure.
  Future<VisitWriteOutcome?> markArrived({required String technicianId, String source = 'manual'}) async {
    state = const AsyncLoading();
    VisitWriteOutcome? outcome;
    final result = await AsyncValue.guard(() async {
      final supabase = Supabase.instance.client;
      final now = DateTime.now();

      try {
        outcome = await runVisitWriteExclusive(jobId, 'first arrival (source=$source)', () async {
          final snapshot = await fetchVisitSnapshot(jobId);
          if (snapshot.everArrived == true) {
            debugPrint(
              'VISIT GUARD: first arrival (source=$source) for job $jobId skipped — an arrival is already '
              'recorded, NOT writing a duplicate On Site marker',
            );
            return VisitWriteOutcome.alreadyLogged;
          }

          debugPrint('ARRIVAL: inserting field_events (gps_arrive, source=$source) for job $jobId...');
          try {
            await supabase.from('field_events').insert({
              'job_id': jobId,
              'technician_id': technicianId,
              'event_type': 'gps_arrive',
              'event_ts': now.toUtc().toIso8601String(),
              'metadata': {'source': source, if (snapshot.nextVisitSeq != null) 'visit_seq': snapshot.nextVisitSeq},
            });
          } catch (e) {
            if (!isDuplicateArrivalError(e)) rethrow;
            debugPrint(
              'VISIT GUARD: first arrival (source=$source) for job $jobId rejected by the DB unique '
              'constraint — already recorded, NOT writing a duplicate',
            );
            return VisitWriteOutcome.alreadyLogged;
          }
          debugPrint('ARRIVAL: field_events insert succeeded for job $jobId');

          debugPrint('ARRIVAL: updating jobs.status to on_site for job $jobId...');
          await supabase.from('jobs').update({'status': 'on_site'}).eq('id', jobId);
          debugPrint('ARRIVAL: jobs.status update succeeded for job $jobId');
          return VisitWriteOutcome.written;
        });
      } catch (e, stackTrace) {
        debugPrint('ARRIVAL ERROR: $e\n$stackTrace');
        rethrow;
      }

      if (outcome == VisitWriteOutcome.written) _ref.read(jobRuntimeProvider(jobId).notifier).setArrived(now);
      _ref.invalidate(arrivalEventProvider(jobId));
      _ref.invalidate(openVisitProvider(jobId));
    });
    if (mounted) state = result;
    return outcome;
  }
}
