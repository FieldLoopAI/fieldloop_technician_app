import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/change_order.dart';
import '../providers/global_voice_service_provider.dart';
import '../providers/job_change_orders_provider.dart';
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
import '../widgets/approval_status_pill.dart';
import '../widgets/editable_line_item_row.dart';
import '../widgets/empty_state_actions.dart';
import '../widgets/primary_button.dart';
import '../widgets/status_notification_banner.dart';
import '../widgets/voice_phase_indicator.dart';
import 'manual_change_order_screen.dart';
import 'voice_command_registrar_mixin.dart';

/// Review screen for every `change_orders` row on a job — pending (awaiting
/// the customer's SMS approval), approved, and declined alike — reached
/// from Job Detail's Change Orders tab via "View Change Orders" the same
/// way Estimate's tab reaches [EstimateScreen] via "View Full Estimate".
///
/// Only a 'pending' row's description and amount are live editable fields
/// (see [EditableLineItemRow], the exact widget the Estimate screen's line
/// items use). Once a customer has approved or declined a row, it renders
/// as plain read-only text ([_ReadOnlyLineItemRow]) — genuinely
/// non-editable, not merely a disabled `TextField` — and its only action is
/// starting a brand-new change order (the manual form, for now); an
/// approved price or scope is never edited in place. The database backs
/// this up independently: the `change_orders` RLS UPDATE policy only
/// permits a technician to update a row while it's still `status =
/// 'pending'`.
///
/// Unlike the Estimate screen, there is no single array of line items to
/// save as a batch — each change order is its own `change_orders` row (see
/// `ChangeOrder`'s doc comment), so each pending row here saves
/// independently via [JobChangeOrdersController.saveEdits].
///
/// A pending row's save button reads "Looks good, send to customer" to
/// match the Estimate screen's button, but it does not actually trigger a
/// new SMS: the customer's approval-request text already went out
/// automatically when the row was created (see
/// `backend/functions/create-change-order`), before any review could
/// happen. There's no backend endpoint to re-send a corrected message, so
/// the button just saves the edit and the row shows a note that a
/// materially different amount needs a manual follow-up outside the app.
class ChangeOrdersScreen extends ConsumerStatefulWidget {
  const ChangeOrdersScreen({super.key, required this.jobId});

  final String jobId;

  @override
  ConsumerState<ChangeOrdersScreen> createState() => _ChangeOrdersScreenState();
}

class _ChangeOrdersScreenState extends ConsumerState<ChangeOrdersScreen>
    with SafeRefDisposal<ChangeOrdersScreen>, VoiceCommandRegistrarMixin<ChangeOrdersScreen> {
  // Keyed by change_orders.id — re-seeded only for rows not already present
  // (see _seedEditableItems), so a rebuild triggered by something unrelated
  // never clobbers text a technician is mid-editing.
  final Map<String, EditableLineItem> _editableById = {};

  // Keyed by change_orders.id — presence of an entry means that row's
  // "Void this change order" inline expansion is currently open (see
  // _buildChangeOrderCard). Deliberately in-card state, not a dialog/route:
  // an AlertDialog here used to race the realtime subscription's own
  // rebuilds during the dialog's pop/teardown, crashing with a
  // `'_dependents.isEmpty'` assertion — an in-place expansion has no
  // Overlay/route of its own to tear down, so there's nothing left to race.
  final Map<String, TextEditingController> _voidReasonControllers = {};

  String? _savingId;
  String? _confirmedId;
  String? _errorId;
  String? _errorMessage;

  // Banner+TTS for a customer's remote approve/decline — the notification
  // itself is written by `JobChangeOrdersController`'s realtime
  // subscription (see `jobStatusNotificationProvider`'s doc comment);
  // captured into local state here (via `ref.listen` in [build]) purely to
  // control how long the banner stays visible, same "consume once, show
  // briefly" shape as `_confirmedId` above.
  JobStatusNotification? _activeNotification;

  @override
  void dispose() {
    for (final item in _editableById.values) {
      item.dispose();
    }
    for (final controller in _voidReasonControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  List<VoiceCommand> buildVoiceCommands() => jobLifecycleVoiceCommands(ref, widget.jobId);

  void _addChangeOrderManually() => Navigator.of(
    context,
  ).push(FadeSlidePageRoute(builder: (_) => ManualChangeOrderScreen(jobId: widget.jobId)));

  // Refetch-on-focus fallback for a customer's approval/decline, which
  // happens outside the app on their phone (see
  // `JobChangeOrdersController._subscribeRealtime`'s doc comment for why
  // Realtime alone isn't relied on). `VoiceCommandRegistrarMixin` already
  // implements RouteAware for the voice-command registry — these overrides
  // add a second effect on the same callbacks (via `super`, so the voice
  // registration still happens) rather than fighting over one RouteAware
  // subscription: didPush covers first opening this screen fresh (the
  // family provider may already exist with stale data from an earlier
  // visit this session, since it isn't autoDispose), didPopNext covers
  // returning to it after a covering route (e.g. Photo Capture) pops.
  //
  // Deferred to a post-frame callback, same reasoning as
  // VoiceCommandRegistrarMixin._registerCommands: didPush/didPopNext can
  // fire while this screen is still mid-build (synchronously from
  // didChangeDependencies), and a provider write at that point is unsafe
  // regardless of `mounted` — see that method's doc comment for the
  // confirmed hazard this defers around.
  void _refreshChangeOrders() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      safeWrite(() => ref.read(jobChangeOrdersProvider(widget.jobId).notifier).refresh());
    });
  }

  @override
  void didPush() {
    super.didPush();
    _refreshChangeOrders();
  }

  @override
  void didPopNext() {
    super.didPopNext();
    _refreshChangeOrders();
  }

  // Only 'pending' change orders get editable state at all — once a
  // customer has approved (or declined) a change order, its description and
  // amount become permanently read-only (see `_buildChangeOrderCard`), so
  // there's nothing here for those rows to edit. A row that transitions out
  // of 'pending' (e.g. via the realtime subscription picking up a customer's
  // approval) has its editable state disposed and dropped on the next seed.
  void _seedEditableItems(List<ChangeOrder> changeOrders) {
    for (final co in changeOrders) {
      if (!co.isPending) continue;
      _editableById.putIfAbsent(
        co.id,
        () => EditableLineItem(description: co.description, amount: co.additionalAmount),
      );
    }
    final staleIds = _editableById.keys
        .where((id) => !changeOrders.any((co) => co.id == id && co.isPending))
        .toList();
    for (final id in staleIds) {
      _editableById.remove(id)?.dispose();
    }

    // Same pruning for the void-reason expansion: it's only ever valid for
    // an approved, not-yet-voided row (see _buildChangeOrderCard), so drop
    // it the moment a row it's open for is voided (most commonly right
    // after _confirmVoid succeeds) or otherwise leaves that state.
    final staleVoidIds = _voidReasonControllers.keys
        .where((id) => !changeOrders.any((co) => co.id == id && co.isApproved && !co.isVoided))
        .toList();
    for (final id in staleVoidIds) {
      _voidReasonControllers.remove(id)?.dispose();
    }
  }

  // Shared save/void-in-flight bookkeeping — both actions are a single
  // Supabase update on one row followed by a brief "done" confirmation, so
  // they share the same _savingId/_confirmedId/_errorId/_errorMessage state
  // rather than duplicating this dance per action.
  Future<void> _runCardAction(String changeOrderId, Future<void> Function() action) async {
    setState(() {
      _savingId = changeOrderId;
      _errorId = null;
      _errorMessage = null;
    });
    try {
      await action();
      if (!mounted) return;
      setState(() {
        _savingId = null;
        _confirmedId = changeOrderId;
      });
      await Future.delayed(const Duration(milliseconds: 1600));
      if (mounted && _confirmedId == changeOrderId) setState(() => _confirmedId = null);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _savingId = null;
        _errorId = changeOrderId;
        _errorMessage = e is StateError ? e.message : e.toString();
      });
    }
  }

  Future<void> _saveChangeOrder(ChangeOrder changeOrder) {
    final editable = _editableById[changeOrder.id];
    if (editable == null) return Future.value();
    final description = editable.descriptionController.text.trim();
    final amount = editable.amount;
    return _runCardAction(
      changeOrder.id,
      () => ref
          .read(jobChangeOrdersProvider(widget.jobId).notifier)
          .saveEdits(changeOrderId: changeOrder.id, description: description, additionalAmount: amount),
    );
  }

  Future<void> _voidChangeOrder(ChangeOrder changeOrder, String reason) {
    return _runCardAction(
      changeOrder.id,
      () => ref
          .read(jobChangeOrdersProvider(widget.jobId).notifier)
          .voidChangeOrder(changeOrderId: changeOrder.id, reason: reason),
    );
  }

  /// Opens the void-reason expansion on [changeOrder]'s own card — no
  /// dialog, no route, nothing with a teardown to race.
  void _startVoiding(String changeOrderId) {
    setState(() {
      _voidReasonControllers.putIfAbsent(changeOrderId, () => TextEditingController());
    });
  }

  /// Collapses the expansion without voiding anything — purely local
  /// widget state, so there is nothing here to await or race.
  void _cancelVoiding(String changeOrderId) {
    setState(() {
      _voidReasonControllers.remove(changeOrderId)?.dispose();
    });
  }

  /// Runs the same [_voidChangeOrder] Supabase write as before — directly,
  /// synchronously, no post-frame-callback deferral. That deferral existed
  /// solely to outlast an AlertDialog's pop/teardown; with the expansion
  /// living in this card's own layout instead, there's no dialog route in
  /// flight for a realtime-triggered rebuild to race against, so nothing
  /// here needs to wait for a frame to settle. The expansion itself closes
  /// as a side effect of the row becoming [ChangeOrder.isVoided] (see
  /// _seedEditableItems' pruning), not by anything explicit in this method.
  Future<void> _confirmVoid(ChangeOrder changeOrder) {
    final controller = _voidReasonControllers[changeOrder.id];
    if (controller == null) return Future.value();
    final reason = controller.text.trim();
    if (reason.isEmpty) return Future.value();
    return _voidChangeOrder(changeOrder, reason);
  }

  /// Consumes a [JobStatusNotification] the moment
  /// `JobChangeOrdersController`'s realtime subscription writes one:
  /// speaks it via TTS, shows it as an in-card banner for a few seconds,
  /// then clears both the local banner state and the provider itself (so a
  /// rebuild — or remounting this screen later — never replays it). See
  /// `jobStatusNotificationProvider`'s doc comment for why this lives on a
  /// separate one-shot provider rather than the change-orders list state.
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
    final changeOrdersAsync = ref.watch(jobChangeOrdersProvider(widget.jobId));
    final estimateAsync = ref.watch(jobEstimateProvider(widget.jobId));
    ref.listen<JobStatusNotification?>(
      jobStatusNotificationProvider(widget.jobId),
      (previous, next) => _handleStatusNotification(next),
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(job != null ? 'Change Orders · ${job.jobIdPublic}' : 'Change Orders'),
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

            return changeOrdersAsync.when(
              loading: () => const Center(child: CircularProgressIndicator(color: AppColors.primaryGreen)),
              error: (error, stackTrace) => _buildErrorState(error, horizontalPadding),
              data: (changeOrders) {
                _seedEditableItems(changeOrders);
                final pending = changeOrders.where((co) => co.isPending).toList();
                final approved = changeOrders.where((co) => co.isApproved).toList();
                final declined = changeOrders.where((co) => co.isDeclined).toList();
                final other = changeOrders
                    .where((co) => !co.isPending && !co.isApproved && !co.isDeclined)
                    .toList();

                final estimateTotal = estimateAsync.valueOrNull?.totalAmount ?? 0;
                // A voided change order is still technically status ==
                // 'approved' (voiding doesn't change status — see
                // JobChangeOrdersController.voidChangeOrder), so it still
                // shows in the "Approved" section above, but it must never
                // count toward the committed total: only a still-active
                // approval (approved AND not voided) counts.
                final approvedTotal = approved
                    .where((co) => !co.isVoided)
                    .fold<double>(0, (sum, co) => sum + co.additionalAmount);
                final runningTotal = estimateTotal + approvedTotal;
                // Same active-job gate Job Detail uses for its voice/tap entry
                // points — a finished job viewed from History is read-only.
                final editable = activeJobStatuses.contains(ref.watch(jobRuntimeProvider(widget.jobId)).status);

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
                        'Change Orders',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textDark),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Additional work found on-site, beyond the original estimate.',
                        style: TextStyle(fontSize: 13, color: AppColors.neutralGrey),
                      ),
                      const SizedBox(height: 20),
                      _RunningTotalCard(estimateTotal: estimateTotal, approvedTotal: approvedTotal, runningTotal: runningTotal),
                      const SizedBox(height: 24),
                      if (changeOrders.isEmpty)
                        _card(
                          EmptyStateActions(
                            icon: Icons.post_add_rounded,
                            title: 'No change orders yet',
                            hint: editable
                                ? 'Add extra work found on site. The customer is texted to approve it before '
                                    'it counts toward the total.'
                                : 'No change orders were added to this job.',
                            actionLabel: 'Add Change Order',
                            onAction: editable ? _addChangeOrderManually : null,
                          ),
                        )
                      else ...[
                        if (editable) ...[
                          FilledButton.icon(
                            onPressed: _addChangeOrderManually,
                            icon: const Icon(Icons.add_rounded, size: 20),
                            label: const Text('Add Change Order'),
                            style: primaryActionButtonStyle,
                          ),
                          const SizedBox(height: 20),
                        ],
                        if (pending.isNotEmpty) ...[
                          _sectionLabel('Awaiting customer approval', AppColors.amber),
                          const SizedBox(height: 10),
                          for (final co in pending) _buildChangeOrderCard(co),
                          const SizedBox(height: 16),
                        ],
                        if (approved.isNotEmpty) ...[
                          _sectionLabel('Approved', AppColors.primaryGreenDark),
                          const SizedBox(height: 10),
                          for (final co in approved) _buildChangeOrderCard(co),
                          const SizedBox(height: 16),
                        ],
                        if (declined.isNotEmpty) ...[
                          _sectionLabel('Declined', AppColors.neutralGrey),
                          const SizedBox(height: 10),
                          for (final co in declined) _buildChangeOrderCard(co),
                          const SizedBox(height: 16),
                        ],
                        if (other.isNotEmpty) ...[
                          _sectionLabel('Other', AppColors.neutralGrey),
                          const SizedBox(height: 10),
                          for (final co in other) _buildChangeOrderCard(co),
                        ],
                      ],
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildErrorState(Object error, double horizontalPadding) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        child: _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                "Couldn't load change orders",
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textDark),
              ),
              const SizedBox(height: 4),
              Text('$error', style: const TextStyle(fontSize: 12, color: AppColors.neutralGrey)),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => ref.read(jobChangeOrdersProvider(widget.jobId).notifier).refresh(),
                  child: const Text('Retry'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String label, Color color) {
    return Row(
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.3)),
      ],
    );
  }

  Widget _buildChangeOrderCard(ChangeOrder changeOrder) {
    final isPending = changeOrder.isPending;
    final isVoided = changeOrder.isVoided;
    final isVoiding = _voidReasonControllers.containsKey(changeOrder.id);
    // Approved/declined rows never get editable state (see
    // _seedEditableItems) — only pending rows need it, and only pending
    // rows read it below.
    final editable = isPending ? _editableById[changeOrder.id] : null;
    if (isPending && editable == null) return const SizedBox.shrink();

    final isSaving = _savingId == changeOrder.id;
    final showConfirm = _confirmedId == changeOrder.id;
    final showError = _errorId == changeOrder.id;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ApprovalStatusPill(status: changeOrder.status, voided: isVoided),
                if (changeOrder.isApproved && changeOrder.approvedAt != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    _formatTimestamp(changeOrder.approvedAt!),
                    style: const TextStyle(fontSize: 11, color: AppColors.neutralGrey),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            // Editing is only ever available for a 'pending' change order —
            // once a customer has approved or declined it, the description
            // and amount render as plain text with no TextField at all (not
            // just a disabled one), so there is no code path left that can
            // write to an already-decided row. See point 3/4 in the task:
            // a genuine post-approval change must be a brand-new change
            // order, and the database's RLS UPDATE policy backs this up
            // independently of the UI.
            if (isPending)
              EditableLineItemRow(item: editable!, onChanged: () => setState(() {}))
            else
              _ReadOnlyLineItemRow(description: changeOrder.description, amount: changeOrder.additionalAmount),
            if (isPending) ...[
              const SizedBox(height: 6),
              const Text(
                'A text already went to the customer when this change order was created. If you '
                'change the amount here, follow up with a corrected message separately.',
                style: TextStyle(fontSize: 11, color: AppColors.neutralGrey, fontStyle: FontStyle.italic),
              ),
            ],
            if (isVoided) ...[
              const SizedBox(height: 6),
              Text(
                'Void reason: ${changeOrder.voidReason ?? '—'}',
                style: const TextStyle(fontSize: 12, color: AppColors.neutralGrey, fontStyle: FontStyle.italic),
              ),
            ],
            const SizedBox(height: 12),
            if (showError) ...[
              Text(
                _errorMessage ?? 'Something went wrong',
                style: const TextStyle(color: AppColors.statusRedText, fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
            ],
            if (showConfirm) ...[
              Text(
                isVoided ? 'Voided' : 'Saved',
                style: const TextStyle(color: AppColors.primaryGreenDark, fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const SizedBox(height: 8),
            ],
            // Action available per state:
            //  - pending: save the edit and (re-)send for approval.
            //  - approved, not voided: void it, or start a new change
            //    order — two distinct actions, never an in-place edit.
            //  - declined: only a new change order (nothing to void).
            //  - voided: a closed historical record — no actions at all.
            if (isPending)
              PrimaryButton(
                label: 'Looks good, send to customer',
                icon: Icons.check_circle_outline_rounded,
                isLoading: isSaving,
                onPressed: () => _saveChangeOrder(changeOrder),
              )
            else if (!isVoided)
              isVoiding
                  ? _buildVoidExpansion(changeOrder)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (changeOrder.isApproved) ...[
                          TextButton(
                            onPressed: isSaving ? null : () => _startVoiding(changeOrder.id),
                            style: TextButton.styleFrom(foregroundColor: AppColors.statusRedText),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.block_rounded, size: 16),
                                SizedBox(width: 6),
                                Text('Void this change order'),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                        ],
                        TextButton(
                          // Was the legacy dictation flow; manual entry until voice
                          // dictation is rebuilt on Gemini Live.
                          onPressed: _addChangeOrderManually,
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_circle_outline_rounded, size: 16),
                              SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'Need to change this? Create a new change order',
                                  textAlign: TextAlign.right,
                                  softWrap: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
          ],
        ),
      ),
    );
  }

  /// The in-card void-reason expansion — replaces the "Void this change
  /// order" button in place for whichever card [_startVoiding] was called
  /// on. Deliberately just more of this same card's own `Column`, not an
  /// overlay/route of any kind (see [_voidReasonControllers]'s doc
  /// comment for why).
  Widget _buildVoidExpansion(ChangeOrder changeOrder) {
    final controller = _voidReasonControllers[changeOrder.id];
    if (controller == null) return const SizedBox.shrink();
    final isSaving = _savingId == changeOrder.id;
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
            'afterward. If more work is needed, create a brand-new change order instead.',
            style: TextStyle(fontSize: 12, color: AppColors.neutralGrey),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            autofocus: true,
            enabled: !isSaving,
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
              TextButton(
                onPressed: isSaving ? null : () => _cancelVoiding(changeOrder.id),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: (isSaving || !canConfirm) ? null : () => _confirmVoid(changeOrder),
                style: TextButton.styleFrom(foregroundColor: AppColors.statusRedText),
                child: isSaving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Confirm Void'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatTimestamp(DateTime dateTime) {
    final local = dateTime.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = local.hour < 12 ? 'AM' : 'PM';
    return '$month/$day/${local.year} $hour12:$minute $period';
  }
}

/// Plain, non-editable rendering of a change order's description and
/// amount — deliberately NOT built from [EditableLineItemRow] or any
/// `TextField`, so an approved or declined row has no editable widget in
/// its tree at all to disable, grey out, or otherwise bypass. Once a
/// customer has made a decision on a change order, the only way to change
/// its price or scope is a brand-new change order (see the "Create a new
/// change order" action next to this row).
class _ReadOnlyLineItemRow extends StatelessWidget {
  const _ReadOnlyLineItemRow({required this.description, required this.amount});

  final String description;
  final double amount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              description,
              style: const TextStyle(fontSize: 14, color: AppColors.textDark),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '\$${amount.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textDark),
          ),
        ],
      ),
    );
  }
}

/// Estimate total + sum of `status == 'approved'` change orders — the job's
/// current committed price. Pending change orders are deliberately excluded
/// (shown separately, in their own "Awaiting customer approval" section)
/// since an unapproved change order shouldn't affect what the job is
/// actually on the hook for yet.
class _RunningTotalCard extends StatelessWidget {
  const _RunningTotalCard({required this.estimateTotal, required this.approvedTotal, required this.runningTotal});

  final double estimateTotal;
  final double approvedTotal;
  final double runningTotal;

  @override
  Widget build(BuildContext context) {
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _totalLine('Estimate total', estimateTotal),
          const SizedBox(height: 6),
          _totalLine('Approved additional work', approvedTotal),
          const Divider(height: 24),
          LabelValueRow(
            label: const Text(
              'Running total',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textDark),
            ),
            value: Text(
              '\$${runningTotal.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.primaryGreenDark),
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalLine(String label, double amount) {
    return LabelValueRow(
      label: Text(label, style: const TextStyle(fontSize: 13, color: AppColors.neutralGrey)),
      value: Text(
        '\$${amount.toStringAsFixed(2)}',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textDark),
      ),
    );
  }
}

/// The shared white card container, matching `_estimateCard` in
/// `estimate_screen.dart` (same shadow/radius/padding) for visual
/// consistency between the two review screens.
Widget _card(Widget child) {
  return Container(
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: AppDecorations.card(),
    child: child,
  );
}
