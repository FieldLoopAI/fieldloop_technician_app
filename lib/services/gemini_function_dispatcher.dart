import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../models/change_order.dart';
import '../models/job_history_entry.dart';
import '../models/job_photo.dart';
import '../models/mock_job.dart';
import '../providers/auth_provider.dart';
import '../providers/job_change_orders_provider.dart';
import '../providers/job_dictations_provider.dart';
import '../providers/job_estimate_provider.dart';
import '../providers/job_photos_provider.dart';
import '../providers/job_voice_commands.dart';
import '../providers/jobs_provider.dart';
import '../providers/permission_providers.dart';
import '../routing/app_navigator_key.dart';
import '../routing/fade_slide_page_route.dart';
import '../screens/change_orders_screen.dart';
import '../screens/estimate_screen.dart';
import '../screens/invoice_screen.dart';
import '../screens/job_history_screen.dart';
import '../screens/photo_preview_screen.dart';
import '../screens/photo_viewer_screen.dart';

/// Holds the camera state that `open_camera`/`capture_photo`/
/// `confirm_photo_upload`/`retake_photo` share ACROSS separate Gemini
/// function calls — unlike every other tool in this dispatcher, this one
/// flow spans several calls over the course of a natural conversation
/// (open, then capture, then confirm-or-retake), so the already-open
/// `CameraController` and the just-captured-but-not-yet-uploaded file have
/// to survive between them instead of being created and torn down fresh
/// inside one atomic call.
///
/// One instance per Gemini Live session — created and owned by
/// `GeminiLiveTestScreen`'s state (NOT by this dispatcher file, which has
/// no session lifecycle of its own) and passed into
/// [dispatchGeminiFunctionCall] on every call; disposed from that screen's
/// `_teardown()`, which cleans up an orphaned open controller/captured file
/// if the session ends mid-flow (e.g. camera opened but never captured, or
/// captured but never confirmed/retaken).
/// How long a native camera open may take before it's treated as slow:
/// logged once as `CAMERA OPEN: WARNING exceeded normal open time`, and
/// the screen starts offering Retry/Cancel. Normal opens on the SM-A507FN
/// finish in 1-5s; slow ones have measured 20-40s.
const Duration cameraOpenSlowWarningAfter = Duration(seconds: 12);

/// Thrown from [GeminiCameraSession.open] when [GeminiCameraSession.
/// cancelPendingOpen] stopped the wait.
class CameraOpenCancelledException implements Exception {
  const CameraOpenCancelledException();
  @override
  String toString() => 'CameraOpenCancelledException: camera open cancelled';
}

/// One [GeminiCameraSession.open] call's cancel handle — see
/// [GeminiCameraSession.cancelPendingOpen].
class _OpenAttempt {
  final Completer<void> cancelled = Completer<void>();
  bool get isCancelled => cancelled.isCompleted;
  void cancel() {
    if (!cancelled.isCompleted) cancelled.completeError(const CameraOpenCancelledException());
  }
}

class GeminiCameraSession {
  CameraController? _controller;
  XFile? _capturedFile;

  /// P2 (live preview as early as possible) — fired the INSTANT
  /// `controller.initialize()` returns and [_controller] is assigned, which
  /// is the earliest moment a real preview texture exists. Everything after
  /// that point in [open] and in the screen's own dispatch wrapper
  /// (returning the payload, sending the `toolResponse`, Gemini generating
  /// and speaking a reply) is bookkeeping the technician should not have to
  /// stare at a blank screen through.
  ///
  /// CAPTURE is deliberately NOT unblocked by this — [capture] still checks
  /// `controller.value.isInitialized` itself, and the screen's
  /// capture_photo trigger is still guarded on the `cameraLive` screen task
  /// that only a genuine `open_camera` SUCCESS sets. This callback gates
  /// the VIEW, not the ACTION, exactly as intended.
  void Function()? onPreviewAvailable;

  /// P2 — fired synchronously the moment an open begins, so the screen can
  /// put up a real "opening the camera" surface instead of leaving the
  /// technician on a blank/unchanged screen for the whole open. Also fired
  /// for a JOINED open (a concurrent second call), since the UI state it
  /// drives is the same either way.
  void Function()? onOpenStarted;

  /// P2 — fired exactly once per genuinely-started open, on BOTH success
  /// and failure, with the error when there was one. The screen's "opening
  /// the camera" surface is put up by [onOpenStarted] before anything can
  /// fail, so it needs a guaranteed counterpart: an open that throws inside
  /// the screen's `_executeDeterministic` returns early, before
  /// `_updateScreenTaskForToolCall` ever runs, which would otherwise strand
  /// that surface on screen for the rest of the session. Hung off [open]'s
  /// own completion chain rather than off any caller's `await`, so no
  /// caller's error handling can skip it.
  void Function(Object? error)? onOpenSettled;

  /// P1 FIX (CONFIRMED via flutter_run_log_new.txt, build #63): most of
  /// confirm_photo_upload's ~9.4s "S3 upload" time is the `/photos/upload-
  /// url` Lambda round trip alone (the actual PUT is a couple of seconds;
  /// DB bookkeeping is already off the critical path — see
  /// [JobPhotosController.uploadPhoto]'s doc comment). Started the instant
  /// [capture] succeeds — overlapping it with however long the technician
  /// spends looking at the preview and deciding keep vs. retake — instead
  /// of only after "keep it" is actually heard. [confirm] awaits this SAME
  /// Future rather than fetching a fresh URL; [retake]/[_discardCapturedFileOnly]
  /// clear it unconsumed so a later, unrelated photo can never reuse a
  /// stale prefetch. See [prefetchUploadUrl]'s own doc comment for the
  /// honest trade-off this makes (an orphaned-but-harmless DB row on
  /// retake) in exchange for the latency win.
  Future<UploadUrlInfo>? _prefetchedUploadUrl;

  /// The device's list of cameras never changes at runtime — cached across
  /// EVERY [GeminiCameraSession] instance (static, not per-session: a new
  /// session is created per Gemini Live conversation, but the underlying
  /// hardware camera list is a device property, not a session one).
  /// CONFIRMED via PHOTO TIMING [open_camera] data (flutter_run_log_new.txt,
  /// build #50): `availableCameras()` itself took 2718ms, consistent across
  /// every build tested (5-8.6s total open_camera time every time) — real
  /// platform-channel enumeration cost on this device, not the open/close
  /// settle-wait below (which only runs AFTER this call and is timestamped
  /// separately), paid needlessly on every single open_camera when the
  /// answer can never change after the very first call. Only the first
  /// open_camera of the app's lifetime still pays it.
  static List<CameraDescription>? _cachedCameras;

  Future<List<CameraDescription>> _getCameras() async {
    final cached = _cachedCameras;
    if (cached != null) {
      // Distinct, greppable line requested for the next real test — proves
      // from the log alone (not just code reading) whether a given
      // open_camera actually hit the cache. Only the FIRST open_camera of
      // the app process's lifetime should ever print the "first time" line
      // below instead of this one — every open_camera after that, in the
      // same or a later Gemini Live session, as long as the app process
      // itself was never killed/restarted (a Dart hot RESTART also resets
      // this — a hot RELOAD does not), should print this one.
      debugPrint('CAMERA: using cached device list (${cached.length} camera(s))');
      return cached;
    }
    debugPrint('CAMERA: enumerating devices (first time)');
    final cameras = await availableCameras();
    _cachedCameras = cameras;
    return cameras;
  }

  /// ISSUE 3(a)/(b) (CONFIRMED via f5a8bd8b-flutter_run_log.txt, then
  /// CONFIRMED THIS ROUND via fbd877f0-flutter_run_log.txt: "Skipped 120
  /// frames! The application may be doing too much work on its main
  /// thread" — a genuine ~2s near-total main-thread freeze — fired DURING
  /// the live preview window).
  ///
  /// (a) This app has NO real use for `ImageAnalysis`/`startImageStream` —
  /// nothing in this codebase needs per-frame image data. Reading the
  /// `camera_android_camerax` plugin's own source (pub cache,
  /// `lib/src/android_camera_camerax.dart`, `initializeCamera`) confirms
  /// `ImageAnalysis` is created and bound to `[preview, imageCapture,
  /// imageAnalysis]` UNCONDITIONALLY, every time, regardless of whether the
  /// app ever streams images — and the public `camera` package's
  /// `CameraController` constructor exposes no parameter to opt out of it.
  /// This is a plugin-level behavior (matches an open GitHub issue on the
  /// `camera` plugin for exactly this), not fixable from this app's Dart
  /// code without forking/patching the plugin — out of scope here.
  ///
  /// (b) A PRIOR round of this same investigation (see the removed
  /// `_startPreviewFrameRateLogging`/`_previewFrameCounter` — check git
  /// history for the full removed implementation) attached a real analyzer
  /// via `startImageStream` for lightweight frame-rate diagnostic logging,
  /// reasoning that a cheap, counter-only callback couldn't meaningfully
  /// compete with preview rendering. CONFIRMED WRONG by reading the
  /// plugin's own `_configureImageAnalysis`/`analyze()` implementation more
  /// closely this round: regardless of how cheap the APP's callback is,
  /// the PLUGIN ITSELF does `await imageProxy.getPlanes()` — marshalling
  /// full-resolution YUV420 pixel plane buffers (megabytes per frame at
  /// `ResolutionPreset.high`) from native memory across the Pigeon platform
  /// channel into Dart — for EVERY frame, dispatched via
  /// `runOnMainThread(...)` on the native side (confirmed in
  /// `AnalyzerProxyApi.java`), the INSTANT any analyzer at all is attached.
  /// That per-frame marshalling, not the app callback, is genuine expensive
  /// main-thread work competing directly with CameraX's own preview
  /// rendering — a very plausible direct cause of this round's "Skipped 120
  /// frames" evidence. REMOVED accordingly: `ImageAnalysis` is back to
  /// merely bound-but-idle (per (a), unavoidably bound by the plugin, but
  /// with no analyzer ever attached — confirmed no `setBackpressureStrategy`
  /// override anywhere in the plugin either, so CameraX's own
  /// `STRATEGY_KEEP_ONLY_LATEST` default applies for whatever residual cost
  /// the unconditional binding itself has). No further preview frame-rate
  /// instrumentation is added this round — the mechanism to get that data
  /// (`startImageStream`) is now confirmed to be the wrong tool for a
  /// diagnostic that must not itself perturb what it's measuring.

  /// CONFIRMED regression investigation (open_camera/capture_photo going
  /// from ~2.2-2.5s to 27-71s per call): start time of each camera-flow
  /// function currently in flight, keyed by function name. This session
  /// only ever drives ONE `CameraController` for ONE job at a time (see the
  /// class doc comment), so "in-flight for this function name" already
  /// means "in-flight for this job" — no extra job-keying needed.
  ///
  /// Root cause confirmed: `_GeminiLiveTestScreenState._onServerMessage`
  /// calls `unawaited(_handleToolCall(...))` per incoming WebSocket
  /// message, with no queue/serialization — if the server sends two
  /// `toolCall` messages close together (a real, observed occurrence, not
  /// hypothetical), a second `capture_photo` reaches [capture] while the
  /// first is still awaiting `controller.takePicture()`. Calling
  /// `takePicture()` twice concurrently on the SAME native `CameraController`
  /// makes the platform camera HAL serialize/contend for the one physical
  /// session instead of the two calls running independently — the confirmed
  /// mechanism behind the 10-30x slowdown, not a resource leak (see
  /// [dispose]/[retake] — the controller itself is never leaked or
  /// double-created).
  final Map<String, DateTime> _inFlightSince = {};

  /// Checks whether [name] is already in flight; if not, marks it in-flight
  /// (recording now as its start time) and returns `null`. If [name] IS
  /// already in flight, does NOT touch the original start time (so a THIRD
  /// overlapping call still reports elapsed time since the genuinely first
  /// one, not since a rejected second one) and returns that call's elapsed
  /// time in milliseconds instead, for the caller to log/reject with.
  int? _checkAndMarkInFlight(String name) {
    final existingStart = _inFlightSince[name];
    if (existingStart != null) {
      return DateTime.now().difference(existingStart).inMilliseconds;
    }
    _inFlightSince[name] = DateTime.now();
    return null;
  }

  /// Clears [name]'s in-flight marker — called from a `finally` block in
  /// every camera dispatcher function so it clears on both success and
  /// failure, never leaving a stale marker behind that would make every
  /// SUBSEQUENT call for [name] this session falsely report an overlap.
  void _clearInFlight(String name) => _inFlightSince.remove(name);

  /// Read-only access to the live preview controller [open] sets up, so the
  /// ambient Gemini screen (`GeminiLiveTestScreen`) can render the SAME
  /// controller this class drives as real, visible screen content instead
  /// of leaving the camera flow entirely headless — see that screen's
  /// `_buildCameraTaskBody`. Nothing outside this class ever opens, closes,
  /// or reconfigures the controller directly.
  CameraController? get controller => _controller;

  /// Read-only access to the most recently captured, not-yet-confirmed/
  /// retaken file — same reasoning as [controller], for the still-preview
  /// step between `capture_photo` and `confirm_photo_upload`/`retake_photo`.
  XFile? get capturedFile => _capturedFile;

  /// Same rear-camera selection + permission check/request +
  /// `CameraController` setup as `PhotoCaptureScreen._initCamera` — see
  /// [_openCamera]'s doc comment for the full mapping. Disposes any
  /// previously-open controller and discards any previously-captured,
  /// not-yet-uploaded file first, so calling this twice in a row cleanly
  /// starts over rather than leaking the old controller or silently
  /// keeping a stale pending capture around.
  ///
  /// P1 FIX — EXCEPT when [_controller] is already open AND initialized:
  /// then this reuses it directly instead of tearing it down and paying
  /// the full native-open cost again (see [GeminiLiveTestScreen]'s
  /// `_maybePrewarmCameraController`, which now calls this SPECULATIVELY
  /// before the technician has asked for a photo — the whole point is
  /// that a GENUINE open_camera request arriving afterward gets the
  /// already-paid controller for free, not a second real init). Safe
  /// under every OTHER existing call pattern too: the screen's own
  /// deterministic-trigger guard already refuses to dispatch a repeat
  /// open_camera while a controller is genuinely already showing live
  /// (`_ScreenTask.cameraLive` — see "OPEN_CAMERA REPEAT WHILE OPEN" in
  /// `gemini_live_test_screen.dart`), so this fast path was never
  /// reachable for a normal double-request before the prewarm feature
  /// existed, and still isn't — it only ever engages for the new
  /// prewarm-then-real-request sequence.
  Future<void> open(WidgetRef ref, String jobId) {
    final existing = _controller;
    if (existing != null && existing.value.isInitialized) {
      debugPrint('CAMERA OPEN: reusing an already-initialized controller (likely prewarmed) — skipping native re-init entirely');
      onOpenStarted?.call();
      onPreviewAvailable?.call();
      return Future<void>.value();
    }
    // CAMERA OPEN/CLOSE RACE (CONFIRMED via the latest flutter_run_log.txt:
    // "E/CXCP: Failed to open camera CameraId-0 after 41 attempts and
    // 22483.723 ms. Last error was CameraError(ERROR_CAMERA_IN_USE)"). Root
    // causes fixed here: (1) `_controller` is only assigned AFTER
    // `initialize()` finishes, so a second open() (e.g. Gemini's retry after
    // the screen's 15s open_camera hard timeout, while the first real call
    // was still running) never saw the in-flight controller and built a
    // SECOND CameraController against the same hardware; (2) dispose() calls
    // from the screen (late-success cleanup, go_back, teardown) could run
    // concurrently with an open. Now: a concurrent open() JOINS the one
    // already in flight, and every open/dispose runs one at a time through
    // [_runExclusive].
    onOpenStarted?.call();
    final inFlight = _openInFlight;
    if (inFlight != null) {
      debugPrint('CAMERA OPEN: an open is already in flight — joining it instead of starting a second controller');
      return inFlight;
    }
    final attempt = _OpenAttempt();
    _currentOpenAttempt = attempt;
    // Timing only: how long this open sat queued behind an earlier camera
    // open/close still running (CONFIRMED ~10s once, behind a prewarm
    // auto-release that had started 3s before the request) — invisible
    // before, since nothing logged between handler_entry and the open's own
    // "CAMERA OPEN: started".
    final queuedAt = DateTime.now();
    final nativeOpen = _runExclusive(() {
      debugPrint(
        'PHOTO TIMING [open_camera]: queue_wait_done at ${DateTime.now()} (waited '
        '${DateTime.now().difference(queuedAt).inMilliseconds}ms behind earlier camera open/close work)',
      );
      return _openExclusive(ref, jobId, attempt);
    });
    unawaited(
      nativeOpen.then<void>(
        (_) => onOpenSettled?.call(null),
        onError: (Object e) {
          // A cancelled open settles silently — the caller already moved on
          // (and may have started a retry whose own surface must not be
          // cleared by this one).
          if (e is CameraOpenCancelledException) return;
          onOpenSettled?.call(e);
        },
      ).whenComplete(() {
        if (identical(_currentOpenAttempt, attempt)) _currentOpenAttempt = null;
      }),
    );
    // Callers wait on whichever comes first: the real native open, or
    // [cancelPendingOpen]. See [_OpenAttempt].
    final future = Future.any([nativeOpen, attempt.cancelled.future]);
    _openInFlight = future;
    unawaited(
      future.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (identical(_openInFlight, future)) _openInFlight = null;
      }),
    );
    return future;
  }

  Future<void>? _openInFlight;
  _OpenAttempt? _currentOpenAttempt;

  /// Stops WAITING on a slow native open — never claims it failed, and
  /// never aborts it: `CameraController.initialize()` has no cancellation
  /// (its own `dispose()` just waits for initialize to finish first), which
  /// is why the old 15s hard timeout was removed (it said "timed out" and
  /// then "the camera's open" for the same call). Instead the pending
  /// [open] completes right away with [CameraOpenCancelledException], and
  /// when the native open eventually returns, [_openExclusive] releases
  /// that controller silently rather than surfacing it. A new [open] after
  /// this does NOT join the abandoned one: it queues behind it through
  /// [_runExclusive] and starts the moment the native side is free.
  /// Returns whether there was anything to cancel.
  bool cancelPendingOpen() {
    final attempt = _currentOpenAttempt;
    if (attempt == null || attempt.isCancelled) return false;
    attempt.cancel();
    _openInFlight = null;
    debugPrint('CAMERA OPEN: cancel requested by the technician — no longer waiting on the native open');
    return true;
  }
  Future<void> _cameraOpChain = Future<void>.value();
  DateTime? _lastCameraClosedAt;

  /// Runs [op] only after every previously-queued camera open/close has fully
  /// finished — the chain itself never errors (each op's error goes only to
  /// its own caller).
  Future<T> _runExclusive<T>(Future<T> Function() op) {
    final previous = _cameraOpChain;
    final done = Completer<void>();
    _cameraOpChain = done.future;
    return previous.then((_) => op()).whenComplete(done.complete);
  }

  static bool _looksLikeCameraInUse(Object e) {
    final text = '${e is CameraException ? '${e.code} ${e.description}' : e}'.toLowerCase();
    return text.contains('in_use') || text.contains('in use') || text.contains('inuse');
  }

  /// P1 — pays the one-time costs an `open_camera` otherwise pays on the
  /// critical path, at a moment nobody is waiting: the device-list
  /// enumeration (CONFIRMED 2.4-9s of real platform-channel work on this
  /// device — see [_cachedCameras], which caches it for the process
  /// lifetime, so only the FIRST open ever pays it) and the permission
  /// read. Called once when a Gemini Live session starts.
  ///
  /// Deliberately does NOT open a controller: holding the camera open
  /// across a whole voice session to save a few seconds would keep the
  /// hardware (and its power draw) claimed for conversations that never
  /// take a photo, and would collide with any other app or screen that
  /// wants the camera in the meantime.
  static Future<void> prewarm(WidgetRef ref) async {
    final stopwatch = Stopwatch()..start();
    try {
      final cameras = await GeminiCameraSession()._getCameras();
      final granted = ref.read(cameraMicProvider).cameraGranted;
      debugPrint(
        'PHOTO TIMING [prewarm]: device enumeration + permission read done in ${stopwatch.elapsedMilliseconds}ms '
        '(${cameras.length} camera(s), cameraGranted=$granted) — the first open_camera of this app process no '
        'longer pays this.',
      );
    } catch (e) {
      debugPrint('PHOTO TIMING [prewarm]: failed after ${stopwatch.elapsedMilliseconds}ms: $e (harmless — open_camera will do it itself)');
    }
  }

  Future<void> _openExclusive(WidgetRef ref, String jobId, _OpenAttempt attempt) async {
    if (attempt.isCancelled) {
      debugPrint('CAMERA OPEN: cancelled before it reached the native side — not opening');
      throw const CameraOpenCancelledException();
    }
    final openStopwatch = Stopwatch()..start();
    var warnedSlow = false;
    debugPrint('CAMERA OPEN: started (job $jobId)');
    // P1 — contention snapshot, logged BEFORE anything is awaited. Every
    // value here is a candidate explanation for a 30s open that a 5s open
    // wouldn't have, and none of them were visible in the previous six runs:
    // a live controller still to be torn down (the CONFIRMED 40s
    // `dispose()`), a close that has only just finished (the settle wait and
    // the ERROR_CAMERA_IN_USE retry storm both hang off this), a still-warm
    // device-list cache, and any other camera-flow function still in flight
    // on the same hardware.
    final closedAgoMs = _lastCameraClosedAt == null
        ? null
        : DateTime.now().difference(_lastCameraClosedAt!).inMilliseconds;
    debugPrint(
      'PHOTO TIMING [open_camera]: contention_snapshot at ${DateTime.now()} — '
      'existingController=${_controller != null}, '
      'controllerInitialized=${_controller?.value.isInitialized ?? false}, '
      'pendingCapturedFile=${_capturedFile != null}, '
      'deviceListCached=${_cachedCameras != null}, '
      'msSinceLastCameraClose=${closedAgoMs ?? "never closed this process"}, '
      'otherCameraFnsInFlight=${_inFlightSince.keys.toList()}',
    );
    // TEMPORARY (reliability audit, Issue 2 — profiling open_camera's
    // 2.2s-68s+ inconsistency): `dart:developer` TimelineTask spans, one per
    // real sub-step, so a DevTools timeline capture during a slow call shows
    // exactly which awaited step actually consumed the time — not another
    // debugPrint guess. Remove once the bottleneck is confirmed and fixed.
    final task = developer.TimelineTask()..start('GeminiCameraSession.open');
    // ISSUE 1 (CONFIRMED via f5a8bd8b-flutter_run_log.txt: a 3.79s Dart-side
    // gap between `audio_hard_pause_engaged` — logged just before this
    // method is even called, in gemini_live_test_screen.dart — and
    // `dispatching_native_open_call` below, with no way from the old logs
    // alone to tell which of discardPending/permissionCheck/availableCameras/
    // CameraController.construct actually consumed it). A plain Stopwatch,
    // not just the TimelineTask above, since TimelineTask spans only show up
    // in a DevTools timeline capture — this prints each step's OWN duration
    // directly into the regular text log, so the next real run's log shows
    // exactly where any remaining gap goes without a separate capture.
    final stepStopwatch = Stopwatch()..start();
    void logStepDone(String step) {
      debugPrint('PHOTO TIMING [open_camera]: ${step}_done at ${DateTime.now()} (took ${stepStopwatch.elapsedMilliseconds}ms)');
      stepStopwatch.reset();
    }

    try {
      task.start('discardPending');
      await _discardPending();
      task.finish();
      logStepDone('discard_pending');

      task.start('permissionCheck');
      var cameraMic = ref.read(cameraMicProvider);
      if (!cameraMic.cameraGranted) {
        debugPrint('CAMERA (dispatcher): camera permission not yet granted for job $jobId — requesting...');
        await ref.read(cameraMicProvider.notifier).request();
        cameraMic = ref.read(cameraMicProvider);
        if (!cameraMic.cameraGranted) {
          throw StateError('Camera permission was not granted — cannot open the camera.');
        }
      }
      task.finish();
      // permission_check_done kept verbatim (existing log line other
      // tooling may already grep for) alongside the new duration line.
      debugPrint('PHOTO TIMING [open_camera]: permission_check_done at ${DateTime.now()}');
      logStepDone('permission_check');

      debugPrint('CAMERA (dispatcher): enumerating available cameras for job $jobId...');
      task.start('availableCameras');
      final cameras = await _getCameras();
      task.finish();
      logStepDone('available_cameras');
      if (cameras.isEmpty) {
        throw StateError('No camera found on this device.');
      }
      final rearCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      // The plugin's dispose() can return before the native camera is truly
      // released — if a close finished moments ago, give the HAL a moment
      // rather than immediately racing it (that race is what makes CameraX
      // spin through dozens of ERROR_CAMERA_IN_USE retries).
      final closedAt = _lastCameraClosedAt;
      if (closedAt != null) {
        final sinceClose = DateTime.now().difference(closedAt);
        const settle = Duration(milliseconds: 500);
        if (sinceClose < settle) {
          final wait = settle - sinceClose;
          debugPrint('CAMERA OPEN: previous close finished ${sinceClose.inMilliseconds}ms ago — waiting ${wait.inMilliseconds}ms for the camera to be released');
          await Future<void>.delayed(wait);
        }
      }

      task.start('CameraController.construct');
      var controller = CameraController(rearCamera, ResolutionPreset.high, enableAudio: false);
      task.finish();
      logStepDone('controller_construct');

      // PART N item 2 (CONFIRMED via 3ebd9995-flutter_run_log.txt: the real
      // "Creating config for PREVIEW" CXCP native log line didn't start
      // until AFTER the 15s HARD TIMEOUT had already fired — meaning
      // nothing camera-related was happening for the first 15+ seconds at
      // all, distinct from "enumerating available cameras" above, which
      // already logs and finishes in ~20ms on its own). This is the exact
      // moment the Dart side dispatches the native "open/bind camera"
      // platform channel call — the gap between THIS line and
      // `controller_initialized` below is how long that specific call sits
      // queued before the native side actually picks it up, not how long
      // permission-check/enumeration/construction took (those are already
      // separately timestamped above).
      debugPrint('PHOTO TIMING [open_camera]: dispatching_native_open_call at ${DateTime.now()}');
      task.start('controller.initialize');
      // At most one backoff retry on ERROR_CAMERA_IN_USE: CameraX already
      // retries internally (the logged 41 attempts / 22s), so a second
      // attempt is only worthwhile if that first one failed quickly.
      var attempts = 0;
      while (true) {
        attempts++;
        final attemptStopwatch = Stopwatch()..start();
        // P1 ROOT-CAUSE INSTRUMENTATION. `controller.initialize()` is a
        // SINGLE platform-channel call — CameraX's use-case binding, the
        // camera2 device open, the capture-session configuration and the
        // first preview frame all happen on the native side of it, with no
        // Dart-visible seam to timestamp between them. Six test runs have
        // therefore only ever produced one opaque 9-21s gap here.
        //
        // What this heartbeat measures instead is the ONE thing that
        // actually discriminates between the two competing explanations,
        // and it has never been measured: DRIFT. A `Timer.periodic` set to
        // 500ms that fires on time proves the Dart isolate and the platform
        // thread servicing it are both healthy, which means the time is
        // genuinely being spent inside native CameraX (hardware/HAL — read
        // the interleaved `CXCP`/`Camera2CameraImpl` logcat lines at these
        // timestamps for the sub-step). A heartbeat that fires LATE by
        // seconds proves the opposite: nothing is waiting on the camera at
        // all, we are starved, and the fix belongs in whatever is saturating
        // the thread (the confirmed 40s `dispose()`, PCM audio reinit, the
        // per-chunk `setState` storms already fixed elsewhere in the screen)
        // rather than in any camera timeout wrapper.
        //
        // Each line also carries an absolute timestamp, so a native logcat
        // capture from the same run aligns against it line-for-line — which
        // is what turns "somewhere in these 21 seconds" into a named
        // sub-step without patching the plugin.
        var heartbeats = 0;
        var worstDriftMs = 0;
        final heartbeat = Timer.periodic(const Duration(milliseconds: 500), (_) {
          heartbeats++;
          final elapsedMs = attemptStopwatch.elapsedMilliseconds;
          final driftMs = elapsedMs - heartbeats * 500;
          if (driftMs > worstDriftMs) worstDriftMs = driftMs;
          debugPrint(
            'PHOTO TIMING [open_camera]: native_open_still_pending at ${DateTime.now()} '
            '(${elapsedMs}ms elapsed, attempt $attempts, heartbeat $heartbeats, scheduling drift ${driftMs}ms — '
            '${driftMs > 300 ? "DART/PLATFORM THREAD STARVED, the camera is NOT what we are waiting on" : "Dart side healthy, time is genuinely inside native CameraX"})',
          );
          // Once per open, at the same threshold the screen starts offering
          // Retry/Cancel — distinct and greppable, unlike the heartbeat.
          if (!warnedSlow && openStopwatch.elapsed >= cameraOpenSlowWarningAfter) {
            warnedSlow = true;
            const line = 'CAMERA OPEN: WARNING exceeded normal open time, still waiting';
            debugPrint(
              '$line (${openStopwatch.elapsedMilliseconds}ms since open started, attempt $attempts, '
              'msSinceLastCameraClose=${_lastCameraClosedAt == null ? "never" : DateTime.now().difference(_lastCameraClosedAt!).inMilliseconds})',
            );
            developer.log(line, name: 'CAMERA', level: 900);
          }
        });
        try {
          await controller.initialize();
          heartbeat.cancel();
          debugPrint(
            'PHOTO TIMING [open_camera]: native_open_returned at ${DateTime.now()} '
            '(${attemptStopwatch.elapsedMilliseconds}ms in controller.initialize(), attempt $attempts, '
            'worst heartbeat drift ${worstDriftMs}ms, previewSize=${controller.value.previewSize})',
          );
          break;
        } catch (e) {
          heartbeat.cancel();
          debugPrint('CAMERA OPEN: attempt $attempts failed after ${attemptStopwatch.elapsedMilliseconds}ms: $e');
          try {
            await controller.dispose();
          } catch (_) {}
          _lastCameraClosedAt = DateTime.now();
          final canRetry = attempts < 2 && _looksLikeCameraInUse(e) && attemptStopwatch.elapsedMilliseconds < 10000;
          if (!canRetry) rethrow;
          debugPrint('CAMERA OPEN: camera reported in-use — backing off 1000ms before a fresh attempt');
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          controller = CameraController(rearCamera, ResolutionPreset.high, enableAudio: false);
        }
      }
      task.finish();
      debugPrint('CAMERA (dispatcher): rear camera initialized (live preview open) for job $jobId');
      debugPrint('PHOTO TIMING [open_camera]: controller_initialized at ${DateTime.now()}');
      logStepDone('controller_initialize');
      if (attempt.isCancelled) {
        // See [cancelPendingOpen]: nobody is waiting for this open anymore —
        // release the camera instead of surfacing a preview.
        debugPrint(
          'CAMERA OPEN: native open finally returned after ${openStopwatch.elapsedMilliseconds}ms but was cancelled '
          '— releasing it silently',
        );
        try {
          await controller.dispose();
        } catch (_) {}
        _lastCameraClosedAt = DateTime.now();
        throw const CameraOpenCancelledException();
      }
      _controller = controller;
      // P2 — surface the preview NOW, before this method's own remaining
      // work, before the dispatch payload is built, before the toolResponse
      // round trip, and long before Gemini finishes speaking about it. See
      // [onPreviewAvailable]'s doc comment.
      debugPrint('PHOTO TIMING [open_camera]: preview_surfaced_to_ui at ${DateTime.now()} (${openStopwatch.elapsedMilliseconds}ms after open started)');
      onPreviewAvailable?.call();
      debugPrint('CAMERA OPEN: complete (${openStopwatch.elapsedMilliseconds}ms, $attempts attempts)');
      // ISSUE 3(b) — see this class's own doc comment above `open`'s
      // preceding fields: no `startImageStream` call here (removed this
      // round) — attaching any analyzer at all, however cheap, forces the
      // plugin to do expensive per-frame native-to-Dart marshalling on the
      // main thread, which is exactly what stutters the preview.
    } finally {
      task.finish();
    }
  }

  /// Same `takePicture()` call `PhotoCaptureScreen._capture`'s shutter
  /// button makes, on the controller [open] already set up — throws if
  /// there isn't one (Gemini called this without an `open_camera` first).
  /// Holds the resulting raw file for [confirm] or [retake]; does NOT
  /// compress or upload it.
  Future<void> capture(String jobId) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw StateError('Camera is not open — call open_camera before capture_photo.');
    }
    // No permission check here — that already happened in open_camera; this
    // is the closest analogous gate capture_photo has of its own.
    debugPrint('PHOTO TIMING [capture_photo]: controller_ready_check_done at ${DateTime.now()}');
    // A previous capture that was never confirmed/retaken shouldn't be
    // silently orphaned by a second capture_photo call.
    await _discardCapturedFileOnly();

    debugPrint('CAMERA (dispatcher): taking picture for job $jobId...');
    debugPrint('PHOTO TIMING [capture_photo]: platform_capture_call_start at ${DateTime.now()}');
    debugPrint('PHOTO FLOW: capture started at ${DateTime.now()}');
    // TODO(capture-latency): this native call is intermittently very slow
    // (12.1s in the 2026-09-25 16:4x trace; 27s and 88s in earlier ones)
    // while main_thread_probe reports the Android main thread blocked for
    // seconds at a time, and that blocking grows over a session. Not fixed
    // blind — needs its own pass with a trace that includes the debug-only
    // `MainThreadSlow` lines from MainActivity.installSlowMainThreadMessageLogger,
    // which name the handler actually holding the main thread.
    final probe = _MainThreadProbe.start('capture_photo');
    try {
      _capturedFile = await controller.takePicture();
    } finally {
      probe.stop();
    }
    debugPrint('PHOTO TIMING [capture_photo]: platform_capture_call_end at ${DateTime.now()}');
    int? capturedBytes;
    try {
      capturedBytes = await File(_capturedFile!.path).length();
    } catch (_) {}
    debugPrint('PHOTO FLOW: capture done — ${_capturedFile!.path} (${capturedBytes ?? '?'} bytes) — awaiting keep/retake');
    debugPrint('CAMERA (dispatcher): photo captured (${_capturedFile!.path}), awaiting confirm or retake');

    // P1 FIX — see [_prefetchedUploadUrl]'s doc comment. Fire-and-forget:
    // NOT awaited here (capture_photo must still return the instant the
    // shutter itself is done), and given its own error listener so an
    // unconsumed failure (the photo gets retaken, never confirmed) can
    // never surface as an unhandled Future error — [confirm] still sees
    // the real error normally if it ends up actually awaiting this.
    final prefetch = prefetchUploadUrl(jobId: jobId);
    _prefetchedUploadUrl = prefetch;
    unawaited(
      prefetch.then((_) {}, onError: (Object e) {
        debugPrint('CAMERA (dispatcher): prefetch upload-url failed (confirm_photo_upload will retry fresh if reached): $e');
      }),
    );
  }

  /// Same [compressPhotoForUpload] + `JobPhotosController.uploadPhoto` call
  /// `PhotoPreviewScreen._confirm`'s Confirm button makes, on the file
  /// [capture] already took — throws if there isn't one (Gemini called this
  /// without a `capture_photo` first). Leaves the camera controller OPEN
  /// afterward (same as the real flow: Photo Preview pops back to a still-
  /// live Photo Capture, ready for another shot).
  Future<PhotoUploadResult> confirm(WidgetRef ref, String jobId) async {
    final file = _capturedFile;
    if (file == null) {
      throw StateError('No photo has been captured yet — call capture_photo before confirm_photo_upload.');
    }

    debugPrint('PHOTO CONFIRM: keep chosen for job $jobId');
    debugPrint('CAMERA (dispatcher): compressing ${file.path} for job $jobId...');
    int? originalBytes;
    try {
      originalBytes = await File(file.path).length();
    } catch (_) {}
    final compressWatch = Stopwatch()..start();
    debugPrint('PHOTO CONFIRM: compress started (${originalBytes ?? '?'} bytes)');
    final compressed = await compressPhotoForUpload(file.path);
    debugPrint(
      'PHOTO CONFIRM: compress done (size ${originalBytes ?? '?'}bytes -> ${compressed.length}bytes, '
      '${compressWatch.elapsedMilliseconds}ms)',
    );
    final uploadWatch = Stopwatch()..start();
    debugPrint('PHOTO CONFIRM: S3 upload started (${compressed.length} bytes)');
    // P1 FIX — see [_prefetchedUploadUrl]'s doc comment: reuses the prefetch
    // [capture] started, rather than fetching a fresh upload URL now.
    final prefetchedUploadUrl = _prefetchedUploadUrl;
    _prefetchedUploadUrl = null;
    final result = await ref
        .read(jobPhotosProvider(jobId).notifier)
        .uploadPhoto(compressed, prefetchedUploadUrl: prefetchedUploadUrl);
    String? s3Key;
    for (final p in (ref.read(jobPhotosProvider(jobId)).valueOrNull ?? const <JobPhoto>[]).reversed) {
      if (p.s3Key != null) {
        s3Key = p.s3Key;
        break;
      }
    }
    debugPrint(
      'PHOTO CONFIRM: S3 upload done (result=$result, key=${s3Key ?? 'n/a — queued offline'}, '
      '${uploadWatch.elapsedMilliseconds}ms)',
    );

    unawaited(File(file.path).delete().catchError((_) => File(file.path)));
    _capturedFile = null;
    return result;
  }

  /// Same `File(...).delete()` `PhotoPreviewScreen._retake`'s Retake button
  /// makes on the file [capture] already took — throws if there isn't one.
  /// Leaves the camera controller OPEN (same as the real flow: Retake pops
  /// back to the still-live camera view for another `capture_photo` call).
  Future<void> retake(String jobId) async {
    final file = _capturedFile;
    if (file == null) {
      throw StateError('No photo has been captured yet — call capture_photo before retake_photo.');
    }
    debugPrint('PHOTO CONFIRM: RETAKE chosen (discard) for job $jobId — camera stays open for another shot');
    debugPrint('CAMERA (dispatcher): retaking — discarding ${file.path} for job $jobId');
    try {
      await File(file.path).delete();
    } catch (e) {
      debugPrint('CAMERA (dispatcher): could not delete discarded photo file: $e');
    }
    _capturedFile = null;
    // P1 FIX — see [_prefetchedUploadUrl]'s doc comment: this photo's own
    // prefetch (if it ever resolves) is simply left unused — its error
    // listener already prevents an unhandled-Future warning — never
    // reused for whatever gets captured next.
    _prefetchedUploadUrl = null;
  }

  Future<void> _discardCapturedFileOnly() async {
    final file = _capturedFile;
    _capturedFile = null;
    _prefetchedUploadUrl = null;
    if (file == null) return;
    try {
      await File(file.path).delete();
    } catch (e) {
      debugPrint('CAMERA (dispatcher): could not delete orphaned captured photo file: $e');
    }
  }

  Future<void> _discardPending() async {
    await _discardCapturedFileOnly();
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      final closeStopwatch = Stopwatch()..start();
      debugPrint('CAMERA CLOSE: started');
      try {
        await controller.dispose();
      } catch (e) {
        debugPrint('CAMERA (dispatcher): error disposing previous camera controller: $e');
      }
      _lastCameraClosedAt = DateTime.now();
      debugPrint('CAMERA CLOSE: complete (${closeStopwatch.elapsedMilliseconds}ms)');
    }
  }

  /// Called once from `GeminiLiveTestScreen._teardown()` at the end of the
  /// Gemini Live session — cleans up an orphaned open controller and/or
  /// unconfirmed captured file if the conversation ended mid-flow (camera
  /// opened but never captured, or captured but never confirmed/retaken),
  /// so nothing leaks past the session that opened it.
  Future<void> dispose() => _runExclusive(_discardPending);
}

/// Routes a Gemini Live `functionCall` (see `gemini_live_test_screen.dart`'s
/// `_geminiToolFunctionDeclarations`) to the existing, already-tested
/// backend/provider code that already implements it. Deliberately NOT where
/// any parsing/pricing/business logic lives — every branch below is a thin
/// call-through to code that already exists elsewhere in the app; this
/// file's only job is picking the right one and shaping its result into a
/// JSON-serializable `functionResponse` payload.
///
/// Returns a JSON-serializable map to embed as the `functionResponse`'s
/// `response` field. Throws on failure — the caller (the WebSocket message
/// handler in `gemini_live_test_screen.dart`) is responsible for catching
/// this and reporting it back to Gemini as an error response rather than
/// leaving the call hanging.
Future<Map<String, dynamic>> dispatchGeminiFunctionCall({
  required WidgetRef ref,
  required GeminiCameraSession cameraSession,
  required GeminiNavigationSession navigationSession,
  required String name,
  required Map<String, dynamic> args,
}) async {
  // The four camera-stage functions are handled here, before the main
  // switch below, for the same reason they always have been: the
  // capture/confirm/retake split IS the conversational confirmation step
  // (see GeminiCameraSession's doc comment) — there is no separate gate to
  // route through first.
  switch (name) {
    case 'open_camera':
      return _openCamera(ref: ref, cameraSession: cameraSession, jobId: _requireString(args, 'job_id'));
    case 'capture_photo':
      return _captureStagedPhoto(cameraSession: cameraSession, jobId: _requireString(args, 'job_id'));
    case 'confirm_photo_upload':
      return _confirmPhotoUpload(ref: ref, cameraSession: cameraSession, jobId: _requireString(args, 'job_id'));
    case 'retake_photo':
      return _retakePhoto(cameraSession: cameraSession, jobId: _requireString(args, 'job_id'));
  }

  switch (name) {
    case 'site_condition':
      return _siteCondition(ref: ref, jobId: _requireString(args, 'job_id'), note: _requireString(args, 'note'));

    case 'get_job_details':
      return _getJobDetails(jobId: _requireString(args, 'job_id'));

    case 'get_job_timeline_answer':
      return _getJobTimelineAnswer(
        jobId: _requireString(args, 'job_id'),
        queryHint: _requireString(args, 'query_hint'),
      );

    case 'get_kb_answer':
      return _getKbAnswer(question: _requireString(args, 'question'), jobId: args['job_id'] as String?);

    case 'get_last_photo':
      return _getLastPhoto(navigationSession: navigationSession, jobId: _requireString(args, 'job_id'));

    case 'view_estimate':
      return _viewEstimate(ref: ref, navigationSession: navigationSession, jobId: _requireString(args, 'job_id'));

    case 'view_change_orders':
      return _viewChangeOrders(
        ref: ref,
        navigationSession: navigationSession,
        jobId: _requireString(args, 'job_id'),
      );

    case 'view_invoice':
      return _viewInvoice(navigationSession: navigationSession, jobId: _requireString(args, 'job_id'));

    case 'view_job_history':
      return _viewJobHistory(
        ref: ref,
        navigationSession: navigationSession,
        jobId: _requireString(args, 'job_id'),
      );

    case 'go_back':
      return _goBack(navigationSession: navigationSession, jobId: _requireString(args, 'job_id'));

    default:
      throw ArgumentError('Unknown Gemini function call: "$name" — not one of the 14 declared tools.');
  }
}

String _requireString(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is! String || value.isEmpty) {
    throw ArgumentError('Missing/invalid required argument "$key" in function call args: $args');
  }
  return value;
}

/// `open_camera` — see [GeminiCameraSession.open] for the real code path
/// (same as `PhotoCaptureScreen._initCamera`). NON_BLOCKING in the tool
/// declaration: this returns as soon as the live preview is open, not once
/// a photo exists.
///
/// CONFIRMED regression fix: rejects outright (rather than merely logging)
/// if a previous `open_camera` for this session hasn't returned yet — see
/// [GeminiCameraSession._inFlightSince]'s doc comment for the confirmed
/// native-camera-HAL-contention mechanism this guards against. Returns a
/// normal `{status: 'rejected_overlap'}` response rather than throwing —
/// deliberately NOT the generic error path: `_updateScreenTaskForToolCall`
/// (`gemini_live_test_screen.dart`) resets the screen task to `none` on any
/// `error` response, which would be WRONG here — the genuinely first,
/// still-in-flight call owns the real screen task and must be the only one
/// allowed to change it once IT finishes; a rejected duplicate has to be a
/// true no-op for screen-task purposes, not something that looks like a
/// camera failure.
Future<Map<String, dynamic>> _openCamera({
  required WidgetRef ref,
  required GeminiCameraSession cameraSession,
  required String jobId,
}) async {
  final overlapMs = cameraSession._checkAndMarkInFlight('open_camera');
  if (overlapMs != null) {
    debugPrint(
      'PHOTO TIMING: open_camera called while previous call still in-flight (started ${overlapMs}ms ago) - '
      'possible duplicate/overlapping request.',
    );
    return {
      'status': 'rejected_overlap',
      'job_id': jobId,
      'message': 'open_camera is already in progress (started ${overlapMs}ms ago) — rejecting this overlapping '
          'call instead of contending for the same camera resource.',
    };
  }
  try {
    debugPrint('PHOTO TIMING [open_camera]: handler_entry at ${DateTime.now()}');
    await cameraSession.open(ref, jobId);
    debugPrint('PHOTO TIMING [open_camera]: handler_exit_returning_success at ${DateTime.now()}');
    return {'status': 'camera_open', 'job_id': jobId};
  } on CameraOpenCancelledException {
    debugPrint('PHOTO TIMING [open_camera]: handler_exit_cancelled at ${DateTime.now()}');
    return {
      'status': 'cancelled',
      'job_id': jobId,
      'message': "Okay, I've stopped opening the camera. Say 'take a photo' when you want to try again.",
    };
  } finally {
    cameraSession._clearInFlight('open_camera');
  }
}

/// `capture_photo` — see [GeminiCameraSession.capture] for the real code
/// path (same `takePicture()` call `PhotoCaptureScreen._capture`'s shutter
/// makes). Deliberately does NOT compress or upload — that's
/// `confirm_photo_upload`'s job, only once the technician has actually said
/// to keep this photo.
///
/// CONFIRMED regression fix: same overlap-rejection as [_openCamera] (see
/// its doc comment for why this returns a `rejected_overlap` status rather
/// than throwing) — this is the exact function CONFIRMED to have been
/// called a second time while a first call was still awaiting
/// `controller.takePicture()`, taking the real device from ~2.2-2.5s to
/// 27-71s per call once two calls contended for the same native camera
/// session.
Future<Map<String, dynamic>> _captureStagedPhoto({
  required GeminiCameraSession cameraSession,
  required String jobId,
}) async {
  final overlapMs = cameraSession._checkAndMarkInFlight('capture_photo');
  if (overlapMs != null) {
    debugPrint(
      'PHOTO TIMING: capture_photo called while previous call still in-flight (started ${overlapMs}ms ago) - '
      'possible duplicate/overlapping request.',
    );
    return {
      'status': 'rejected_overlap',
      'job_id': jobId,
      'message': 'capture_photo is already in progress (started ${overlapMs}ms ago) — rejecting this overlapping '
          'call instead of contending for the same camera resource.',
    };
  }
  try {
    debugPrint('PHOTO TIMING [capture_photo]: handler_entry at ${DateTime.now()}');
    await cameraSession.capture(jobId);
    debugPrint('PHOTO TIMING [capture_photo]: handler_exit_returning_success at ${DateTime.now()}');
    return {'status': 'captured', 'job_id': jobId};
  } finally {
    cameraSession._clearInFlight('capture_photo');
  }
}

/// `confirm_photo_upload` — see [GeminiCameraSession.confirm] for the real
/// code path (same [compressPhotoForUpload] +
/// `JobPhotosController.uploadPhoto` calls `PhotoPreviewScreen._confirm`'s
/// Confirm button makes, offline-queue fallback included).
///
/// Reliability audit finding (upgraded from diagnostic-only logging):
/// [GeminiCameraSession.confirm] reads `_capturedFile`, uploads it, and only
/// THEN nulls it — two overlapping calls both read the same non-null file
/// before either clears it, so both would compress and upload the SAME
/// photo, attaching two rows to the job for one shot. Rejects the same way
/// [_openCamera]/[_captureStagedPhoto] do (a `rejected_overlap` status, not
/// a thrown error — see their doc comments for why that distinction
/// matters to `_updateScreenTaskForToolCall`).
Future<Map<String, dynamic>> _confirmPhotoUpload({
  required WidgetRef ref,
  required GeminiCameraSession cameraSession,
  required String jobId,
}) async {
  final overlapMs = cameraSession._checkAndMarkInFlight('confirm_photo_upload');
  if (overlapMs != null) {
    debugPrint(
      'PHOTO TIMING: confirm_photo_upload called while previous call still in-flight (started ${overlapMs}ms '
      'ago) - possible duplicate/overlapping request.',
    );
    return {
      'status': 'rejected_overlap',
      'job_id': jobId,
      'message': 'confirm_photo_upload is already in progress (started ${overlapMs}ms ago) — rejecting this '
          'overlapping call instead of uploading the same photo twice.',
    };
  }
  try {
    final result = await cameraSession.confirm(ref, jobId);
    final queuedOffline = result == PhotoUploadResult.queuedOffline;
    return {'status': queuedOffline ? 'queued_offline' : 'uploaded', 'job_id': jobId};
  } finally {
    cameraSession._clearInFlight('confirm_photo_upload');
  }
}

/// `retake_photo` — see [GeminiCameraSession.retake] for the real code path
/// (same file-delete `PhotoPreviewScreen._retake`'s Retake button makes).
///
/// Diagnostic-only overlap tracking, same reasoning as
/// [_confirmPhotoUpload] — a file delete carries no camera-hardware
/// contention risk.
Future<Map<String, dynamic>> _retakePhoto({required GeminiCameraSession cameraSession, required String jobId}) async {
  final overlapMs = cameraSession._checkAndMarkInFlight('retake_photo');
  if (overlapMs != null) {
    debugPrint(
      'PHOTO TIMING: retake_photo called while previous call still in-flight (started ${overlapMs}ms ago) - '
      'possible duplicate/overlapping request.',
    );
  }
  try {
    await cameraSession.retake(jobId);
    return {'status': 'retaken', 'job_id': jobId};
  } finally {
    cameraSession._clearInFlight('retake_photo');
  }
}

/// `site_condition` — reuses the EXACT existing backend logic behind the
/// fixed-phrase "FieldLoop, site condition" command (see
/// `handleDictationCommand` in `job_voice_commands.dart`, called with
/// `commandType: DictationCommandType.siteCondition`): a single, direct
/// [insertJobDictation] write into `job_dictations`, straight through the
/// technician's own authenticated Supabase session (RLS-scoped) — no
/// Lambda involved at all. Confirmed against that existing handler: unlike
/// `prepareEstimate`, `siteCondition` dictations are never handed to the
/// `/estimates/parse` Lambda (that call is explicitly gated to
/// `commandType == DictationCommandType.prepareEstimate` there) — a site
/// condition note is just stored verbatim, nothing to parse into structured
/// line items.
///
/// Deliberately ONE atomic call with no confirmation step: a site condition
/// note carries no price and commits to nothing, unlike the voice-driven
/// estimate/change-order/invoice/void creation flows (removed entirely —
/// see the system instruction — after proving unreliable across extensive
/// testing). [note] is passed straight through unmodified, never
/// paraphrased.
Future<Map<String, dynamic>> _siteCondition({required WidgetRef ref, required String jobId, required String note}) async {
  final technicianId = ref.read(authControllerProvider).value?.id;
  if (technicianId == null) {
    throw StateError('No signed-in technician — cannot save a site condition note.');
  }

  final dictationId = await insertJobDictation(
    jobId: jobId,
    technicianId: technicianId,
    commandType: DictationCommandType.siteCondition,
    transcript: note,
  );
  return {'status': 'saved', 'dictation_id': dictationId, 'job_id': jobId};
}

/// `get_job_details` — real-data lookup, deliberately NOT read through
/// [jobByIdProvider]'s cache: that cache only ever holds whatever's already
/// loaded into today's/history jobs lists (see its own doc comment), so a
/// direct `jobs` table read here guarantees this always reflects the job's
/// current row regardless of that cache's state. Same table/select shape
/// `todaysJobsQueryProvider`/`historyJobsQueryProvider` already use (see
/// `jobs_provider.dart`), parsed through the same [MockJob.fromMap] so
/// status/nulls are handled identically — just a single row instead of a
/// list.
///
/// Deliberately does NOT include `job_id` (or any other non-speakable raw
/// field) in the returned map — CONFIRMED bug: Gemini would occasionally
/// read the raw UUID out loud since it was sitting right there in the
/// function response JSON it was composing a spoken reply from. Gemini
/// already knows the current job_id from the system instruction and never
/// needs to speak it, so it's simply never given it here. `summary` is a
/// ready-to-speak natural-language sentence assembled here (not left for
/// the model to build from the raw fields itself) — the system instruction
/// tells Gemini to speak this field directly rather than reading off
/// `customer_name`/`service_address`/etc. as a stilted list. The raw fields
/// are still returned alongside it for follow-up questions ("what's the
/// address again") that need a specific value, not the whole summary.
Future<Map<String, dynamic>> _getJobDetails({required String jobId}) async {
  // The customer's name lives on the related `customers` row, not on `jobs`
  // — embedded here exactly as the Home/History job queries do (see
  // `_jobColumns` in `jobs_provider.dart`). A plain `.select()` never had
  // it, which is why this always said the customer wasn't on file.
  final row = await Supabase.instance.client
      .from('jobs')
      .select('*, customers(household_name)')
      .eq('id', jobId)
      .single();
  final job = MockJob.fromMap(row);

  // [MockJob.hasCustomerName] is false only when there genuinely is no name.
  final hasCustomerName = job.hasCustomerName;
  final summary = 'This job is ${hasCustomerName ? "for ${job.customerName} " : ""}at '
      '${job.serviceAddress}, regarding ${job.description}. Current status: ${job.status.label}.';

  return {
    'customer_name': job.customerName,
    'service_address': job.serviceAddress,
    'description': job.description,
    'status': job.status.label,
    'summary': summary,
  };
}

/// `get_job_timeline_answer` — real-data lookup, same reasoning as
/// [_getJobDetails]: reads the `job_history_feed` view directly (the exact
/// same view/query [jobHistoryFeedProvider] uses — see
/// `job_history_provider.dart`) rather than through that provider's cache,
/// so this always reflects live data regardless of whether
/// `JobHistoryScreen` has been opened yet this session.
///
/// Deliberately returns the FULL chronological event list rather than
/// attempting to pre-filter it server-side by [queryHint] — real logged
/// events (arrivals/departures, photos, dictations, estimate events, each
/// with a real timestamp) are what let Gemini answer "when did we arrive"/
/// "what have we done so far" from actual data instead of its own
/// conversational memory or a guess; picking out which event(s) actually
/// answer what was asked is Gemini's job, not this thin dispatcher's — see
/// `dispatchGeminiFunctionCall`'s own doc comment on why business/parsing
/// logic doesn't live here. [queryHint] is accepted and logged for
/// visibility into what prompted the lookup, not used to filter the query.
Future<Map<String, dynamic>> _getJobTimelineAnswer({required String jobId, required String queryHint}) async {
  debugPrint('DISPATCHER: get_job_timeline_answer for job $jobId (query_hint="$queryHint")');
  final rows = await Supabase.instance.client
      .from('job_history_feed')
      .select()
      .eq('job_id', jobId)
      .order('ts', ascending: true);
  final entries = rows.map((row) => JobHistoryEntry.fromJson(row)).toList();
  return {
    'job_id': jobId,
    'event_count': entries.length,
    'events': [
      for (final entry in entries)
        {
          'type': entry.type,
          'description': entry.description,
          'timestamp': entry.timestamp.toIso8601String(),
          if (entry.isVoided) 'voided': true,
        },
    ],
  };
}

/// Calls the exact same extracted request `_handleTroubleshoot` uses (see
/// `fetchTroubleshootingAnswer` in `job_voice_commands.dart`) — real field
/// names (`question`, `jobId`), [jobId] optional (trade-scopes the answer
/// when given, same as every existing caller).
Future<Map<String, dynamic>> _getKbAnswer({required String question, String? jobId}) async {
  // ISSUE 3(a) — timestamped the instant this dispatcher function is
  // entered (before `fetchTroubleshootingAnswer`'s own internal timing
  // starts), so the gap between THIS line and that function's own
  // `request_sent` line (should be ~0ms — nothing awaits in between) proves
  // whether any dispatch-side delay exists above the network call itself,
  // as distinct from the network/Lambda-side span that function times.
  debugPrint('KB TIMING [get_kb_answer]: dispatcher_entry at ${DateTime.now()} question="$question"');
  final answer = await fetchTroubleshootingAnswer(question: question, jobId: jobId);
  return {'answer': answer};
}

/// `get_last_photo` — fetches this job's photos via the SAME `/photos/
/// for-job` request `JobPhotosController._fetchUploaded` already makes
/// (direct call, not through that cached provider — same "always reflects
/// live data" reasoning as [_getJobDetails]/[_getJobTimelineAnswer] above;
/// going through the provider would risk racing its own still-in-flight
/// initial load the first time this job's photos are ever read this
/// session), picks the most recently captured one, and pushes it via the
/// SAME [PhotoViewerScreen] every existing photo-thumbnail tap already
/// uses (see `photo_capture_screen.dart`'s `_PhotoGrid`) — a real, visible
/// photo preview, not just a spoken description. Pushed through
/// [navigationSession] exactly like `view_estimate`/etc., so `go_back`
/// correctly pops it and the go-back-cooldown protection applies the same
/// way.
Future<Map<String, dynamic>> _getLastPhoto({
  required GeminiNavigationSession navigationSession,
  required String jobId,
}) async {
  final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
  if (accessToken == null) {
    throw StateError('No active session — please sign in again.');
  }

  debugPrint('DISPATCHER: get_last_photo fetching photos for job $jobId...');
  final response = await http.post(
    Uri.parse('$apiBaseUrl/photos/for-job'),
    headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
    body: jsonEncode({'jobId': jobId}),
  );
  if (response.statusCode != 200) {
    throw StateError('Failed to fetch photos (${response.statusCode}): ${response.body}');
  }

  final decoded = jsonDecode(response.body) as Map<String, dynamic>;
  final rows = (decoded['photos'] as List<dynamic>?) ?? const [];
  if (rows.isEmpty) {
    return {'found': false, 'message': 'No photos have been taken on this job yet.'};
  }

  // Same row->JobPhoto shape as JobPhotosController._fetchUploaded.
  final photos = rows.map((raw) {
    final row = raw as Map<String, dynamic>;
    final s3Key = row['s3Key'] as String?;
    final rawTs = row['capturedAt'] as String?;
    return JobPhoto(
      id: (row['id'] ?? s3Key ?? rawTs).toString(),
      status: JobPhotoStatus.uploaded,
      timestamp: rawTs != null ? DateTime.parse(rawTs).toLocal() : DateTime.now(),
      s3Key: s3Key,
      url: row['url'] as String?,
    );
  }).toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

  final lastPhoto = photos.first;
  navigationSession.push(PhotoViewerScreen(photo: lastPhoto), name: 'get_last_photo');

  return {'found': true, 'captured_at': lastPhoto.timestamp.toIso8601String()};
}

/// One [GeminiNavigationSession] stack entry — a class, not a record, so
/// [GeminiNavigationSession._remove] can match it by identity.
final class _PushedScreen {
  _PushedScreen(this.name);
  final String name;
}

/// Pushes [screen] unless the screen [name] already pushed is still on top;
/// returns whether it pushed. P0 FIX (CONFIRMED in a real session: an echoed
/// "invoice" re-fired view_invoice and stacked a second InvoiceScreen, so
/// "go back" popped the duplicate and looked like it did nothing) — same
/// idea as open_camera's "OPEN_CAMERA REPEAT WHILE OPEN" guard, but here in
/// the dispatcher so it covers Gemini's own toolCalls as well as the app's
/// deterministic triggers.
bool _pushUnlessAlreadyOnTop(GeminiNavigationSession session, String name, Widget screen) {
  if (session.topScreenName == name) {
    debugPrint('VIEW REPEAT WHILE OPEN: "$name" is already the top screen — not pushing a duplicate');
    return false;
  }
  session.push(screen, name: name);
  return true;
}

/// Holds how many screens `view_estimate`/`view_change_orders`/
/// `view_invoice`/`view_job_history` have pushed on top of the ambient
/// Gemini screen but not yet popped — `go_back` needs this so it only ever
/// pops one of THOSE, never the ambient session route itself. Without this,
/// `Navigator.pop()` alone can't tell "there's a view_* screen to back out
/// of" apart from "nothing is pushed, popping now would tear down the whole
/// Gemini session" — both look identical to a bare `canPop()` check, since
/// the ambient screen is itself a pushed route sitting on top of Job Detail.
///
/// One instance per Gemini Live session — created and owned by
/// `GeminiLiveTestScreen`'s state, same lifecycle as [GeminiCameraSession],
/// passed into [dispatchGeminiFunctionCall] on every call.
///
/// Deliberately does NOT try to track screens pushed some OTHER way (e.g. a
/// technician tapping from Job History into a photo viewer) — this only
/// ever counts pushes THIS class itself made via [push], so `go_back`
/// reliably unwinds exactly what Gemini's own navigation put on the stack.
class GeminiNavigationSession {
  GeminiNavigationSession({this.onActiveChanged});

  /// Fires on the 0->1 and 1->0 edges of [_pushed]'s length (never for
  /// e.g. a second push while one is already active) — `true` means "a
  /// view_* screen is now on top of the ambient session," `false` means
  /// "back down to zero, the ambient session's own UI owns the screen
  /// again." `GeminiLiveTestScreen` uses this to hide its OWN corner-pill/
  /// camera UI entirely while a view_* screen is up: that screen already
  /// has its own `VoicePhaseIndicator` in its own AppBar (the normal
  /// convention every job-scoped screen already follows), and since the
  /// ambient ScreenWidget is inserted as an `OverlayEntry` OUTSIDE the
  /// Navigator's own route-ordering (see `GeminiLiveTestScreen.
  /// onAmbientSessionEnded`'s doc comment), it can end up rendering ABOVE a
  /// later-pushed view_* route in z-order — painting nothing while one is
  /// active is what avoids a redundant/overlapping second indicator (or,
  /// worse, obscuring that real screen entirely during a camera task).
  final ValueChanged<bool>? onActiveChanged;

  /// Function names of the screens [push] put on the stack, bottom to top —
  /// one entry per still-mounted pushed route. A list of names rather than
  /// the old bare count so [topScreenName] can answer "is this screen
  /// already showing?" for the view_* no-op guard (see
  /// [_pushUnlessAlreadyOnTop]).
  ///
  /// P0 FIX: each entry is an object identity, removed exactly once by
  /// whichever of [goBack] or the route's own `.then` sees it first. The
  /// old count was decremented by BOTH for a voice-driven pop — harmless at
  /// depth 1 (the `> 0` guard), but at depth 2 (a duplicate invoice push)
  /// it zeroed the count with one screen still showing.
  final List<_PushedScreen> _pushed = [];

  /// The function name (e.g. `'view_invoice'`) of the screen this session
  /// most recently pushed and that is still on top, or `null` if none.
  String? get topScreenName => _pushed.isEmpty ? null : _pushed.last.name;

  /// `view_estimate`/`view_change_orders`/`view_invoice`/`view_job_history`
  /// — pushes [screen] via the EXACT same [FadeSlidePageRoute] transition
  /// the matching tap button on Job Detail already pushes (see the
  /// `_TabContent` build cases in `job_detail_screen.dart` — "View Full
  /// Estimate"/"View Change Orders"/"View Full Invoice"/"View Full
  /// Timeline"). No new screens, no new navigation logic — this only
  /// triggers the same push from a Gemini function call instead of a tap,
  /// while tracking it so [goBack] can unwind it later.
  ///
  /// Uses [rootNavigatorKey] rather than a `BuildContext` — same reasoning
  /// `GlobalVoiceService._triggerGeminiSession` already established for
  /// pushing the ambient Gemini screen itself: this dispatcher has no
  /// BuildContext of its own to push through.
  void push(Widget screen, {required String name}) {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) {
      throw StateError('No navigator available — cannot navigate.');
    }
    if (_pushed.isEmpty) onActiveChanged?.call(true);
    final entry = _PushedScreen(name);
    _pushed.add(entry);
    unawaited(
      navigator.push(FadeSlidePageRoute(builder: (_) => screen))
          // Covers the technician backing out via the screen's own AppBar
          // back arrow / system back gesture instead of saying "go back" —
          // either way this entry must be gone once the pushed screen is
          // actually gone, or a later go_back would try to pop one screen
          // too many. A no-op if [goBack] already removed it.
          .then((_) => _remove(entry)),
    );
  }

  /// By [identical], not `List.remove`: two pushes of the same screen are
  /// distinct entries.
  void _remove(_PushedScreen entry) {
    final index = _pushed.indexWhere((e) => identical(e, entry));
    if (index < 0) return;
    _pushed.removeAt(index);
    if (_pushed.isEmpty) onActiveChanged?.call(false);
  }

  /// `go_back` — pops exactly one of the screens [push] put on the stack,
  /// via the SAME standard `Navigator.pop()` the tap-driven back arrow/
  /// system back gesture already uses on every one of those screens —
  /// never a hardcoded route back to Job Detail, so this correctly reaches
  /// Job Detail regardless of which view_* screen is currently on top.
  /// Returns whether there was anything to pop; `false` means the
  /// technician is already at Job Detail (nothing this session pushed
  /// remains on top) — the caller decides what, if anything, to tell them.
  bool goBack() {
    if (_pushed.isEmpty) return false;
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null || !navigator.canPop()) return false;
    navigator.pop();
    _remove(_pushed.last);
    return true;
  }
}

/// CONFIRMED CRASH ("Bad state: Cannot use 'ref' after the widget was
/// disposed"): shared by every function below that does `ref.read(notifier)`
/// -> `await refresh()` -> `ref.read(provider)` again — the ambient Gemini
/// session (whose `ref` this is) can be torn down WHILE that `await` is in
/// flight (a go_back/end_session arriving mid-lookup), and Riverpod's
/// `ref.read`/`.watch`/`.exists` ALL throw the same `StateError` once
/// disposed — there is no separate, safe "is this still valid" check to
/// call first (same class of "ref outlived its widget" bug already fixed
/// elsewhere in this codebase via a `mounted` guard/deferral — see
/// `GeminiLiveTestScreen._teardown`'s `Future(() {...})` doc comment).
/// Callers use this for the SECOND read, right after the `await` — the
/// navigation itself already genuinely succeeded by that point, so the
/// caller still reports that success, just without the freshly re-read
/// data, instead of throwing and reporting total failure for a request
/// that actually worked.
T? _readAfterAwaitIfStillMounted<T>(WidgetRef ref, ProviderListenable<T> provider) {
  try {
    return ref.read(provider);
  } on StateError catch (e) {
    if (!e.message.contains('disposed')) rethrow;
    return null;
  }
}

/// `view_estimate` — navigates to the Estimate screen and also fetches and
/// returns the job's real current estimate (id/status/total/line items) so
/// Gemini can speak the real details, not just confirm it navigated.
/// `estimate: null` when the job has none yet — same as `EstimateScreen`
/// itself would show.
Future<Map<String, dynamic>> _viewEstimate({
  required WidgetRef ref,
  required GeminiNavigationSession navigationSession,
  required String jobId,
}) async {
  final pushed = _pushUnlessAlreadyOnTop(navigationSession, 'view_estimate', EstimateScreen(jobId: jobId));

  final controller = ref.read(jobEstimateProvider(jobId).notifier);
  await controller.refresh();
  final estimate = _readAfterAwaitIfStillMounted(ref, jobEstimateProvider(jobId))?.valueOrNull;
  return {
    'status': pushed ? 'navigated' : 'already_on_screen',
    'job_id': jobId,
    'estimate': estimate == null
        ? null
        : {
            'id': estimate.id,
            'status': estimate.status,
            'total_amount': estimate.totalAmount,
            'line_items': [
              for (final item in estimate.lineItems) {'description': item.description, 'amount': item.amount},
            ],
          },
  };
}

/// `view_change_orders` — navigates to the Change Orders screen, same as
/// [_viewEstimate]. Also fetches and returns every one of the job's real
/// change orders (id/description/amount/status/voided) so Gemini can
/// genuinely tell them apart afterward instead of guessing which one "the
/// $50 fitting one"
/// means.
Future<Map<String, dynamic>> _viewChangeOrders({
  required WidgetRef ref,
  required GeminiNavigationSession navigationSession,
  required String jobId,
}) async {
  final pushed =
      _pushUnlessAlreadyOnTop(navigationSession, 'view_change_orders', ChangeOrdersScreen(jobId: jobId));

  final controller = ref.read(jobChangeOrdersProvider(jobId).notifier);
  await controller.refresh();
  final changeOrders =
      _readAfterAwaitIfStillMounted(ref, jobChangeOrdersProvider(jobId))?.valueOrNull ?? const <ChangeOrder>[];
  return {
    'status': pushed ? 'navigated' : 'already_on_screen',
    'job_id': jobId,
    'change_orders': [
      for (final co in changeOrders)
        {
          'id': co.id,
          'description': co.description,
          'amount': co.additionalAmount,
          'status': co.status,
          'voided': co.isVoided,
        },
    ],
  };
}

Future<Map<String, dynamic>> _viewInvoice({required GeminiNavigationSession navigationSession, required String jobId}) async {
  final pushed = _pushUnlessAlreadyOnTop(navigationSession, 'view_invoice', InvoiceScreen(jobId: jobId));
  return {'status': pushed ? 'navigated' : 'already_on_screen', 'job_id': jobId};
}

/// `view_job_history` — the one of the four that needs a lookup first:
/// [JobHistoryScreen] takes the whole job object (`job_detail_screen.dart`'s
/// "View Full Timeline" button passes the already-loaded `job` it has in
/// scope), so this reads it from [jobByIdProvider] the same way every other
/// job-scoped read in this dispatcher does.
Future<Map<String, dynamic>> _viewJobHistory({
  required WidgetRef ref,
  required GeminiNavigationSession navigationSession,
  required String jobId,
}) async {
  final job = ref.read(jobByIdProvider(jobId));
  if (job == null) {
    throw StateError('Job $jobId not found — cannot open its history.');
  }
  final pushed = _pushUnlessAlreadyOnTop(navigationSession, 'view_job_history', JobHistoryScreen(job: job));
  return {'status': pushed ? 'navigated' : 'already_on_screen', 'job_id': jobId};
}

/// `go_back` — see [GeminiNavigationSession.goBack] for why this can't just
/// be a bare `Navigator.pop()` call here: it needs to know whether there's
/// actually a view_* screen on top to pop, or whether the technician is
/// already at Job Detail (in which case this is a harmless no-op, not an
/// accidental pop of the ambient session itself).
Future<Map<String, dynamic>> _goBack({
  required GeminiNavigationSession navigationSession,
  required String jobId,
}) async {
  final wentBack = navigationSession.goBack();
  return {'status': wentBack ? 'navigated_back' : 'already_at_job_details', 'job_id': jobId};
}

/// Timing only — measures how responsive the Android main (platform) thread
/// is while a native camera call is in flight. Every CameraX step the camera
/// plugin takes before the shutter (bind, flash mode, rotation, the capture
/// request itself) is a separate platform-channel call on that thread, and
/// CONFIRMED in a real trace ~6.4s passed between `platform_capture_call_start`
/// and CameraX's own `takePictureInternal`, with the only other native
/// activity in that window being the audio player's release/setup — which
/// also runs on the main thread. Round-trips a cheap, read-only platform call
/// one at a time (never two outstanding, so it adds no pressure of its own)
/// and logs any slow one, plus a summary, so the next trace shows directly
/// when and for how long that thread was blocked.
class _MainThreadProbe {
  _MainThreadProbe._(this._label);

  final String _label;
  final Stopwatch _elapsed = Stopwatch()..start();
  bool _stopped = false;
  int _probes = 0;
  int _slowProbes = 0;
  int _worstMs = 0;
  int _worstAtMs = 0;

  static const Duration _interval = Duration(milliseconds: 300);
  static const int _slowMs = 150;

  static _MainThreadProbe start(String label) => _MainThreadProbe._(label).._loop();

  Future<void> _loop() async {
    while (!_stopped) {
      final sentAtMs = _elapsed.elapsedMilliseconds;
      final roundTrip = Stopwatch()..start();
      try {
        await Permission.camera.status;
      } catch (_) {
        return;
      }
      final ms = roundTrip.elapsedMilliseconds;
      _probes++;
      if (ms > _worstMs) {
        _worstMs = ms;
        _worstAtMs = sentAtMs;
      }
      if (ms >= _slowMs) {
        _slowProbes++;
        debugPrint(
          'PHOTO TIMING [$_label]: main_thread_probe SLOW — a platform call sent ${sentAtMs}ms into the native call '
          'took ${ms}ms to come back (Android main thread busy)',
        );
      }
      if (_stopped) break;
      await Future<void>.delayed(_interval);
    }
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    debugPrint(
      'PHOTO TIMING [$_label]: main_thread_probe summary — $_probes probe(s) over ${_elapsed.elapsedMilliseconds}ms, '
      '$_slowProbes slow (>= ${_slowMs}ms), worst ${_worstMs}ms (sent ${_worstAtMs}ms in)',
    );
  }
}
