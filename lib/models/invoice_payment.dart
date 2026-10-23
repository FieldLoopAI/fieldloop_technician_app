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
    this.processingFeeCents,
    this.chargeTotalCents,
  });

  final String id;
  final String? invoiceNumber;
  final InvoicePaymentStatus status;
  final DateTime? paidAt;
  final double? total;

  /// Card-fee surcharge (server STRIPE_PASS_FEE): only in the reply when it
  /// is on, and only set on an invoice whose Checkout charged it.
  final int? processingFeeCents;
  final int? chargeTotalCents;

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
      processingFeeCents: (invoice['processing_fee_cents'] as num?)?.toInt(),
      chargeTotalCents: (invoice['charge_total_cents'] as num?)?.toInt(),
    );
  }
}

/// `/invoices/checkout`'s reply.
class CheckoutSession {
  const CheckoutSession({
    required this.url,
    required this.sessionId,
    required this.amountCents,
    required this.feeCents,
    this.processingFeeCents,
    this.chargeTotalCents,
  });

  final String url;
  final String sessionId;
  final int? amountCents;
  final int? feeCents;

  /// See [LatestInvoicePayment.processingFeeCents].
  final int? processingFeeCents;
  final int? chargeTotalCents;
}

/// The card processing fee the customer pays on top, and the total they
/// pay — only when the server reported a fee above zero; otherwise null and
/// the Payment panel shows nothing extra.
({int processingFeeCents, int chargeTotalCents})? cardSurcharge({
  required int? processingFeeCents,
  required int? chargeTotalCents,
}) {
  if (processingFeeCents == null || processingFeeCents <= 0) return null;
  if (chargeTotalCents == null || chargeTotalCents <= 0) return null;
  return (processingFeeCents: processingFeeCents, chargeTotalCents: chargeTotalCents);
}

/// Integer cents -> "$1234.56", the Invoice Review money format.
String formatCents(int cents) => '\$${(cents ~/ 100)}.${(cents % 100).toString().padLeft(2, '0')}';

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

/// Where Invoice Review's read of `/invoices/payment-status` stands. Until
/// it has [loaded], the screen can't know whether the invoice is frozen.
enum PaymentStatusLoad { loading, loaded, failed }

/// The existing adjustments lock (sent / generating / updating), plus, when
/// the flag is on, a frozen payment or a payment status that hasn't loaded
/// (still loading, or the read failed). No invoice yet loads as unpaid.
bool adjustmentsLocked({
  required bool enabled,
  required bool sent,
  required bool generating,
  required bool updatingAdjustments,
  required InvoicePaymentStatus? status,
  PaymentStatusLoad load = PaymentStatusLoad.loaded,
}) =>
    sent ||
    generating ||
    updatingAdjustments ||
    (enabled && (load != PaymentStatusLoad.loaded || isInvoicePaymentFrozen(status)));

/// "Fix something first" (pop back to Job Detail to edit) is hidden once the
/// invoice is frozen — there is nothing left to fix before sending.
bool showFixSomethingFirst({required bool enabled, required InvoicePaymentStatus? status}) =>
    !(enabled && isInvoicePaymentFrozen(status));

/// The "Internal only" fee/net box is hidden while the homeowner may be
/// holding the tablet (pending or paid).
bool showInternalFeeSection({required bool enabled, required InvoicePaymentStatus? status}) =>
    !(enabled && isInvoicePaymentFrozen(status));

/// The "Platform Fee (x%)" rate as shown: the real rate to up to 2 decimals
/// with trailing zeros trimmed (0.0195 -> "1.95", 0.02 -> "2"); flag off
/// keeps the old 1-decimal text.
String platformFeeRatePercent({required bool enabled, required double feeRate}) {
  final percent = feeRate * 100;
  if (!enabled) return percent.toStringAsFixed(1);
  return percent.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
}

/// "Generate & Send Invoice" can't run once payment started on the latest
/// invoice (the backend refuses it too).
bool showGenerateButton({required bool enabled, required InvoicePaymentStatus? status}) =>
    !(enabled && isInvoicePaymentFrozen(status));
