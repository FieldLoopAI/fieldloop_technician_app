import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../models/job_photo.dart';

/// Real job-site photos for a job: uploaded ones come from `field_events`
/// (`event_type = 'photo'`, `metadata->>'status' = 'uploaded'`); photos
/// captured during this session are added optimistically (with an
/// `uploading` status) as soon as the shutter is pressed, then updated in
/// place as the upload-url request, S3 upload, and status update complete.
final jobPhotosProvider =
    StateNotifierProvider.family<JobPhotosController, AsyncValue<List<JobPhoto>>, String>(
      (ref, jobId) => JobPhotosController(jobId),
    );

class JobPhotosController extends StateNotifier<AsyncValue<List<JobPhoto>>> {
  JobPhotosController(this.jobId) : super(const AsyncLoading()) {
    _loadUploaded();
  }

  final String jobId;

  Future<void> _loadUploaded() async {
    final result = await AsyncValue.guard(_fetchUploaded);
    if (!mounted) return;
    state = result;
  }

  Future<List<JobPhoto>> _fetchUploaded() async {
    try {
      debugPrint('PHOTOS: querying uploaded field_events photos for job $jobId...');
      final rows = await Supabase.instance.client
          .from('field_events')
          .select('id, s3_object_key, event_ts, metadata')
          .eq('job_id', jobId)
          .eq('event_type', 'photo')
          .eq('metadata->>status', 'uploaded')
          .order('event_ts', ascending: true);
      debugPrint('PHOTOS: uploaded photos query returned ${rows.length} row(s)');

      return rows.map((row) {
        final s3Key = row['s3_object_key'] as String?;
        final rawTs = row['event_ts'] as String?;
        return JobPhoto(
          id: s3Key ?? row['id'].toString(),
          status: JobPhotoStatus.uploaded,
          timestamp: rawTs != null ? DateTime.parse(rawTs).toLocal() : DateTime.now(),
          s3Key: s3Key,
        );
      }).toList();
    } catch (e, stackTrace) {
      debugPrint('PHOTOS ERROR (fetch uploaded): $e\n$stackTrace');
      rethrow;
    }
  }

  /// Re-syncs with `field_events`, keeping any photos still uploading (or
  /// failed) this session — they're either not queryable as "uploaded" yet
  /// or never made it, and shouldn't be dropped from the grid on refresh.
  Future<void> refresh() async {
    final inFlight = state.valueOrNull?.where((p) => p.status != JobPhotoStatus.uploaded).toList() ?? const [];
    final result = await AsyncValue.guard(() async {
      final uploaded = await _fetchUploaded();
      return [...uploaded, ...inFlight];
    });
    if (!mounted) return;
    state = result;
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

  /// Uploads an already-compressed JPEG: requests a presigned S3 URL from
  /// the `/photos/upload-url` Lambda, PUTs the bytes straight to S3, then
  /// flips the pre-created `field_events` row to `uploaded`. The photo is
  /// added to [state] immediately with an `uploading` status (carrying
  /// [bytes] so the thumbnail shows the real image right away) and updated
  /// in place as each step completes; any failure marks it `failed` and
  /// rethrows so the caller can surface an on-screen error.
  Future<void> uploadPhoto(Uint8List bytes) async {
    final id = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final startedAt = DateTime.now();
    _upsert(JobPhoto(id: id, status: JobPhotoStatus.uploading, timestamp: startedAt, localBytes: bytes));

    String? s3Key;
    try {
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
        throw StateError(
          'Failed to get upload URL (${uploadUrlResponse.statusCode}): ${uploadUrlResponse.body}',
        );
      }

      final decoded = jsonDecode(uploadUrlResponse.body) as Map<String, dynamic>;
      final uploadUrl = decoded['uploadUrl'] as String?;
      s3Key = decoded['s3Key'] as String?;
      if (uploadUrl == null || s3Key == null) {
        throw StateError('Upload URL response missing uploadUrl/s3Key.');
      }
      debugPrint('PHOTOS: got upload URL, s3Key=$s3Key');
      _upsert(JobPhoto(id: id, status: JobPhotoStatus.uploading, timestamp: startedAt, localBytes: bytes, s3Key: s3Key));

      debugPrint('PHOTOS: uploading ${bytes.length} bytes to S3...');
      final putResponse = await http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'image/jpeg'},
        body: bytes,
      );
      if (putResponse.statusCode < 200 || putResponse.statusCode >= 300) {
        throw StateError('S3 upload failed (${putResponse.statusCode}).');
      }
      debugPrint('PHOTOS: S3 upload succeeded for s3Key=$s3Key');

      debugPrint('PHOTOS: marking field_events uploaded for s3Key=$s3Key...');
      await Supabase.instance.client
          .from('field_events')
          .update({'metadata': {'status': 'uploaded'}})
          .eq('s3_object_key', s3Key);
      debugPrint('PHOTOS: field_events status update succeeded for s3Key=$s3Key');

      _upsert(
        JobPhoto(id: id, status: JobPhotoStatus.uploaded, timestamp: startedAt, localBytes: bytes, s3Key: s3Key),
      );
    } catch (e, stackTrace) {
      debugPrint('PHOTOS ERROR (upload): $e\n$stackTrace');
      _upsert(
        JobPhoto(
          id: id,
          status: JobPhotoStatus.failed,
          timestamp: startedAt,
          localBytes: bytes,
          s3Key: s3Key,
          error: e.toString(),
        ),
      );
      rethrow;
    }
  }
}
