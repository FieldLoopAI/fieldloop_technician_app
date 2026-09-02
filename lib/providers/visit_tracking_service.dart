import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../models/mock_job.dart';
import '../utils/network_error.dart';
import 'auth_provider.dart';
import 'job_runtime_provider.dart';
import 'jobs_provider.dart';
import 'visit_provider.dart';

/// Geofence radius for automatic departure/re-arrival detection — the same
/// 150ft (45m) radius `JobDetailScreen`'s own arrival geofencing (untouched
/// by this file) already uses for the very first arrival.
const double _geofenceRadiusMeters = 45.0;

/// How long a technician must be CONTINUOUSLY outside [_geofenceRadiusMeters]
/// before an automatic departure is logged. Not a single-reading trigger
/// (unlike arrival): normal on-site movement or GPS jitter right at the
/// boundary must not falsely end a visit, so this is a debounce timer that
/// starts the moment they first go outside and is cancelled/reset the
/// moment they're seen back inside before it elapses.
const Duration _departureDebounceDuration = Duration(minutes: 3);

/// Tracks automatic departure/re-arrival for EXACTLY ONE job at a time —
/// whichever job the technician currently has "entered". [enterJobScope]/
/// [exitJobScope] are called from the exact same trigger points
/// `JobDetailScreen` already calls `GlobalVoiceService.enterJobScope`/
/// `exitJobScope` from for this same job — its own `initState`/`dispose` —
/// so a job is "entered" for as long as its detail screen is open and
/// "exited" the moment the technician marks it complete or navigates away
/// (back to the app's own Home tab, to a different job, or logs out).
///
/// WHY THIS IS ITS OWN APP-WIDE SINGLETON, not `JobDetailScreen`'s own
/// widget state (which is what originally owned this position
/// stream/debounce timer): a `StreamSubscription`/`Timer` field on a
/// `State` object only keeps running for as long as that State is
/// mounted. Minimizing the app (the device's own Home button) does not by
/// itself dispose `JobDetailScreen` — but tying this to a screen's mount
/// state at all makes it fragile against any future widget-lifecycle
/// churn (screen rebuilds, the Android activity being recreated, etc.).
/// Hosting it here instead, exactly mirroring `GlobalVoiceService`'s own
/// lifetime (`global_voice_service_provider.dart` — created once, kept
/// alive for the whole authenticated session, torn down only by an
/// explicit call), means it is unaffected by any of that: only
/// [exitJobScope] (or [stopForLogout]) ever stops it. As with the
/// existing arrival system, the position stream itself continuing to
/// deliver updates while the OS has backgrounded the app still depends on
/// background ("Always") location permission being granted — see
/// [_startPositionStream]'s permission check below, which checks the
/// exact same [Geolocator.checkPermission] tiers
/// `_JobDetailScreenState._startGeofencing` (untouched) already relies on
/// for automatic arrival detection.
final visitTrackingServiceProvider = Provider<VisitTrackingService>((ref) {
  return VisitTrackingService(ref);
});

class VisitTrackingService {
  VisitTrackingService(this._ref);

  final Ref _ref;

  /// The one job currently "entered", or `null` if none is. Every method
  /// below that's reachable from an async gap (a permission check, a
  /// Supabase write, a native position callback) re-checks this against
  /// whatever job id it was working with before touching any further
  /// state — the same "did the scope change out from under me while I was
  /// awaiting" discipline `JobDetailScreen`'s own geofencing used before
  /// this moved here, just keyed on this field instead of `mounted`.
  String? _jobId;
  ProviderSubscription<JobRuntimeState>? _runtimeSub;
  StreamSubscription<Position>? _positionSub;
  Timer? _debounceTimer;

  /// `true` = an arrive with no matching depart yet (technician on site for
  /// this visit); `false` = currently away mid-job; `null` = not yet known
  /// (before the initial [openVisitProvider] read in [_startMonitoring]
  /// resolves). Updated locally right after each successful automatic
  /// depart/re-arrive write so the position stream's own state machine
  /// doesn't need a fresh DB round-trip on every GPS update —
  /// [openVisitProvider] (watched by the manual "Leaving Site"/"Back on
  /// Site" buttons' UI) is still the actual source of truth and gets
  /// invalidated on every write, same as before this moved here.
  bool? _visitOpen;

  /// Guards [_confirmDeparture]/[_confirmReArrival] against a second
  /// position update re-entering the same transition while the first
  /// one's Supabase write is still in flight.
  bool _transitionInFlight = false;

  // --- Pending-visit-event queue drain --------------------------------
  //
  // Independent of [enterJobScope]/[exitJobScope]/[_jobId] above — a
  // queued event (see `visit_provider.dart`'s `_insertVisitEventResilient`)
  // can belong to ANY job, including one no longer "entered" by the time
  // connectivity comes back, so draining runs for the whole app session
  // regardless of which (if any) job is currently scoped in. Same
  // connectivity-listener shape as `OfflineUploadQueueService`
  // (`offline_upload_queue_provider.dart`), the direct model for this.
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _queueDrainStarted = false;
  bool _draining = false;

  /// Idempotent — safe to call more than once, only the first call does
  /// anything. Called once from `RootShell`, the same place
  /// `OfflineUploadQueueService.start()` is (no permission gate needed
  /// here either — this only opens a local DB and listens for
  /// connectivity).
  Future<void> startQueueDrain() async {
    if (_queueDrainStarted) return;
    _queueDrainStarted = true;
    debugPrint('VISIT TRACKING: starting pending-visit-event queue drain service...');
    // Catches anything left over from a previous session that ended while
    // still offline, before waiting on any connectivity event.
    unawaited(_syncQueueIfOnline());
    _connectivitySub = _connectivity.onConnectivityChanged.listen(_onConnectivityChanged);
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    if (isOfflineResult(results)) return;
    debugPrint('VISIT TRACKING: connectivity changed to $results, checking for queued visit events');
    unawaited(_syncQueueIfOnline());
  }

  Future<void> _syncQueueIfOnline() async {
    if (_draining) return;
    final connectivity = await _connectivity.checkConnectivity();
    if (isOfflineResult(connectivity)) {
      debugPrint('VISIT TRACKING: queue drain check skipped — still offline');
      return;
    }
    _draining = true;
    try {
      await drainPendingVisitEvents(_ref);
    } finally {
      _draining = false;
    }
  }
  // ---------------------------------------------------------------------

  void _log(String message) => debugPrint('VISIT TRACKING [job=$_jobId]: $message');

  /// Called from `JobDetailScreen.initState` — the same trigger point
  /// `GlobalVoiceService.enterJobScope()` is called from for this job.
  /// Defensive against a stale prior scope (mirrors
  /// `GlobalVoiceService`'s own "explicitly exit, don't just skip entry"
  /// hardening): under normal navigation only one `JobDetailScreen` is
  /// ever mounted at a time, so this shouldn't fire, but if it somehow
  /// does, the previous job's tracking is stopped first — this stays tied
  /// to exactly one job, never more, per the design.
  void enterJobScope(String jobId) {
    if (_jobId == jobId) return;
    if (_jobId != null) {
      debugPrint(
        'VISIT TRACKING: job $jobId entering scope while job $_jobId was still scoped — exiting it first',
      );
      exitJobScope();
    }
    _jobId = jobId;
    _log('entered scope');
    // fireImmediately so a job that's already on_site when its screen is
    // (re)opened (e.g. app was fully restarted) starts monitoring right
    // away, without needing a live status transition first.
    _runtimeSub = _ref.listen<JobRuntimeState>(
      jobRuntimeProvider(jobId),
      (previous, next) => _onRuntimeChanged(jobId, previous, next),
      fireImmediately: true,
    );
  }

  /// Called from `JobDetailScreen.dispose()` — the same trigger point
  /// `GlobalVoiceService.exitJobScope()` is called from — and from
  /// [stopForLogout] (`ProfileScreen`'s logout flow), so a stale
  /// stream/timer never survives into a different technician's session on
  /// the same device.
  void exitJobScope() {
    if (_jobId == null) return;
    _log('exiting scope');
    _runtimeSub?.close();
    _runtimeSub = null;
    _cancelDebounce('scope exited');
    unawaited(_stopPositionStream());
    _jobId = null;
    _visitOpen = null;
    _transitionInFlight = false;
  }

  /// Also stops the queue-drain connectivity listener (unlike
  /// `exitJobScope`'s doc comment above might suggest in isolation) and
  /// resets [_queueDrainStarted] so a fresh login re-establishes it —
  /// `RootShell`'s own `startQueueDrain` guard flag lives on its `State`,
  /// which is recreated on a fresh login, but this service is a singleton
  /// that survives across logout/login, so it needs its own reset here.
  Future<void> stopForLogout() async {
    exitJobScope();
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    _queueDrainStarted = false;
  }

  void _onRuntimeChanged(String jobId, JobRuntimeState? previous, JobRuntimeState next) {
    if (_jobId != jobId) return; // stale callback after a scope change
    final wasOnSite = previous?.status == JobStatus.onSite;
    final isOnSiteNow = next.status == JobStatus.onSite;
    if (!wasOnSite && isOnSiteNow) {
      _log('job entered on_site — starting visit monitoring');
      unawaited(_startMonitoring(jobId));
    } else if (wasOnSite && !isOnSiteNow) {
      _log('job left on_site (e.g. marked complete) — stopping visit monitoring');
      _cancelDebounce('job left on_site status');
      unawaited(_stopPositionStream());
    }
  }

  /// Determines whether there's currently an open visit for [jobId] (a
  /// fresh read — see [openVisitProvider]) and starts the position stream
  /// in the matching mode. A no-op if the scope has already moved on to a
  /// different (or no) job by the time the read resolves.
  Future<void> _startMonitoring(String jobId) async {
    if (_jobId != jobId || _positionSub != null) return;
    final job = _ref.read(jobByIdProvider(jobId));
    if (job == null) return;

    _log('determining current visit state...');
    final openVisitArrivedAt = await _ref.read(openVisitProvider(jobId).future);
    if (_jobId != jobId) return; // scope changed while awaiting
    _visitOpen = openVisitArrivedAt != null;
    _log('starting visit monitoring, visitOpen=$_visitOpen');

    await _startPositionStream(job);
  }

  Future<void> _startPositionStream(MockJob job) async {
    if (_jobId != job.id || _positionSub != null) return;

    _log('checking location permission for visit monitoring...');
    final permission = await Geolocator.checkPermission();
    if (_jobId != job.id) return;
    _log('permission status is $permission');

    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      _log(
        'location permission not granted, automatic departure/re-arrival detection unavailable — '
        'manual "Leaving Site"/"Back on Site" buttons still work',
      );
      return;
    }

    if (job.serviceLat == null || job.serviceLng == null) {
      _log('job has no service_lat/service_lng on file, skipping automatic detection');
      return;
    }

    _log('starting visit-monitoring position stream (accuracy=high, distanceFilter=10m)...');
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10),
    ).listen(
      (position) => _onPositionUpdate(job, position),
      onError: (Object e) => debugPrint('VISIT TRACKING ERROR (position stream) for job ${job.id}: $e'),
    );
  }

  Future<void> _stopPositionStream() async {
    final sub = _positionSub;
    if (sub == null) return;
    _positionSub = null;
    _log('stopping visit-monitoring position stream');
    await sub.cancel();
  }

  void _cancelDebounce(String reason) {
    final timer = _debounceTimer;
    if (timer == null) return;
    timer.cancel();
    _debounceTimer = null;
    _log('debounce cancelled ($reason)');
  }

  /// The visit-monitoring state machine — see the field docs on
  /// [_positionSub]/[_visitOpen] above for the two branches this switches
  /// between. Every `_jobId != job.id` guard covers the scope having moved
  /// on to a different (or no) job during an async gap in this callback
  /// (a genuinely possible native-callback timing case, same as the
  /// original `JobDetailScreen`-owned version this replaces).
  Future<void> _onPositionUpdate(MockJob job, Position position) async {
    if (_jobId != job.id) return;
    try {
      final distanceMeters = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        job.serviceLat!,
        job.serviceLng!,
      );
      _log(
        'distance to job site is ${distanceMeters.toStringAsFixed(1)}m for job ${job.id} '
        '(visitOpen=$_visitOpen)',
      );

      if (_visitOpen == true) {
        final outside = distanceMeters > _geofenceRadiusMeters;
        if (!outside) {
          _cancelDebounce('came back inside geofence before 3 minutes elapsed');
          return;
        }
        if (_debounceTimer != null || _transitionInFlight) return;
        _log(
          'debounce started for job ${job.id} — outside geofence, waiting '
          '${_departureDebounceDuration.inMinutes} continuous minute(s) before confirming departure',
        );
        _debounceTimer = Timer(_departureDebounceDuration, () => _confirmDeparture(job));
        return;
      }

      if (_visitOpen == false) {
        if (distanceMeters > _geofenceRadiusMeters || _transitionInFlight) return;
        _log('back within geofence — logging automatic re-arrival for job ${job.id}');
        await _confirmReArrival(job);
      }
    } catch (e, stackTrace) {
      debugPrint('VISIT TRACKING ERROR (position update) for job ${job.id}: $e\n$stackTrace');
    }
  }

  Future<void> _confirmDeparture(MockJob job) async {
    _debounceTimer = null;
    if (_jobId != job.id || _transitionInFlight) return;
    _transitionInFlight = true;
    try {
      _log(
        '${_departureDebounceDuration.inMinutes}-minute debounce elapsed — '
        'confirming departure for job ${job.id}',
      );
      final technicianId = _ref.read(authControllerProvider).value?.id;
      if (technicianId == null) {
        debugPrint(
          'VISIT TRACKING ERROR: no signed-in technician id, cannot log automatic departure for job ${job.id}',
        );
        return;
      }
      await _ref
          .read(visitActionProvider(job.id).notifier)
          .logDeparture(technicianId: technicianId, source: 'automatic');
      if (_jobId != job.id) return;
      _visitOpen = false;
    } finally {
      _transitionInFlight = false;
    }
  }

  Future<void> _confirmReArrival(MockJob job) async {
    if (_jobId != job.id || _transitionInFlight) return;
    _transitionInFlight = true;
    try {
      final technicianId = _ref.read(authControllerProvider).value?.id;
      if (technicianId == null) {
        debugPrint(
          'VISIT TRACKING ERROR: no signed-in technician id, cannot log automatic re-arrival for job ${job.id}',
        );
        return;
      }
      await _ref
          .read(visitActionProvider(job.id).notifier)
          .logReArrival(technicianId: technicianId, source: 'automatic');
      if (_jobId != job.id) return;
      _visitOpen = true;
    } finally {
      _transitionInFlight = false;
    }
  }
}
