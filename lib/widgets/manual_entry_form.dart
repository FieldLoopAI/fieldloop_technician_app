import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';

/// Shared pieces for the manual (typed) estimate / change order / invoice
/// line forms.

/// Live currency formatting as the technician types: digits with at most one
/// decimal point and two decimal places, the whole-dollar part grouped with
/// commas ("1,250.5"). No minus sign can be typed, so amounts can never go
/// negative from the keyboard. Always read values back with [parseAmount],
/// which strips the commas.
final moneyInputFormatters = <TextInputFormatter>[const _CurrencyInputFormatter()];

/// Quantities (up to three decimal places — e.g. 2.5 hours), no grouping.
final quantityInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,3}')),
];

double? parseAmount(String text) => double.tryParse(text.replaceAll(',', '').trim());

class _CurrencyInputFormatter extends TextInputFormatter {
  const _CurrencyInputFormatter();

  static final _valid = RegExp(r'^\d*\.?\d{0,2}$');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text.replaceAll(',', '');
    if (!_valid.hasMatch(raw)) return oldValue;
    final dot = raw.indexOf('.');
    final whole = dot < 0 ? raw : raw.substring(0, dot);
    final fraction = dot < 0 ? '' : raw.substring(dot);
    final grouped = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    final text = '$grouped$fraction';
    // Keep the caret the same number of DIGITS from the end, so typing in
    // the middle doesn't jump it around as commas come and go.
    final digitsAfterCaret = newValue.text
        .substring(newValue.selection.end.clamp(0, newValue.text.length))
        .replaceAll(',', '')
        .length;
    var offset = text.length;
    for (var seen = 0; offset > 0 && seen < digitsAfterCaret; offset--) {
      if (text[offset - 1] != ',') seen++;
    }
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: offset));
  }
}

/// Inline validator: required, numeric, and strictly positive (or >= 0 when
/// [allowZero]).
String? Function(String?) positiveNumberValidator(String label, {bool allowZero = false}) {
  return (value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '$label is required';
    final parsed = parseAmount(text);
    if (parsed == null) return 'Enter a valid number';
    if (parsed < 0 || (!allowZero && parsed == 0)) return '$label must be more than 0';
    return null;
  };
}

String? requiredTextValidator(String? value) =>
    (value == null || value.trim().isEmpty) ? 'Description is required' : null;

String formatMoney(double amount) => '\$${amount.toStringAsFixed(2)}';

/// Sticky bottom Save/Cancel bar — sits in `Scaffold.bottomNavigationBar`
/// so a long list of line items can never scroll the actions out of reach.
/// Padded by the keyboard inset itself, since a scaffold's bottom bar is
/// otherwise left behind the keyboard.
class StickyActionBar extends StatelessWidget {
  const StickyActionBar({
    super.key,
    required this.saveLabel,
    required this.onSave,
    required this.onCancel,
    this.saving = false,
    this.summary,
  });

  final String saveLabel;
  final VoidCallback? onSave;
  final VoidCallback onCancel;
  final bool saving;

  /// Optional left-aligned line above the buttons (e.g. the running total).
  final Widget? summary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _buildBar(),
    );
  }

  Widget _buildBar() {
    // Hairline top divider + an upward shadow, so the bar reads as separate
    // from the content scrolling underneath it.
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppSurfaces.card,
        border: Border(top: BorderSide(color: AppSurfaces.outline)),
        boxShadow: AppShadows.bottomBar,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (summary != null) ...[summary!, const SizedBox(height: 10)],
              Row(
                children: [
                  // Deliberately low-weight next to Save (text-only, grey) so
                  // the primary action is unmistakable.
                  Expanded(
                    child: TextButton(
                      onPressed: saving ? null : onCancel,
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.neutralGrey,
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    // [onSave] null (form not valid yet) renders the standard
                    // disabled grey — no $0.00 or blank submit is possible.
                    child: FilledButton(
                      onPressed: saving ? null : onSave,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primaryGreen,
                        foregroundColor: Colors.white,
                        // Stays green while saving (spinner shown); grey only when
                        // the form is not valid yet.
                        disabledBackgroundColor: saving ? AppColors.primaryGreen : AppColors.borderGrey,
                        disabledForegroundColor: AppColors.neutralGrey,
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5),
                      ),
                      child: saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                            )
                          : Text(saveLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// White rounded card matching the app's existing section cards.
class FormSectionCard extends StatelessWidget {
  const FormSectionCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: AppDecorations.card(),
      child: child,
    );
  }
}

/// Brief (~0.6s) animated checkmark shown after a successful save, before
/// the form pops back with its snackbar. Non-dismissible and short on
/// purpose: it confirms the save without slowing the technician down.
Future<void> showSaveSuccess(BuildContext context) async {
  // showGeneralDialog pushes onto the ROOT navigator by default — pop that
  // one, never the form's own route.
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (_, _, _) => const Center(child: _SuccessCheck()),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 650));
  navigator.pop();
}

class _SuccessCheck extends StatelessWidget {
  const _SuccessCheck();

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.6, end: 1),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutBack,
      builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
      child: Container(
        width: 88,
        height: 88,
        decoration: const BoxDecoration(color: AppColors.primaryGreen, shape: BoxShape.circle, boxShadow: AppShadows.raised),
        child: const Icon(Icons.check_rounded, color: Colors.white, size: 52),
      ),
    );
  }
}
