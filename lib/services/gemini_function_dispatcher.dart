import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
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
class GeminiCameraSession {
  CameraController? _controller;
  XFile? _capturedFile;

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
  Future<void> open(WidgetRef ref, String jobId) async {
    // TEMPORARY (reliability audit, Issue 2 — profiling open_camera's
    // 2.2s-68s+ inconsistency): `dart:developer` TimelineTask spans, one per
    // real sub-step, so a DevTools timeline capture during a slow call shows
    // exactly which awaited step actually consumed the time — not another
    // debugPrint guess. Remove once the bottleneck is confirmed and fixed.
    final task = developer.TimelineTask()..start('GeminiCameraSession.open');
    try {
      task.start('discardPending');
      await _discardPending();
      task.finish();

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
      debugPrint('PHOTO TIMING [open_camera]: permission_check_done at ${DateTime.now()}');

      debugPrint('CAMERA (dispatcher): enumerating available cameras for job $jobId...');
      task.start('availableCameras');
      final cameras = await availableCameras();
      task.finish();
      if (cameras.isEmpty) {
        throw StateError('No camera found on this device.');
      }
      final rearCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      task.start('CameraController.construct');
      final controller = CameraController(rearCamera, ResolutionPreset.high, enableAudio: false);
      task.finish();

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
      await controller.initialize();
      task.finish();
      debugPrint('CAMERA (dispatcher): rear camera initialized (live preview open) for job $jobId');
      debugPrint('PHOTO TIMING [open_camera]: controller_initialized at ${DateTime.now()}');
      _controller = controller;
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
    _capturedFile = await controller.takePicture();
    debugPrint('PHOTO TIMING [capture_photo]: platform_capture_call_end at ${DateTime.now()}');
    debugPrint('CAMERA (dispatcher): photo captured (${_capturedFile!.path}), awaiting confirm or retake');
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

    debugPrint('CAMERA (dispatcher): compressing ${file.path} for job $jobId...');
    final compressed = await compressPhotoForUpload(file.path);
    debugPrint('CAMERA (dispatcher): uploading compressed photo (${compressed.length} bytes) for job $jobId...');
    final result = await ref.read(jobPhotosProvider(jobId).notifier).uploadPhoto(compressed);

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
    debugPrint('CAMERA (dispatcher): retaking — discarding ${file.path} for job $jobId');
    try {
      await File(file.path).delete();
    } catch (e) {
      debugPrint('CAMERA (dispatcher): could not delete discarded photo file: $e');
    }
    _capturedFile = null;
  }

  Future<void> _discardCapturedFileOnly() async {
    final file = _capturedFile;
    _capturedFile = null;
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
      try {
        await controller.dispose();
      } catch (e) {
        debugPrint('CAMERA (dispatcher): error disposing previous camera controller: $e');
      }
    }
  }

  /// Called once from `GeminiLiveTestScreen._teardown()` at the end of the
  /// Gemini Live session — cleans up an orphaned open controller and/or
  /// unconfirmed captured file if the conversation ended mid-flow (camera
  /// opened but never captured, or captured but never confirmed/retaken),
  /// so nothing leaks past the session that opened it.
  Future<void> dispose() => _discardPending();
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
  final row = await Supabase.instance.client.from('jobs').select().eq('id', jobId).single();
  final job = MockJob.fromMap(row);

  // `MockJob.fromMap` substitutes the literal string 'Not provided' for a
  // null/missing `customer_name` column — same fallback used everywhere
  // else in the app (e.g. JobDetailScreen), so a job genuinely showing "Not
  // provided" here reflects the `jobs` row itself having no customer name on
  // file, not a read/parsing bug in this function (confirmed: identical
  // `.select()` shape and `MockJob.fromMap` parsing as `todaysJobsQueryProvider`/
  // `historyJobsQueryProvider`, which the rest of the app already relies on).
  final hasCustomerName = job.customerName.isNotEmpty && job.customerName != 'Not provided';
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
  navigationSession.push(PhotoViewerScreen(photo: lastPhoto));

  return {'found': true, 'captured_at': lastPhoto.timestamp.toIso8601String()};
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

  /// Fires on the 0->1 and 1->0 edges of [_pushedScreenCount] (never for
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

  int _pushedScreenCount = 0;

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
  void push(Widget screen) {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) {
      throw StateError('No navigator available — cannot navigate.');
    }
    if (_pushedScreenCount == 0) onActiveChanged?.call(true);
    _pushedScreenCount++;
    unawaited(
      navigator.push(FadeSlidePageRoute(builder: (_) => screen))
          // Covers the technician backing out via the screen's own AppBar
          // back arrow / system back gesture instead of saying "go back" —
          // either way this count must drop back to 0 once the pushed
          // screen is actually gone, or a later go_back would try to pop
          // one screen too many.
          .then((_) {
            if (_pushedScreenCount > 0) _pushedScreenCount--;
            if (_pushedScreenCount == 0) onActiveChanged?.call(false);
          }),
    );
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
    if (_pushedScreenCount == 0) return false;
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null || !navigator.canPop()) return false;
    navigator.pop();
    _pushedScreenCount--;
    if (_pushedScreenCount == 0) onActiveChanged?.call(false);
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
  navigationSession.push(EstimateScreen(jobId: jobId));

  final controller = ref.read(jobEstimateProvider(jobId).notifier);
  await controller.refresh();
  final estimate = _readAfterAwaitIfStillMounted(ref, jobEstimateProvider(jobId))?.valueOrNull;
  return {
    'status': 'navigated',
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
  navigationSession.push(ChangeOrdersScreen(jobId: jobId));

  final controller = ref.read(jobChangeOrdersProvider(jobId).notifier);
  await controller.refresh();
  final changeOrders =
      _readAfterAwaitIfStillMounted(ref, jobChangeOrdersProvider(jobId))?.valueOrNull ?? const <ChangeOrder>[];
  return {
    'status': 'navigated',
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
  navigationSession.push(InvoiceScreen(jobId: jobId));
  return {'status': 'navigated', 'job_id': jobId};
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
  navigationSession.push(JobHistoryScreen(job: job));
  return {'status': 'navigated', 'job_id': jobId};
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
