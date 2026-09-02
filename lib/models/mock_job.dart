import 'package:flutter/foundation.dart';

/// Status of a job, mirroring the eventual `jobs.status` column.
enum JobStatus { scheduled, enRoute, onSite, complete, invoiced, paid, closed }

extension JobStatusX on JobStatus {
  String get label {
    switch (this) {
      case JobStatus.scheduled:
        return 'Scheduled';
      case JobStatus.enRoute:
        return 'En Route';
      case JobStatus.onSite:
        return 'On Site';
      case JobStatus.complete:
        return 'Complete';
      case JobStatus.invoiced:
        return 'Invoiced';
      case JobStatus.paid:
        return 'Paid';
      case JobStatus.closed:
        return 'Closed';
    }
  }

  /// Matches the snake_case values the real `jobs` table will use.
  String get wireValue {
    switch (this) {
      case JobStatus.scheduled:
        return 'scheduled';
      case JobStatus.enRoute:
        return 'en_route';
      case JobStatus.onSite:
        return 'on_site';
      case JobStatus.complete:
        return 'complete';
      case JobStatus.invoiced:
        return 'invoiced';
      case JobStatus.paid:
        return 'paid';
      case JobStatus.closed:
        return 'closed';
    }
  }

  /// Parses the snake_case `jobs.status` column value.
  static JobStatus fromWireValue(String value) {
    switch (value) {
      case 'scheduled':
        return JobStatus.scheduled;
      case 'en_route':
        return JobStatus.enRoute;
      case 'on_site':
        return JobStatus.onSite;
      case 'complete':
        return JobStatus.complete;
      case 'invoiced':
        return JobStatus.invoiced;
      case 'paid':
        return JobStatus.paid;
      case 'closed':
        return JobStatus.closed;
      default:
        throw ArgumentError('Unknown jobs.status value: $value');
    }
  }
}

/// A service job.
///
/// Fields mirror the eventual `jobs` Supabase table so the model can be
/// swapped for a real one without touching the UI.
class MockJob {
  const MockJob({
    required this.id,
    required this.jobIdPublic,
    required this.customerName,
    required this.serviceAddress,
    required this.description,
    required this.tradeCategory,
    required this.status,
    required this.scheduledStart,
    this.estimateTotal,
    this.totalEstimate,
    this.totalInvoiced,
    this.totalPaid,
    this.serviceLat,
    this.serviceLng,
    this.billableHours,
  });

  final String id;
  final String jobIdPublic;
  final String customerName;
  final String serviceAddress;
  final String description;
  final String tradeCategory;
  final JobStatus status;
  final DateTime scheduledStart;
  final double? estimateTotal;

  /// Job site coordinates, used for GPS geofenced arrival detection. `null`
  /// when the job has no coordinates on file — automatic detection is
  /// skipped in that case (the manual "I've Arrived" button still works).
  final double? serviceLat;
  final double? serviceLng;

  /// Total on-site labor time across every complete arrive-to-depart visit
  /// pair, computed and saved once the job is marked complete — see
  /// `JobCompleteActionController.markComplete` / `computeBillableHours`
  /// (`visit_provider.dart`). `null` until then.
  final double? billableHours;

  /// Running totals for the job's estimate/invoice/payment lifecycle.
  /// `null` means the job hasn't reached that stage yet — use
  /// [totalEstimateDisplay], [totalInvoicedDisplay], [totalPaidDisplay] for
  /// a ready-to-show fallback instead of formatting these directly.
  final double? totalEstimate;
  final double? totalInvoiced;
  final double? totalPaid;

  String get totalEstimateDisplay =>
      totalEstimate != null ? '\$${totalEstimate!.toStringAsFixed(2)}' : 'Not yet estimated';
  String get totalInvoicedDisplay =>
      totalInvoiced != null ? '\$${totalInvoiced!.toStringAsFixed(2)}' : 'Not yet invoiced';
  String get totalPaidDisplay =>
      totalPaid != null ? '\$${totalPaid!.toStringAsFixed(2)}' : 'Not yet paid';

  /// Builds a job from a `jobs` table row.
  ///
  /// Only `id` is trusted to always be present. `status` and
  /// `scheduled_start` are core to how a job is queried/displayed, so
  /// they're still parsed eagerly, but a null/malformed value falls back
  /// to a safe default instead of crashing (with a debugPrint so it's
  /// visible that a row came back with unexpected data). Every other
  /// column is read with a nullable cast and a display-friendly fallback.
  factory MockJob.fromMap(Map<String, dynamic> map) {
    final id = map['id'] as String;

    final statusRaw = map['status'] as String?;
    JobStatus status;
    if (statusRaw != null) {
      status = JobStatusX.fromWireValue(statusRaw);
    } else {
      debugPrint('MockJob.fromMap: job $id has a null status, defaulting to scheduled');
      status = JobStatus.scheduled;
    }

    final scheduledStartRaw = map['scheduled_start'] as String?;
    DateTime scheduledStart;
    if (scheduledStartRaw != null) {
      scheduledStart = DateTime.parse(scheduledStartRaw).toLocal();
    } else {
      debugPrint('MockJob.fromMap: job $id has a null scheduled_start, defaulting to now');
      scheduledStart = DateTime.now();
    }

    return MockJob(
      id: id,
      jobIdPublic: (map['job_id_public'] as String?) ?? 'Not provided',
      customerName: (map['customer_name'] as String?) ?? 'Not provided',
      serviceAddress: (map['service_address'] as String?) ?? 'Not provided',
      description: (map['description'] as String?) ?? '',
      tradeCategory: (map['trade_category'] as String?) ?? 'Not provided',
      status: status,
      scheduledStart: scheduledStart,
      estimateTotal: _parseNullableDouble(map['estimate_total'], id, 'estimate_total'),
      totalEstimate: _parseNullableDouble(map['total_estimate'], id, 'total_estimate'),
      totalInvoiced: _parseNullableDouble(map['total_invoiced'], id, 'total_invoiced'),
      totalPaid: _parseNullableDouble(map['total_paid'], id, 'total_paid'),
      serviceLat: _parseNullableDouble(map['service_lat'], id, 'service_lat'),
      serviceLng: _parseNullableDouble(map['service_lng'], id, 'service_lng'),
      billableHours: _parseNullableDouble(map['billable_hours'], id, 'billable_hours'),
    );
  }
}

/// Parses a nullable numeric column. Handles the common Postgrest quirk of
/// serializing Postgres `numeric`/`decimal` columns as JSON strings (e.g.
/// `"150.00"` instead of `150.00`) so money columns don't hit the same
/// "type X is not a subtype of Y" crash nullable text columns did.
double? _parseNullableDouble(dynamic value, String jobId, String columnName) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) {
    final parsed = double.tryParse(value);
    if (parsed != null) return parsed;
  }
  debugPrint(
    'MockJob.fromMap: job $jobId has an unparseable $columnName value ($value), treating as null',
  );
  return null;
}
