import 'package:flutter/material.dart';

/// A single row from the `job_history_feed` Supabase view — a unified,
/// chronological activity feed for a job spanning GPS arrivals/departures,
/// photos, dictations (prepare-estimate/site-condition), and estimate
/// events. [s3ObjectKey] is only populated for `photo` rows.
class JobHistoryEntry {
  const JobHistoryEntry({
    required this.type,
    required this.description,
    required this.timestamp,
    this.s3ObjectKey,
    this.voidedAt,
    this.voidReason,
  });

  factory JobHistoryEntry.fromJson(Map<String, dynamic> json) {
    final rawVoidedAt = json['voided_at'] as String?;
    return JobHistoryEntry(
      type: json['type'] as String? ?? '',
      description: json['description'] as String? ?? '',
      timestamp: DateTime.parse(json['ts'] as String).toLocal(),
      s3ObjectKey: json['s3_object_key'] as String?,
      voidedAt: rawVoidedAt != null ? DateTime.tryParse(rawVoidedAt) : null,
      voidReason: json['void_reason'] as String?,
    );
  }

  final String type;
  final String description;
  final DateTime timestamp;
  final String? s3ObjectKey;

  // `job_history_feed` is a Supabase view whose SQL isn't checked into this
  // repo, so it's unconfirmed whether it currently exposes `voided_at`/
  // `void_reason` for change-order rows at all. These are parsed
  // defensively (null when absent) so this model never breaks against the
  // live view either way; see JobHistoryFeedTimeline for how a non-null
  // [voidedAt] renders.
  final DateTime? voidedAt;
  final String? voidReason;

  bool get isPhoto => s3ObjectKey != null;

  bool get isVoided => voidedAt != null;

  /// Icon for [type]. Falls back to a generic icon for any event type not
  /// explicitly mapped yet (e.g. change orders, invoices, once those are
  /// built) so a future addition to `job_history_feed` doesn't break this
  /// UI before its icon is added here.
  IconData get icon {
    switch (type) {
      case 'gps_arrive':
      case 'gps_depart':
        return Icons.location_on_rounded;
      case 'photo':
        return Icons.photo_camera_rounded;
      case 'prepare_estimate':
      case 'site_condition':
        return Icons.description_rounded;
      case 'estimate_sent':
      case 'estimate_created':
        return Icons.attach_money_rounded;
      default:
        return Icons.event_note_rounded;
    }
  }
}
