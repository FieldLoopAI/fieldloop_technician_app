/// Identifies ONE specific photo the technician just kept, for anything
/// that must later target exactly that photo's own `field_events` row —
/// currently the voice photo description (see `savePhotoNote` in
/// `offline_upload_queue_provider.dart`), which must never land on a
/// different photo or event of the same job.
///
/// Exactly one of two shapes:
///  - uploaded (or at least reserved) online: [fieldEventId] is the row's
///    own id, captured from the `/photos/upload-url` insert.
///  - queued offline: no `field_events` row exists yet (or the one reserved
///    before the connection dropped is orphaned and will never be used), so
///    [pendingUploadId] points at the on-device `pending_uploads` row that
///    will create the real one when it drains.
class KeptPhotoRef {
  const KeptPhotoRef({
    required this.jobId,
    required this.localPhotoId,
    this.fieldEventId,
    this.pendingUploadId,
    this.s3Key,
  });

  final String jobId;

  /// The in-memory `JobPhoto.id` (`local-...`) this session's photo strip
  /// shows it under — used to show a saved note on it immediately.
  final String localPhotoId;
  final int? fieldEventId;
  final int? pendingUploadId;
  final String? s3Key;

  bool get isQueuedOffline => fieldEventId == null && pendingUploadId != null;

  /// One-line form for log lines.
  String describe() => isQueuedOffline
      ? 'pending_upload_id=$pendingUploadId job_id=$jobId (queued offline — field_events row not created yet)'
      : 'field_events.id=${fieldEventId ?? 'UNKNOWN'} job_id=$jobId s3Key=${s3Key ?? 'n/a'}';
}
