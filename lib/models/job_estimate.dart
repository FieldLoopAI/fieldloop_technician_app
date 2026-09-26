/// A single structured line item within a [JobEstimate] — as extracted by
/// Groq from the technician's verbatim dictation (see
/// `backend/functions/parse-estimate-dictation`), or typed in on the manual
/// estimate editor.
///
/// [amount] is the line total and the ONLY value anything downstream reads
/// (change-order running totals, `/invoices/preview`, the invoice PDF).
/// [quantity]/[unitPrice] are optional extras the manual editor records so a
/// line can be re-edited as qty × price; dictated items leave them null.
class EstimateLineItem {
  const EstimateLineItem({required this.description, required this.amount, this.quantity, this.unitPrice});

  final String description;
  final double amount;
  final double? quantity;
  final double? unitPrice;

  factory EstimateLineItem.fromJson(Map<String, dynamic> json) {
    return EstimateLineItem(
      description: json['description'] as String? ?? '',
      amount: (json['amount'] as num?)?.toDouble() ?? 0,
      quantity: (json['quantity'] as num?)?.toDouble(),
      unitPrice: (json['unit_price'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'description': description,
    'amount': amount,
    if (quantity != null) 'quantity': quantity,
    if (unitPrice != null) 'unit_price': unitPrice,
  };
}

/// A parsed, structured estimate for a job — the `job_estimates` row
/// produced by the `/estimates/parse` Lambda from a technician's verbatim
/// `prepare_estimate` dictation (see `JobEstimateController.parseDictation`
/// in `job_estimate_provider.dart`). [totalAmount] is Groq's own computed
/// total, not re-derived from [lineItems] client-side — it's the backend's
/// single source of truth for what the technician's estimate adds up to.
///
/// [status] is the raw `job_estimates.status` value ('draft' while the
/// technician can still review/edit it, 'sent' once
/// [JobEstimateController.sendToCustomer] has texted it to the customer —
/// see [isDraft]). Kept as the raw string rather than an enum since this
/// screen only ever needs to distinguish "still editable" from "already
/// sent" — the separate (and older, UI-only) `EstimateStatus` enum in
/// `estimate_invoice_providers.dart` covers the not-yet-backed
/// sent/signed distinction for the rest of the app.
class JobEstimate {
  const JobEstimate({
    required this.id,
    required this.jobId,
    required this.sourceDictationId,
    required this.lineItems,
    required this.totalAmount,
    required this.status,
    this.createdAt,
    this.voidedAt,
    this.voidReason,
  });

  final String id;
  final String jobId;
  final String? sourceDictationId;
  final List<EstimateLineItem> lineItems;
  final double totalAmount;
  final String status;
  final DateTime? createdAt;
  final DateTime? voidedAt;
  final String? voidReason;

  bool get isDraft => status == 'draft';
  bool get isSent => status == 'sent';
  bool get isApproved => status == 'approved';
  bool get isDeclined => status == 'declined';

  /// True once a technician has voided this estimate (see
  /// `JobEstimateController.voidEstimate`) — same concept, same trigger
  /// condition (only ever offered for an already-[isApproved] row), as
  /// `ChangeOrder.isVoided`.
  bool get isVoided => voidedAt != null;

  factory JobEstimate.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['line_items'] as List<dynamic>?) ?? const [];
    final rawCreatedAt = json['created_at'] as String?;
    final rawVoidedAt = json['voided_at'] as String?;
    return JobEstimate(
      id: json['id'].toString(),
      jobId: json['job_id'].toString(),
      sourceDictationId: json['source_dictation_id']?.toString(),
      lineItems: rawItems
          .map((raw) => EstimateLineItem.fromJson(raw as Map<String, dynamic>))
          .toList(),
      totalAmount: (json['total_amount'] as num?)?.toDouble() ?? 0,
      status: (json['status'] as String?) ?? 'draft',
      createdAt: rawCreatedAt != null ? DateTime.tryParse(rawCreatedAt) : null,
      voidedAt: rawVoidedAt != null ? DateTime.tryParse(rawVoidedAt) : null,
      voidReason: json['void_reason'] as String?,
    );
  }

  JobEstimate copyWith({
    List<EstimateLineItem>? lineItems,
    double? totalAmount,
    String? status,
    DateTime? voidedAt,
    String? voidReason,
  }) {
    return JobEstimate(
      id: id,
      jobId: jobId,
      sourceDictationId: sourceDictationId,
      lineItems: lineItems ?? this.lineItems,
      totalAmount: totalAmount ?? this.totalAmount,
      status: status ?? this.status,
      createdAt: createdAt,
      voidedAt: voidedAt ?? this.voidedAt,
      voidReason: voidReason ?? this.voidReason,
    );
  }
}
