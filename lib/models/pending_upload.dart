/// Status of a row in the on-device `pending_uploads` table (see
/// `PendingUploadsDb`) — mirrors the column values exactly (`.name` of each
/// enum value IS the stored string), never anything fancier than that.
enum PendingUploadStatus {
  pending,
  uploading,
  failed;

  static PendingUploadStatus fromName(String value) {
    return PendingUploadStatus.values.firstWhere(
      (s) => s.name == value,
      orElse: () => PendingUploadStatus.pending,
    );
  }
}

/// A photo captured with no connectivity (or that failed to upload for a
/// network reason), persisted locally so it survives an app restart until
/// `OfflineUploadQueueService` can retry it. [id] is null only before the
/// row has been inserted — every row read back from the DB always has one.
class PendingUpload {
  const PendingUpload({
    this.id,
    required this.jobId,
    required this.localFilePath,
    this.caption,
    required this.createdAt,
    this.status = PendingUploadStatus.pending,
  });

  final int? id;
  final String jobId;
  final String localFilePath;
  final String? caption;
  final DateTime createdAt;
  final PendingUploadStatus status;

  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'job_id': jobId,
      'local_file_path': localFilePath,
      'caption': caption,
      'created_at': createdAt.toIso8601String(),
      'status': status.name,
    };
  }

  factory PendingUpload.fromMap(Map<String, Object?> map) {
    return PendingUpload(
      id: map['id'] as int?,
      jobId: map['job_id'] as String,
      localFilePath: map['local_file_path'] as String,
      caption: map['caption'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      status: PendingUploadStatus.fromName(map['status'] as String),
    );
  }
}
