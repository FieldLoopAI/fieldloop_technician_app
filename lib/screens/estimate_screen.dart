import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/job_estimate.dart';
import '../providers/global_voice_service_provider.dart';
import '../providers/job_dictations_provider.dart';
import '../providers/job_estimate_provider.dart';
import '../providers/job_runtime_provider.dart';
import '../providers/job_status_notifications_provider.dart';
import '../providers/job_voice_commands.dart';
import '../providers/jobs_provider.dart';
import '../providers/safe_ref_disposal.dart';
import '../providers/voice_command_registry_provider.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../theme/design_tokens.dart';
import '../widgets/app_components.dart';
import '../widgets/editable_line_item_row.dart';
import '../widgets/empty_state_actions.dart';
import '../widgets/primary_button.dart';
import '../widgets/status_notification_banner.dart';
import '../widgets/voice_phase_indicator.dart';
import 'manual_estimate_screen.dart';
import 'voice_command_registrar_mixin.dart';

/// A single itemized estimate — deliberately one proposal, not a
/// Good/Better/Best comparison. Also a job-scoped screen for voice purposes
/// — see [buildVoiceCommands] — even though it has no estimate-specific
/// voice commands of its own yet; it registers the same job-lifecycle set
/// (arrived/job complete/site condition/ask a question) every other job
/// screen does, so voice keeps working here too.
///
/// Body layout branches on the REAL `job_estimates.status` for the current
/// job (via [jobEstimateProvider], watched in [build] and kept live by that
/// provider's realtime subscription — see
/// `JobEstimateController._subscribeRealtime`, same pattern as
/// `job_change_orders_provider.dart`):
///  - no row yet -> [_buildNoEstimateCard]
///  - `status == 'draft'` -> [_buildDraftReview] (Feature 1: editable line
///    items, add/delete, "Looks good, send to customer")
///  - anything else (`'sent'`, `'approved'`, `'declined'`, ...) ->
///    [_buildFinalized]: line items/total render read-only
///    ([_LineItemRow], never a `TextField`), [_EstimateStatusBadge] shows
///    the real status, and an approved-not-yet-voided estimate gets a
///    "Void this estimate" in-card expansion (never a modal dialog — see
///    that expansion's doc comment for why) — all the same rules, for the
///    same reasons, as `ChangeOrdersScreen`.
///
/// This screen no longer has any "Signed"/e-signature concept — that was
/// leftover mock UI (`EstimateStatus.signed`, the "Simulate customer
/// signing (demo)" button) from before `job_estimates.status` existed as a
/// real column, and never corresponded to anything in the schema (which
/// only has `draft`/`sent`/`approved`/`declined`, plus `voided_at`/
/// `void_reason`). NOTE: `invoice_screen.dart` and Job Detail's
/// job-complete gating still read `estimateStatusProvider`/
/// `EstimateStatus.signed` for unrelated reasons — removing this screen's
/// only way to ever set that value to `signed` makes those other features
/// permanently unreachable; see the removal commit's notes/PR description
/// for the full accounting of what else references this mock enum.
class EstimateScreen extends ConsumerStatefulWidget {
  const EstimateScreen({super.key, required this.jobId});

  final String jobId;

  @override
  ConsumerState<EstimateScreen> createState() => _EstimateScreenState();
}

class _EstimateScreenState extends ConsumerState<EstimateScreen>
    with SafeRefDisposal<EstimateScreen>, VoiceCommandRegistrarMixin<EstimateScreen> {
  bool _sending = false;
  bool _savingDraft = false;
  String? _sendingStatus;
  bool _showConfirmation = false;
  String? _confirmationMessage;
  String? _sendError;
  bool _dictationExpanded = false;

  // Feature 1 (review/edit) — the technician's in-progress edits to a
  // `status == 'draft'` estimate. Re-seeded (see [_seedEditableItems]) only
  // when the underlying [JobEstimate.id] changes, so a rebuild triggered by
  // something unrelated (e.g. the job-detail providers refreshing) never
  // clobbers text the technician is mid-typing.
  String? _editingEstimateId;
  final List<EditableLineItem> _editableItems = [];

  // Void — same in-card-expansion pattern as ChangeOrdersScreen's
  // `_voidReasonControllers` (see that screen's doc comment for why this is
  // deliberately not a modal dialog: an AlertDialog here raced the realtime
  // subscription's own rebuilds during the dialog's pop/teardown and
  // crashed with a `'_dependents.isEmpty'` assertion). Only one estimate
  // row exists per job at a time (unlike change orders' per-row list), so a
  // single nullable controller is enough instead of a Map keyed by id.
  TextEditingController? _voidReasonController;
  bool _voiding = false;
  String? _voidError;

  // Banner+TTS for a customer's remote approve/decline — same pattern as
  // ChangeOrdersScreen's `_activeNotification` (see that field's doc
  // comment and `jobStatusNotificationProvider`'s doc comment).
  JobStatusNotification? _activeNotification;

  @override
  void dispose() {
    for (final item in _editableItems) {
      item.dispose();
    }
    _voidReasonController?.dispose();
    super.dispose();
  }

  @override
  List<VoiceCommand> buildVoiceCommands() => jobLifecycleVoiceCommands(ref, widget.jobId);

  void _seedEditableItems(JobEstimate estimate) {
    if (_editingEstimateId == estimate.id) return;
    for (final item in _editableItems) {
      item.dispose();
    }
    _editableItems
      ..clear()
      ..addAll(
        estimate.lineItems.isEmpty
            ? [EditableLineItem()]
            : estimate.lineItems.map(
                (item) => EditableLineItem(description: item.description, amount: item.amount),
              ),
      );
    _editingEstimateId = estimate.id;
  }

  double get _editableTotal => _editableItems.fold<double>(0, (sum, item) => sum + item.amount);

  void _addLineItem() => setState(() => _editableItems.add(EditableLineItem()));

  void _removeLineItem(EditableLineItem item) {
    setState(() => _editableItems.remove(item));
    item.dispose();
  }

  /// Feature 1.3 + Feature 2 — saves any edits, then sends the finalized
  /// estimate to the customer over SMS (see
  /// [JobEstimateController.saveLineItems]/[JobEstimateController.sendToCustomer]
  /// for the actual backend calls). Any failure (missing phone, SMS
  /// failure, save failure) surfaces inline via [_sendError] rather than
  /// silently leaving/marking the estimate sent.
  Future<void> _sendDraftEstimate(JobEstimate estimate) async {
    setState(() {
      _sending = true;
      _sendingStatus = 'Saving edits…';
      _sendError = null;
    });
    try {
      final items = _editableItems
          .map((e) => EstimateLineItem(description: e.descriptionController.text.trim(), amount: e.amount))
          .where((item) => item.description.isNotEmpty)
          .toList();
      final total = items.fold<double>(0, (sum, item) => sum + item.amount);

      final notifier = ref.read(jobEstimateProvider(widget.jobId).notifier);
      await notifier.saveLineItems(estimateId: estimate.id, lineItems: items, totalAmount: total);
      final customerName = await notifier.sendToCustomer(
        estimate.id,
        onStatus: (status) {
          if (mounted) setState(() => _sendingStatus = status);
        },
      );

      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendingStatus = null;
        _showConfirmation = true;
        _confirmationMessage = 'Estimate sent to $customerName';
      });
      await Future.delayed(const Duration(milliseconds: 1800));
      if (mounted) setState(() => _showConfirmation = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendingStatus = null;
        _sendError = e is StateError ? e.message : e.toString();
      });
    }
  }

  /// Opens the void-reason expansion on the estimate card — no dialog, no
  /// route, same reasoning as `ChangeOrdersScreen._startVoiding`.
  void _startVoiding() {
    setState(() {
      _voidReasonController ??= TextEditingController();
      _voidError = null;
    });
  }

  /// Collapses the expansion without voiding anything — purely local
  /// widget state, nothing to await or race.
  void _cancelVoiding() {
    setState(() {
      _voidReasonController?.dispose();
      _voidReasonController = null;
      _voidError = null;
    });
  }

  /// Runs [JobEstimateController.voidEstimate] directly and synchronously —
  /// no post-frame-callback deferral, same reasoning as
  /// `ChangeOrdersScreen._confirmVoid`: that deferral only ever existed to
  /// outlast an AlertDialog's pop/teardown, and there is no dialog route
  /// here to outlast.
  Future<void> _confirmVoid(JobEstimate estimate) async {
    final controller = _voidReasonController;
    if (controller == null) return;
    final reason = controller.text.trim();
    if (reason.isEmpty) return;

    setState(() {
      _voiding = true;
      _voidError = null;
    });
    try {
      await ref.read(jobEstimateProvider(widget.jobId).notifier).voidEstimate(estimateId: estimate.id, reason: reason);
      if (!mounted) return;
      _voidReasonController?.dispose();
      setState(() {
        _voiding = false;
        _voidReasonController = null;
        _showConfirmation = true;
        _confirmationMessage = 'Estimate voided';
      });
      await Future.delayed(const Duration(milliseconds: 1600));
      if (mounted && _confirmationMessage == 'Estimate voided') setState(() => _showConfirmation = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _voiding = false;
        _voidError = e is StateError ? e.message : e.toString();
      });
    }
  }

  /// Consumes a [JobStatusNotification] the moment
  /// `JobEstimateController`'s realtime subscription writes one — same
  /// shape as `ChangeOrdersScreen._handleStatusNotification`.
  void _handleStatusNotification(JobStatusNotification? notification) {
    if (notification == null) return;
    ref.read(jobStatusNotificationProvider(widget.jobId).notifier).state = null;
    setState(() => _activeNotification = notification);
    unawaited(ref.read(globalVoiceServiceProvider.notifier).speak(notification.spokenMessage));
    Future.delayed(const Duration(seconds: 6), () {
      if (mounted && _activeNotification == notification) setState(() => _activeNotification = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(jobByIdProvider(widget.jobId));
    final estimateAsync = ref.watch(jobEstimateProvider(widget.jobId));
    ref.listen<JobStatusNotification?>(
      jobStatusNotificationProvider(widget.jobId),
      (previous, next) => _handleStatusNotification(next),
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(job != null ? 'Estimate · ${job.jobIdPublic}' : 'Estimate'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
        actions: const [
          Padding(padding: EdgeInsets.only(right: 14), child: Center(child: VoicePhaseIndicator())),
        ],
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
                  if (_activeNotification != null)
                    StatusNotificationBanner(
                      notification: _activeNotification!,
                      onDismiss: () => setState(() => _activeNotification = null),
                    ),
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
                  estimateAsync.when(
                    loading: _buildLoadingCard,
                    error: (error, stackTrace) => _buildErrorCard(error),
                    data: (estimate) {
                      if (estimate == null) return _buildNoEstimateCard();
                      debugPrint(
                        'ESTIMATE SCREEN: rendering with id=${estimate.id} status="${estimate.status}" '
                        'isDraft=${estimate.isDraft} isVoided=${estimate.isVoided} '
                        'createdAt=${estimate.createdAt}',
                      );
                      if (estimate.isDraft) return _buildDraftReview(estimate);
                      return _buildFinalized(estimate);
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildLoadingCard() {
    return _estimateCard(
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Column(
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 3, color: AppColors.primaryGreen),
            ),
            SizedBox(height: 14),
            Text(
              'Parsing your dictated estimate…',
              style: TextStyle(fontSize: 13, color: AppColors.neutralGrey, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard(Object error) {
    return _estimateCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            "Couldn't load the estimate",
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textDark),
          ),
          const SizedBox(height: 4),
          Text('$error', style: const TextStyle(fontSize: 12, color: AppColors.neutralGrey)),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => ref.read(jobEstimateProvider(widget.jobId).notifier).refresh(),
              child: const Text('Retry'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoEstimateCard() {
    // Same active-job gate Job Detail uses for its entry points — a finished
    // job viewed from History is read-only. (Voice dictation is removed from
    // here until it's rebuilt on Gemini Live.)
    final editable = activeJobStatuses.contains(ref.watch(jobRuntimeProvider(widget.jobId)).status);
    return _estimateCard(
      EmptyStateActions(
        icon: Icons.receipt_long_rounded,
        title: 'No estimate yet',
        hint: editable
            ? 'Add the line items for this job. It saves as a draft you can review before sending.'
            : 'No estimate was created for this job.',
        actionLabel: 'Create Estimate',
        onAction: editable
            ? () => Navigator.of(
                context,
              ).push(FadeSlidePageRoute(builder: (_) => ManualEstimateScreen(jobId: widget.jobId)))
            : null,
      ),
    );
  }

  /// Saves the draft's line-item edits WITHOUT sending — the manual edit
  /// path for an existing draft, however it was created (dictated or typed).
  Future<void> _saveDraftEdits(JobEstimate estimate) async {
    final items = _editableItems
        .map((e) => EstimateLineItem(description: e.descriptionController.text.trim(), amount: e.amount))
        .where((item) => item.description.isNotEmpty)
        .toList();
    if (items.isEmpty) {
      setState(() => _sendError = 'Add at least one line item with a description before saving.');
      return;
    }
    setState(() {
      _savingDraft = true;
      _sendError = null;
    });
    try {
      final total = items.fold<double>(0, (sum, item) => sum + item.amount);
      await ref
          .read(jobEstimateProvider(widget.jobId).notifier)
          .saveLineItems(estimateId: estimate.id, lineItems: items, totalAmount: total);
      if (!mounted) return;
      setState(() => _savingDraft = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Estimate changes saved.')));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _savingDraft = false;
        _sendError = e is StateError ? e.message : e.toString();
      });
    }
  }

  /// Feature 1 — a `status == 'draft'` estimate: every line item is a live
  /// editable row (description + amount), the total recomputes as amounts
  /// change, line items can be added/removed, the original dictation is one
  /// tap away for cross-checking, and "Looks good, send to customer" is the
  /// only way forward (Feature 2).
  Widget _buildDraftReview(JobEstimate estimate) {
    _seedEditableItems(estimate);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _EstimateStatusBadge(status: estimate.status, voided: estimate.isVoided),
        const SizedBox(height: 12),
        Text(
          estimate.sourceDictationId == null
              ? 'Review the line items below, fix anything that\'s off, then send.'
              : 'Review the AI-parsed line items below, fix anything that\'s off, then send.',
          style: const TextStyle(fontSize: 12, color: AppColors.neutralGrey),
        ),
        const SizedBox(height: 16),
        _OriginalDictationSection(
          dictationId: estimate.sourceDictationId,
          expanded: _dictationExpanded,
          onToggle: () => setState(() => _dictationExpanded = !_dictationExpanded),
        ),
        const SizedBox(height: 16),
        _estimateCard(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final item in _editableItems)
                EditableLineItemRow(
                  item: item,
                  onChanged: () => setState(() {}),
                  onDelete: () => _removeLineItem(item),
                ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _addLineItem,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add line item'),
                ),
              ),
              const Divider(height: 20),
              LabelValueRow(
                label: const Text(
                  'Total',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textDark),
                ),
                value: Text(
                  '\$${_editableTotal.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.primaryGreenDark),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (_sendError != null) ...[
          Text(_sendError!, style: const TextStyle(color: AppColors.statusRedText, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
        ],
        if (_sending && _sendingStatus != null) ...[
          Text(
            _sendingStatus!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.neutralGrey, fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 10),
        ],
        if (_showConfirmation && _confirmationMessage != null) ...[
          Text(
            _confirmationMessage!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.primaryGreenDark, fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 10),
        ],
        Stack(
          alignment: Alignment.center,
          children: [
            PrimaryButton(
              label: 'Looks good, send to customer',
              icon: Icons.send_rounded,
              isLoading: _sending,
              onPressed: _savingDraft ? null : () => _sendDraftEstimate(estimate),
            ),
            if (_showConfirmation) const _ConfirmationCheck(),
          ],
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: (_sending || _savingDraft) ? null : () => _saveDraftEdits(estimate),
          icon: _savingDraft
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_outlined, size: 18),
          label: const Text('Save changes without sending'),
          style: secondaryActionButtonStyle,
        ),
      ],
    );
  }

  /// A non-draft (`'sent'`, `'approved'`, `'declined'`, ...) estimate.
  /// [estimate]'s own real `status`/`isVoided` drive everything shown here —
  /// the badge, the void action, the (already always-read-only) line items.
  Widget _buildFinalized(JobEstimate estimate) {
    final isVoiding = _voidReasonController != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _EstimateStatusBadge(status: estimate.status, voided: estimate.isVoided),
        const SizedBox(height: 20),
        _estimateCard(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (estimate.lineItems.isEmpty)
                const Text('No line items yet', style: TextStyle(color: AppColors.neutralGrey))
              else
                for (final item in estimate.lineItems) _LineItemRow(item: item),
              const Divider(height: 28),
              LabelValueRow(
                label: const Text(
                  'Total',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textDark),
                ),
                value: Text(
                  '\$${estimate.totalAmount.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.primaryGreenDark),
                ),
              ),
              if (estimate.isVoided) ...[
                const SizedBox(height: 10),
                Text(
                  'Void reason: ${estimate.voidReason ?? '—'}',
                  style: const TextStyle(fontSize: 12, color: AppColors.neutralGrey, fontStyle: FontStyle.italic),
                ),
              ],
            ],
          ),
        ),
        // Void is only ever offered for a real-status 'approved', not-yet-
        // voided estimate — same rule, same reason, as
        // ChangeOrdersScreen's void action: a customer-approved estimate's
        // numbers are never edited in place, only closed out (with a
        // reason) or superseded by a brand-new estimate.
        if (estimate.isApproved && !estimate.isVoided) ...[
          const SizedBox(height: 16),
          isVoiding ? _buildVoidExpansion(estimate) : _buildVoidPrompt(),
        ],
        if (_voidError != null) ...[
          const SizedBox(height: 10),
          Text(_voidError!, style: const TextStyle(color: AppColors.statusRedText, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
        const SizedBox(height: 16),
        _OriginalDictationSection(
          dictationId: estimate.sourceDictationId,
          expanded: _dictationExpanded,
          onToggle: () => setState(() => _dictationExpanded = !_dictationExpanded),
        ),
        const SizedBox(height: 28),
        if (_showConfirmation && _confirmationMessage != null)
          Text(
            _confirmationMessage!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.primaryGreenDark, fontWeight: FontWeight.w700, fontSize: 14),
          ),
      ],
    );
  }

  /// Collapsed state of the void action — a single button that opens
  /// [_buildVoidExpansion] on this same card. Same shape as
  /// ChangeOrdersScreen's "Void this change order" button.
  Widget _buildVoidPrompt() {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton(
        onPressed: _startVoiding,
        style: TextButton.styleFrom(foregroundColor: AppColors.statusRedText),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block_rounded, size: 16),
            SizedBox(width: 6),
            Text('Void this estimate'),
          ],
        ),
      ),
    );
  }

  /// The in-card void-reason expansion — identical pattern to
  /// `ChangeOrdersScreen._buildVoidExpansion`: no dialog, no route, just
  /// more of this same card's own layout, so there is nothing here with a
  /// teardown that could race the realtime subscription's rebuilds.
  Widget _buildVoidExpansion(JobEstimate estimate) {
    final controller = _voidReasonController;
    if (controller == null) return const SizedBox.shrink();
    final canConfirm = controller.text.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF2F2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.statusRedText.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'This closes it out as a historical record — it cannot be edited or voided again '
            'afterward. If more work is needed, dictate a brand-new estimate instead.',
            style: TextStyle(fontSize: 12, color: AppColors.neutralGrey),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            autofocus: true,
            enabled: !_voiding,
            minLines: 2,
            maxLines: 4,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Reason for voiding',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: _voiding ? null : _cancelVoiding, child: const Text('Cancel')),
              const SizedBox(width: 4),
              TextButton(
                onPressed: (_voiding || !canConfirm) ? null : () => _confirmVoid(estimate),
                style: TextButton.styleFrom(foregroundColor: AppColors.statusRedText),
                child: _voiding
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Confirm Void'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The shared white card container used for every state of the estimate
/// body (loading/error/empty/draft/finalized) — pulled out so the same
/// shadow/radius/padding is defined once instead of repeated at each call
/// site.
Widget _estimateCard(Widget child) {
  return Container(
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: AppDecorations.card(),
    child: child,
  );
}

/// The estimate's real `job_estimates.status` (plus [voided]), as a colored
/// pill — the exact same shape as `_ChangeOrderStatusBadge` in
/// `change_orders_screen.dart`, reused here for visual and behavioral
/// parity: draft (editable) / sent / approved / declined (all locked) /
/// voided (locked, closed-out). This is the only status concept this
/// screen has — the older, UI-only `EstimateStatus` enum
/// (`estimate_invoice_providers.dart`, notably its now-removed-here
/// `.signed` value) never corresponded to a real `job_estimates.status`
/// value and is NOT used anywhere in this file anymore, though
/// `invoice_screen.dart` and Job Detail still read it for unrelated
/// (pre-existing, untouched) invoice-generation/job-complete gating.
class _EstimateStatusBadge extends StatelessWidget {
  const _EstimateStatusBadge({required this.status, this.voided = false});

  final String status;
  final bool voided;

  @override
  Widget build(BuildContext context) {
    if (voided) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(20)),
        child: const Text(
          'Voided',
          style: TextStyle(color: AppColors.neutralGrey, fontSize: 12, fontWeight: FontWeight.w700),
        ),
      );
    }
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

/// Feature 1.4 — the collapsible "original dictation" section. Fetches the
/// verbatim transcript behind [dictationId] (see `dictationTranscriptProvider`
/// in `job_dictations_provider.dart`) so a technician can cross-check the
/// AI-parsed numbers against exactly what they said. Renders nothing if this
/// estimate has no source dictation on record.
class _OriginalDictationSection extends ConsumerWidget {
  const _OriginalDictationSection({required this.dictationId, required this.expanded, required this.onToggle});

  final String? dictationId;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dictationId = this.dictationId;
    if (dictationId == null) return const SizedBox.shrink();
    final transcriptAsync = ref.watch(dictationTranscriptProvider(dictationId));

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.neutralGreyLight.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.record_voice_over_rounded, size: 18, color: AppColors.neutralGrey),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Original dictation',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textDark),
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    color: AppColors.neutralGrey,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: transcriptAsync.when(
                loading: () => const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                error: (error, stackTrace) => const Text(
                  'Could not load the original dictation.',
                  style: TextStyle(fontSize: 12, color: AppColors.neutralGrey),
                ),
                data: (transcript) => Text(
                  (transcript != null && transcript.trim().isNotEmpty) ? transcript : 'No transcript found.',
                  style: const TextStyle(fontSize: 13, color: AppColors.textDark, height: 1.4),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The green check-mark "action succeeded" cue, shown briefly after a send
/// completes — extracted from the original inline animation (unchanged
/// visuals/timing) so both [_EstimateScreenState._buildDraftReview] and
/// [_EstimateScreenState._buildFinalized] share one definition.
class _ConfirmationCheck extends StatelessWidget {
  const _ConfirmationCheck();

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.check_circle_rounded, color: AppColors.primaryGreen, size: 52)
        .animate()
        .scale(begin: const Offset(0.5, 0.5), end: const Offset(1, 1), duration: 300.ms, curve: Curves.easeOutBack)
        .then(delay: 700.ms)
        .fadeOut(duration: 300.ms);
  }
}

class _LineItemRow extends StatelessWidget {
  const _LineItemRow({required this.item});

  final EstimateLineItem item;

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
