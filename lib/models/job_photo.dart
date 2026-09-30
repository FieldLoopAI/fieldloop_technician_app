import 'dart:typed_data';

enum JobPhotoStatus { uploading, uploaded, failed, queuedOffline }

/// A job-site photo captured via the device camera. [localBytes] holds the
/// compressed JPEG bytes for photos captured THIS session — kept around so
/// the thumbnail can show the real image immediately without waiting on a
/// network round-trip. [url] is a temporary (1-hour) signed S3 link
/// returned by `GET /photos/for-job` for photos loaded from the backend
/// (this job's full history, not just this session) — used to render the
/// thumbnail/full-size view via `CachedNetworkImage` whenever [localBytes]
/// isn't available. A photo can have neither (still loading) or both
/// (captured this session, since re-synced from the backend).
///
/// [fieldEventId] is this photo's own `field_events.id` once known, and
/// [transcript] the technician's spoken description saved on that row (see
/// `savePhotoNote` in `offline_upload_queue_provider.dart`) — `null` when
/// the photo has no note.
class JobPhoto {
  const JobPhoto({
    required this.id,
    required this.status,
    required this.timestamp,
    this.s3Key,
    this.localBytes,
    this.error,
    this.url,
    this.fieldEventId,
    this.transcript,
  });

  final String id;
  final JobPhotoStatus status;
  final DateTime timestamp;
  final String? s3Key;
  final Uint8List? localBytes;
  final String? error;
  final String? url;
  final int? fieldEventId;
  final String? transcript;

  bool get hasNote => transcript != null && transcript!.trim().isNotEmpty;

  JobPhoto copyWith({
    JobPhotoStatus? status,
    String? s3Key,
    Uint8List? localBytes,
    String? error,
    String? url,
    int? fieldEventId,
    String? transcript,
  }) {
    return JobPhoto(
      id: id,
      status: status ?? this.status,
      timestamp: timestamp,
      s3Key: s3Key ?? this.s3Key,
      localBytes: localBytes ?? this.localBytes,
      error: error ?? this.error,
      url: url ?? this.url,
      fieldEventId: fieldEventId ?? this.fieldEventId,
      transcript: transcript ?? this.transcript,
    );
  }
}
