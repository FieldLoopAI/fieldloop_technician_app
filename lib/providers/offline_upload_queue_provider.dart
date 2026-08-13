import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/pending_upload.dart';
import '../utils/network_error.dart';
import 'job_photos_provider.dart';
import 'pending_uploads_db.dart';

/// Live "N photos pending upload" counts, keyed by job id — kept in sync
/// with the `pending_uploads` table by [OfflineUploadQueueService] so the
/// photo strip/grid badges can watch this instead of re-querying SQLite on
/// every rebuild.
class OfflineUploadQueueState {
  const OfflineUploadQueueState({this.pendingCountByJob = const {}});

  final Map<String, int> pendingCountByJob;

  int countFor(String jobId) => pendingCountByJob[jobId] ?? 0;

  OfflineUploadQueueState copyWith({Map<String, int>? pendingCountByJob}) {
    return OfflineUploadQueueState(pendingCountByJob: pendingCountByJob ?? this.pendingCountByJob);
  }
}

/// The ONE offline photo-upload queue for the entire app.
///
/// Created once, above the navigation/router level (`RootShell`, same as
/// `GlobalVoiceService` — see that file's doc comment for the established
/// pattern) and kept alive for the whole authenticated session.
///
/// A photo enters the queue only via [enqueue], called by
/// `JobPhotosController.uploadPhoto` the moment a capture can't go out
/// immediately (no connectivity, or a network error mid-upload) — the
/// compressed bytes are written to a file under the app's documents
/// directory (survives app restarts, unlike a temp directory) and a
/// `pending_uploads` row is inserted with status `pending`.
///
/// From then on this service owns getting it uploaded: it listens for
/// `connectivity_plus` transitions from no-connection to connected and
/// drains the queue, and also runs one sync check on [start] (app
/// startup/login) in case rows were left over from a previous session that
/// never got the chance to sync. Screens never touch the queue table
/// directly — only through this provider's [enqueue] (indirectly, via
/// `JobPhotosController`) and the live [pendingUploadCountForJobProvider]
/// badge counts.
final offlineUploadQueueProvider = StateNotifierProvider<OfflineUploadQueueService, OfflineUploadQueueState>(
  (ref) => OfflineUploadQueueService(ref),
);

class OfflineUploadQueueService extends StateNotifier<OfflineUploadQueueState> {
  OfflineUploadQueueService(this._ref) : super(const OfflineUploadQueueState());

  final Ref _ref;
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _started = false;
  bool _syncing = false;

  /// Idempotent — safe to call more than once, only the first call does
  /// anything. Called exactly once, from `RootShell`, the same place
  /// `GlobalVoiceService.start()` is called.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    debugPrint('OFFLINE QUEUE: starting...');
    await _refreshCounts();
    // Item 6: catch anything left over from a previous session that was
    // closed while still offline, before waiting on any connectivity event.
    unawaited(_syncIfOnline());
    _subscription = _connectivity.onConnectivityChanged.listen(_onConnectivityChanged);
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    if (isOfflineResult(results)) return;
    debugPrint('OFFLINE QUEUE: connectivity changed to $results, checking for pending uploads');
    unawaited(_syncIfOnline());
  }

  Future<void> _syncIfOnline() async {
    if (_syncing) return;
    final connectivity = await _connectivity.checkConnectivity();
    if (isOfflineResult(connectivity)) {
      debugPrint('OFFLINE QUEUE: sync check skipped — still offline');
      return;
    }
    _syncing = true;
    try {
      await _drainQueue();
    } finally {
      _syncing = false;
    }
  }

  Future<void> _drainQueue() async {
    final pending = await PendingUploadsDb.instance.queryRetryable();
    debugPrint('OFFLINE QUEUE: connectivity restored, found ${pending.length} pending uploads');
    for (final upload in pending) {
      await _uploadOne(upload);
    }
    await _refreshCounts();
  }

  Future<void> _uploadOne(PendingUpload upload) async {
    final id = upload.id;
    if (id == null) return;
    debugPrint('OFFLINE QUEUE: uploading item $id');
    await PendingUploadsDb.instance.updateStatus(id, PendingUploadStatus.uploading);
    try {
      final file = File(upload.localFilePath);
      if (!await file.exists()) {
        throw StateError('Queued photo file missing on disk: ${upload.localFilePath}');
      }
      final bytes = await file.readAsBytes();
      // Same upload-url + PUT + field_events-update sequence the live
      // capture path uses — called exactly once per photo, here, since a
      // queued item never reached (or never completed) that sequence
      // itself.
      await uploadPhotoBytes(jobId: upload.jobId, bytes: bytes);
      await PendingUploadsDb.instance.delete(id);
      unawaited(file.delete().catchError((_) => file));
      debugPrint('OFFLINE QUEUE: item $id uploaded successfully');

      // The optimistic JobPhotoStatus.queuedOffline entry that
      // JobPhotosController._queueOffline added for this photo when it was
      // first captured is keyed by a local-only id ('local-...') that has
      // no correlation back to this pending_uploads row — so there's no id
      // to look up and flip to `uploaded` in place. Calling
      // JobPhotosController.refresh() would NOT fix this either: it
      // deliberately re-adds every non-uploaded entry as "still in
      // flight", so the stale queuedOffline entry would survive a refresh()
      // call untouched, alongside a second, separate `uploaded` entry for
      // the same photo pulled in from field_events — i.e. it would still
      // show the pending icon (plus a new duplicate thumbnail), not clear
      // it. Invalidating instead discards jobPhotosProvider's whole cached
      // list so it rebuilds from field_events alone, which now reports this
      // photo as uploaded.
      // DIAGNOSTIC (Task C): exact provider name + operation, logged both
      // immediately before and after the call, so a real-device log can
      // confirm this actually runs (and isn't, e.g., thrown before reaching
      // here, or silently no-op'ing on an already-invalidated provider).
      debugPrint(
        'OFFLINE QUEUE: upload complete for $id, invalidating jobPhotosProvider(${upload.jobId}) '
        'so the thumbnail grid refetches from field_events',
      );
      _ref.invalidate(jobPhotosProvider(upload.jobId));
      debugPrint('OFFLINE QUEUE: jobPhotosProvider(${upload.jobId}) invalidated (item $id)');
    } catch (e, stackTrace) {
      debugPrint('OFFLINE QUEUE: item $id failed: $e\n$stackTrace');
      await PendingUploadsDb.instance.updateStatus(id, PendingUploadStatus.failed);
    }
  }

  /// Saves [bytes] to persistent app storage and inserts a `pending_uploads`
  /// row. Returns the saved file's path. This is the ONLY place a photo
  /// enters the durable queue — everything else in this class only ever
  /// reads rows back out and retries them.
  Future<String> enqueue({required String jobId, required Uint8List bytes, String? caption}) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final queueDir = Directory(p.join(docsDir.path, 'pending_uploads'));
    if (!await queueDir.exists()) {
      await queueDir.create(recursive: true);
    }
    final fileName = 'photo_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final file = File(p.join(queueDir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);

    await PendingUploadsDb.instance.insert(
      PendingUpload(jobId: jobId, localFilePath: file.path, caption: caption, createdAt: DateTime.now()),
    );
    debugPrint('OFFLINE QUEUE: queued photo for job $jobId at ${file.path}');
    await _refreshCounts();
    return file.path;
  }

  Future<void> _refreshCounts() async {
    final all = await PendingUploadsDb.instance.queryRetryable();
    final counts = <String, int>{};
    for (final upload in all) {
      counts[upload.jobId] = (counts[upload.jobId] ?? 0) + 1;
    }
    if (mounted) state = state.copyWith(pendingCountByJob: counts);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

/// Live "N photos pending upload" count for [jobId] — watch this from the
/// photo strip/grid badges rather than querying SQLite directly; it updates
/// automatically as [OfflineUploadQueueService] enqueues and drains items.
final pendingUploadCountForJobProvider = Provider.family<int, String>((ref, jobId) {
  return ref.watch(offlineUploadQueueProvider).countFor(jobId);
});
