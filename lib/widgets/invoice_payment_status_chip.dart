import 'package:flutter/material.dart';

import '../models/invoice_payment.dart';
import '../theme/design_tokens.dart';

/// Build 185 — Unpaid / Pending / Paid as a [StatusChip], same tones as the
/// mock badge it replaces on Job Detail (neutral / amber / green).
class InvoicePaymentStatusChip extends StatelessWidget {
  const InvoicePaymentStatusChip({super.key, required this.status});

  final InvoicePaymentStatus status;

  @override
  Widget build(BuildContext context) => StatusChip(
    tone: switch (status) {
      InvoicePaymentStatus.unpaid => StatusTone.neutral,
      InvoicePaymentStatus.pending => StatusTone.pending,
      InvoicePaymentStatus.paid => StatusTone.approved,
    },
    label: invoicePaymentStatusLabel(status),
    icon: status == InvoicePaymentStatus.unpaid ? Icons.receipt_long_rounded : null,
  );
}
