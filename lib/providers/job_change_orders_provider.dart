import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/change_order.dart';
import 'job_status_notifications_provider.dart';

/// All `change_orders` rows for a job — pending and approved alike (see
/// `ChangeOrdersScreen`, the sole reader). Reads go straight through the
/// technician's own authenticated Supabase session (RLS-scoped), same
/// pattern as `jobEstimateProvider` in `job_estimate_provider.dart` — no
/// Lambda needed for a plain read or for saving review edits ([saveEdits]).
final jobChangeOrdersProvider =
    StateNotifierProvider.family<JobChangeOrdersController, AsyncValue<List<ChangeOrder>>, String>(
      (ref, jobId) => JobChangeOrdersController(ref, jobId),
    );

class JobChangeOrdersController extends StateNotifier<AsyncValue<List<ChangeOrder>>> {
  JobChangeOrdersController(this.ref, this.jobId) : super(const AsyncLoading()) {
    _load();
    _subscribeRealtime();
  }

  final Ref ref;
  final String jobId;
  RealtimeChannel? _realtimeChannel;

  Future<void> _load() async {
    final result = await AsyncValue.guard(_fetchAll);
    if (!mounted) return;
    state = result;
  }

  /// Live updates for a customer's approval/decline — which happens outside
  /// the app entirely, on their phone via SMS reply (see
  /// `backend/functions/create-change-order`) — so the review screen
  /// doesn't need an app restart, or even a return-to-screen navigation, to
  /// pick up a status change. Best-effort: if Realtime replication isn't
  /// enabled for `change_orders` in the Supabase project, this channel just
  /// never fires and `ChangeOrdersScreen`'s refetch-on-return (RouteAware)
  /// is what keeps the data correct instead.
  ///
  /// Refetches the whole list rather than patching the payload's row in
  /// place — simpler and still cheap for a list scoped to one job, and
  /// avoids the payload's column casing/shape ever drifting from
  /// [ChangeOrder.fromJson].
  void _subscribeRealtime() {
    debugPrint('CHANGE ORDER: subscribing to realtime changes for job $jobId...');
    _realtimeChannel = Supabase.instance.client
        .channel('change_orders:job:$jobId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'change_orders',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'job_id', value: jobId),
          callback: (payload) {
            debugPrint('CHANGE ORDER: realtime ${payload.eventType} for job $jobId, refetching...');
            _maybeNotifyStatusChange(payload);
            _load();
          },
        )
        .subscribe();
  }

  /// Detects a customer's remote approve/decline (see
  /// `backend/functions/approve-change-order`) and, if that's what this
  /// event is, writes a [JobStatusNotification] for
  /// `ChangeOrdersScreen`'s `ref.listen` to pick up (banner + TTS).
  ///
  /// Deliberately diffs against this controller's own cached [state] (the
  /// row's status as of the *previous* fetch) rather than
  /// `payload.oldRecord`: Supabase Realtime only populates `oldRecord`'s
  /// non-key columns when the table has `REPLICA IDENTITY FULL` set, which
  /// isn't confirmed for `change_orders` — comparing against our own prior
  /// state works regardless of that Postgres-level setting. Only fires for
  /// an actual transition (never on the technician's own `saveEdits`/
  /// `voidChangeOrder` writes, which don't touch `status` at all, so
  /// `oldStatus == newStatus` and this is a no-op for those).
  void _maybeNotifyStatusChange(PostgresChangePayload payload) {
    if (payload.eventType != PostgresChangeEvent.update) return;
    final newRow = payload.newRecord;
    final id = newRow['id']?.toString();
    final newStatus = newRow['status'] as String?;
    if (id == null || (newStatus != 'approved' && newStatus != 'declined')) return;

    String? oldStatus;
    for (final co in state.valueOrNull ?? const <ChangeOrder>[]) {
      if (co.id == id) {
        oldStatus = co.status;
        break;
      }
    }
    if (oldStatus == null || oldStatus == newStatus) return;

    debugPrint('CHANGE ORDER: realtime detected $id transitioned $oldStatus -> $newStatus for job $jobId');
    ref.read(jobStatusNotificationProvider(jobId).notifier).state = JobStatusNotification(
      kind: JobStatusNotificationKind.changeOrder,
      status: newStatus!,
      summary: (newRow['description'] as String?) ?? '',
    );
  }

  @override
  void dispose() {
    final channel = _realtimeChannel;
    if (channel != null) Supabase.instance.client.removeChannel(channel);
    super.dispose();
  }

  Future<List<ChangeOrder>> _fetchAll() async {
    debugPrint('CHANGE ORDER: fetching all change_orders rows for job $jobId...');
    final rows = await Supabase.instance.client
        .from('change_orders')
        .select()
        .eq('job_id', jobId)
        .order('created_at', ascending: false);
    return rows.map((row) => ChangeOrder.fromJson(row)).toList();
  }

  /// Re-fetches from `change_orders` directly.
  Future<void> refresh() => _load();

  /// Saves a technician's review edits to one change order's description
  /// and/or amount straight to its `change_orders` row — RLS permits a
  /// direct update here, same as `JobEstimateController.saveLineItems`, but
  /// ONLY while the row is still `status = 'pending'`: the
  /// "technician updates own pending change orders" UPDATE policy rejects
  /// this call outright once a customer has approved or declined the row,
  /// independent of `ChangeOrdersScreen` only ever calling this for pending
  /// rows in the first place. Does NOT touch `status`: approval is a
  /// separate, customer-driven concept (see [ChangeOrder.isApproved]), not
  /// something a save here should imply.
  ///
  /// The customer's approval-request SMS already went out automatically at
  /// creation time (`backend/functions/create-change-order`), before any
  /// review happens here — there is no backend route to re-send a
  /// corrected message, so an edit that changes the amount materially
  /// needs a manual follow-up outside the app; see the note shown on each
  /// pending row in `ChangeOrdersScreen`.
  Future<void> saveEdits({
    required String changeOrderId,
    required String description,
    required double additionalAmount,
  }) async {
    debugPrint('CHANGE ORDER: saving edits for change order $changeOrderId (job $jobId)...');
    await Supabase.instance.client
        .from('change_orders')
        .update({'description': description, 'additional_amount': additionalAmount})
        .eq('id', changeOrderId);
    debugPrint('CHANGE ORDER: edits saved for change order $changeOrderId');
    if (!mounted) return;
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData([
      for (final co in current)
        if (co.id == changeOrderId)
          co.copyWith(description: description, additionalAmount: additionalAmount)
        else
          co,
    ]);
  }

  /// Voids an already-approved change order, closing it out as a historical
  /// record rather than editing it — see `ChangeOrdersScreen`'s "Void this
  /// change order" action, the only caller. Updates ONLY `voided_at` and
  /// `void_reason`; deliberately never touches `description` or
  /// `additional_amount` in this call, so a void can never masquerade as a
  /// price/scope edit.
  ///
  /// RLS backs this up independently of the UI only offering Void for
  /// approved, not-yet-voided rows: the "technician updates own pending
  /// change orders" policy permits an update while `status = 'pending'` OR
  /// (`status = 'approved'` AND `voided_at IS NULL`) — so a second void
  /// attempt on an already-voided row, or a void attempt on a 'declined'
  /// row, is rejected at the database level even if somehow triggered.
  Future<void> voidChangeOrder({required String changeOrderId, required String reason}) async {
    debugPrint('CHANGE ORDER: voiding change order $changeOrderId (job $jobId)...');
    final voidedAt = DateTime.now().toUtc();
    await Supabase.instance.client
        .from('change_orders')
        .update({'voided_at': voidedAt.toIso8601String(), 'void_reason': reason})
        .eq('id', changeOrderId);
    debugPrint('CHANGE ORDER: change order $changeOrderId voided');
    if (!mounted) return;
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData([
      for (final co in current)
        if (co.id == changeOrderId) co.copyWith(voidedAt: voidedAt, voidReason: reason) else co,
    ]);
  }
}
