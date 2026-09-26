/// A manual invoice line item (a fee or a discount) added on the Invoice
/// Review screen — an `invoice_adjustments` row (see
/// `supabase/migrations/20260924000000_invoice_adjustments.sql`).
/// `/invoices/preview` and `/invoices/generate-pdf` add these on top of the
/// estimate and approved change orders; they never modify either.
///
/// [amount] is signed: positive for a fee/charge, negative for a discount.
class InvoiceAdjustment {
  const InvoiceAdjustment({required this.id, required this.jobId, required this.description, required this.amount});

  final String id;
  final String jobId;
  final String description;
  final double amount;

  bool get isDiscount => amount < 0;

  factory InvoiceAdjustment.fromJson(Map<String, dynamic> json) {
    return InvoiceAdjustment(
      id: json['id'].toString(),
      jobId: json['job_id'].toString(),
      description: (json['description'] as String?) ?? '',
      amount: (json['amount'] as num?)?.toDouble() ?? 0,
    );
  }
}
