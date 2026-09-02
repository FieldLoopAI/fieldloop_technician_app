import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What kind of `job_estimates`/`change_orders` row a
/// [JobStatusNotification] is about — drives the wording in
/// [JobStatusNotification.bannerTitle]/[JobStatusNotification.spokenMessage].
enum JobStatusNotificationKind { changeOrder, estimate }

/// A one-shot notification that a customer remotely approved or declined a
/// change order or estimate — written by
/// `JobChangeOrdersController`/`JobEstimateController`'s realtime
/// subscriptions the moment they detect a `status` transition into
/// `'approved'`/`'declined'` (see each controller's
/// `_maybeNotifyStatusChange`), and consumed via `ref.listen` by whichever
/// screen for that job is open (`ChangeOrdersScreen`/`EstimateScreen`) to
/// show an in-app banner and speak it aloud with TTS.
class JobStatusNotification {
  const JobStatusNotification({required this.kind, required this.status, required this.summary});

  final JobStatusNotificationKind kind;

  /// The new status — always `'approved'` or `'declined'`; nothing else
  /// ever creates one of these (see the controllers' diff logic).
  final String status;

  /// A short human-readable label for what changed (e.g. a change order's
  /// description, or "the estimate") — may be empty.
  final String summary;

  bool get isApproved => status == 'approved';

  String get _noun => kind == JobStatusNotificationKind.changeOrder ? 'Change order' : 'Estimate';

  String get bannerTitle => isApproved ? '$_noun approved ✓' : '$_noun declined';

  String get spokenMessage {
    final verb = isApproved ? 'approved' : 'declined';
    final lowerNoun = kind == JobStatusNotificationKind.changeOrder ? 'the change order' : 'the estimate';
    return summary.trim().isEmpty
        ? 'Customer $verb $lowerNoun'
        : 'Customer $verb $lowerNoun: ${summary.trim()}';
  }
}

/// Per-job holder for the latest [JobStatusNotification] — `null` when
/// there's nothing new to show. Deliberately a plain [StateProvider], not
/// part of `jobChangeOrdersProvider`/`jobEstimateProvider`'s own
/// [AsyncValue] state: this is a transient, one-shot side-channel event
/// ("something just changed, tell the technician"), not persisted data
/// about a job, so it's cleared back to `null` immediately after a listener
/// consumes it — see `ChangeOrdersScreen`/`EstimateScreen`'s `ref.listen`
/// wiring, the only consumers.
final jobStatusNotificationProvider = StateProvider.family<JobStatusNotification?, String>((ref, jobId) => null);
