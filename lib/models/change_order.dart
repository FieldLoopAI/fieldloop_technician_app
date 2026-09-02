/// A single `change_orders` row — additional work found on-site, dictated
/// via the `change_order` voice command (see `handleChangeOrderCommand` in
/// `job_voice_commands.dart`) and saved through the `/change-orders/create`
/// Lambda (see `backend/functions/create-change-order`), which also texts
/// the customer an approval request immediately on creation if a phone
/// number is on file.
///
/// Unlike [JobEstimate]'s `line_items` (a JSON array living inside ONE
/// `job_estimates` row), a change order is NOT a line item within a bigger
/// row — each change order IS its own row, one `description` + one
/// `additional_amount`, and a job can accumulate many of them over time.
///
/// [status] starts `'pending'` (awaiting the customer's SMS approval reply)
/// and becomes `'approved'` once they approve it — see
/// `ChangeOrdersScreen` for how pending vs. approved changes what counts
/// toward the job's running total.
class ChangeOrder {
  const ChangeOrder({
    required this.id,
    required this.jobId,
    required this.description,
    required this.additionalAmount,
    required this.status,
    this.createdAt,
    this.approvedAt,
    this.voidedAt,
    this.voidReason,
  });

  final String id;
  final String jobId;
  final String description;
  final double additionalAmount;
  final String status;
  final DateTime? createdAt;
  final DateTime? approvedAt;
  final DateTime? voidedAt;
  final String? voidReason;

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isDeclined => status == 'declined';

  /// True once a technician has voided this change order (see
  /// `JobChangeOrdersController.voidChangeOrder`). Only ever meaningful for
  /// an already-[isApproved] row — voiding a `'pending'` or `'declined'`
  /// one is never offered in the UI and is not a state the RLS policy
  /// permits anyway.
  bool get isVoided => voidedAt != null;

  factory ChangeOrder.fromJson(Map<String, dynamic> json) {
    final rawCreatedAt = json['created_at'] as String?;
    final rawApprovedAt = json['approved_at'] as String?;
    final rawVoidedAt = json['voided_at'] as String?;
    return ChangeOrder(
      id: json['id'].toString(),
      jobId: json['job_id'].toString(),
      description: (json['description'] as String?) ?? '',
      additionalAmount: (json['additional_amount'] as num?)?.toDouble() ?? 0,
      status: (json['status'] as String?) ?? 'pending',
      createdAt: rawCreatedAt != null ? DateTime.tryParse(rawCreatedAt) : null,
      approvedAt: rawApprovedAt != null ? DateTime.tryParse(rawApprovedAt) : null,
      voidedAt: rawVoidedAt != null ? DateTime.tryParse(rawVoidedAt) : null,
      voidReason: json['void_reason'] as String?,
    );
  }

  ChangeOrder copyWith({
    String? description,
    double? additionalAmount,
    String? status,
    DateTime? voidedAt,
    String? voidReason,
  }) {
    return ChangeOrder(
      id: id,
      jobId: jobId,
      description: description ?? this.description,
      additionalAmount: additionalAmount ?? this.additionalAmount,
      status: status ?? this.status,
      createdAt: createdAt,
      approvedAt: approvedAt,
      voidedAt: voidedAt ?? this.voidedAt,
      voidReason: voidReason ?? this.voidReason,
    );
  }
}
