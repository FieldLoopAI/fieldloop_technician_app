import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/mock_line_item.dart';
import '../providers/estimate_invoice_providers.dart';
import '../providers/jobs_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/primary_button.dart';

/// A single itemized estimate — deliberately one proposal, not a
/// Good/Better/Best comparison.
class EstimateScreen extends ConsumerStatefulWidget {
  const EstimateScreen({super.key, required this.jobId});

  final String jobId;

  @override
  ConsumerState<EstimateScreen> createState() => _EstimateScreenState();
}

class _EstimateScreenState extends ConsumerState<EstimateScreen> {
  bool _sending = false;
  bool _showConfirmation = false;

  Future<void> _sendToCustomer() async {
    setState(() => _sending = true);
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    ref.read(estimateStatusProvider(widget.jobId).notifier).state = EstimateStatus.sent;
    setState(() {
      _sending = false;
      _showConfirmation = true;
    });
    await Future.delayed(const Duration(milliseconds: 1600));
    if (mounted) setState(() => _showConfirmation = false);
  }

  void _simulateSignature() {
    ref.read(estimateStatusProvider(widget.jobId).notifier).state = EstimateStatus.signed;
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(jobByIdProvider(widget.jobId));
    // MOCK DATA - replace with Supabase query (line_items table, type='estimate')
    final items = ref.watch(estimateLineItemsProvider(widget.jobId));
    final status = ref.watch(estimateStatusProvider(widget.jobId));
    final total = items.fold<double>(0, (sum, item) => sum + item.amount);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(job != null ? 'Estimate · ${job.jobIdPublic}' : 'Estimate'),
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
                  const Text(
                    'Itemized Estimate',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textDark),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'One proposal for this job — no pricing tiers.',
                    style: TextStyle(fontSize: 13, color: AppColors.neutralGrey),
                  ),
                  const SizedBox(height: 20),
                  _EstimateStatusBanner(status: status),
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
                        if (items.isEmpty)
                          const Text('No line items yet', style: TextStyle(color: AppColors.neutralGrey))
                        else
                          for (final item in items) _LineItemRow(item: item),
                        const Divider(height: 28),
                        Row(
                          children: [
                            const Text(
                              'Total',
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
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      _buildAction(status),
                      if (_showConfirmation)
                        const Icon(Icons.check_circle_rounded, color: AppColors.primaryGreen, size: 52)
                            .animate()
                            .scale(begin: const Offset(0.5, 0.5), end: const Offset(1, 1), duration: 300.ms, curve: Curves.easeOutBack)
                            .then(delay: 700.ms)
                            .fadeOut(duration: 300.ms),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildAction(EstimateStatus status) {
    switch (status) {
      case EstimateStatus.draft:
        return PrimaryButton(
          label: 'Send to Customer',
          icon: Icons.send_rounded,
          isLoading: _sending,
          onPressed: _sendToCustomer,
        );
      case EstimateStatus.sent:
        return Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: AppColors.neutralGreyLight.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: const Text(
                'Sent — awaiting customer signature',
                style: TextStyle(color: AppColors.neutralGrey, fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _simulateSignature,
              child: const Text('Simulate customer signing (demo)'),
            ),
          ],
        );
      case EstimateStatus.signed:
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: AppColors.primaryGreen.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: const Text(
            'Signed ✓',
            style: TextStyle(color: AppColors.primaryGreenDark, fontWeight: FontWeight.w700, fontSize: 15),
          ),
        );
    }
  }
}

class _EstimateStatusBanner extends StatelessWidget {
  const _EstimateStatusBanner({required this.status});

  final EstimateStatus status;

  @override
  Widget build(BuildContext context) {
    late final Color color;
    late final String label;
    late final IconData icon;
    switch (status) {
      case EstimateStatus.draft:
        color = AppColors.neutralGrey;
        label = 'Draft — not yet sent';
        icon = Icons.edit_note_rounded;
      case EstimateStatus.sent:
        color = AppColors.amber;
        label = 'Sent — awaiting customer signature';
        icon = Icons.mark_email_read_outlined;
      case EstimateStatus.signed:
        color = AppColors.primaryGreenDark;
        label = 'Signed';
        icon = Icons.verified_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
        ],
      ),
    );
  }
}

class _LineItemRow extends StatelessWidget {
  const _LineItemRow({required this.item});

  final MockLineItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(item.description, style: const TextStyle(fontSize: 14, color: AppColors.textDark)),
          ),
          Text(
            '\$${item.amount.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textDark),
          ),
        ],
      ),
    );
  }
}
