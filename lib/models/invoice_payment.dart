/// Build 185 — an invoice's payment lifecycle (`invoices.payment_status`),
/// separate from the old `invoices.status` ('draft'/'sent'). Only the
/// stripe-webhook Lambda ever sets [paid].
enum InvoicePaymentStatus { unpaid, pending, paid }

/// Raw `payment_status` -> [InvoicePaymentStatus]. Anything missing or
/// unknown reads as [InvoicePaymentStatus.unpaid] — never as paid.
InvoicePaymentStatus parseInvoicePaymentStatus(Object? raw) => switch (raw) {
  'pending' => InvoicePaymentStatus.pending,
  'paid' => InvoicePaymentStatus.paid,
  _ => InvoicePaymentStatus.unpaid,
};

/// Job Detail / Invoice Review label.
String invoicePaymentStatusLabel(InvoicePaymentStatus status) => switch (status) {
  InvoicePaymentStatus.unpaid => 'Unpaid',
  InvoicePaymentStatus.pending => 'Pending',
  InvoicePaymentStatus.paid => 'Paid',
};

/// Once payment is initiated (pending) or done (paid) the invoice is frozen:
/// no adjustments, no regenerating.
bool isInvoicePaymentFrozen(InvoicePaymentStatus? status) =>
    status == InvoicePaymentStatus.pending || status == InvoicePaymentStatus.paid;

/// The job's latest invoice as `/invoices/payment-status` returns it.
class LatestInvoicePayment {
  const LatestInvoicePayment({
    required this.id,
    required this.invoiceNumber,
    required this.status,
    required this.paidAt,
    required this.total,
  });

  final String id;
  final String? invoiceNumber;
  final InvoicePaymentStatus status;
  final DateTime? paidAt;
  final double? total;

  /// `{"invoice": {...} | null}` -> the invoice, or null when the job has none.
  static LatestInvoicePayment? fromResponse(Map<String, dynamic> json) {
    final invoice = json['invoice'];
    if (invoice is! Map<String, dynamic>) return null;
    final rawPaidAt = invoice['paid_at'] as String?;
    final rawTotal = invoice['total'];
    return LatestInvoicePayment(
      id: invoice['id'].toString(),
      invoiceNumber: invoice['invoice_number'] as String?,
      status: parseInvoicePaymentStatus(invoice['payment_status']),
      paidAt: rawPaidAt == null ? null : DateTime.tryParse(rawPaidAt),
      total: rawTotal == null ? null : double.tryParse(rawTotal.toString()),
    );
  }
}

/// `/invoices/checkout`'s reply.
class CheckoutSession {
  const CheckoutSession({required this.url, required this.sessionId, required this.amountCents, required this.feeCents});

  final String url;
  final String sessionId;
  final int? amountCents;
  final int? feeCents;
}

// ---------------------------------------------------------------------------
// Invoice Review visibility rules (pure, so test/b185 can pin them).
// ---------------------------------------------------------------------------

/// "Collect Payment" shows once this screen has an invoice id, until paid.
bool showCollectPaymentButton({
  required bool enabled,
  required String? invoiceId,
  required InvoicePaymentStatus? status,
}) =>
    enabled && invoiceId != null && status != InvoicePaymentStatus.paid;

/// The existing adjustments lock (sent / generating / updating), plus a
/// frozen payment when the flag is on.
bool adjustmentsLocked({
  required bool enabled,
  required bool sent,
  required bool generating,
  required bool updatingAdjustments,
  required InvoicePaymentStatus? status,
}) =>
    sent || generating || updatingAdjustments || (enabled && isInvoicePaymentFrozen(status));

/// The "Internal only" fee/net box is hidden while the homeowner may be
/// holding the tablet (pending or paid).
bool showInternalFeeSection({required bool enabled, required InvoicePaymentStatus? status}) =>
    !(enabled && isInvoicePaymentFrozen(status));

/// "Generate & Send Invoice" can't run once payment started on the latest
/// invoice (the backend refuses it too).
bool showGenerateButton({required bool enabled, required InvoicePaymentStatus? status}) =>
    !(enabled && isInvoicePaymentFrozen(status));
