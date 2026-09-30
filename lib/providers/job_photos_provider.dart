import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../models/job_photo.dart';
import '../models/kept_photo_ref.dart';
import '../utils/network_error.dart';
import 'offline_upload_queue_provider.dart';
import 'pending_uploads_db.dart';

/// Outcome of [JobPhotosController.uploadPhoto] — distinct from a thrown
/// exception because "queued offline" is NOT a failure from the
/// technician's perspective (see `PhotoPreviewScreen._confirm`, which treats
/// it the same as a real upload: navigate back normally, just with a
/// different confirmation message).
enum PhotoUploadResult { uploaded, queuedOffline }

/// [JobPhotosController.uploadPhotoDetailed]'s result: the same
/// [PhotoUploadResult] [JobPhotosController.uploadPhoto] returns, plus a
/// [KeptPhotoRef] naming exactly which row (or queued item) this photo is.
class PhotoUploadOutcome {
  const PhotoUploadOutcome(this.result, this.ref, {this.noteStatus});

  final PhotoUploadResult result;
  final KeptPhotoRef ref;

  /// Only when a note rode along with the upload (see
  /// [JobPhotosController.uploadPhotoDetailed]'s `transcript`).
  final PhotoNoteWriteStatus? noteStatus;
}

/// What happened to a note uploaded together with its photo:
///  - [written]: landed in the same `field_events` write that marked the
///    photo uploaded;
///  - [queued]: will be written later — the photo itself was queued
///    offline (the note travels as its `caption`), or that write hit a
///    network error and the note went to `pending_photo_notes`;
///  - [failed]: the photo is uploaded but the note could not be saved.
enum PhotoNoteWriteStatus { written, queued, failed }

/// Real job-site photos for a job: uploaded ones come from
/// `GET /photos/for-job` (this job's FULL history — every photo ever
/// uploaded, not just ones captured this session — each with a temporary
/// 1-hour signed S3 [JobPhoto.url] for direct display); photos captured
/// during this session are added optimistically (with an `uploading`
/// status) as soon as the shutter is pressed, then updated in place as the
/// upload-url request, S3 upload, and status update complete.
final jobPhotosProvider =
    StateNotifierProvider.family<JobPhotosController, AsyncValue<List<JobPhoto>>, String>(
      (ref, jobId) => JobPhotosController(ref, jobId),
    );

class JobPhotosController extends StateNotifier<AsyncValue<List<JobPhoto>>> {
  JobPhotosController(this._ref, this.jobId) : super(const AsyncLoading()) {
    // DIAGNOSTIC (Task B): this constructor — and therefore _loadUploaded()
    // below — runs exactly once per (jobId) family instance, the first
    // time `jobPhotosProvider(jobId)` is ever read anywhere in the app.
    // Riverpod caches family instances indefinitely (this provider is NOT
    // .autoDispose), so re-watching the same jobId later (navigating away
    // and back, or even logging out and back in — the ProviderScope itself
    // is only ever created once, in main.dart's runApp) reuses this SAME
    // instance rather than constructing a new one. If this log line is
    // missing on a return visit, that confirms the query is not re-running.
    debugPrint('PHOTOS DIAG: JobPhotosController constructed for job_id=$jobId (fetchCount will start at 0)');
    _loadUploaded();
  }

  final Ref _ref;
  final String jobId;
  int _fetchCount = 0;

  /// When [_fetchUploaded] last completed successfully — see
  /// [refreshIfStale]. `null` until the first successful fetch.
  DateTime? _lastFetchedAt;

  /// Signed URLs from `/photos/for-job` are valid for 1 hour (see that
  /// endpoint's docs); refetch a bit before they'd actually expire rather
  /// than cutting it exactly at the wire, so a technician who's had the
  /// screen open close to the full hour never hits a dead URL in the gap.
  static const Duration _urlStaleAfter = Duration(minutes: 50);

  Future<void> _loadUploaded() async {
    final result = await AsyncValue.guard(_fetchUploaded);
    if (!mounted) return;
    state = result;
  }

  Future<List<JobPhoto>> _fetchUploaded() async {
    _fetchCount++;
    debugPrint('PHOTOS DIAG: _fetchUploaded() call #$_fetchCount for job_id=$jobId');
    try {
      final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
      if (accessToken == null) {
        throw StateError('No active session — please sign in again.');
      }

      debugPrint('PHOTOS: fetching photos for job $jobId via /photos/for-job...');
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
      debugPrint('PHOTOS DIAG: _fetchUploaded() call #$_fetchCount for job_id=$jobId returned ${rows.length} row(s)');
      _lastFetchedAt = DateTime.now();

      // A `/photos/for-job` deployed before photo notes existed returns no
      // `transcript` key at all — read the notes straight off field_events
      // instead of showing every photo as note-less.
      final lambdaReturnsTranscripts = rows.any((raw) => (raw as Map<String, dynamic>).containsKey('transcript'));
      final fallbackTranscripts = rows.isEmpty || lambdaReturnsTranscripts
          ? const <int, String>{}
          : await _fetchPhotoTranscriptsDirect(jobId);

      return rows.map((raw) {
        final row = raw as Map<String, dynamic>;
        final s3Key = row['s3Key'] as String?;
        final rawTs = row['capturedAt'] as String?;
        final fieldEventId = row['id'] is int ? row['id'] as int : int.tryParse('${row['id']}');
        return JobPhoto(
          id: (row['id'] ?? s3Key ?? rawTs).toString(),
          status: JobPhotoStatus.uploaded,
          timestamp: rawTs != null ? DateTime.parse(rawTs).toLocal() : DateTime.now(),
          s3Key: s3Key,
          url: row['url'] as String?,
          fieldEventId: fieldEventId,
          transcript: (row['transcript'] as String?) ?? fallbackTranscripts[fieldEventId],
        );
      }).toList();
    } catch (e, stackTrace) {
      debugPrint('PHOTOS ERROR (fetch uploaded): $e\n$stackTrace');
      rethrow;
    }
  }

  /// Re-syncs with the backend, keeping any photos still uploading (or
  /// failed) this session — they're either not queryable as "uploaded" yet
  /// or never made it, and shouldn't be dropped from the grid on refresh.
  ///
  /// A failed refresh (e.g. a transient network blip) deliberately leaves
  /// the existing state alone rather than replacing an already-good photo
  /// grid with an error screen — this matters more now than it used to,
  /// since [refreshIfStale] calls this as a routine background check every
  /// time the grid becomes visible again, not just on an explicit
  /// user-initiated retry.
  Future<void> refresh() async {
    final inFlight = state.valueOrNull?.where((p) => p.status != JobPhotoStatus.uploaded).toList() ?? const [];
    final result = await AsyncValue.guard(() async {
      final uploaded = await _fetchUploaded();
      return [...uploaded, ...inFlight];
    });
    if (!mounted) return;
    if (result is AsyncError) {
      debugPrint('PHOTOS: refresh() failed, keeping existing state: ${result.error}');
      return;
    }
    state = result;
  }

  /// Called whenever the photo grid becomes visible again after being away
  /// for a while (see `JobDetailScreen`/`PhotoCaptureScreen`'s
  /// `didPopNext`) — signed URLs from `/photos/for-job` expire after 1
  /// hour, so a technician who keeps the app open longer than that would
  /// otherwise be stuck with dead image links for the rest of the session.
  /// No-ops if the last fetch is still within [_urlStaleAfter], so this is
  /// cheap to call on every return to the screen rather than needing its
  /// own separate "is it worth checking" logic at each call site.
  Future<void> refreshIfStale() async {
    final lastFetchedAt = _lastFetchedAt;
    if (lastFetchedAt != null && DateTime.now().difference(lastFetchedAt) < _urlStaleAfter) {
      debugPrint(
        'PHOTOS: refreshIfStale() for job $jobId — last fetch was '
        '${DateTime.now().difference(lastFetchedAt).inMinutes}m ago, still fresh, skipping',
      );
      return;
    }
    debugPrint('PHOTOS: refreshIfStale() for job $jobId — refetching (stale or never fetched)');
    await refresh();
  }

  /// Single choke point for every `state = AsyncData(...)` write — several
  /// of [uploadPhoto]'s steps call this after an `await` (the upload-url
  /// request, the S3 PUT, the `field_events` status update), and the
  /// screen watching this provider can be gone by the time any of them
  /// resolve, so every write funnels through this one guard rather than
  /// repeating it at each call site.
  void _upsert(JobPhoto photo) {
    if (!mounted) return;
    final current = state.valueOrNull ?? const [];
    final idx = current.indexWhere((p) => p.id == photo.id);
    final next = [...current];
    if (idx == -1) {
      next.add(photo);
    } else {
      next[idx] = photo;
    }
    state = AsyncData(next);
  }

  /// Uploads an already-compressed JPEG. Checks connectivity BEFORE ever
  /// calling `/photos/upload-url` — that request is what pre-creates the
  /// `field_events` row server-side, so if the device is known offline this
  /// skips straight to queuing without touching it at all, and the offline
  /// queue (`OfflineUploadQueueService`) is the only thing that calls it
  /// later, exactly once, when it actually retries. This is what keeps a
  /// queued-then-retried photo from ever creating two `field_events` rows
  /// for the same photo.
  ///
  /// If the OS reports a connection but the request still fails with a
  /// network error mid-flight (e.g. connectivity drops between the
  /// upload-url response and the S3 PUT), this still queues rather than
  /// losing the photo — in that narrow case a `field_events` row may already
  /// have been reserved server-side and is left orphaned (never flipped to
  /// `uploaded`) rather than duplicated visibly; the alternative (silently
  /// dropping the photo) is worse for a "never lose a photo" requirement.
  ///
  /// The photo is added to [state] immediately with an `uploading` status
  /// (carrying [bytes] so the thumbnail shows the real image right away)
  /// and updated in place as the outcome becomes known. Only a genuine
  /// (non-network) failure marks it `failed` and rethrows so the caller can
  /// surface an on-screen error — a network failure queues it instead and
  /// returns [PhotoUploadResult.queuedOffline], not an exception.
  Future<PhotoUploadResult> uploadPhoto(Uint8List bytes, {Future<UploadUrlInfo>? prefetchedUploadUrl}) async {
    return (await uploadPhotoDetailed(bytes, prefetchedUploadUrl: prefetchedUploadUrl)).result;
  }

  /// Shows [transcript] on this session's photo matching [ref] right away,
  /// without waiting for the next `/photos/for-job` refetch.
  void applyPhotoNote(KeptPhotoRef ref, String transcript) {
    final current = state.valueOrNull ?? const <JobPhoto>[];
    for (final photo in current) {
      final isMatch = photo.id == ref.localPhotoId || (ref.fieldEventId != null && photo.fieldEventId == ref.fieldEventId);
      if (isMatch) _upsert(photo.copyWith(transcript: transcript));
    }
  }

  /// [uploadPhoto], plus the [KeptPhotoRef] naming this photo's own
  /// `field_events` row (or, when queued offline, its `pending_uploads` row)
  /// — see [KeptPhotoRef]'s doc comment.
  ///
  /// [transcript] is the technician's confirmed voice note for this photo,
  /// when there is one: it goes into the SAME `field_events` write that
  /// marks the photo uploaded (see [uploadPhotoBytes]), or rides along as
  /// the queued photo's `caption` when offline — never a separate write
  /// after the fact.
  Future<PhotoUploadOutcome> uploadPhotoDetailed(
    Uint8List bytes, {
    Future<UploadUrlInfo>? prefetchedUploadUrl,
    String? transcript,
  }) async {
    final id = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final startedAt = DateTime.now();
    _upsert(
      JobPhoto(id: id, status: JobPhotoStatus.uploading, timestamp: startedAt, localBytes: bytes, transcript: transcript),
    );

    final connectivity = await Connectivity().checkConnectivity();
    if (isOfflineResult(connectivity)) {
      debugPrint('PHOTOS: no connectivity ($connectivity) — queuing photo without calling upload-url');
      // The offline queue's own retry always fetches a fresh URL later (see
      // [uploadPhotoBytes]'s doc comment) — any prefetch already in flight
      // for this photo is simply left unawaited/unused, not an error.
      return _queueOffline(id: id, startedAt: startedAt, bytes: bytes, transcript: transcript);
    }

    try {
      final uploaded = await uploadPhotoBytes(
        jobId: jobId,
        bytes: bytes,
        prefetchedUploadUrl: prefetchedUploadUrl,
        transcript: transcript,
      );
      final s3Key = uploaded.s3Key;
      // FIX 1 (CRITICAL): this used to also call
      // _ref.invalidate(jobPhotosProvider(jobId)) here — but `_ref` belongs
      // to THIS SAME JobPhotosController instance (the one
      // jobPhotosProvider(jobId) currently resolves to), so that was a
      // provider trying to invalidate itself from within its own method.
      // Riverpod asserts on that ("A provider cannot depend on itself") on
      // every call, which is what actually crashed here — the upload
      // itself (S3 PUT + field_events update, both above) had already
      // succeeded by this point, so the crash only made it LOOK like the
      // upload failed. The _upsert below is already the correct way to
      // reflect a successful upload in THIS controller's own state — a
      // direct `state = AsyncData(...)` write on `this`, no rebuild-from-
      // outside needed — so no replacement fetch/invalidate call is added
      // here; removing the crashing line is the whole fix. Contrast with
      // OfflineUploadQueueService._uploadOne, a genuinely DIFFERENT
      // provider/service, which correctly invalidates jobPhotosProvider
      // from outside it — that call is unrelated and unchanged.
      _upsert(
        JobPhoto(
          id: id,
          status: JobPhotoStatus.uploaded,
          timestamp: startedAt,
          localBytes: bytes,
          s3Key: s3Key,
          fieldEventId: uploaded.fieldEventId,
          transcript: uploaded.noteStatus == PhotoNoteWriteStatus.failed ? null : transcript,
        ),
      );
      debugPrint('PHOTOS: upload complete for $id, state updated directly (uploaded)');
      return PhotoUploadOutcome(
        PhotoUploadResult.uploaded,
        KeptPhotoRef(jobId: jobId, localPhotoId: id, fieldEventId: uploaded.fieldEventId, s3Key: s3Key),
        noteStatus: uploaded.noteStatus,
      );
    } catch (e, stackTrace) {
      if (isNetworkError(e)) {
        debugPrint('PHOTOS: upload failed with a network error ($e) — queuing offline instead');
        return _queueOffline(id: id, startedAt: startedAt, bytes: bytes, transcript: transcript);
      }
      debugPrint('PHOTOS ERROR (upload): $e\n$stackTrace');
      _upsert(
        JobPhoto(id: id, status: JobPhotoStatus.failed, timestamp: startedAt, localBytes: bytes, error: e.toString()),
      );
      rethrow;
    }
  }

  Future<PhotoUploadOutcome> _queueOffline({
    required String id,
    required DateTime startedAt,
    required Uint8List bytes,
    String? transcript,
  }) async {
    try {
      final queued = await _ref
          .read(offlineUploadQueueProvider.notifier)
          .enqueue(jobId: jobId, bytes: bytes, caption: transcript);
      debugPrint('PHOTOS: photo queued for offline upload at ${queued.localPath} (pending_upload_id=${queued.pendingUploadId})');
      _upsert(
        JobPhoto(
          id: id,
          status: JobPhotoStatus.queuedOffline,
          timestamp: startedAt,
          localBytes: bytes,
          transcript: transcript,
        ),
      );
      return PhotoUploadOutcome(
        PhotoUploadResult.queuedOffline,
        KeptPhotoRef(jobId: jobId, localPhotoId: id, pendingUploadId: queued.pendingUploadId),
        noteStatus: transcript == null ? null : PhotoNoteWriteStatus.queued,
      );
    } catch (e, stackTrace) {
      // Couldn't even persist locally (disk full, etc.) — that IS a real
      // failure the technician needs to know about, not a silent queue.
      debugPrint('PHOTOS ERROR (offline queue): $e\n$stackTrace');
      _upsert(
        JobPhoto(id: id, status: JobPhotoStatus.failed, timestamp: startedAt, localBytes: bytes, error: e.toString()),
      );
      rethrow;
    }
  }
}

/// A presigned S3 PUT URL plus the `s3Key` the `/photos/upload-url` Lambda
/// chose for it — see [prefetchUploadUrl]. [fieldEventId] is the id of the
/// `field_events` row that same call inserted for this photo (`null` only
/// if it genuinely couldn't be determined — see [prefetchUploadUrl]).
typedef UploadUrlInfo = ({String uploadUrl, String s3Key, int? fieldEventId});

/// What [uploadPhotoBytes] actually uploaded: the S3 key, the
/// `field_events` row id it belongs to, and — only when a transcript was
/// passed — what happened to it.
typedef UploadedPhotoInfo = ({String s3Key, int? fieldEventId, PhotoNoteWriteStatus? noteStatus});

/// Calls the `/photos/upload-url` Lambda alone — the first of
/// [uploadPhotoBytes]'s two network round trips, split out so it can be
/// started EARLY (while the technician is still looking at the photo
/// preview, deciding keep vs. retake) instead of only after "keep it" is
/// heard. CONFIRMED via flutter_run_log_new.txt (build #63): this call
/// alone accounts for most of confirm_photo_upload's ~9.4s "S3 upload"
/// time (the actual S3 PUT itself is a couple of seconds; the DB
/// bookkeeping calls after it are already off the critical path — see
/// [uploadPhotoBytes]'s own doc comment) — a real backend/network cost
/// this app can't reduce directly, but CAN move off the spoken-confirmation
/// critical path by overlapping it with time the technician is going to
/// spend deciding anyway.
///
/// HONEST TRADE-OFF: the Lambda INSERTs a `field_events` row (status
/// `upload_pending`) as a side effect of generating the URL (see
/// `backend/functions/get-photo-upload-url/index.js`) — calling this on
/// every CAPTURE rather than every CONFIRM means a retaken (never
/// confirmed) photo leaves an orphaned `upload_pending` row behind. That
/// row is harmless functionally (every job-history/photo query filters on
/// `metadata->>status = 'uploaded'`, so it never appears anywhere), just
/// permanent DB clutter — accepted here for the latency win rather than
/// left for a future backend change (a cancel/cleanup endpoint, or not
/// inserting until the PUT actually succeeds) to fix properly.
Future<UploadUrlInfo> prefetchUploadUrl({required String jobId}) async {
  final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
  if (accessToken == null) {
    throw StateError('No active session — please sign in again.');
  }

  final fileName = 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';

  debugPrint('PHOTOS: requesting upload URL for job $jobId, file $fileName...');
  final uploadUrlResponse = await http.post(
    Uri.parse('$apiBaseUrl/photos/upload-url'),
    headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
    body: jsonEncode({'jobId': jobId, 'fileName': fileName}),
  );
  if (uploadUrlResponse.statusCode != 200) {
    throw StateError('Failed to get upload URL (${uploadUrlResponse.statusCode}): ${uploadUrlResponse.body}');
  }

  final decoded = jsonDecode(uploadUrlResponse.body) as Map<String, dynamic>;
  final uploadUrl = decoded['uploadUrl'] as String?;
  final s3Key = decoded['s3Key'] as String?;
  if (uploadUrl == null || s3Key == null) {
    throw StateError('Upload URL response missing uploadUrl/s3Key.');
  }
  debugPrint('PHOTOS: got upload URL, s3Key=$s3Key');

  // The row's own id, straight from the Lambda's insert. An older Lambda
  // deploy doesn't return it; s3_object_key is unique per photo (it
  // embeds a millisecond timestamp), so the id is looked up by it
  // instead, scoped to this job and event type.
  final rawId = decoded['fieldEventId'];
  var fieldEventId = rawId is int ? rawId : int.tryParse('${rawId ?? ''}');
  if (fieldEventId == null) {
    fieldEventId = await _lookupPhotoFieldEventId(jobId: jobId, s3Key: s3Key);
    debugPrint(
      'PHOTO NOTE [row_id]: upload-url response had no fieldEventId — looked up by s3_object_key: '
      'field_events.id=${fieldEventId ?? 'NOT FOUND'} (s3Key=$s3Key)',
    );
  }
  return (uploadUrl: uploadUrl, s3Key: s3Key, fieldEventId: fieldEventId);
}

/// See [prefetchUploadUrl] — the fallback for a Lambda that doesn't return
/// the inserted row's id. Returns `null` (never throws) when it can't be
/// found: the photo upload itself must never fail because of this.
Future<int?> _lookupPhotoFieldEventId({required String jobId, required String s3Key}) async {
  try {
    final rows = await Supabase.instance.client
        .from('field_events')
        .select('id')
        .eq('s3_object_key', s3Key)
        .eq('job_id', jobId)
        .eq('event_type', 'photo')
        .limit(2);
    if (rows.length != 1) {
      debugPrint('PHOTO NOTE [row_id]: lookup for s3Key=$s3Key matched ${rows.length} rows — not guessing');
      return null;
    }
    final id = rows.first['id'];
    return id is int ? id : int.tryParse('$id');
  } catch (e) {
    debugPrint('PHOTO NOTE [row_id]: lookup for s3Key=$s3Key failed: $e');
    return null;
  }
}

/// Fallback for [JobPhotosController._fetchUploaded] when `/photos/for-job`
/// doesn't return `transcript` yet — `field_events.id` -> note for every
/// photo in [jobId] that has one. Empty (never throws) on failure: a
/// missing note must never fail the photo grid itself.
Future<Map<int, String>> _fetchPhotoTranscriptsDirect(String jobId) async {
  try {
    final rows = await Supabase.instance.client
        .from('field_events')
        .select('id, transcript')
        .eq('job_id', jobId)
        .eq('event_type', 'photo')
        .not('transcript', 'is', null);
    return {
      for (final row in rows)
        if (row['id'] is int && row['transcript'] is String) row['id'] as int: row['transcript'] as String,
    };
  } catch (e) {
    debugPrint('PHOTOS: direct photo-note fetch for job $jobId failed (showing photos without notes): $e');
    return const {};
  }
}

/// Writes the technician's confirmed voice description into [fieldEventId]'s
/// `transcript` column — matched on the row's own id AND [jobId] AND
/// `event_type = 'photo'`, never job_id alone, so it can only ever land on
/// that one photo. `.select()` makes a 0-row match (wrong id, or an RLS
/// grant gap — see [_markFieldEventUploaded]'s BUG A2 note) throw instead
/// of silently "succeeding".
///
/// Throws on any failure; callers decide whether it's a network failure to
/// queue (see `savePhotoNote` in `offline_upload_queue_provider.dart`).
Future<void> writePhotoTranscript({
  required int fieldEventId,
  required String jobId,
  required String transcript,
}) async {
  debugPrint(
    'PHOTO NOTE [save]: field_events.transcript UPDATE REACHED — executing '
    'WHERE id=$fieldEventId AND job_id=$jobId AND event_type=photo (${transcript.length} chars) at ${DateTime.now()}',
  );
  final updated = await Supabase.instance.client
      .from('field_events')
      .update({'transcript': transcript})
      .eq('id', fieldEventId)
      .eq('job_id', jobId)
      .eq('event_type', 'photo')
      .select('id');
  debugPrint(
    'PHOTO NOTE [save]: field_events.transcript UPDATE returned ${updated.length} row(s) '
    '(ids=${updated.map((r) => r['id']).join(',')}) for field_events.id=$fieldEventId at ${DateTime.now()}',
  );
  if (updated.isEmpty) {
    throw StateError(
      'field_events transcript update for id=$fieldEventId job_id=$jobId event_type=photo matched 0 rows — '
      'wrong row, or missing RLS UPDATE grant on field_events.',
    );
  }
}

/// Requests a presigned S3 URL from the `/photos/upload-url` Lambda (or
/// reuses [prefetchedUploadUrl], when given — see [prefetchUploadUrl]),
/// PUTs [bytes] straight to S3, then flips the pre-created `field_events`
/// row to `uploaded`. Returns the `s3Key` on success; throws on any
/// failure (network or otherwise) — callers decide what a given failure
/// means for them (see [JobPhotosController.uploadPhoto], which queues on
/// a network error, and `OfflineUploadQueueService`, which retries later).
///
/// Shared by both the live-capture upload path and the offline queue's
/// retry so they hit `/photos/upload-url` + the S3 PUT + the `field_events`
/// update identically — never two separate implementations that could
/// drift apart. [prefetchedUploadUrl] is only ever passed by the live-
/// capture path (see [GeminiCameraSession.capture]/`.confirm` in
/// `gemini_function_dispatcher.dart`); the offline queue always fetches
/// fresh, since a queued retry can run long after any prefetch would have
/// gone stale.
///
/// [transcript], when given, is written in that SAME `field_events` update
/// (photo + note in one write), which is then awaited rather than left in
/// the background — see [_markFieldEventUploaded].
Future<UploadedPhotoInfo> uploadPhotoBytes({
  required String jobId,
  required Uint8List bytes,
  Future<UploadUrlInfo>? prefetchedUploadUrl,
  String? transcript,
}) async {
  final urlInfo = await (prefetchedUploadUrl ?? prefetchUploadUrl(jobId: jobId));
  final uploadUrl = urlInfo.uploadUrl;
  final s3Key = urlInfo.s3Key;

  debugPrint('PHOTOS: uploading ${bytes.length} bytes to S3...');
  final putResponse = await http.put(Uri.parse(uploadUrl), headers: {'Content-Type': 'image/jpeg'}, body: bytes);
  if (putResponse.statusCode < 200 || putResponse.statusCode >= 300) {
    throw StateError('S3 upload failed (${putResponse.statusCode}).');
  }
  debugPrint('PHOTOS: S3 upload succeeded for s3Key=$s3Key');

  // BUG 3 FIX (CONFIRMED via flutter_run_log_new.txt, build #56): this
  // update used to be awaited HERE, gating the caller's "uploaded" result —
  // and therefore the spoken confirmation and every other user-facing
  // "done" signal — on an extra ~1.3s Supabase round trip for a field the
  // technician never sees or waits on. The photo is genuinely, durably
  // uploaded the instant the S3 PUT above succeeds; this UPDATE only flips
  // an internal `field_events.metadata.status` bookkeeping field so job-
  // history queries stop showing 'upload_pending'. Still fully awaited and
  // still throws loudly on 0 rows (see BUG A2 fix below) — just off the
  // critical path via `unawaited`, with its own error caught and logged
  // rather than propagating into a promise nobody's awaiting.
  if (transcript == null) {
    unawaited(_markFieldEventUploaded(s3Key));
    return (s3Key: s3Key, fieldEventId: urlInfo.fieldEventId, noteStatus: null);
  }

  // A note rides along: awaited, so the caller only reports it saved once
  // it really is. The photo itself is already safe in S3 either way, so a
  // failure here never fails the upload — a network error keeps the note
  // in `pending_photo_notes` for the next reconnect.
  final fieldEventId = urlInfo.fieldEventId;
  try {
    await _markFieldEventUploaded(s3Key, transcript: transcript, rethrowErrors: true);
    return (s3Key: s3Key, fieldEventId: fieldEventId, noteStatus: PhotoNoteWriteStatus.written);
  } catch (e) {
    if (fieldEventId != null && isNetworkError(e)) {
      try {
        await PendingUploadsDb.instance.insertPhotoNote(jobId: jobId, fieldEventId: fieldEventId, transcript: transcript);
        debugPrint('PHOTO NOTE [queue]: photo+note write hit a network error ($e) — note queued for field_events.id=$fieldEventId');
        return (s3Key: s3Key, fieldEventId: fieldEventId, noteStatus: PhotoNoteWriteStatus.queued);
      } catch (queueError) {
        debugPrint('PHOTO NOTE [queue]: could not queue note for field_events.id=$fieldEventId: $queueError');
      }
    }
    debugPrint('PHOTO NOTE [save]: FAILED — photo uploaded (s3Key=$s3Key) but its note was not saved: $e');
    return (s3Key: s3Key, fieldEventId: fieldEventId, noteStatus: PhotoNoteWriteStatus.failed);
  }
}

/// See [uploadPhotoBytes]'s BUG 3 FIX doc comment for why this runs
/// unawaited rather than gating the upload's own return — except when a
/// [transcript] rides along, which [uploadPhotoBytes] awaits with
/// [rethrowErrors] so the note's outcome is known.
Future<void> _markFieldEventUploaded(String s3Key, {String? transcript, bool rethrowErrors = false}) async {
  debugPrint(
    'PHOTOS: marking field_events uploaded for s3Key=$s3Key'
    '${transcript != null ? ' — PHOTO NOTE [save]: single photo+note write (${transcript.length} chars)' : ''}...',
  );
  try {
    // BUG A2 fix: this used to fire-and-forget the update with no check on
    // whether it actually touched a row. The field_events row is INSERTed by
    // the /photos/upload-url Lambda using a privileged service-role Supabase
    // key (see backend/functions/get-photo-upload-url), which bypasses RLS —
    // but this UPDATE runs through the app's own RLS-governed client
    // (Supabase.instance.client, initialized with the anon/user key, see
    // main.dart). If there's no RLS UPDATE policy granting technicians write
    // access to field_events, Postgrest doesn't throw — it just silently
    // matches zero rows, so the row's metadata never actually flips to
    // 'uploaded', while this code kept logging "succeeded" regardless. That
    // exactly explains "upload confirmed successful, but _fetchUploaded()'s
    // `metadata->>status = 'uploaded'` filter returns 0 rows forever" — the
    // filter itself was correct, the write just never landed. `.select()`
    // forces Postgrest to return the updated row(s), so an empty result here
    // is now a loud, diagnosable failure instead of a silent no-op.
    final updated = await Supabase.instance.client
        .from('field_events')
        .update({
          'metadata': {'status': 'uploaded'},
          'transcript': ?transcript,
        })
        .eq('s3_object_key', s3Key)
        .select();
    if (updated.isEmpty) {
      throw StateError(
        'field_events update for s3Key=$s3Key matched 0 rows — likely missing/insufficient '
        'RLS UPDATE grant on field_events for the technician role.',
      );
    }
    debugPrint('PHOTOS: field_events status update succeeded for s3Key=$s3Key (${updated.length} row updated)');
  } catch (e, stackTrace) {
    // BUG 3 FIX: now genuinely fire-and-forget from the upload's own
    // perspective (the S3 file itself is safe either way), so a failure
    // here MUST be loud somewhere since nothing awaits this Future anymore
    // — logged, not silently swallowed.
    debugPrint('PHOTOS ERROR (background field_events status update for s3Key=$s3Key): $e\n$stackTrace');
    if (rethrowErrors) rethrow;
  }
}
