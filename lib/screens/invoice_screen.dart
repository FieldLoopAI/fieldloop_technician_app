import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/mock_line_item.dart';
import '../providers/estimate_invoice_providers.dart';
import '../providers/jobs_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/primary_button.dart';

class InvoiceScreen extends ConsumerStatefulWidget {
  const InvoiceScreen({super.key, required this.jobId});

  final String jobId;

  @override
  ConsumerState<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends ConsumerState<InvoiceScreen> {
  bool _generating = false;

  Future<void> _generateAndSend() async {
    setState(() => _generating = true);
    await Future.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    ref.read(invoiceStatusProvider(widget.jobId).notifier).state = InvoiceStatus.pending;
    setState(() => _generating = false);
  }

  void _simulatePayment() {
    ref.read(invoiceStatusProvider(widget.jobId).notifier).state = InvoiceStatus.paid;
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(jobByIdProvider(widget.jobId));
    // MOCK DATA - replace with Supabase query (line_items table, filtered by job_id)
    final estimateItems = ref.watch(estimateLineItemsProvider(widget.jobId));
    final changeOrders = ref.watch(changeOrdersProvider(widget.jobId));
    final estimateStatus = ref.watch(estimateStatusProvider(widget.jobId));
    final invoiceStatus = ref.watch(invoiceStatusProvider(widget.jobId));

    final total =
        estimateItems.fold<double>(0, (sum, item) => sum + item.amount) +
        changeOrders.fold<double>(0, (sum, item) => sum + item.amount);

    final canGenerate = estimateStatus == EstimateStatus.signed && invoiceStatus == InvoiceStatus.notYetInvoiced;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(job != null ? 'Invoice · ${job.jobIdPublic}' : 'Invoice'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isTablet = constraints.maxWidth > 600;
            final horizontalPadding = isTablet ? constraints.maxWidth * 0.16 : 20.0;

            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(horizontalPadding, 20, horizontalPadding, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Final Invoice',
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textDark),
                        ),
                      ),
                      _PaymentStatusBadge(status: invoiceStatus),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 16, offset: const Offset(0, 6)),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Estimate',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.neutralGrey, letterSpacing: 0.3),
                        ),
                        const SizedBox(height: 6),
                        if (estimateItems.isEmpty)
                          const Text('No line items', style: TextStyle(color: AppColors.neutralGrey))
                        else
                          for (final item in estimateItems) _LineItemRow(item: item),
                        if (changeOrders.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          const Text(
                            'Change Orders',
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.neutralGrey, letterSpacing: 0.3),
                          ),
                          const SizedBox(height: 6),
                          for (final item in changeOrders) _LineItemRow(item: item),
                        ],
                        const Divider(height: 28),
                        Row(
                          children: [
                            const Text(
                              'Total Due',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textDark),
                            ),
                            const Spacer(),
                            Text(
                              '\$${total.toStringAsFixed(2)}',
                              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.primaryGreenDark),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  _buildAction(invoiceStatus, canGenerate),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildAction(InvoiceStatus status, bool canGenerate) {
    switch (status) {
      case InvoiceStatus.notYetInvoiced:
        final button = PrimaryButton(
          label: 'Generate & Send Invoice',
          icon: Icons.receipt_long_rounded,
          isLoading: _generating,
          onPressed: canGenerate ? _generateAndSend : null,
        );
        if (canGenerate) return button;
        return Tooltip(message: 'Sign the estimate before invoicing', child: button);
      case InvoiceStatus.pending:
        return Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(color: AppColors.amber.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
              alignment: Alignment.center,
              child: const Text(
                'Invoice sent — payment pending',
                style: TextStyle(color: AppColors.amber, fontWeight: FontWeight.w700, fontSize: 14),
              ),
            ),
            const SizedBox(height: 10),
            TextButton(onPressed: _simulatePayment, child: const Text('Simulate payment received (demo)')),
          ],
        );
      case InvoiceStatus.paid:
        return Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(color: AppColors.primaryGreen.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
              alignment: Alignment.center,
              child: const Text(
                'Paid ✓',
                style: TextStyle(color: AppColors.primaryGreenDark, fontWeight: FontWeight.w700, fontSize: 15),
              ),
            )
            .animate()
            .fadeIn(duration: 300.ms)
            .scale(begin: const Offset(0.96, 0.96), end: const Offset(1, 1), duration: 300.ms);
    }
  }
}

class _PaymentStatusBadge extends StatelessWidget {
  const _PaymentStatusBadge({required this.status});

  final InvoiceStatus status;

  @override
  Widget build(BuildContext context) {
    late final Color fg;
    late final Color bg;
    late final String label;
    switch (status) {
      case InvoiceStatus.notYetInvoiced:
        fg = AppColors.neutralGrey;
        bg = const Color(0xFFF3F4F6);
        label = 'Not Yet Invoiced';
      case InvoiceStatus.pending:
        fg = AppColors.amber;
        bg = const Color(0xFFFEF3C7);
        label = 'Pending';
      case InvoiceStatus.paid:
        fg = AppColors.primaryGreenDark;
        bg = const Color(0xFFE3F5E9);
        label = 'Paid';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

class _LineItemRow extends StatelessWidget {
  const _LineItemRow({required this.item});

  final MockLineItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(item.description, style: const TextStyle(fontSize: 13.5, color: AppColors.textDark)),
          ),
          Text(
            '\$${item.amount.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.textDark),
          ),
        ],
      ),
    );
  }
}
