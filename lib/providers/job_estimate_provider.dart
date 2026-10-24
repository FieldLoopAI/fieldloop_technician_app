import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../models/job_estimate.dart';
import '../services/server_error_message.dart';
import 'job_status_notifications_provider.dart';
import 'payment_lock.dart';

/// The current, most-recent structured estimate for a job. Reads go
/// straight to `job_estimates` through the technician's own authenticated
/// Supabase session (RLS-scoped, same pattern as `job_dictations` — see
/// `job_dictations_provider.dart` — no Lambda needed for a plain read).
/// [JobEstimateController.parseDictation] is the one WRITE path, which does
/// need the `/estimates/parse` Lambda (it calls Groq and writes via a
/// service-role key — see `backend/functions/parse-estimate-dictation`).
/// Both live on the same controller/[AsyncValue] so the Estimate screen sees
/// one continuous transition — existing estimate (or none) -> parsing the
/// new dictation -> the new estimate landing — instead of juggling two
/// separate providers that could disagree about what's "current".
/// True while [JobEstimateController.parseDictation] runs for the job, so
/// the Estimate screen's loading card only says "Parsing your dictated
/// estimate…" when a dictation is actually being parsed.
final estimateParsingProvider = StateProvider.family<bool, String>((ref, jobId) => false);

final jobEstimateProvider =
    StateNotifierProvider.family<JobEstimateController, AsyncValue<JobEstimate?>, String>(
      (ref, jobId) => JobEstimateController(ref, jobId),
    );

class JobEstimateController extends StateNotifier<AsyncValue<JobEstimate?>> {
  JobEstimateController(this.ref, this.jobId) : super(const AsyncLoading()) {
    _load();
    _subscribeRealtime();
  }

  final Ref ref;
  final String jobId;
  RealtimeChannel? _realtimeChannel;

  Future<void> _load() async {
    final result = await AsyncValue.guard(_fetchLatest);
    if (!mounted) return;
    state = result;
  }

  /// Live updates for a customer's approval/decline — which happens outside
  /// the app entirely, on their phone via the SMS link (see
  /// `backend/functions/approve-estimate`) — same pattern, same reasoning,
  /// as `JobChangeOrdersController._subscribeRealtime` in
  /// `job_change_orders_provider.dart`: best-effort (a silent no-op if
  /// Realtime replication isn't enabled for `job_estimates`), and refetches
  /// the whole row rather than patching the payload in place to avoid ever
  /// drifting from [JobEstimate.fromJson]'s column handling.
  void _subscribeRealtime() {
    debugPrint('ESTIMATE: subscribing to realtime changes for job $jobId...');
    _realtimeChannel = Supabase.instance.client
        .channel('job_estimates:job:$jobId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'job_estimates',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'job_id', value: jobId),
          callback: (payload) {
            debugPrint('ESTIMATE: realtime ${payload.eventType} for job $jobId, refetching...');
            _maybeNotifyStatusChange(payload);
            _load();
          },
        )
        .subscribe();
  }

  /// Detects a customer's remote approve/decline via the SMS link (see
  /// `backend/functions/approve-estimate`) and, if that's what this event
  /// is, writes a [JobStatusNotification] for `EstimateScreen`'s
  /// `ref.listen` to pick up (banner + TTS) — same reasoning, same
  /// diff-against-our-own-cached-state approach (not `payload.oldRecord`,
  /// which depends on `REPLICA IDENTITY FULL` being set), as
  /// `JobChangeOrdersController._maybeNotifyStatusChange`. Only fires for
  /// an actual transition: never on this technician's own `saveLineItems`/
  /// `sendToCustomer`("sent" is excluded below)/`voidEstimate` writes.
  void _maybeNotifyStatusChange(PostgresChangePayload payload) {
    if (payload.eventType != PostgresChangeEvent.update) return;
    final newRow = payload.newRecord;
    final id = newRow['id']?.toString();
    final newStatus = newRow['status'] as String?;
    if (id == null || (newStatus != 'approved' && newStatus != 'declined')) return;

    final previous = state.valueOrNull;
    if (previous == null || previous.id != id || previous.status == newStatus) return;

    debugPrint('ESTIMATE: realtime detected $id transitioned ${previous.status} -> $newStatus for job $jobId');
    ref.read(jobStatusNotificationProvider(jobId).notifier).state = JobStatusNotification(
      kind: JobStatusNotificationKind.estimate,
      status: newStatus!,
      summary: '',
    );
  }

  @override
  void dispose() {
    final channel = _realtimeChannel;
    if (channel != null) Supabase.instance.client.removeChannel(channel);
    super.dispose();
  }

  /// A job can accumulate more than one `job_estimates` row over time (e.g.
  /// a replacement after a void or a decline) — this fetches every row,
  /// most recent first, and picks the one to show with
  /// [selectDisplayedEstimate] (the rule can't be expressed as a single
  /// `order()`/`limit(1)` query).
  Future<JobEstimate?> _fetchLatest() async {
    debugPrint('ESTIMATE: fetching all job_estimates rows for job $jobId (selecting by status priority)...');
    final rows = await Supabase.instance.client
        .from('job_estimates')
        .select()
        .eq('job_id', jobId)
        .order('created_at', ascending: false);
    final estimates = rows.map((row) => JobEstimate.fromJson(row)).toList();
    final selected = selectDisplayedEstimate(estimates);
    debugPrint(
      'ESTIMATE: ${estimates.length} row(s) for job $jobId '
      '(${estimates.where((e) => e.isVoided).length} voided) — showing '
      '${selected == null ? 'none' : '${selected.status} row ${selected.id}'}',
    );
    return selected;
  }

  /// Re-fetches from `job_estimates` directly — separate from
  /// [parseDictation] so the Estimate screen can offer a plain retry after a
  /// failed fetch without re-running (and re-billing) the Groq parse.
  Future<void> refresh() => _load();

  /// Sends [dictationId] (a just-saved `prepare_estimate` dictation — see
  /// `handleDictationCommand` in `job_voice_commands.dart`, the only caller)
  /// to the `/estimates/parse` Lambda: it loads the dictation's verbatim
  /// transcript, uses Groq to extract structured line items + a total,
  /// saves the result as a new `job_estimates` row, and marks the source
  /// `job_dictations` row `'processed'`. Sets state to [AsyncLoading] for
  /// the duration of that AI call (a couple of seconds) so the Estimate
  /// screen shows a spinner rather than the estimate this is about to
  /// replace — leaving the old one visible during this window would look
  /// like the dictation had no effect.
  Future<void> parseDictation(String dictationId) async {
    if (!mounted) return;
    debugPrint('ESTIMATE: parseDictation starting for dictation $dictationId (job $jobId)');
    state = const AsyncLoading();
    final parsing = ref.read(estimateParsingProvider(jobId).notifier)..state = true;
    final result = await AsyncValue.guard(() async {
      await ensureJobMoneyUnlocked(jobId);
      return _parse(dictationId);
    });
    parsing.state = false;
    if (!mounted) return;
    if (result.hasError) {
      debugPrint('ESTIMATE ERROR (parse): ${result.error}');
    }
    state = result;
  }

  Future<JobEstimate?> _parse(String dictationId) async {
    final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
    if (accessToken == null) {
      throw StateError('No active session — please sign in again.');
    }

    debugPrint('ESTIMATE: requesting /estimates/parse for dictation $dictationId (job $jobId)...');
    final response = await http.post(
      Uri.parse('$apiBaseUrl/estimates/parse'),
      headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'dictationId': dictationId}),
    );
    if (response.statusCode != 200) {
      throw StateError('Estimate parsing failed (${response.statusCode}): ${response.body}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final estimateJson = decoded['estimate'] as Map<String, dynamic>?;
    if (estimateJson == null) {
      throw StateError('Estimate parsing response missing "estimate".');
    }
    final estimate = JobEstimate.fromJson(estimateJson);
    debugPrint(
      'ESTIMATE: parse succeeded for job $jobId — ${estimate.lineItems.length} line item(s), '
      'total=\$${estimate.totalAmount}',
    );
    return estimate;
  }

  /// Manual (typed) counterpart to [parseDictation]: creates the job's
  /// estimate from [lineItems] entered on the manual estimate editor. Same
  /// `/estimates/parse` route (`mode: 'manual'` — no dictation, no Groq), and
  /// the Lambda writes the identical `job_estimates` row shape the dictated
  /// path does, so nothing downstream can tell the two apart. Throws on
  /// failure (the editor shows the error and keeps the technician's input);
  /// on success the new draft becomes [state] immediately.
  Future<void> createManual(List<EstimateLineItem> lineItems) async {
    await ensureJobMoneyUnlocked(jobId);
    final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
    if (accessToken == null) {
      throw StateError('No active session — please sign in again.');
    }
    debugPrint('ESTIMATE: creating manual estimate (${lineItems.length} line item(s)) for job $jobId...');
    final response = await http.post(
      Uri.parse('$apiBaseUrl/estimates/parse'),
      headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
      body: jsonEncode({
        'mode': 'manual',
        'jobId': jobId,
        'lineItems': lineItems.map((item) => item.toJson()).toList(),
      }),
    );
    if (response.statusCode != 200) {
      throw StateError('Saving the estimate failed (${response.statusCode}): ${response.body}');
    }
    final estimateJson = (jsonDecode(response.body) as Map<String, dynamic>)['estimate'] as Map<String, dynamic>?;
    if (estimateJson == null) {
      throw StateError('Estimate response missing "estimate".');
    }
    final estimate = JobEstimate.fromJson(estimateJson);
    debugPrint('ESTIMATE: manual estimate ${estimate.id} created for job $jobId (total=\$${estimate.totalAmount})');
    if (!mounted) return;
    state = AsyncData(estimate);
  }

  /// Saves a technician's review edits (Feature 1: added/removed/reworded
  /// line items, corrected amounts) straight to the `job_estimates` row —
  /// RLS now permits a direct update here, same as the read above, so no
  /// Lambda round-trip is needed just to persist a price correction. Only
  /// ever called for a `status == 'draft'` estimate (see
  /// `_EstimateScreenState._sendDraftEstimate`, the sole caller); updates
  /// the cached [state] in place on success so the screen reflects exactly
  /// what was saved without a full refetch.
  Future<void> saveLineItems({
    required String estimateId,
    required List<EstimateLineItem> lineItems,
    required double totalAmount,
  }) async {
    await ensureJobMoneyUnlocked(jobId);
    debugPrint('ESTIMATE: saving edited line items for estimate $estimateId (job $jobId)...');
    await Supabase.instance.client
        .from('job_estimates')
        .update({
          'line_items': lineItems.map((item) => item.toJson()).toList(),
          'total_amount': totalAmount,
        })
        .eq('id', estimateId);
    debugPrint('ESTIMATE: line item edits saved for estimate $estimateId');
    if (!mounted) return;
    final current = state.valueOrNull;
    if (current != null && current.id == estimateId) {
      state = AsyncData(current.copyWith(lineItems: lineItems, totalAmount: totalAmount));
    }
  }

  /// Feature 2 — sends the now-finalized estimate to the customer over SMS
  /// and, only once that succeeds, flips `job_estimates.status` to `'sent'`.
  /// Order matters: per spec, a missing phone number or a failed SMS must
  /// leave the estimate exactly as it was (still `'draft'`), never silently
  /// marked sent.
  ///
  /// 1. Looks up the customer's phone/name for [jobId] via the `jobs` ->
  ///    `customers` relationship (a Postgrest embedded-resource select —
  ///    "the jobs -> customers relationship already in the schema").
  /// 2. POSTs to the PDF-generation Lambda (`/estimates/generate-pdf`) to
  ///    get a `pdfUrl` for this estimate — [onStatus], if given, is told
  ///    about this stage so the screen can show "Generating PDF…".
  /// 3. POSTs to the SMS-send Lambda, including that `pdfUrl` so the
  ///    Lambda appends a link to the message it texts the customer.
  /// 4. Updates `job_estimates.status` to `'sent'` directly via Supabase
  ///    (RLS-permitted, same as [saveLineItems]) and updates [state] in
  ///    place so the screen flips out of edit mode immediately.
  ///
  /// Returns the customer's name for the on-screen confirmation. Throws —
  /// with a message written to be shown directly to the technician — if the
  /// phone number is missing, PDF generation fails, or the SMS send fails.
  Future<String> sendToCustomer(String estimateId, {void Function(String status)? onStatus}) async {
    await ensureJobMoneyUnlocked(jobId);
    debugPrint('ESTIMATE: looking up customer contact for job $jobId...');
    final jobRow = await Supabase.instance.client
        .from('jobs')
        .select('customers(id, household_name, primary_phone)')
        .eq('id', jobId)
        .single();
    final customer = jobRow['customers'] as Map<String, dynamic>?;
    final customerName = customer?['household_name'] as String?;
    final customerPhone = customer?['primary_phone'] as String?;
    debugPrint(
      'ESTIMATE DEBUG: job_id=$jobId customer_id=${customer?['id']} '
      'raw_primary_phone=${customerPhone == null ? 'null' : '"$customerPhone"'}',
    );
    if (customerPhone == null || customerPhone.trim().isEmpty) {
      debugPrint('ESTIMATE: no customer phone on file for job $jobId — refusing to send');
      throw StateError('This customer has no phone number on file — add one before sending.');
    }

    final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
    if (accessToken == null) {
      throw StateError('No active session — please sign in again.');
    }

    onStatus?.call('Generating PDF…');
    debugPrint('ESTIMATE: requesting /estimates/generate-pdf for estimate $estimateId...');
    final pdfResponse = await http.post(
      Uri.parse('$apiBaseUrl/estimates/generate-pdf'),
      headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'estimateId': estimateId}),
    );
    if (pdfResponse.statusCode != 200) {
      debugPrint('ESTIMATE ERROR (generate-pdf): ${pdfResponse.statusCode} ${pdfResponse.body}');
      throw StateError(friendlyServerError(pdfResponse.body));
    }
    final pdfDecoded = jsonDecode(pdfResponse.body) as Map<String, dynamic>;
    final pdfUrl = pdfDecoded['pdfUrl'] as String?;
    if (pdfUrl == null || pdfUrl.isEmpty) {
      throw StateError('Generating the estimate PDF failed: response missing "pdfUrl".');
    }
    debugPrint('ESTIMATE: PDF generated for estimate $estimateId');

    onStatus?.call('Sending to customer…');
    const smsRoute = '/estimates/send-sms';
    debugPrint('ESTIMATE: sending estimate $estimateId via SMS to $customerName ($smsRoute)...');
    final response = await http.post(
      Uri.parse('$apiBaseUrl$smsRoute'),
      headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
      body: jsonEncode({
        'jobId': jobId,
        'estimateId': estimateId,
        'customerName': customerName,
        'customerPhone': customerPhone,
        'pdfUrl': pdfUrl,
      }),
    );
    if (response.statusCode != 200) {
      debugPrint('ESTIMATE ERROR (send): ${response.statusCode} ${response.body}');
      throw StateError(friendlyServerError(response.body, sms: true));
    }
    debugPrint('ESTIMATE: SMS send succeeded for estimate $estimateId');

    await Supabase.instance.client.from('job_estimates').update({'status': 'sent'}).eq('id', estimateId);
    debugPrint('ESTIMATE: job_estimates.status updated to sent for estimate $estimateId');

    if (mounted) {
      final current = state.valueOrNull;
      if (current != null && current.id == estimateId) {
        state = AsyncData(current.copyWith(status: 'sent'));
      }
    }
    return (customerName == null || customerName.trim().isEmpty) ? 'the customer' : customerName;
  }

  /// Voids an already-approved estimate — same concept, same call shape, as
  /// `JobChangeOrdersController.voidChangeOrder`: closes it out as a
  /// historical record rather than editing it. Updates ONLY `voided_at` and
  /// `void_reason`; never touches `line_items` or `total_amount`, so a void
  /// can never masquerade as a price/scope edit on a job the customer has
  /// already approved specific numbers for.
  ///
  /// RLS backs this up independently of `EstimateScreen` only offering Void
  /// for an approved, not-yet-voided estimate — see
  /// `supabase/migrations/20260821020000_job_estimates_voiding.sql`.
  ///
  /// Then re-reads the rows: a voided estimate is never the one shown (see
  /// [selectDisplayedEstimate]), so the screen moves on to a newer estimate,
  /// or to "No estimate yet" and its Create Estimate action.
  Future<void> voidEstimate({required String estimateId, required String reason}) async {
    await ensureJobMoneyUnlocked(jobId);
    debugPrint('ESTIMATE: voiding estimate $estimateId (job $jobId)...');
    final voidedAt = DateTime.now().toUtc();
    await Supabase.instance.client
        .from('job_estimates')
        .update({'voided_at': voidedAt.toIso8601String(), 'void_reason': reason})
        .eq('id', estimateId);
    debugPrint('ESTIMATE: estimate $estimateId voided');
    if (!mounted) return;
    final current = state.valueOrNull;
    if (current != null && current.id == estimateId) {
      state = AsyncData(current.copyWith(voidedAt: voidedAt, voidReason: reason));
    }
    await _load();
  }
}

/// Which of a job's `job_estimates` rows ([newestFirst], ordered by
/// `created_at` descending) the app shows — and so what Job Details, the
/// change-order running total, voice `view_estimate` and the invoice
/// prefetch read:
///  1. Voided rows are ignored: a closed-out estimate is history, never
///     "the" estimate. No row left -> null ("No estimate yet").
///  2. The most recent `'sent'`/`'approved'`/`'declined'` row wins over a
///     newer `'draft'` — a customer-facing decision is never silently
///     superseded by an unrelated new dictation (that would make an
///     approved estimate invisible, and editable-looking again).
///  3. Except a declined one: a draft created after the decline is its
///     replacement (the "Create a new estimate" action), so that draft wins.
///  4. Otherwise, the most recent row.
JobEstimate? selectDisplayedEstimate(List<JobEstimate> newestFirst) {
  final live = newestFirst.where((e) => !e.isVoided).toList();
  if (live.isEmpty) return null;
  final decided = live.where((e) => _decidedStatuses.contains(e.status)).toList();
  if (decided.isEmpty) return live.first;
  final selected = decided.first;
  if (selected.isDeclined && live.first.id != selected.id) return live.first;
  return selected;
}

/// Statuses that represent a customer-facing decision already made on an
/// estimate — see [selectDisplayedEstimate].
const _decidedStatuses = {'sent', 'approved', 'declined'};
