import 'change_order.dart';
import 'invoice_adjustment.dart';
import 'job_estimate.dart';

/// Read-only snapshot of what a job's invoice would look like — the
/// `/invoices/preview` Lambda's response (see
/// `backend/functions/generate-invoice`, despite its folder name — this
/// route never saves anything; only `/invoices/generate-pdf` does, via
/// `generateInvoicePdf` in `invoice_provider.dart`). [estimate] and every
/// change-order list below are raw `job_estimates`/`change_orders` rows, so
/// this reuses [JobEstimate.fromJson]/[ChangeOrder.fromJson] rather than a
/// separate parse.
///
/// [approvedChangeOrders] is what actually counts toward [grossTotal] — the
/// other three lists ([pendingChangeOrders], [voidedChangeOrders],
/// [declinedChangeOrders]) are shown on `InvoiceReviewScreen` purely so a
/// technician can see the full picture (and why something was excluded)
/// before sending, same "show everything, exclude only what's decided"
/// principle as `ChangeOrdersScreen`.
class InvoicePreview {
  const InvoicePreview({
    required this.estimate,
    required this.approvedChangeOrders,
    required this.pendingChangeOrders,
    required this.voidedChangeOrders,
    required this.declinedChangeOrders,
    this.adjustments = const [],
    required this.estimateApproved,
    required this.grossTotal,
    required this.feeRate,
    required this.feeAmount,
    required this.netToContractor,
    this.billableHours,
    this.technicianHourlyRate,
    this.referenceLaborValue,
  });

  final JobEstimate estimate;
  final List<ChangeOrder> approvedChangeOrders;
  final List<ChangeOrder> pendingChangeOrders;
  final List<ChangeOrder> voidedChangeOrders;
  final List<ChangeOrder> declinedChangeOrders;

  /// Manual invoice lines (fees/discounts) — already included in
  /// [grossTotal] by `/invoices/preview`. Empty from a backend that
  /// predates them.
  final List<InvoiceAdjustment> adjustments;

  double get adjustmentsTotal => adjustments.fold<double>(0, (sum, a) => sum + a.amount);

  /// Mirrors `estimate.status == 'approved'` — kept as its own field (rather
  /// than re-derived on the client) since the backend already computed it
  /// once for the same purpose (gating the "hasn't been approved yet"
  /// warning banner).
  final bool estimateApproved;

  /// Estimate total + approved (non-voided) change orders — the customer-
  /// facing total. Never includes pending/declined/voided change orders.
  final double grossTotal;

  /// The contractor's platform fee rate (e.g. `0.02` for 2%) — internal
  /// only, never shown to the customer (see the invoice PDF, which omits it
  /// entirely).
  final double feeRate;
  final double feeAmount;
  final double netToContractor;

  /// Total on-site labor time for the job, if it's been completed — shown
  /// on `InvoiceReviewScreen` as reference only, never part of any total
  /// ([grossTotal]/[feeAmount]/[netToContractor] never factor this in).
  final double? billableHours;

  /// The technician's own hourly rate, if one is on file (`technicians.
  /// hourly_rate`) — `null` when it isn't, in which case [referenceLaborValue]
  /// is also `null` (the backend only computes it when both inputs exist).
  /// Purely informational, same as [billableHours] — never affects any total.
  final double? technicianHourlyRate;

  /// [billableHours] × [technicianHourlyRate], already computed server-side
  /// — a reference figure only ("what this time would be worth"), not a
  /// line item and never added into [grossTotal]/[feeAmount]/
  /// [netToContractor]. `null` whenever either input is `null`.
  final double? referenceLaborValue;

  factory InvoicePreview.fromJson(Map<String, dynamic> json) {
    List<ChangeOrder> parseChangeOrders(String key) {
      final raw = (json[key] as List<dynamic>?) ?? const [];
      return raw.map((item) => ChangeOrder.fromJson(item as Map<String, dynamic>)).toList();
    }

    return InvoicePreview(
      estimate: JobEstimate.fromJson(json['estimate'] as Map<String, dynamic>),
      approvedChangeOrders: parseChangeOrders('approvedChangeOrders'),
      pendingChangeOrders: parseChangeOrders('pendingChangeOrders'),
      voidedChangeOrders: parseChangeOrders('voidedChangeOrders'),
      declinedChangeOrders: parseChangeOrders('declinedChangeOrders'),
      adjustments: ((json['adjustments'] as List<dynamic>?) ?? const [])
          .map((item) => InvoiceAdjustment.fromJson(item as Map<String, dynamic>))
          .toList(),
      estimateApproved: json['estimateApproved'] as bool? ?? false,
      grossTotal: (json['grossTotal'] as num?)?.toDouble() ?? 0,
      feeRate: (json['feeRate'] as num?)?.toDouble() ?? 0,
      feeAmount: (json['feeAmount'] as num?)?.toDouble() ?? 0,
      netToContractor: (json['netToContractor'] as num?)?.toDouble() ?? 0,
      billableHours: (json['billableHours'] as num?)?.toDouble(),
      technicianHourlyRate: (json['technicianHourlyRate'] as num?)?.toDouble(),
      referenceLaborValue: (json['referenceLaborValue'] as num?)?.toDouble(),
    );
  }
}
