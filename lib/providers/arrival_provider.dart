import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'job_runtime_provider.dart';

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
  /// (the "I've Arrived" button) and `'automatic'` (geofence trigger) can be
  /// told apart later.
  Future<void> markArrived({required String technicianId, String source = 'manual'}) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final supabase = Supabase.instance.client;
      final now = DateTime.now();

      try {
        debugPrint('ARRIVAL: inserting field_events (gps_arrive, source=$source) for job $jobId...');
        await supabase.from('field_events').insert({
          'job_id': jobId,
          'technician_id': technicianId,
          'event_type': 'gps_arrive',
          'event_ts': now.toUtc().toIso8601String(),
          'metadata': {'source': source},
        });
        debugPrint('ARRIVAL: field_events insert succeeded for job $jobId');

        debugPrint('ARRIVAL: updating jobs.status to on_site for job $jobId...');
        await supabase.from('jobs').update({'status': 'on_site'}).eq('id', jobId);
        debugPrint('ARRIVAL: jobs.status update succeeded for job $jobId');
      } catch (e, stackTrace) {
        debugPrint('ARRIVAL ERROR: $e\n$stackTrace');
        rethrow;
      }

      _ref.read(jobRuntimeProvider(jobId).notifier).setArrived(now);
      _ref.invalidate(arrivalEventProvider(jobId));
    });
  }
}
