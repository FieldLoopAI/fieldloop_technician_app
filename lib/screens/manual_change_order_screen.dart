import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/change_order_provider.dart';
import '../providers/job_change_orders_provider.dart';
import '../providers/jobs_provider.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/app_components.dart';
import '../widgets/manual_entry_form.dart';

/// Manual (typed) change order — the way to add one while voice dictation
/// is removed (pending its rebuild on Gemini Live). Goes through the same
/// `/change-orders/create` Lambda with
/// the typed amount (see [createChangeOrder]'s `amount`), so it is created
/// `pending` and the customer gets the same approval text; it only counts
/// toward "Approved additional work" / the running total once they approve,
/// exactly like a dictated one. There is deliberately no approved/pending
/// toggle here — approval stays the customer's.
class ManualChangeOrderScreen extends ConsumerStatefulWidget {
  const ManualChangeOrderScreen({super.key, required this.jobId});

  final String jobId;

  @override
  ConsumerState<ManualChangeOrderScreen> createState() => _ManualChangeOrderScreenState();
}

enum _PricingMode { flat, quantity }

class _ManualChangeOrderScreenState extends ConsumerState<ManualChangeOrderScreen> {
  final _formKey = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _flatAmount = TextEditingController();
  final _quantity = TextEditingController(text: '1');
  final _unitPrice = TextEditingController();
  _PricingMode _mode = _PricingMode.flat;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _description.dispose();
    _flatAmount.dispose();
    _quantity.dispose();
    _unitPrice.dispose();
    super.dispose();
  }

  double get _amount {
    if (_mode == _PricingMode.flat) return parseAmount(_flatAmount.text) ?? 0;
    final q = parseAmount(_quantity.text);
    final p = parseAmount(_unitPrice.text);
    if (q == null || p == null) return 0;
    return (q * p * 100).roundToDouble() / 100;
  }

  /// Save stays disabled until there is a description and a total above $0.
  bool get _valid => _description.text.trim().isNotEmpty && _amount > 0;

  bool get _dirty =>
      _description.text.trim().isNotEmpty || _flatAmount.text.trim().isNotEmpty || _unitPrice.text.trim().isNotEmpty;

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_amount <= 0) {
      setState(() => _error = 'The change order total must be more than \$0.00.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final smsSent = await createChangeOrder(
        jobId: widget.jobId,
        description: _description.text.trim(),
        amount: _amount,
      );
      // Same refresh the realtime subscription would do — immediate, so the
      // screen we pop back to already shows the new pending row.
      await ref.read(jobChangeOrdersProvider(widget.jobId).notifier).refresh();
      if (!mounted) return;
      await showSaveSuccess(context);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            smsSent
                ? 'Change order sent for approval'
                : "Change order saved — the approval text couldn't be sent to the customer",
          ),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is StateError ? e.message : e.toString();
      });
    }
  }

  Future<bool> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard this change order?'),
        content: const Text("What you've entered won't be saved."),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Keep editing')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  Future<void> _cancel() async {
    if (_dirty && !await _confirmDiscard()) return;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(jobByIdProvider(widget.jobId));

    return PopScope(
      canPop: !_dirty || _saving,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text(job != null ? 'New Change Order · ${job.jobIdPublic}' : 'New Change Order'),
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.textDark,
          elevation: 0,
        ),
        bottomNavigationBar: StickyActionBar(
          saveLabel: 'Save & Request Approval',
          saving: _saving,
          onSave: _valid ? _save : null,
          onCancel: _cancel,
          summary: LabelValueRow(
            label: const Text(
              'Additional cost',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textDark),
            ),
            value: Text(
              formatMoney(_amount),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.primaryGreenDark),
            ),
          ),
        ),
        body: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final horizontalPadding = responsiveGutter(constraints.maxWidth);
              return Form(
                key: _formKey,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(horizontalPadding, 16, horizontalPadding, 24),
                  children: [
                    const Text(
                      'Describe the additional work and its price. It is saved as pending, and the customer is '
                      'texted to approve it before it counts toward the total.',
                      style: TextStyle(fontSize: 13, color: AppColors.neutralGrey, height: 1.35),
                    ),
                    const SizedBox(height: 16),
                    FormSectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            controller: _description,
                            textCapitalization: TextCapitalization.sentences,
                            minLines: 2,
                            maxLines: 4,
                            decoration: const InputDecoration(labelText: 'Description of the additional work'),
                            validator: requiredTextValidator,
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 16),
                          SegmentedButton<_PricingMode>(
                            segments: const [
                              ButtonSegment(value: _PricingMode.flat, label: Text('Flat amount')),
                              ButtonSegment(value: _PricingMode.quantity, label: Text('Qty × price')),
                            ],
                            selected: {_mode},
                            showSelectedIcon: false,
                            onSelectionChanged: _saving ? null : (s) => setState(() => _mode = s.first),
                          ),
                          const SizedBox(height: 16),
                          if (_mode == _PricingMode.flat)
                            TextFormField(
                              controller: _flatAmount,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: moneyInputFormatters,
                              decoration: const InputDecoration(labelText: 'Amount', prefixText: '\$ '),
                              validator: positiveNumberValidator('Amount'),
                              onChanged: (_) => setState(() {}),
                            )
                          else
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: TextFormField(
                                    controller: _quantity,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    inputFormatters: quantityInputFormatters,
                                    decoration: const InputDecoration(labelText: 'Qty'),
                                    validator: positiveNumberValidator('Qty'),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  flex: 3,
                                  child: TextFormField(
                                    controller: _unitPrice,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    inputFormatters: moneyInputFormatters,
                                    decoration: const InputDecoration(labelText: 'Unit price', prefixText: '\$ '),
                                    validator: positiveNumberValidator('Price'),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _error!,
                        style: const TextStyle(color: AppColors.error, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
