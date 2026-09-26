import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/job_estimate.dart';
import '../providers/job_estimate_provider.dart';
import '../providers/jobs_provider.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/app_components.dart';
import '../widgets/manual_entry_form.dart';

/// Manual (typed) estimate creation — the way to create an estimate while
/// voice dictation is removed (pending its rebuild on Gemini Live). Line
/// items are entered as description × quantity ×
/// unit price; saving goes through [JobEstimateController.createManual],
/// which writes the same `job_estimates` row shape the dictated path does, so
/// the result lands as a normal draft on the Estimate screen (reviewable,
/// editable, sendable) and flows into change-order totals and the invoice
/// exactly like a dictated one.
class ManualEstimateScreen extends ConsumerStatefulWidget {
  const ManualEstimateScreen({super.key, required this.jobId});

  final String jobId;

  @override
  ConsumerState<ManualEstimateScreen> createState() => _ManualEstimateScreenState();
}

class _ManualEstimateScreenState extends ConsumerState<ManualEstimateScreen> {
  final _formKey = GlobalKey<FormState>();
  final List<_LineDraft> _lines = [_LineDraft()];
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  double get _total => _lines.fold<double>(0, (sum, line) => sum + line.lineTotal);

  bool get _dirty => _lines.length > 1 || _lines.first.hasInput;

  /// Save stays disabled until every line has a description, a quantity
  /// above 0 and a valid price, and the estimate adds up to more than $0.
  bool get _valid => _lines.every((line) => line.isComplete) && _total > 0;

  void _addLine() => setState(() => _lines.add(_LineDraft()));

  /// The last remaining line is cleared rather than removed, so the trash
  /// icon can always be shown and the form never ends up with zero rows.
  void _removeLine(_LineDraft line) {
    if (_lines.length == 1) {
      setState(line.clear);
      return;
    }
    setState(() => _lines.remove(line));
    line.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final items = [
        for (final line in _lines)
          EstimateLineItem(
            description: line.description.text.trim(),
            amount: line.lineTotal,
            quantity: line.quantity,
            unitPrice: line.unitPrice,
          ),
      ];
      await ref.read(jobEstimateProvider(widget.jobId).notifier).createManual(items);
      if (!mounted) return;
      await showSaveSuccess(context);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Estimate saved')),
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
        title: const Text('Discard this estimate?'),
        content: const Text("The line items you've entered won't be saved."),
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
          title: Text(job != null ? 'New Estimate · ${job.jobIdPublic}' : 'New Estimate'),
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.textDark,
          elevation: 0,
        ),
        bottomNavigationBar: StickyActionBar(
          saveLabel: 'Save Estimate',
          saving: _saving,
          onSave: _valid ? _save : null,
          onCancel: _cancel,
          summary: LabelValueRow(
            label: const Text(
              'Estimate total',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textDark),
            ),
            value: Text(
              formatMoney(_total),
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
                      'Add each piece of work with its quantity and unit price. It saves as a draft you can '
                      'review before sending.',
                      style: TextStyle(fontSize: 13, color: AppColors.neutralGrey, height: 1.35),
                    ),
                    const SizedBox(height: 16),
                    for (var i = 0; i < _lines.length; i++) ...[
                      _LineItemCard(
                        key: ObjectKey(_lines[i]),
                        index: i,
                        line: _lines[i],
                        onChanged: () => setState(() {}),
                        onRemove: () => _removeLine(_lines[i]),
                      ),
                      const SizedBox(height: 12),
                    ],
                    OutlinedButton.icon(
                      onPressed: _saving ? null : _addLine,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Add line item'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primaryGreenDark,
                        side: const BorderSide(color: AppColors.primaryGreen),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

class _LineDraft {
  final description = TextEditingController();
  final quantityText = TextEditingController(text: '1');
  final unitPriceText = TextEditingController();

  double? get quantity => parseAmount(quantityText.text);
  double? get unitPrice => parseAmount(unitPriceText.text);

  double get lineTotal {
    final q = quantity;
    final p = unitPrice;
    if (q == null || p == null) return 0;
    return (q * p * 100).roundToDouble() / 100;
  }

  bool get isComplete {
    final q = quantity;
    final p = unitPrice;
    return description.text.trim().isNotEmpty && q != null && q > 0 && p != null && p >= 0;
  }

  void clear() {
    description.clear();
    quantityText.text = '1';
    unitPriceText.clear();
  }

  bool get hasInput =>
      description.text.trim().isNotEmpty || unitPriceText.text.trim().isNotEmpty || quantityText.text.trim() != '1';

  void dispose() {
    description.dispose();
    quantityText.dispose();
    unitPriceText.dispose();
  }
}

class _LineItemCard extends StatelessWidget {
  const _LineItemCard({
    super.key,
    required this.index,
    required this.line,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final _LineDraft line;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return FormSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Item ${index + 1}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.neutralGrey),
              ),
              const Spacer(),
              // Always visible (the last row is cleared instead of removed),
              // at a full 48dp target for gloved use.
              IconButton(
                onPressed: onRemove,
                tooltip: 'Remove item',
                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.statusRedText, size: 22),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextFormField(
            controller: line.description,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Description'),
            validator: requiredTextValidator,
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: line.quantityText,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: quantityInputFormatters,
                  decoration: const InputDecoration(labelText: 'Qty'),
                  validator: positiveNumberValidator('Qty'),
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: TextFormField(
                  controller: line.unitPriceText,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: moneyInputFormatters,
                  decoration: const InputDecoration(labelText: 'Unit price', prefixText: '\$ '),
                  validator: positiveNumberValidator('Price', allowZero: true),
                  onChanged: (_) => onChanged(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Line total  ${formatMoney(line.lineTotal)}',
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.textDark),
            ),
          ),
        ],
      ),
    );
  }
}
