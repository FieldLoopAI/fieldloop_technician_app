/// Status of a row in the on-device `pending_visit_events` table (see
/// `PendingVisitEventsDb`) — mirrors `PendingUploadStatus`
/// (`pending_upload.dart`)'s exact shape/naming for the same reason: the
/// `.name` of each enum value IS the stored string, nothing fancier.
enum PendingVisitEventStatus {
  pending,
  failed;

  static PendingVisitEventStatus fromName(String value) {
    return PendingVisitEventStatus.values.firstWhere(
      (s) => s.name == value,
      orElse: () => PendingVisitEventStatus.pending,
    );
  }
}

/// A `gps_arrive`/`gps_depart` `field_events` row that couldn't be written
/// directly after exhausting `visit_provider.dart`'s retry attempts (a
/// network error on every one — a genuine, e.g. RLS/validation, error is
/// never queued, it surfaces immediately instead), persisted locally so it
/// survives an app restart until connectivity is confirmed restored and
/// `VisitTrackingService` can retry it — same resilience philosophy as
/// `PendingUpload` (`pending_upload.dart`) already applies to photos, just
/// for this much smaller/simpler payload: no file on disk, only the row
/// itself needs to survive.
class PendingVisitEvent {
  const PendingVisitEvent({
    this.id,
    required this.jobId,
    required this.technicianId,
    required this.eventType,
    required this.source,
    required this.eventTs,
    required this.createdAt,
    this.status = PendingVisitEventStatus.pending,
  });

  final int? id;
  final String jobId;
  final String technicianId;

  /// `'gps_arrive'` or `'gps_depart'`.
  final String eventType;

  /// `'automatic'`, `'manual'`, or `'job_complete'` — mirrors the
  /// `metadata.source` value the direct-insert path already stamps on
  /// every visit-tracking `field_events` row.
  final String source;

  /// WHEN the event actually happened — captured once, before the first
  /// write attempt, and reused unchanged across every retry AND this
  /// queued row, so a technician's real departure/arrival time is never
  /// shifted to whenever the write eventually succeeds.
  final DateTime eventTs;

  final DateTime createdAt;
  final PendingVisitEventStatus status;

  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'job_id': jobId,
      'technician_id': technicianId,
      'event_type': eventType,
      'source': source,
      'event_ts': eventTs.toUtc().toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'status': status.name,
    };
  }

  factory PendingVisitEvent.fromMap(Map<String, Object?> map) {
    return PendingVisitEvent(
      id: map['id'] as int?,
      jobId: map['job_id'] as String,
      technicianId: map['technician_id'] as String,
      eventType: map['event_type'] as String,
      source: map['source'] as String,
      eventTs: DateTime.parse(map['event_ts'] as String),
      createdAt: DateTime.parse(map['created_at'] as String),
      status: PendingVisitEventStatus.fromName(map['status'] as String),
    );
  }
}
