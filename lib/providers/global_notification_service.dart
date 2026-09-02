import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_provider.dart';
import 'currently_viewed_job_provider.dart';
import 'jobs_provider.dart';
import 'local_notifications_service.dart';

/// The ONE app-wide realtime-notification listener for the entire app.
///
/// Same architecture as `GlobalVoiceService`
/// (`global_voice_service_provider.dart`) and `OfflineUploadQueueService`
/// (`offline_upload_queue_provider.dart`): created once, above the
/// navigation/router level (`RootShell` starts it, right after login —
/// same call site as those two), and kept alive for the whole authenticated
/// session — NOT tied to whether any particular job's screen happens to be
/// open. `stopForLogout` (called from Profile, same as the other two) is
/// the only thing that tears it down.
///
/// Unlike `GlobalVoiceService`, nothing in the UI watches this service's
/// state reactively (there's no "voice transcript" equivalent to show), so
/// this is a plain [Provider] returning one long-lived instance rather than
/// a [StateNotifierProvider] — same reasoning as `LocalNotificationsService`
/// being a plain singleton instead of a provider.
///
/// Opens three realtime subscriptions, each scoped to the signed-in
/// technician: a new `jobs` row assigned to them, and a `change_orders`/
/// `job_estimates` row of theirs transitioning to `'approved'`/`'declined'`
/// (a customer's remote decision via SMS/web link — see
/// `JobChangeOrdersController`/`JobEstimateController`'s own per-job realtime
/// subscriptions in `job_change_orders_provider.dart`/
/// `job_estimate_provider.dart`, which cover the SAME events but only show
/// an in-app banner + TTS, and only while that job's Estimate/Change Orders
/// screen happens to be open). This service is what makes those events
/// visible from anywhere — Home, History, a different job, or the app
/// backgrounded — via a real system notification instead.
final globalNotificationServiceProvider = Provider<GlobalNotificationService>((ref) {
  return GlobalNotificationService(ref);
});

class GlobalNotificationService {
  GlobalNotificationService(this._ref);

  final Ref _ref;
  bool _started = false;

  RealtimeChannel? _jobsChannel;
  RealtimeChannel? _changeOrdersChannel;
  RealtimeChannel? _estimatesChannel;

  // Local "what did we last see" caches, seeded from a one-time fetch in
  // [start] and kept current by every realtime event after that — the same
  // diff-against-our-own-prior-state approach as
  // `JobChangeOrdersController`/`JobEstimateController._maybeNotifyStatusChange`
  // (see those methods' doc comments for why: `payload.oldRecord` needs
  // `REPLICA IDENTITY FULL`, which isn't confirmed for these tables). Without
  // this, an unrelated update to an already-approved row — e.g. voiding it,
  // which never touches `status` — would still arrive as an UPDATE event and
  // re-fire a stale "approved"/"declined" notification.
  final Map<String, String> _changeOrderStatus = {};
  final Map<String, String> _estimateStatus = {};

  /// Idempotent — safe to call more than once, only the first call does
  /// anything. Called exactly once, from `RootShell`, the same place
  /// `GlobalVoiceService.initialize()`/`OfflineUploadQueueService.start()`
  /// are called.
  Future<void> start() async {
    if (_started) return;
    final technician = _ref.read(authControllerProvider).value;
    if (technician == null) {
      debugPrint('NOTIFICATIONS: start() called with no signed-in technician, not starting');
      return;
    }
    _started = true;
    debugPrint('NOTIFICATIONS: starting global notification service for technician ${technician.id}');

    // The plugin itself is already initialized from main() before login —
    // this is a no-op guard, not a real dependency on ordering.
    await LocalNotificationsService.instance.initialize();

    await Future.wait([
      _seedChangeOrderStatuses(technician.id),
      _seedEstimateStatuses(technician.id),
    ]);

    _subscribeJobs(technician.id);
    _subscribeChangeOrders(technician.id);
    _subscribeEstimates(technician.id);
  }

  Future<void> stopForLogout() async {
    if (!_started) return;
    debugPrint('NOTIFICATIONS: stopping for logout');
    _started = false;
    final client = Supabase.instance.client;
    final channels = [_jobsChannel, _changeOrdersChannel, _estimatesChannel];
    _jobsChannel = null;
    _changeOrdersChannel = null;
    _estimatesChannel = null;
    for (final channel in channels) {
      if (channel != null) await client.removeChannel(channel);
    }
    _changeOrderStatus.clear();
    _estimateStatus.clear();
  }

  Future<void> _seedChangeOrderStatuses(String technicianId) async {
    final rows = await Supabase.instance.client
        .from('change_orders')
        .select('id, status')
        .eq('technician_id', technicianId);
    for (final row in rows) {
      final id = row['id']?.toString();
      final status = row['status'] as String?;
      if (id != null && status != null) _changeOrderStatus[id] = status;
    }
    debugPrint('NOTIFICATIONS: seeded ${_changeOrderStatus.length} change_order status(es) for technician $technicianId');
  }

  Future<void> _seedEstimateStatuses(String technicianId) async {
    final rows = await Supabase.instance.client
        .from('job_estimates')
        .select('id, status')
        .eq('technician_id', technicianId);
    for (final row in rows) {
      final id = row['id']?.toString();
      final status = row['status'] as String?;
      if (id != null && status != null) _estimateStatus[id] = status;
    }
    debugPrint('NOTIFICATIONS: seeded ${_estimateStatus.length} job_estimate status(es) for technician $technicianId');
  }

  void _subscribeJobs(String technicianId) {
    debugPrint('NOTIFICATIONS: subscribing to jobs realtime (lead_technician_id=$technicianId, INSERT)...');
    _jobsChannel = Supabase.instance.client
        .channel('notifications:jobs:$technicianId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'jobs',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'lead_technician_id',
            value: technicianId,
          ),
          callback: _onJobInserted,
        )
        .subscribe();
  }

  void _subscribeChangeOrders(String technicianId) {
    debugPrint('NOTIFICATIONS: subscribing to change_orders realtime (technician_id=$technicianId, UPDATE)...');
    _changeOrdersChannel = Supabase.instance.client
        .channel('notifications:change_orders:$technicianId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'change_orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'technician_id',
            value: technicianId,
          ),
          callback: _onChangeOrderUpdated,
        )
        .subscribe();
  }

  void _subscribeEstimates(String technicianId) {
    debugPrint('NOTIFICATIONS: subscribing to job_estimates realtime (technician_id=$technicianId, UPDATE)...');
    _estimatesChannel = Supabase.instance.client
        .channel('notifications:job_estimates:$technicianId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'job_estimates',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'technician_id',
            value: technicianId,
          ),
          callback: _onEstimateUpdated,
        )
        .subscribe();
  }

  void _onJobInserted(PostgresChangePayload payload) {
    debugPrint('NOTIFICATIONS: jobs INSERT callback fired, payload: ${payload.newRecord}');
    final row = payload.newRecord;
    final jobId = row['id']?.toString();
    if (jobId == null) return;
    final address = (row['service_address'] as String?)?.trim();

    // So `jobByIdProvider`/`JobDetailScreen` already have this job by the
    // time the technician taps the notification — Home watches this
    // provider (it's kept mounted the whole session via RootShell's
    // IndexedStack), so invalidating refetches immediately rather than
    // waiting for a manual pull-to-refresh.
    _ref.invalidate(todaysJobsQueryProvider);

    _maybeNotify(jobId: jobId, title: 'New job assigned — ${address?.isNotEmpty == true ? address : 'a new job'}');
  }

  void _onChangeOrderUpdated(PostgresChangePayload payload) {
    debugPrint('NOTIFICATIONS: change_orders realtime UPDATE fired');
    final row = payload.newRecord;
    final id = row['id']?.toString();
    final newStatus = row['status'] as String?;
    if (id == null || newStatus == null) return;

    final oldStatus = _changeOrderStatus[id];
    _changeOrderStatus[id] = newStatus;
    if (oldStatus == newStatus) return;
    if (newStatus != 'approved' && newStatus != 'declined') return;

    final jobId = row['job_id']?.toString();
    if (jobId == null) return;

    debugPrint('NOTIFICATIONS: change order $id transitioned $oldStatus -> $newStatus (job $jobId)');
    final title = newStatus == 'approved'
        ? 'Change order approved — \$${_formatAmount(row['additional_amount'])}'
        : 'Change order declined';
    _maybeNotify(jobId: jobId, title: title);
  }

  void _onEstimateUpdated(PostgresChangePayload payload) {
    debugPrint('NOTIFICATIONS: job_estimates realtime UPDATE fired');
    final row = payload.newRecord;
    final id = row['id']?.toString();
    final newStatus = row['status'] as String?;
    if (id == null || newStatus == null) return;

    final oldStatus = _estimateStatus[id];
    _estimateStatus[id] = newStatus;
    if (oldStatus == newStatus) return;
    if (newStatus != 'approved' && newStatus != 'declined') return;

    final jobId = row['job_id']?.toString();
    if (jobId == null) return;

    debugPrint('NOTIFICATIONS: estimate $id transitioned $oldStatus -> $newStatus (job $jobId)');
    if (newStatus == 'approved') {
      _maybeNotify(jobId: jobId, title: 'Estimate approved — \$${_formatAmount(row['total_amount'])}');
    } else {
      unawaited(_notifyEstimateDeclined(jobId));
    }
  }

  Future<void> _notifyEstimateDeclined(String jobId) async {
    final label = await _jobLabel(jobId);
    _maybeNotify(jobId: jobId, title: 'Estimate declined — $label');
  }

  /// Looks up a job's public id (falling back to its address) for the
  /// "Estimate declined" wording — tries the already-cached job list first
  /// (covers the common case for free, no network round trip) and only
  /// queries `jobs` directly if it's a job this technician hasn't loaded
  /// into that cache this session.
  Future<String> _jobLabel(String jobId) async {
    final cached = _ref.read(jobByIdProvider(jobId));
    if (cached != null) {
      return cached.jobIdPublic != 'Not provided' ? cached.jobIdPublic : cached.serviceAddress;
    }
    debugPrint('NOTIFICATIONS: job $jobId not cached, querying jobs table for its label...');
    final row = await Supabase.instance.client
        .from('jobs')
        .select('job_id_public, service_address')
        .eq('id', jobId)
        .maybeSingle();
    if (row == null) return jobId;
    final publicId = row['job_id_public'] as String?;
    if (publicId != null && publicId.isNotEmpty) return publicId;
    return (row['service_address'] as String?) ?? jobId;
  }

  /// Shows a system notification for [jobId] UNLESS the technician is
  /// already looking at that exact job right now — see
  /// `currentlyViewedJobIdProvider`'s doc comment for why: the existing
  /// in-app banner + TTS on Estimate/Change Orders already covers that case,
  /// so a system notification on top of it would be a duplicate.
  void _maybeNotify({required String jobId, required String title}) {
    final viewingJobId = _ref.read(currentlyViewedJobIdProvider);
    if (viewingJobId == jobId) {
      debugPrint(
        'NOTIFICATIONS: suppressing system notification for job $jobId — '
        'technician is already viewing it, the in-app banner covers this',
      );
      return;
    }
    unawaited(LocalNotificationsService.instance.show(title: title, jobId: jobId));
  }
}

String _formatAmount(dynamic raw) {
  double value;
  if (raw is num) {
    value = raw.toDouble();
  } else if (raw is String) {
    value = double.tryParse(raw) ?? 0;
  } else {
    value = 0;
  }
  return value.toStringAsFixed(2);
}
