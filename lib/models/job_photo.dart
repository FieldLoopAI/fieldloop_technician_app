import 'dart:typed_data';

enum JobPhotoStatus { uploading, uploaded, failed }

/// A job-site photo captured via the device camera. [localBytes] holds the
/// compressed JPEG bytes for photos captured this session — kept around so
/// the thumbnail can show the real image without needing a way to fetch it
/// back from S3. Photos loaded from `field_events` on screen open (captured
/// in an earlier session) only have [s3Key]/[status], since no local bytes
/// exist for those.
class JobPhoto {
  const JobPhoto({
    required this.id,
    required this.status,
    required this.timestamp,
    this.s3Key,
    this.localBytes,
    this.error,
  });

  final String id;
  final JobPhotoStatus status;
  final DateTime timestamp;
  final String? s3Key;
  final Uint8List? localBytes;
  final String? error;

  JobPhoto copyWith({
    JobPhotoStatus? status,
    String? s3Key,
    Uint8List? localBytes,
    String? error,
  }) {
    return JobPhoto(
      id: id,
      status: status ?? this.status,
      timestamp: timestamp,
      s3Key: s3Key ?? this.s3Key,
      localBytes: localBytes ?? this.localBytes,
      error: error ?? this.error,
    );
  }
}
