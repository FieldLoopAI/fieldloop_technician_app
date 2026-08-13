import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../models/job_photo.dart';
import '../utils/network_error.dart';
import 'offline_upload_queue_provider.dart';

/// Outcome of [JobPhotosController.uploadPhoto] — distinct from a thrown
/// exception because "queued offline" is NOT a failure from the
/// technician's perspective (see `PhotoPreviewScreen._confirm`, which treats
/// it the same as a real upload: navigate back normally, just with a
/// different confirmation message).
enum PhotoUploadResult { uploaded, queuedOffline }

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

      return rows.map((raw) {
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
  Future<PhotoUploadResult> uploadPhoto(Uint8List bytes) async {
    final id = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final startedAt = DateTime.now();
    _upsert(JobPhoto(id: id, status: JobPhotoStatus.uploading, timestamp: startedAt, localBytes: bytes));

    final connectivity = await Connectivity().checkConnectivity();
    if (isOfflineResult(connectivity)) {
      debugPrint('PHOTOS: no connectivity ($connectivity) — queuing photo without calling upload-url');
      return _queueOffline(id: id, startedAt: startedAt, bytes: bytes);
    }

    try {
      final s3Key = await uploadPhotoBytes(jobId: jobId, bytes: bytes);
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
      _upsert(JobPhoto(id: id, status: JobPhotoStatus.uploaded, timestamp: startedAt, localBytes: bytes, s3Key: s3Key));
      debugPrint('PHOTOS: upload complete for $id, state updated directly (uploaded)');
      return PhotoUploadResult.uploaded;
    } catch (e, stackTrace) {
      if (isNetworkError(e)) {
        debugPrint('PHOTOS: upload failed with a network error ($e) — queuing offline instead');
        return _queueOffline(id: id, startedAt: startedAt, bytes: bytes);
      }
      debugPrint('PHOTOS ERROR (upload): $e\n$stackTrace');
      _upsert(
        JobPhoto(id: id, status: JobPhotoStatus.failed, timestamp: startedAt, localBytes: bytes, error: e.toString()),
      );
      rethrow;
    }
  }

  Future<PhotoUploadResult> _queueOffline({
    required String id,
    required DateTime startedAt,
    required Uint8List bytes,
  }) async {
    try {
      final localPath = await _ref
          .read(offlineUploadQueueProvider.notifier)
          .enqueue(jobId: jobId, bytes: bytes);
      debugPrint('PHOTOS: photo queued for offline upload at $localPath');
      _upsert(JobPhoto(id: id, status: JobPhotoStatus.queuedOffline, timestamp: startedAt, localBytes: bytes));
      return PhotoUploadResult.queuedOffline;
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

/// Requests a presigned S3 URL from the `/photos/upload-url` Lambda, PUTs
/// [bytes] straight to S3, then flips the pre-created `field_events` row to
/// `uploaded`. Returns the `s3Key` on success; throws on any failure
/// (network or otherwise) — callers decide what a given failure means for
/// them (see [JobPhotosController.uploadPhoto], which queues on a network
/// error, and `OfflineUploadQueueService`, which retries later).
///
/// Shared by both the live-capture upload path and the offline queue's
/// retry so they hit `/photos/upload-url` + the S3 PUT + the `field_events`
/// update identically — never two separate implementations that could
/// drift apart.
Future<String> uploadPhotoBytes({required String jobId, required Uint8List bytes}) async {
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

  debugPrint('PHOTOS: uploading ${bytes.length} bytes to S3...');
  final putResponse = await http.put(Uri.parse(uploadUrl), headers: {'Content-Type': 'image/jpeg'}, body: bytes);
  if (putResponse.statusCode < 200 || putResponse.statusCode >= 300) {
    throw StateError('S3 upload failed (${putResponse.statusCode}).');
  }
  debugPrint('PHOTOS: S3 upload succeeded for s3Key=$s3Key');

  debugPrint('PHOTOS: marking field_events uploaded for s3Key=$s3Key...');
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

  return s3Key;
}
