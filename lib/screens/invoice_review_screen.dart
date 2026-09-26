import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/change_order.dart';
import '../models/invoice_adjustment.dart';
import '../models/invoice_preview.dart';
import '../models/job_estimate.dart';
import '../models/mock_job.dart';
import '../providers/global_voice_service_provider.dart';
import '../providers/invoice_provider.dart';
import '../providers/job_voice_commands.dart';
import '../providers/jobs_provider.dart';
import '../providers/safe_ref_disposal.dart';
import '../providers/voice_command_registry_provider.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../theme/design_tokens.dart';
import '../widgets/app_components.dart';
import '../widgets/manual_entry_form.dart';
import '../widgets/primary_button.dart';
import 'voice_command_registrar_mixin.dart';

/// The final review step before an invoice is actually generated and texted
/// to the customer — reached from Job Detail's "FieldLoop, generate invoice"
/// voice command or its "Generate Invoice" tap fallback (see
/// `handleGenerateInvoiceCommand` in `job_voice_commands.dart`, the sole
/// entry point for both), or Job Detail's "View Full Invoice", which already
/// fetched [preview] via the read-only `/invoices/preview` Lambda before
/// navigating here. The one thing editable in place is the manual
/// Adjustments section (fees/discounts — see [InvoiceAdjustment]); adding or
/// removing one re-fetches the preview, since the server computes the
/// totals. Anything else that needs fixing (an estimate to approve, a change
/// order to re-send), "Fix something first" pops back to Job Detail for —
/// same "review here, edit elsewhere" split as `ChangeOrdersScreen`'s
/// "create a new change order" action.
///
/// Also a job-scoped screen for voice purposes (see [buildVoiceCommands]) —
/// same `VoiceCommandRegistrarMixin` pattern as Estimate/Change Orders —
/// even though it has no invoice-specific voice commands of its own; it
/// registers the same job-lifecycle set so voice keeps working here too.
class InvoiceReviewScreen extends ConsumerStatefulWidget {
  const InvoiceReviewScreen({super.key, required this.jobId, required this.preview});

  final String jobId;
  final InvoicePreview preview;

  @override
  ConsumerState<InvoiceReviewScreen> createState() => _InvoiceReviewScreenState();
}

class _InvoiceReviewScreenState extends ConsumerState<InvoiceReviewScreen>
    with SafeRefDisposal<InvoiceReviewScreen>, VoiceCommandRegistrarMixin<InvoiceReviewScreen> {
  bool _generating = false;
  String? _generatingStatus;
  String? _error;
  bool _sent = false;
  String? _sentMessage;

  /// Starts as the snapshot this screen was opened with; replaced by a fresh
  /// `/invoices/preview` fetch after a manual line is added or removed, since
  /// the server is what computes the totals (see [_refreshPreview]).
  late InvoicePreview _preview = widget.preview;
  bool _updatingAdjustments = false;
  String? _adjustmentError;

  /// "Generate & Send Invoice" needs at least one line to bill — from the
  /// estimate, an approved change order, or a manual invoice line.
  bool get _hasLineItems =>
      _preview.estimate.lineItems.isNotEmpty ||
      _preview.approvedChangeOrders.isNotEmpty ||
      _preview.adjustments.isNotEmpty;

  Future<void> _refreshPreview() async {
    final fresh = await fetchInvoicePreview(jobId: widget.jobId);
    if (mounted) setState(() => _preview = fresh);
  }

  Future<void> _addAdjustment() async {
    final added = await showModalBottomSheet<_NewAdjustment>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _AddAdjustmentSheet(currentTotal: _preview.grossTotal),
    );
    if (added == null || !mounted) return;
    await _runAdjustmentChange(
      () => addInvoiceAdjustment(jobId: widget.jobId, description: added.description, amount: added.amount),
    );
  }

  Future<void> _removeAdjustment(InvoiceAdjustment adjustment) async {
    await _runAdjustmentChange(() => deleteInvoiceAdjustment(adjustment.id));
  }

  Future<void> _runAdjustmentChange(Future<Object?> Function() change) async {
    setState(() {
      _updatingAdjustments = true;
      _adjustmentError = null;
    });
    try {
      await change();
      ref.invalidate(jobInvoiceAdjustmentsProvider(widget.jobId));
      await _refreshPreview();
    } catch (e) {
      if (mounted) setState(() => _adjustmentError = e is StateError ? e.message : e.toString());
    } finally {
      if (mounted) setState(() => _updatingAdjustments = false);
    }
  }

  @override
  List<VoiceCommand> buildVoiceCommands() => jobLifecycleVoiceCommands(ref, widget.jobId);

  /// Whether the extra confirmation dialog is required before generating —
  /// per spec, exactly when the estimate isn't approved OR at least one
  /// change order is still pending; otherwise "Generate & Send Invoice"
  /// proceeds straight to [_generateAndSend].
  bool get _needsExtraConfirmation =>
      !_preview.estimateApproved || _preview.pendingChangeOrders.isNotEmpty;

  Future<void> _onGeneratePressed() async {
    if (!_needsExtraConfirmation) {
      await _generateAndSend();
      return;
    }
    final confirmed = await _showConfirmDialog();
    if (confirmed) await _generateAndSend();
  }

  /// The "one extra confirmation dialog" the spec calls for — a plain
  /// `AlertDialog` is safe here (unlike `EstimateScreen`/`ChangeOrdersScreen`,
  /// which deliberately avoid dialogs — see their void-action doc comments):
  /// those screens' dialogs raced a live realtime subscription's own
  /// rebuilds during the dialog's pop/teardown. This screen holds a static
  /// [InvoicePreview] snapshot with no subscription of its own, so there's
  /// nothing for a dialog teardown to race.
  Future<bool> _showConfirmDialog() async {
    final preview = _preview;
    final reasons = <String>[
      if (!preview.estimateApproved) "the estimate hasn't been approved by the customer yet",
      if (preview.pendingChangeOrders.isNotEmpty)
        '${preview.pendingChangeOrders.length} change order'
            '${preview.pendingChangeOrders.length == 1 ? ' is' : 's are'} still pending approval',
    ];
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Send this invoice?'),
        content: Text('Heads up — ${reasons.join(' and ')}. Send the invoice anyway?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryGreen,
              foregroundColor: Colors.white,
            ),
            child: const Text('Send Anyway'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Generates + saves the invoice, then texts it to the customer — see
  /// [generateInvoicePdf]/[sendInvoiceSms]. Order matters, same reasoning as
  /// `JobEstimateController.sendToCustomer`: the invoice is only ever
  /// generated once (not idempotent), so this only runs after the
  /// technician has confirmed via [_onGeneratePressed].
  Future<void> _generateAndSend() async {
    setState(() {
      _generating = true;
      _generatingStatus = 'Generating PDF…';
      _error = null;
    });
    try {
      final generated = await generateInvoicePdf(jobId: widget.jobId);
      if (!mounted) return;
      setState(() => _generatingStatus = 'Sending to customer…');

      await sendInvoiceSms(invoiceId: generated.id, pdfUrl: generated.pdfUrl);
      if (!mounted) return;

      final customerName = ref.read(jobByIdProvider(widget.jobId))?.customerName.trim();
      final message = 'Invoice sent to ${(customerName == null || customerName.isEmpty) ? 'the customer' : customerName}';
      setState(() {
        _generating = false;
        _generatingStatus = null;
        _sent = true;
        _sentMessage = message;
      });
      unawaited(ref.read(globalVoiceServiceProvider.notifier).speak(message));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _generatingStatus = null;
        _error = e is StateError ? e.message : e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(jobByIdProvider(widget.jobId));
    final preview = _preview;
    final estimate = preview.estimate;
    final approvedTotal = preview.approvedChangeOrders.fold<double>(0, (sum, co) => sum + co.additionalAmount);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(job != null ? 'Invoice Review · ${job.jobIdPublic}' : 'Invoice Review'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = responsiveGutter(constraints.maxWidth, min: 20);

            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(horizontalPadding, 20, horizontalPadding, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (job != null) ...[_JobHeaderCard(job: job), const SizedBox(height: 16)],
                  _buildEstimateSection(estimate),
                  const SizedBox(height: 20),
                  _buildChangeOrdersSection(preview),
                  const SizedBox(height: 20),
                  _buildAdjustmentsSection(preview),
                  if (preview.billableHours != null) ...[
                    const SizedBox(height: 20),
                    _TimeOnSiteCard(preview: preview),
                  ],
                  const SizedBox(height: 20),
                  _FinancialSummaryCard(estimate: estimate, approvedTotal: approvedTotal, preview: preview),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.center,
                    // Pops back to Job Detail — both the Estimate and Change
                    // Orders tabs (and their full screens) live there; this
                    // screen deliberately offers no in-place editing of its
                    // own (see the class doc comment).
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Fix something first'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.statusRedText, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (_generating && _generatingStatus != null) ...[
                    Text(
                      _generatingStatus!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.neutralGrey, fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (_sent && _sentMessage != null)
                    _SentConfirmation(message: _sentMessage!)
                  else ...[
                    if (!_hasLineItems) ...[
                      const Text(
                        'Add at least one line item before generating the invoice.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.neutralGrey, fontSize: 12.5),
                      ),
                      const SizedBox(height: 10),
                    ],
                    PrimaryButton(
                      label: 'Generate & Send Invoice',
                      icon: Icons.receipt_long_rounded,
                      isLoading: _generating,
                      onPressed: (_hasLineItems && !_updatingAdjustments) ? _onGeneratePressed : null,
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildEstimateSection(JobEstimate estimate) {
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'Estimate',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.neutralGrey, letterSpacing: 0.3),
              ),
              const Spacer(),
              _EstimateStatusBadge(status: estimate.status),
            ],
          ),
          const SizedBox(height: 12),
          if (!estimate.isApproved) ...[
            const _WarningBanner(message: "This estimate hasn't been approved by the customer yet."),
            const SizedBox(height: 14),
          ],
          if (estimate.lineItems.isEmpty)
            const Text('No line items', style: TextStyle(color: AppColors.neutralGrey))
          else
            for (final item in estimate.lineItems) _LineItemRow(description: item.description, amount: item.amount),
          const Divider(height: 28),
          LabelValueRow(
            label: const Text(
              'Estimate Total',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textDark),
            ),
            value: Text(
              '\$${estimate.totalAmount.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.primaryGreenDark),
            ),
          ),
        ],
      ),
    );
  }

  /// Manual invoice lines (fees/discounts) — see [InvoiceAdjustment]. Added
  /// here, on top of the estimate + approved change orders, without touching
  /// either of those customer-facing records.
  Widget _buildAdjustmentsSection(InvoicePreview preview) {
    final locked = _sent || _generating || _updatingAdjustments;
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'Adjustments',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.neutralGrey, letterSpacing: 0.3),
              ),
              const Spacer(),
              if (_updatingAdjustments)
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 8),
          if (preview.adjustments.isEmpty)
            const Text(
              'Add a fee or a discount to this invoice before sending it.',
              style: TextStyle(fontSize: 12.5, color: AppColors.neutralGrey),
            )
          else
            for (final adjustment in preview.adjustments)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      adjustment.isDiscount ? Icons.discount_outlined : Icons.add_circle_outline_rounded,
                      size: 16,
                      color: adjustment.isDiscount ? AppColors.amber : AppColors.primaryGreenDark,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        adjustment.description,
                        style: const TextStyle(fontSize: 13.5, color: AppColors.textDark),
                      ),
                    ),
                    Text(
                      _signedMoney(adjustment.amount),
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: adjustment.isDiscount ? AppColors.amber : AppColors.textDark,
                      ),
                    ),
                    IconButton(
                      onPressed: locked ? null : () => _removeAdjustment(adjustment),
                      tooltip: 'Remove',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.neutralGrey),
                    ),
                  ],
                ),
              ),
          if (_adjustmentError != null) ...[
            const SizedBox(height: 8),
            Text(_adjustmentError!, style: const TextStyle(color: AppColors.error, fontSize: 12.5)),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: locked ? null : _addAdjustment,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add Line Item'),
              style: TextButton.styleFrom(foregroundColor: AppColors.primaryGreenDark),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChangeOrdersSection(InvoicePreview preview) {
    final hasAny = preview.approvedChangeOrders.isNotEmpty ||
        preview.pendingChangeOrders.isNotEmpty ||
        preview.declinedChangeOrders.isNotEmpty ||
        preview.voidedChangeOrders.isNotEmpty;
    if (!hasAny) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Change Orders',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textDark),
        ),
        const SizedBox(height: 12),
        if (preview.approvedChangeOrders.isNotEmpty) ...[
          _changeOrderGroup(
            label: 'Approved — included',
            color: AppColors.primaryGreenDark,
            changeOrders: preview.approvedChangeOrders,
            kind: _ChangeOrderKind.approved,
          ),
          const SizedBox(height: 14),
        ],
        if (preview.pendingChangeOrders.isNotEmpty) ...[
          _changeOrderGroup(
            label: 'Pending — not included in this invoice',
            color: AppColors.amber,
            changeOrders: preview.pendingChangeOrders,
            kind: _ChangeOrderKind.pending,
          ),
          const SizedBox(height: 14),
        ],
        if (preview.declinedChangeOrders.isNotEmpty) ...[
          _changeOrderGroup(
            label: 'Declined — excluded',
            color: AppColors.neutralGrey,
            changeOrders: preview.declinedChangeOrders,
            kind: _ChangeOrderKind.declined,
          ),
          const SizedBox(height: 14),
        ],
        if (preview.voidedChangeOrders.isNotEmpty)
          _changeOrderGroup(
            label: 'Voided — excluded',
            color: AppColors.neutralGrey,
            changeOrders: preview.voidedChangeOrders,
            kind: _ChangeOrderKind.voided,
          ),
      ],
    );
  }

  Widget _changeOrderGroup({
    required String label,
    required Color color,
    required List<ChangeOrder> changeOrders,
    required _ChangeOrderKind kind,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.3)),
          ],
        ),
        const SizedBox(height: 8),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < changeOrders.length; i++) ...[
                if (i > 0) const Divider(height: 20),
                _ChangeOrderRow(changeOrder: changeOrders[i], kind: kind),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

enum _ChangeOrderKind { approved, pending, declined, voided }

/// One change order's read-only rendering inside its status group — struck
/// through only when [kind] is [_ChangeOrderKind.voided] (mirroring
/// `EstimateScreen`'s voided-estimate treatment), always showing a short
/// note on why it is/isn't part of [InvoicePreview.grossTotal].
class _ChangeOrderRow extends StatelessWidget {
  const _ChangeOrderRow({required this.changeOrder, required this.kind});

  final ChangeOrder changeOrder;
  final _ChangeOrderKind kind;

  String get _note {
    switch (kind) {
      case _ChangeOrderKind.approved:
        return 'Included in this invoice';
      case _ChangeOrderKind.pending:
        return 'Not included in this invoice — awaiting customer approval';
      case _ChangeOrderKind.declined:
        return 'Excluded — declined by customer';
      case _ChangeOrderKind.voided:
        return 'Excluded — voided (${changeOrder.voidReason ?? 'no reason given'})';
    }
  }

  @override
  Widget build(BuildContext context) {
    final struckThrough = kind == _ChangeOrderKind.voided;
    final textColor = struckThrough ? AppColors.neutralGrey : AppColors.textDark;
    final decoration = struckThrough ? TextDecoration.lineThrough : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                changeOrder.description,
                style: TextStyle(fontSize: 13.5, color: textColor, decoration: decoration),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '\$${changeOrder.additionalAmount.toStringAsFixed(2)}',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: textColor, decoration: decoration),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(_note, style: const TextStyle(fontSize: 11.5, color: AppColors.neutralGrey, fontStyle: FontStyle.italic)),
      ],
    );
  }
}

/// The job header — customer name + service address only (no status pill;
/// that lives on Job Detail already), matching `_JobHeaderCard`'s card style
/// there.
class _JobHeaderCard extends StatelessWidget {
  const _JobHeaderCard({required this.job});

  final MockJob job;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            job.customerName,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textDark),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.location_on_outlined, size: 15, color: AppColors.neutralGreyLight),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  job.serviceAddress,
                  style: const TextStyle(fontSize: 13, color: AppColors.neutralGrey),
                ),
              ),
            ],
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: 0.05, end: 0, duration: 300.ms);
  }
}

/// The prominent amber warning shown when the estimate isn't yet approved —
/// distinct from (and stronger than) the plain status badge, since sending
/// an invoice against an unapproved estimate needs to be unmissable.
class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.amber, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppColors.amber, fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// The estimate's real `job_estimates.status`, as a colored pill — same
/// color mapping as `EstimateScreen`'s own status badge (green=approved,
/// amber=sent, grey=declined/draft), duplicated here as a private widget
/// rather than shared since that one is file-private to `estimate_screen.dart`.
class _EstimateStatusBadge extends StatelessWidget {
  const _EstimateStatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    late final Color fg;
    late final Color bg;
    late final String label;
    switch (status) {
      case 'draft':
        fg = AppColors.neutralGrey;
        bg = AppColors.statusGreyTint;
        label = 'Draft';
      case 'sent':
        fg = AppColors.statusAmberText;
        bg = AppColors.statusAmberTint;
        label = 'Sent — awaiting customer';
      case 'approved':
        fg = AppColors.statusGreenText;
        bg = AppColors.greenTint;
        label = 'Approved ✓';
      case 'declined':
        fg = AppColors.neutralGrey;
        bg = AppColors.statusGreyTint;
        label = 'Declined';
      default:
        fg = AppColors.neutralGrey;
        bg = AppColors.statusGreyTint;
        label = status;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

class _LineItemRow extends StatelessWidget {
  const _LineItemRow({required this.description, required this.amount});

  final String description;
  final double amount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(description, style: const TextStyle(fontSize: 14, color: AppColors.textDark)),
          ),
          Text(
            '\$${amount.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textDark),
          ),
        ],
      ),
    );
  }
}

/// Estimate Total, + Approved Change Orders, = Gross Total (the customer-
/// facing math, large/bold), then Platform Fee + Net to Contractor — visibly
/// smaller and boxed off as "internal only", since neither ever appears on
/// the customer's PDF (see `backend/functions/generate-invoice-pdf`, which
/// omits the fee entirely).
class _FinancialSummaryCard extends StatelessWidget {
  const _FinancialSummaryCard({required this.estimate, required this.approvedTotal, required this.preview});

  final JobEstimate estimate;
  final double approvedTotal;
  final InvoicePreview preview;

  @override
  Widget build(BuildContext context) {
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _summaryLine('Estimate Total', estimate.totalAmount),
          const SizedBox(height: 6),
          _summaryLine('+ Approved Change Orders', approvedTotal),
          if (preview.adjustments.isNotEmpty) ...[
            const SizedBox(height: 6),
            LabelValueRow(
              label: const Text('Adjustments', style: TextStyle(fontSize: 13.5, color: AppColors.neutralGrey)),
              value: Text(
                _signedMoney(preview.adjustmentsTotal),
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.textDark),
              ),
            ),
          ],
          const Divider(height: 26),
          LabelValueRow(
            label: const Text(
              'Gross Total',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppColors.textDark),
            ),
            value: Text(
              '\$${preview.grossTotal.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w900, color: AppColors.primaryGreenDark),
            ),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(10)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 13, color: AppColors.neutralGrey),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Internal only — not shown to the customer',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.neutralGrey),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _summarySmallLine('Platform Fee (${(preview.feeRate * 100).toStringAsFixed(1)}%)', preview.feeAmount),
                const SizedBox(height: 4),
                _summarySmallLine('Net to Contractor', preview.netToContractor),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryLine(String label, double amount) {
    return LabelValueRow(
      label: Text(label, style: const TextStyle(fontSize: 13.5, color: AppColors.neutralGrey)),
      value: Text(
        '\$${amount.toStringAsFixed(2)}',
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.textDark),
      ),
    );
  }

  Widget _summarySmallLine(String label, double amount) {
    return LabelValueRow(
      label: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.neutralGrey)),
      value: Text(
        '\$${amount.toStringAsFixed(2)}',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.neutralGrey),
      ),
    );
  }
}

/// "Time on Site" card — technician-facing reference info only, positioned
/// between the Change Orders section and the Financial Summary card (per
/// spec, deliberately NOT part of that card): hours always shown when
/// [InvoicePreview.billableHours] is known; the reference labor value
/// (hours × the technician's own hourly rate, already computed server-side)
/// only when both [InvoicePreview.technicianHourlyRate] and
/// [InvoicePreview.referenceLaborValue] are on file. Neither figure here
/// ever factors into [InvoicePreview.grossTotal]/`feeAmount`/
/// `netToContractor` — billing is itemized-price-based (the estimate +
/// approved change orders), not time-based; this is purely "what my time on
/// this job was worth," shown for the technician's own information.
class _TimeOnSiteCard extends StatelessWidget {
  const _TimeOnSiteCard({required this.preview});

  final InvoicePreview preview;

  @override
  Widget build(BuildContext context) {
    final hours = preview.billableHours;
    if (hours == null) return const SizedBox.shrink();
    final rate = preview.technicianHourlyRate;
    final laborValue = preview.referenceLaborValue;
    final showLaborValue = rate != null && laborValue != null;

    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Time on Site',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.neutralGrey, letterSpacing: 0.3),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.schedule_rounded, size: 18, color: AppColors.textDark),
              const SizedBox(width: 8),
              Text(
                '${hours.toStringAsFixed(2)} hours on site',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textDark),
              ),
            ],
          ),
          if (showLaborValue) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Text(
                '≈ \$${laborValue.toStringAsFixed(2)} reference labor value at your '
                '\$${rate.toStringAsFixed(2)}/hr rate',
                style: const TextStyle(fontSize: 12.5, color: AppColors.neutralGrey),
              ),
            ),
          ],
          const SizedBox(height: 10),
          const Text(
            'For your reference only — already included in your estimate pricing above, '
            'not shown to the customer.',
            style: TextStyle(fontSize: 11, color: AppColors.neutralGreyLight, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

/// Persistent post-send state — replaces the "Generate & Send Invoice"
/// button entirely once sent, same "nothing left to do here" treatment as
/// Job Detail's `_JobCompleteButton` once `_alreadyDone`.
class _SentConfirmation extends StatelessWidget {
  const _SentConfirmation({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.primaryGreen.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle_rounded, color: AppColors.primaryGreenDark, size: 20),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.primaryGreenDark, fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms).scale(begin: const Offset(0.96, 0.96), end: const Offset(1, 1), duration: 300.ms);
  }
}

/// The shared white card container, matching `_estimateCard`/`_card` in
/// `estimate_screen.dart`/`change_orders_screen.dart` (same shadow/radius/
/// padding) for visual consistency across all three review screens.
Widget _card(Widget child) {
  return Container(
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: AppDecorations.card(),
    child: child,
  );
}

/// `+$25.00` / `−$10.00` — adjustments carry a sign, unlike every other
/// amount on this screen.
String _signedMoney(double amount) => '${amount < 0 ? '−' : '+'}\$${amount.abs().toStringAsFixed(2)}';

class _NewAdjustment {
  const _NewAdjustment(this.description, this.amount);
  final String description;

  /// Signed — negative for a discount.
  final double amount;
}

/// "Add Line Item" bottom sheet: a fee or a discount, always entered as a
/// positive amount (the Fee/Discount choice sets the sign). A discount can't
/// exceed [currentTotal], so the invoice never goes below $0.
class _AddAdjustmentSheet extends StatefulWidget {
  const _AddAdjustmentSheet({required this.currentTotal});

  final double currentTotal;

  @override
  State<_AddAdjustmentSheet> createState() => _AddAdjustmentSheetState();
}

class _AddAdjustmentSheetState extends State<_AddAdjustmentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _amount = TextEditingController();
  bool _isDiscount = false;

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  /// "Add to Invoice" stays disabled until there is a description and an
  /// amount above $0 (and, for a discount, no more than the invoice total).
  bool get _valid {
    final value = parseAmount(_amount.text);
    return _description.text.trim().isNotEmpty &&
        value != null &&
        value > 0 &&
        (!_isDiscount || value <= widget.currentTotal);
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final value = parseAmount(_amount.text)!;
    Navigator.of(context).pop(_NewAdjustment(_description.text.trim(), _isDiscount ? -value : value));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(color: AppColors.borderGrey, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Add Line Item',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textDark),
              ),
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Fee / charge'), icon: Icon(Icons.add_rounded)),
                  ButtonSegment(value: true, label: Text('Discount'), icon: Icon(Icons.remove_rounded)),
                ],
                selected: {_isDiscount},
                onSelectionChanged: (s) => setState(() => _isDiscount = s.first),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _description,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: _isDiscount ? 'Discount description' : 'Fee description'),
                validator: requiredTextValidator,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: moneyInputFormatters,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Amount', prefixText: '\$ '),
                validator: (value) {
                  final base = positiveNumberValidator('Amount')(value);
                  if (base != null) return base;
                  if (_isDiscount && parseAmount(value!)! > widget.currentTotal) {
                    return "A discount can't be more than the invoice total (${formatMoney(widget.currentTotal)})";
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _valid ? _submit : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primaryGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Add to Invoice'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
