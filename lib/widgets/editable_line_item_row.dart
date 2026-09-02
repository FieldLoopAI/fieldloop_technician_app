import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One editable line item's live-editing state (a description + amount
/// [TextEditingController] pair). Plain field holder, not a widget, so it
/// survives rebuilds of [EditableLineItemRow] untouched; owned and disposed
/// by whichever screen creates it (see `_EstimateScreenState` in
/// `estimate_screen.dart` and `_ChangeOrdersScreenState` in
/// `change_orders_screen.dart`).
class EditableLineItem {
  EditableLineItem({String description = '', double amount = 0})
      : descriptionController = TextEditingController(text: description),
        amountController = TextEditingController(text: amount == 0 ? '' : amount.toStringAsFixed(2));

  final TextEditingController descriptionController;
  final TextEditingController amountController;

  double get amount => double.tryParse(amountController.text.trim()) ?? 0;

  void dispose() {
    descriptionController.dispose();
    amountController.dispose();
  }
}

/// One editable row: a description field, an amount field, and — only when
/// [onDelete] is given — a delete button. [onChanged] fires on every
/// keystroke in either field so the parent can recompute a live total.
/// Shared by the Estimate screen's line items and the Change Orders review
/// screen so both use the exact same edit-field UI, visually and in code.
class EditableLineItemRow extends StatelessWidget {
  const EditableLineItemRow({super.key, required this.item, required this.onChanged, this.onDelete});

  final EditableLineItem item;
  final VoidCallback onChanged;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
              controller: item.descriptionController,
              style: const TextStyle(fontSize: 14, color: AppColors.textDark),
              decoration: const InputDecoration(isDense: true, hintText: 'Description', border: UnderlineInputBorder()),
              onChanged: (_) => onChanged(),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 92,
            child: TextField(
              controller: item.amountController,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textDark),
              decoration: const InputDecoration(isDense: true, prefixText: '\$', border: UnderlineInputBorder()),
              onChanged: (_) => onChanged(),
            ),
          ),
          if (onDelete != null)
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.neutralGrey),
              onPressed: onDelete,
              splashRadius: 18,
              tooltip: 'Remove line item',
            ),
        ],
      ),
    );
  }
}
