import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/pending_visit_event.dart';
import '../utils/network_error.dart';
import 'pending_visit_events_db.dart';

/// Extends the existing GPS arrival system (`arrival_provider.dart`, left
/// untouched) to support multiple arrive/depart cycles per job: automatic
/// departure detection (a debounced geofence-exit timer — see
/// `JobDetailScreen`'s visit-monitoring position stream), automatic
/// re-arrival, the manual "Leaving Site"/"Back on Site" fallback buttons,
/// and the billable-hours computation run when a job is marked complete
/// (`job_complete_provider.dart`).
///
/// Whether job [jobId] currently has an OPEN visit — i.e. the most recent
/// `gps_arrive`/`gps_depart` `field_events` row is an arrival with no
/// matching departure logged after it yet. Non-null means the technician
/// is, as far as `field_events` shows, on site for that visit right now;
/// the value is that visit's arrival timestamp. This is the source of
/// truth both the automatic debounce logic and the manual visit-control
/// buttons key off — always a fresh read, never derived from local widget
/// state, so it stays correct across app restarts/multiple devices.
final openVisitProvider = FutureProvider.family<DateTime?, String>((ref, jobId) async {
  return fetchOpenVisitArrivedAt(jobId);
});

/// Plain (non-provider) version of the same lookup — used directly by
/// `JobCompleteActionController.markComplete` (`job_complete_provider.dart`)
/// to decide whether an open visit needs auto-closing before completion,
/// without that file and this one depending on each other's providers.
Future<DateTime?> fetchOpenVisitArrivedAt(String jobId) async {
  debugPrint('VISIT: checking for an open visit (unmatched gps_arrive) for job $jobId...');
  final rows = await Supabase.instance.client
      .from('field_events')
      .select('event_type, event_ts')
      .eq('job_id', jobId)
      .inFilter('event_type', ['gps_arrive', 'gps_depart'])
      .order('event_ts', ascending: false)
      .limit(1);

  if (rows.isEmpty) {
    debugPrint('VISIT: job $jobId has no arrive/depart events yet — no open visit');
    return null;
  }
  final last = rows.first;
  if (last['event_type'] != 'gps_arrive') {
    debugPrint('VISIT: job $jobId — most recent visit event is a departure, no open visit');
    return null;
  }
  final ts = DateTime.parse(last['event_ts'] as String).toLocal();
  debugPrint('VISIT: job $jobId has an open visit, arrived at $ts');
  return ts;
}

/// Sums every COMPLETE arrive-to-depart pair found in [events] (a job's
/// `gps_arrive`/`gps_depart` `field_events` rows, any order) into total
/// billable hours, rounded to 2 decimal places. Any gap between one
/// visit's departure and the next visit's arrival is excluded by
/// construction — this only ever adds up the time between a logged
/// arrival and its own matching departure, never the time in between
/// visits. An arrival with no matching departure contributes nothing
/// (shouldn't happen by the time this runs — `markComplete` always closes
/// the open visit first — but this stays correct even if one somehow
/// slips through).
double computeBillableHours(List<Map<String, dynamic>> events) {
  final sorted = [...events]
    ..sort((a, b) => (a['event_ts'] as String).compareTo(b['event_ts'] as String));

  DateTime? openArrival;
  var total = Duration.zero;
  for (final row in sorted) {
    final type = row['event_type'] as String?;
    final ts = DateTime.parse(row['event_ts'] as String);
    if (type == 'gps_arrive') {
      openArrival = ts;
    } else if (type == 'gps_depart' && openArrival != null) {
      total += ts.difference(openArrival);
      openArrival = null;
    }
  }

  final hours = total.inSeconds / 3600.0;
  return double.parse(hours.toStringAsFixed(2));
}

// --- Retry/queue resilience for visit-tracking's field_events writes ------
//
// CONFIRMED PROBLEM (real-device testing): a SocketException/ClientException
// "Connection timed out" hit a field_events write mid-test. Before this, that
// insert simply threw and the event was gone — nothing else in this file
// (or JobCompleteActionController's billable_hours pairing) has any way to
// recover a gps_arrive/gps_depart row that was never written, and a missing
// one silently corrupts the arrive-to-depart pairing [computeBillableHours]
// depends on. Every visit-tracking field_events insert now goes through
// [_insertVisitEventResilient] instead of calling Supabase directly.

/// Delays between retry attempts on a NETWORK error specifically (see
/// [isNetworkError]) — 3 retries (4 attempts total including the first),
/// increasing so a longer outage isn't hammered with requests.
const _visitEventRetryDelays = [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 10)];

Map<String, dynamic> _visitEventRow({
  required String jobId,
  required String technicianId,
  required String eventType,
  required String source,
  required DateTime eventTs,
}) {
  return {
    'job_id': jobId,
    'technician_id': technicianId,
    'event_type': eventType,
    'event_ts': eventTs.toUtc().toIso8601String(),
    'metadata': {'source': source},
  };
}

/// Attempts a single `field_events` insert for [row], retrying up to
/// [_visitEventRetryDelays]`.length` times on a NETWORK error specifically.
/// A non-network error (bad data, RLS) is never retried — it rethrows
/// immediately, exactly as an unguarded insert always has, since silently
/// retrying (or queuing) a genuine error would just hide it instead of
/// surfacing it. Returns `true` if the insert eventually succeeded
/// directly, `false` if every retry was exhausted due to network errors —
/// the caller ([_insertVisitEventResilient]) is what queues it locally in
/// that case.
Future<bool> _tryInsertFieldEvent(
  Map<String, dynamic> row, {
  required String eventLabel,
  required String jobId,
}) async {
  for (var attempt = 0; ; attempt++) {
    try {
      await Supabase.instance.client.from('field_events').insert(row);
      if (attempt == 0) {
        debugPrint('VISIT QUEUE: $eventLabel field_events insert succeeded for job $jobId');
      } else {
        debugPrint('VISIT QUEUE: $eventLabel field_events insert succeeded for job $jobId on retry attempt $attempt');
      }
      return true;
    } catch (e, stackTrace) {
      if (!isNetworkError(e)) {
        debugPrint(
          'VISIT QUEUE ERROR: $eventLabel field_events insert failed for job $jobId with a non-network '
          'error, not retrying: $e\n$stackTrace',
        );
        rethrow;
      }
      if (attempt >= _visitEventRetryDelays.length) {
        debugPrint(
          'VISIT QUEUE: $eventLabel field_events insert for job $jobId exhausted all '
          '${_visitEventRetryDelays.length} retries due to network errors — giving up on a direct write: $e',
        );
        return false;
      }
      final delay = _visitEventRetryDelays[attempt];
      debugPrint(
        'VISIT QUEUE: $eventLabel field_events insert for job $jobId failed with a network error '
        '(attempt ${attempt + 1}/${_visitEventRetryDelays.length + 1}) — retrying in ${delay.inSeconds}s: $e',
      );
      await Future.delayed(delay);
    }
  }
}

/// The resilient entry point every visit-tracking `field_events` write
/// (departure, re-arrival) goes through — see [insertDepartureEvent]/
/// [VisitActionController.logReArrival]. Attempts a direct insert with
/// retry ([_tryInsertFieldEvent]); if every retry is exhausted due to a
/// network error, durably queues it locally ([PendingVisitEventsDb])
/// instead of losing it — the same resilience philosophy
/// `OfflineUploadQueueService` already applies to photos
/// (`offline_upload_queue_provider.dart`), applied here to the much
/// smaller `field_events` row itself rather than a file.
/// `VisitTrackingService.startQueueDrain` drains this queue once
/// connectivity is confirmed restored (see `drainPendingVisitEvents`).
/// [eventTs] is
/// captured ONCE by the caller, before the first attempt, so a retried or
/// queued event still records the moment it actually happened, not
/// whenever the write eventually lands.
Future<void> _insertVisitEventResilient({
  required String jobId,
  required String technicianId,
  required String eventType,
  required String source,
  required String eventLabel,
}) async {
  final eventTs = DateTime.now();
  final row = _visitEventRow(
    jobId: jobId,
    technicianId: technicianId,
    eventType: eventType,
    source: source,
    eventTs: eventTs,
  );

  final succeeded = await _tryInsertFieldEvent(row, eventLabel: eventLabel, jobId: jobId);
  if (succeeded) return;

  debugPrint('VISIT QUEUE: queuing $eventLabel locally for job $jobId — will retry once connectivity is restored');
  await PendingVisitEventsDb.instance.insert(
    PendingVisitEvent(
      jobId: jobId,
      technicianId: technicianId,
      eventType: eventType,
      source: source,
      eventTs: eventTs,
      createdAt: DateTime.now(),
    ),
  );
  debugPrint('VISIT QUEUE: $eventLabel queued locally for job $jobId (not lost — will be retried automatically)');
}

/// Retries every locally-queued visit event once — called by
/// `VisitTrackingService` when connectivity is restored, and once at
/// startup to catch anything left over from a previous session that ended
/// while still offline. A row that fails again (still offline, or another
/// transient error) is simply left in the queue for the NEXT connectivity
/// event rather than retried in a tight loop here — [_tryInsertFieldEvent]'s
/// short backoff is only for the moment-of-write case; this IS the
/// longer-running retry mechanism for whatever it couldn't recover from.
/// [ref] is used only to invalidate [openVisitProvider] for a job whose
/// queued event just landed, so the manual "Leaving Site"/"Back on Site"
/// buttons' UI catches up to the now-true remote state.
Future<void> drainPendingVisitEvents(Ref ref) async {
  final pending = await PendingVisitEventsDb.instance.queryRetryable();
  if (pending.isEmpty) return;
  debugPrint('VISIT QUEUE: connectivity restored, found ${pending.length} queued visit event(s) to retry');

  for (final event in pending) {
    final id = event.id;
    if (id == null) continue;
    try {
      final row = _visitEventRow(
        jobId: event.jobId,
        technicianId: event.technicianId,
        eventType: event.eventType,
        source: event.source,
        eventTs: event.eventTs,
      );
      await Supabase.instance.client.from('field_events').insert(row);
      await PendingVisitEventsDb.instance.delete(id);
      debugPrint(
        'VISIT QUEUE: queued ${event.eventType} for job ${event.jobId} (id=$id) sent successfully, removed from queue',
      );
      ref.invalidate(openVisitProvider(event.jobId));
    } catch (e, stackTrace) {
      debugPrint(
        'VISIT QUEUE: queued ${event.eventType} for job ${event.jobId} (id=$id) failed again, leaving it '
        'queued for the next connectivity check: $e\n$stackTrace',
      );
      await PendingVisitEventsDb.instance.updateStatus(id, PendingVisitEventStatus.failed);
    }
  }
}

/// This job's still-queued `gps_arrive`/`gps_depart` events (not yet in
/// `field_events` — see [PendingVisitEventsDb]), in the same
/// `event_type`/`event_ts` row shape [computeBillableHours] expects.
///
/// WHY THIS EXISTS: `JobCompleteActionController.markComplete`
/// (`job_complete_provider.dart`) auto-closes any open visit with a
/// `gps_depart` write immediately before computing `billable_hours` — if
/// THAT specific write hits a network error and gets queued rather than
/// landing directly, a `field_events` query run right after would miss it
/// entirely, undercounting the job's final visit. `markComplete` merges
/// this list into its `field_events` query result before calling
/// [computeBillableHours], so billable_hours is correct immediately even
/// when the very last event is still sitting in the local queue awaiting
/// connectivity — not just eventually, once it drains.
Future<List<Map<String, dynamic>>> pendingVisitEventRowsFor(String jobId) async {
  final pending = await PendingVisitEventsDb.instance.queryRetryable();
  return pending
      .where((event) => event.jobId == jobId)
      .map((event) => {'event_type': event.eventType, 'event_ts': event.eventTs.toUtc().toIso8601String()})
      .toList();
}
// ---------------------------------------------------------------------

/// Shared `gps_depart` insert — called by [VisitActionController.logDeparture]
/// (the automatic 3-minute debounce timeout and the manual "Leaving Site"
/// button both go through that controller) AND directly by
/// `JobCompleteActionController.markComplete` for the auto-close-on-complete
/// case (item 4 of the multi-visit design), which needs this insert as part
/// of its own write sequence rather than through the StateNotifier's
/// separate `AsyncValue` lifecycle. Retried, and queued locally on
/// persistent network failure — see [_insertVisitEventResilient].
Future<void> insertDepartureEvent({
  required String jobId,
  required String technicianId,
  required String source,
}) async {
  await _insertVisitEventResilient(
    jobId: jobId,
    technicianId: technicianId,
    eventType: 'gps_depart',
    source: source,
    eventLabel: 'departure',
  );
}

/// Drives the manual "Leaving Site" / "Back on Site" fallback buttons on
/// Job Detail — mirrors `arrivalActionProvider`'s manual/automatic
/// `source` pattern (`arrival_provider.dart`, left untouched) but for the
/// 2nd-and-later visit cycles that provider was never built to handle.
/// Exposed as an [AsyncValue] for the same reason: a loading state on the
/// button, a real error message surfaced if the write fails.
final visitActionProvider =
    StateNotifierProvider.family<VisitActionController, AsyncValue<void>, String>(
      (ref, jobId) => VisitActionController(ref, jobId),
    );

class VisitActionController extends StateNotifier<AsyncValue<void>> {
  VisitActionController(this._ref, this.jobId) : super(const AsyncData(null));

  final Ref _ref;
  final String jobId;

  /// Logs a `gps_depart` event — the automatic 3-minute debounce timeout
  /// (`source: 'automatic'`) and the manual "Leaving Site" button
  /// (`source: 'manual'`) both call this.
  Future<void> logDeparture({required String technicianId, String source = 'manual'}) async {
    state = const AsyncLoading();
    final result = await AsyncValue.guard(() async {
      await insertDepartureEvent(jobId: jobId, technicianId: technicianId, source: source);
      _ref.invalidate(openVisitProvider(jobId));
    });
    if (!mounted) return;
    state = result;
  }

  /// Logs a fresh `gps_arrive` event for a 2nd-or-later visit — the
  /// automatic immediate-on-re-entry trigger (`source: 'automatic'`) and
  /// the manual "Back on Site" button (`source: 'manual'`) both call this.
  /// Deliberately does NOT touch `jobs.status` or `jobRuntimeProvider`: the
  /// job is already `on_site` from the first arrival and stays that way
  /// through every subsequent depart/re-arrive cycle — only
  /// `markComplete` ever moves it past that.
  /// Retried, and queued locally on persistent network failure — see
  /// [_insertVisitEventResilient].
  Future<void> logReArrival({required String technicianId, String source = 'manual'}) async {
    state = const AsyncLoading();
    final result = await AsyncValue.guard(() async {
      await _insertVisitEventResilient(
        jobId: jobId,
        technicianId: technicianId,
        eventType: 'gps_arrive',
        source: source,
        eventLabel: 're-arrival',
      );
      _ref.invalidate(openVisitProvider(jobId));
    });
    if (!mounted) return;
    state = result;
  }
}
