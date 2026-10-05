import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../models/invoice_preview.dart';
import '../models/mock_job.dart';
import 'arrival_provider.dart';
import 'auth_provider.dart';
import 'change_order_provider.dart';
import 'global_voice_service_provider.dart';
import 'invoice_provider.dart';
import 'job_complete_provider.dart';
import 'job_dictations_provider.dart';
import 'job_estimate_provider.dart';
import 'job_runtime_provider.dart';
import 'visit_provider.dart';
import 'voice_command_registry_provider.dart';

/// Trigger words for the ask-a-question flow — "help" is the primary,
/// easier-to-pronounce word (replacing the old "troubleshoot" trigger,
/// which technicians in the field found awkward to say reliably), with
/// "ask" and "question" as synonyms routing to the exact same flow. Plain
/// substring matching, same style as [GlobalVoiceService]'s own wake-word
/// variant matching.
const _askQuestionTriggerVariants = {'help', 'ask', 'question'};

bool _matchesAskQuestionTrigger(String lowerText) {
  return _askQuestionTriggerVariants.any(lowerText.contains);
}

/// Commands that make sense from anywhere within a job's context —
/// arrival, job completion, a site-condition note, and the ask-a-question
/// flow. Every job-scoped screen (Job Detail, Photo Capture, Photo
/// Preview, Estimate, Voice Assistant) registers this same set while it's
/// active (see `VoiceCommandRegistrarMixin.buildVoiceCommands`) — this is
/// what makes voice feel like one continuous assistant following the
/// technician through the app rather than a per-screen feature.
List<VoiceCommand> jobLifecycleVoiceCommands(WidgetRef ref, String jobId) {
  return [
    VoiceCommand(
      id: 'arrived',
      matches: (t) => t.contains('arrived'),
      handler: (_) => _handleArrived(ref, jobId),
    ),
    VoiceCommand(
      id: 'job_complete',
      matches: (t) => t.contains('job complete'),
      handler: (_) => _handleJobComplete(ref, jobId),
    ),
    VoiceCommand(
      id: 'site_condition',
      matches: (t) => t.contains('site condition'),
      handler: (_) => handleDictationCommand(
        ref: ref,
        jobId: jobId,
        commandType: DictationCommandType.siteCondition,
        prompt: 'Say your note after the tone',
        savedLabel: 'Site condition note saved.',
      ),
    ),
    VoiceCommand(
      id: 'ask_question',
      matches: (t) => _matchesAskQuestionTrigger(t),
      handler: (_) => handleAskQuestionCommand(ref: ref, jobId: jobId),
    ),
  ];
}

/// Navigates to Photo Capture for [jobId]. [navigate] is injected by the
/// registering screen (rather than this file importing PhotoCaptureScreen
/// directly) to avoid a circular import between this shared command file
/// and the screens that use it.
VoiceCommand openCameraVoiceCommand({
  required WidgetRef ref,
  required String jobId,
  required VoidCallback navigate,
}) {
  return VoiceCommand(
    id: 'open_camera',
    matches: (t) => t.contains('photo') || t.contains('open camera'),
    handler: (_) async {
      // `navigate`/`ref` both belong to whichever screen registered this
      // command — if it's disposed between match and dispatch (a narrow
      // window, but not provably impossible), either can throw; catch
      // rather than let it surface as an unhandled Future error.
      try {
        debugPrint('VOICE ACTION: opening camera for job $jobId');
        navigate();
        // FIX 3: don't block the handler (and therefore the next
        // wake-word cycle) on the confirmation finishing playback — it
        // speaks concurrently with the navigation that already started.
        unawaited(ref.read(globalVoiceServiceProvider.notifier).speak('Opening camera'));
      } catch (e, stackTrace) {
        debugPrint('VOICE ERROR (open camera): $e\n$stackTrace');
      }
    },
  );
}

/// Prompts the technician to describe the job and price, captures it
/// verbatim, and saves it to `job_dictations` for the office to turn into a
/// formal estimate — see [handleDictationCommand]. (The full Estimate
/// screen itself is reached separately, via the "View Full Estimate" button
/// on Job Detail's Estimate tab — this command is voice/tap dictation, not
/// navigation.)
VoiceCommand prepareEstimateVoiceCommand({required WidgetRef ref, required String jobId}) {
  return VoiceCommand(
    id: 'prepare_estimate',
    matches: (t) => t.contains('prepare estimate'),
    handler: (_) => handleDictationCommand(
      ref: ref,
      jobId: jobId,
      commandType: DictationCommandType.prepareEstimate,
      prompt: 'Go ahead, describe the work and price',
      savedLabel: 'Estimate note saved.',
    ),
  );
}

/// Prompts the technician to describe additional work found on-site and its
/// price, captures it verbatim, and — once confirmed — saves it as a
/// pending change order the customer can approve. See
/// [handleChangeOrderCommand].
VoiceCommand changeOrderVoiceCommand({required WidgetRef ref, required String jobId}) {
  return VoiceCommand(
    id: 'change_order',
    matches: (t) => t.contains('change order'),
    handler: (_) => handleChangeOrderCommand(ref: ref, jobId: jobId),
  );
}

/// "FieldLoop, generate invoice" — available once this job has a
/// `job_estimates` row on record, any status (draft/sent/approved/
/// declined): [handleGenerateInvoiceCommand] is what actually enforces that
/// gate. [navigate] is injected by the registering screen (rather than this
/// file importing `InvoiceReviewScreen` directly) to avoid a circular import
/// between this shared command file and the screens that use it — same
/// reasoning as [openCameraVoiceCommand].
VoiceCommand generateInvoiceVoiceCommand({
  required WidgetRef ref,
  required String jobId,
  required void Function(InvoicePreview preview) navigate,
}) {
  return VoiceCommand(
    id: 'generate_invoice',
    matches: (t) => t.contains('generate invoice'),
    handler: (_) => handleGenerateInvoiceCommand(ref: ref, jobId: jobId, navigate: navigate),
  );
}

/// Shared implementation behind the `generate_invoice` voice command and the
/// "Generate Invoice" tap-button fallback on Job Detail's Invoice tab — same
/// "voice and tap always do the same thing" principle as
/// [handleDictationCommand]/[handleChangeOrderCommand].
///
/// Gates on this job having an estimate on record at all (any status —
/// unlike the invoice itself, which separately warns if that estimate isn't
/// yet *approved*): declines with a spoken message rather than calling the
/// Lambda for a job that can't possibly produce a preview
/// (`backend/functions/generate-invoice` throws "No estimate found for this
/// job" for exactly this case, so this check just avoids the round trip and
/// gives a friendlier message).
///
/// Once gated, calls the read-only `/invoices/preview` Lambda (see
/// [fetchInvoicePreview] — this never saves anything), navigates to
/// `InvoiceReviewScreen` with the result, then speaks a short summary
/// (estimate approval + gross total, plus a pending-change-order count only
/// when one exists) — navigation isn't blocked on the summary finishing
/// playback, same FIX 3 reasoning as [openCameraVoiceCommand]'s "Opening
/// camera" confirmation.
Future<void> handleGenerateInvoiceCommand({
  required WidgetRef ref,
  required String jobId,
  required void Function(InvoicePreview preview) navigate,
}) async {
  final service = ref.read(globalVoiceServiceProvider.notifier);
  const tag = 'generate_invoice';
  try {
    debugPrint('VOICE: "$tag" triggered for job $jobId');
    final hasEstimate = ref.read(jobEstimateProvider(jobId)).valueOrNull != null;
    if (!hasEstimate) {
      debugPrint('VOICE: "$tag" not ready for job $jobId — no estimate on record');
      unawaited(service.speak('This job needs an estimate before an invoice can be generated'));
      return;
    }

    final preview = await fetchInvoicePreview(jobId: jobId);
    debugPrint(
      'VOICE: "$tag" preview fetched for job $jobId (grossTotal=${preview.grossTotal}, '
      'pending=${preview.pendingChangeOrders.length})',
    );

    navigate(preview);

    final total = preview.grossTotal.toStringAsFixed(0);
    final estimateClause = preview.estimateApproved
        ? 'Estimate approved, total \$$total.'
        : "Estimate hasn't been approved yet, total \$$total.";
    final pendingCount = preview.pendingChangeOrders.length;
    final pendingClause = pendingCount == 0
        ? ''
        : ' $pendingCount change order${pendingCount == 1 ? '' : 's'} still pending customer approval.';
    unawaited(service.speak('Invoice ready for review. $estimateClause$pendingClause'));
  } catch (e, stackTrace) {
    debugPrint('VOICE ERROR ("$tag") for job $jobId: $e\n$stackTrace');
    unawaited(service.speak("Sorry, I couldn't prepare the invoice."));
  }
}

/// Goes through the exact same `markArrived` call the on-screen "I've
/// Arrived" button uses (`arrivalActionProvider`). The already-arrived check
/// happens INSIDE `markArrived`, serialized against the geofence trigger and
/// against a fresh read — NOT against the cached `arrivalEventProvider`,
/// which still reads "not arrived" while an automatic arrival's insert is in
/// flight (the D4 duplicate On Site marker race).
Future<void> _handleArrived(WidgetRef ref, String jobId) async {
  try {
    final service = ref.read(globalVoiceServiceProvider.notifier);
    debugPrint('VOICE: "arrived" command matched for job $jobId');

    final technicianId = ref.read(authControllerProvider).value?.id;
    if (technicianId == null) {
      debugPrint('VOICE ERROR: no signed-in technician id, cannot log arrival for job $jobId');
      unawaited(service.speak("Sorry, I didn't catch that"));
      return;
    }

    // The write itself must finish before we know which confirmation to
    // speak, so this part stays sequential — FIX 3 only applies to not
    // blocking on the confirmation's playback afterward (below).
    final outcome = await ref.read(arrivalActionProvider(jobId).notifier).markArrived(technicianId: technicianId);
    if (outcome == null) {
      debugPrint('VOICE ERROR: arrival logging failed for job $jobId: ${ref.read(arrivalActionProvider(jobId)).error}');
      unawaited(service.speak("Sorry, I didn't catch that"));
    } else if (outcome == VisitWriteOutcome.alreadyLogged) {
      debugPrint('VOICE: arrival already logged for job $jobId');
      unawaited(service.speak('Arrival already logged'));
    } else {
      debugPrint('VOICE: arrival logged for job $jobId');
      unawaited(service.speak('Arrival logged'));
    }
  } catch (e, stackTrace) {
    debugPrint('VOICE ERROR (arrived): $e\n$stackTrace');
  }
}

/// "job complete" — checks (via [JobCompleteActionController.checkEvidence])
/// whether this job has any `job_estimates` row or any photo `field_events`
/// row logged, speaks a warning if neither exists (or a plain confirmation
/// if at least one does), then waits for a short confirm/cancel response
/// (see [GlobalVoiceService.captureConfirmation] — the same short-settle-
/// window primitive `handleChangeOrderCommand` uses for its confirm/redo
/// step, not the long dictation window: this is a yes/no decision, not
/// free-form speech).
///
/// Three-way outcome (see [ConfirmationOutcome]):
///  - [ConfirmationOutcome.confirmed] — the only outcome that ever touches
///    Supabase ([JobCompleteActionController.markComplete] — the real
///    `jobs.status` update + `field_events` insert; syncing local
///    [jobRuntimeProvider] state is what makes `JobDetailScreen` reactively
///    flip into its read-only view immediately, without navigating away
///    and back).
///  - [ConfirmationOutcome.redo] — an EXPLICIT "cancel" (or "no"/"redo"/
///    "wrong"). Stops outright, speaks "Okay, not marking complete", no
///    write, no retry — this is the one outcome that must NEVER loop back,
///    since the technician gave a clear, deliberate answer.
///  - [ConfirmationOutcome.unclear] — silence/garbled speech on every
///    attempt; `captureConfirmation` has already spoken an explicit
///    "let's try again from the start" by the time this returns, so this
///    handler just restarts its own loop (re-checks evidence, re-prompts)
///    rather than marking complete OR giving up — an unclear reply is
///    never treated as the safe default in either direction.
Future<void> _handleJobComplete(WidgetRef ref, String jobId) async {
  final service = ref.read(globalVoiceServiceProvider.notifier);
  const tag = 'job_complete';
  try {
    debugPrint('VOICE: "$tag" command matched for job $jobId');
    final runtime = ref.read(jobRuntimeProvider(jobId));
    if (runtime.status == JobStatus.complete) {
      debugPrint('VOICE: "$tag" job $jobId is already complete, nothing to do');
      unawaited(service.speak('This job is already marked complete'));
      return;
    }

    final controller = ref.read(jobCompleteActionProvider(jobId).notifier);

    // Only ConfirmationOutcome.unclear re-enters this loop — see the doc
    // comment above for why an explicit redo/cancel must exit instead.
    while (true) {
      final evidence = await controller.checkEvidence();

      final prompt = evidence.hasAny
          ? 'Mark this job complete?'
          : 'This job has no photos or estimate logged. Say confirm to mark it complete anyway, or say cancel.';
      debugPrint('VOICE: "$tag" prompting for job $jobId (hasEvidence=${evidence.hasAny}): "$prompt"');
      await service.speak(prompt);

      final outcome = await service.captureConfirmation(transcriptForDisplay: prompt);
      debugPrint('VOICE: "$tag" confirmation outcome for job $jobId: $outcome');

      if (outcome == ConfirmationOutcome.unclear) {
        debugPrint('VOICE: "$tag" unclear for job $jobId — restarting the flow from the start, no write made');
        continue;
      }
      if (outcome == ConfirmationOutcome.redo) {
        debugPrint('VOICE: "$tag" explicitly cancelled for job $jobId — no write made');
        unawaited(service.speak('Okay, not marking complete'));
        return;
      }

      // Confirmed — the mic just closed (captureConfirmation leaves phase
      // at `listening`) and a real Supabase write is about to start below,
      // so re-assert `processing` until the resulting speak() takes over.
      service.markProcessing();

      final technicianId = ref.read(authControllerProvider).value?.id;
      if (technicianId == null) {
        debugPrint('VOICE ERROR ("$tag"): no signed-in technician id, cannot mark job $jobId complete');
        unawaited(service.speak("Sorry, I couldn't mark that complete"));
        return;
      }

      debugPrint('VOICE: "$tag" writing completion for job $jobId...');
      await controller.markComplete(technicianId: technicianId, evidence: evidence);
      final result = ref.read(jobCompleteActionProvider(jobId));
      if (result.hasError) {
        debugPrint('VOICE ERROR ("$tag"): completion write failed for job $jobId: ${result.error}');
        unawaited(service.speak("Sorry, I couldn't mark that complete"));
        return;
      }
      debugPrint('VOICE: "$tag" job $jobId marked complete');
      unawaited(service.speak('Job marked complete.'));
      return;
    }
  } catch (e, stackTrace) {
    debugPrint('VOICE ERROR ("$tag"): $e\n$stackTrace');
    unawaited(service.speak("Sorry, I couldn't mark that complete"));
  }
}

/// Shared implementation behind the `prepare_estimate` and `site_condition`
/// voice commands (and the "Dictate Estimate" tap-button fallback on Job
/// Detail): speaks [prompt], captures everything said afterward verbatim
/// via [GlobalVoiceService.captureDictation] (continuous, multi-sentence,
/// finalizing only after a real pause — not the short single-command
/// window), then — FIX (transcription-error safety net) — reads the FULL
/// transcript back and requires an explicit "confirm" before it's ever
/// written to `job_dictations`. This exists because a real transcription
/// error was confirmed in the field: "two hours labor at one hundred fifty
/// dollars an hour" came back as "to our labour at 10050 per hour" — a
/// price error serious enough that it must never reach saved data
/// unreviewed. "Redo" (spoken or tapped — see
/// [GlobalVoiceService.submitConfirmationTap]) discards the transcript
/// entirely and re-prompts from scratch, no partial state carried over.
///
/// Every step here is awaited — including the final confirmation speech —
/// mirroring the real-completion pattern `confirm_photo` already uses (see
/// `PhotoPreviewScreen.buildVoiceCommands`): this Future only completes
/// once the dictation has actually been saved, discarded for good (empty
/// capture), or has definitively failed and the technician has been told,
/// which is what `GlobalVoiceService._dispatchCommand` uses to know when
/// it's safe to resume listening for the next command — never before the
/// real work is done, the old broken pattern this replaces.
Future<void> handleDictationCommand({
  required WidgetRef ref,
  required String jobId,
  required DictationCommandType commandType,
  required String prompt,
  required String savedLabel,
}) async {
  final service = ref.read(globalVoiceServiceProvider.notifier);
  final tag = commandType.name;
  try {
    // Redo re-enters this loop from scratch — same prompt, no leftover
    // state from the discarded attempt.
    while (true) {
      debugPrint('VOICE: "$tag" dictation mode entered for job $jobId');
      await service.speak(prompt);

      debugPrint('VOICE: "$tag" dictation capture started for job $jobId');
      final transcript = await service.captureDictation(handlerTag: tag);
      debugPrint('VOICE: "$tag" transcript finalized for job $jobId: "$transcript"');

      if (transcript.trim().isEmpty) {
        debugPrint('VOICE: "$tag" dictation captured nothing for job $jobId, not saving');
        await service.speak("Sorry, I didn't catch that");
        return;
      }

      // FIX (transcription-error safety net) — read back the COMPLETE
      // transcript, not a truncated preview: price/quantity accuracy is
      // exactly what's at stake here, and a truncated readback could hide
      // an error in the part not read back.
      await service.speak(
        'Here is what I heard: $transcript. Say confirm to save this, or say redo to try again.',
      );
      final outcome = await service.captureConfirmation(transcriptForDisplay: transcript);
      debugPrint('VOICE: "$tag" confirmation outcome for job $jobId: $outcome');

      if (outcome != ConfirmationOutcome.confirmed) {
        // Both an explicit redo AND an exhausted-unclear reply restart
        // this loop from scratch — same reasoning either way: an unsaved
        // transcript is cheap to redo, unlike job_complete's write, so
        // there's no need to distinguish them here (captureConfirmation
        // has already spoken its own "let's try again" message for the
        // unclear case).
        debugPrint(
          'VOICE: "$tag" transcript discarded for job $jobId ($outcome) — nothing saved, re-entering '
          'dictation capture',
        );
        continue;
      }

      // Confirmed — the mic just closed (captureConfirmation leaves phase
      // at `listening`) and a real Supabase write is about to start below,
      // so re-assert `processing` until the resulting speak() takes over.
      service.markProcessing();

      final technicianId = ref.read(authControllerProvider).value?.id;
      if (technicianId == null) {
        debugPrint('VOICE ERROR ("$tag"): no signed-in technician id, cannot save dictation for job $jobId');
        await service.speak("Sorry, I didn't catch that");
        return;
      }

      try {
        final dictationId = await insertJobDictation(
          jobId: jobId,
          technicianId: technicianId,
          commandType: commandType,
          transcript: transcript,
        );
        debugPrint('VOICE: "$tag" job_dictations insert succeeded for job $jobId (status=captured)');
        await service.speak(savedLabel);

        // Turns the verbatim transcript just saved above into a structured
        // estimate (line items + total) via Groq — see
        // `JobEstimateController.parseDictation`. Fire-and-forget: the
        // Estimate screen watches `jobEstimateProvider(jobId)` directly and
        // shows its own loading state while this runs, so the voice
        // command doesn't need to block the wake-word loop on a
        // multi-second AI call after already confirming the save to the
        // technician.
        if (commandType == DictationCommandType.prepareEstimate) {
          debugPrint('VOICE: "$tag" kicking off /estimates/parse for dictation $dictationId (job $jobId)');
          unawaited(ref.read(jobEstimateProvider(jobId).notifier).parseDictation(dictationId));
        }
      } catch (e, stackTrace) {
        debugPrint('VOICE ERROR ("$tag" save) for job $jobId: $e\n$stackTrace');
        await service.speak("Sorry, I couldn't save that note");
      }
      return;
    }
  } catch (e, stackTrace) {
    debugPrint('VOICE ERROR ("$tag") for job $jobId: $e\n$stackTrace');
    await service.speak("Sorry, I couldn't save that note");
  }
}

/// Change-order counterpart to [handleDictationCommand] — deliberately NOT
/// built on top of it (a change order isn't a `job_dictations` row; it goes
/// straight to `change_orders` via the Lambdas below), but copies its
/// proven capture/confirm/redo/TTS-sequencing shape exactly, step for step:
/// speak [GlobalVoiceService.speak] the prompt, capture verbatim via the
/// same long-settle-window [GlobalVoiceService.captureDictation] used for
/// prepare_estimate/site_condition (no reinterpretation of the price at
/// this stage), read the FULL transcript back, then require an explicit
/// "confirm" via the same corrected-window [GlobalVoiceService.
/// captureConfirmation] before anything is saved — "redo" re-enters this
/// loop from scratch, no partial state carried over. See
/// [handleDictationCommand]'s doc comment for why this transcription-error
/// safety net (readback + explicit confirm) exists at all — the same
/// reasoning applies here, and a wrong price is exactly as costly in a
/// change order as in an estimate.
///
/// Only once confirmed: [createChangeOrder] sends the full verbatim
/// transcript as-is to `/change-orders/create`, which does the price
/// extraction (a small Groq call, server-side) and the save in one round
/// trip — there is no separate parse endpoint (`/change-orders/parse` was
/// never actually deployed; the price extraction now lives entirely in
/// `backend/functions/create-change-order`). The order is saved as
/// `'pending'` with the full transcript as its description, and the
/// customer is texted an approval request if Twilio is configured.
///
/// Every step here is awaited, same real-completion pattern
/// [handleDictationCommand] and `confirm_photo` already use — this Future
/// only resolves once the change order has actually been saved, discarded
/// for good (empty capture), or has definitively failed and the technician
/// has been told, which is what lets `GlobalVoiceService._dispatchCommand`
/// know it's safe to resume listening for the next command.
Future<void> handleChangeOrderCommand({required WidgetRef ref, required String jobId}) async {
  final service = ref.read(globalVoiceServiceProvider.notifier);
  const tag = 'change_order';
  try {
    // Redo re-enters this loop from scratch — same prompt, no leftover
    // state from the discarded attempt.
    while (true) {
      debugPrint('VOICE: "$tag" dictation mode entered for job $jobId');
      await service.speak('Go ahead, describe the additional work and price');

      debugPrint('VOICE: "$tag" dictation capture started for job $jobId');
      final transcript = await service.captureDictation(handlerTag: tag);
      debugPrint('VOICE: "$tag" transcript finalized for job $jobId: "$transcript"');

      if (transcript.trim().isEmpty) {
        debugPrint('VOICE: "$tag" dictation captured nothing for job $jobId, not saving');
        await service.speak("Sorry, I didn't catch that");
        return;
      }

      // Same transcription-error safety net as handleDictationCommand: read
      // back the COMPLETE transcript before ever acting on it.
      await service.speak(
        'Here is what I heard: $transcript. Say confirm to save this, or say redo to try again.',
      );
      final outcome = await service.captureConfirmation(transcriptForDisplay: transcript);
      debugPrint('VOICE: "$tag" confirmation outcome for job $jobId: $outcome');

      if (outcome != ConfirmationOutcome.confirmed) {
        // Both an explicit redo AND an exhausted-unclear reply restart
        // this loop from scratch — see handleDictationCommand's identical
        // reasoning for why they're not distinguished here.
        debugPrint(
          'VOICE: "$tag" transcript discarded for job $jobId ($outcome) — nothing saved, re-entering '
          'dictation capture',
        );
        continue;
      }

      // Confirmed — the mic just closed (captureConfirmation leaves phase
      // at `listening`) and a real backend write is about to start below,
      // so re-assert `processing` until the resulting speak() takes over.
      service.markProcessing();

      try {
        debugPrint('VOICE: "$tag" saving change order for job $jobId...');
        final smsSent = await createChangeOrder(jobId: jobId, description: transcript);
        debugPrint('VOICE: "$tag" change_orders insert succeeded for job $jobId (status=pending, smsSent=$smsSent)');
        await service.speak(
          smsSent
              ? 'Change order sent to the customer for approval'
              : "Change order saved, but I couldn't reach the customer",
        );
      } catch (e, stackTrace) {
        debugPrint('VOICE ERROR ("$tag" save) for job $jobId: $e\n$stackTrace');
        await service.speak("Sorry, I couldn't save that change order");
      }
      return;
    }
  } catch (e, stackTrace) {
    debugPrint('VOICE ERROR ("$tag") for job $jobId: $e\n$stackTrace');
    await service.speak("Sorry, I couldn't save that change order");
  }
}

/// Prompts the technician with a greeting, listens for a spoken question,
/// then hands off to [_handleTroubleshoot] for the Lambda round-trip and
/// spoken answer — the tap fallback (Job Detail's "Ask a Question" button)
/// calls this directly too, same fallback principle as
/// [handleDictationCommand].
///
/// Uses the exact same TTS-completion-then-safety-buffer sequence already
/// proven correct for [handleDictationCommand]'s prompt, not a fresh one:
/// [GlobalVoiceService.speak] only resolves once the greeting has
/// genuinely finished playing (see `GlobalVoiceService._configureTts`), and
/// [GlobalVoiceService.captureDictation] then waits out its own post-prompt
/// safety buffer before opening the mic. A previous attempt at this flow
/// skipped straight to listening with no greeting step at all, which is
/// exactly the "mic picks up its own prompt audio" bug this sequence
/// exists to prevent — see [handleDictationCommand]'s doc comment for the
/// confirmed field incident.
Future<void> handleAskQuestionCommand({required WidgetRef ref, required String jobId}) async {
  final service = ref.read(globalVoiceServiceProvider.notifier);
  try {
    debugPrint('VOICE: "ask_question" trigger matched for job $jobId');

    final fullName = ref.read(authControllerProvider).value?.fullName.trim() ?? '';
    final firstName = fullName.isNotEmpty ? fullName.split(RegExp(r'\s+')).first : 'there';
    final greeting = "Hi $firstName, what's your question?";

    debugPrint('VOICE: "ask_question" greeting TTS started for job $jobId: "$greeting"');
    await service.speak(greeting);
    debugPrint('VOICE: "ask_question" greeting TTS completed for job $jobId');

    debugPrint('VOICE: "ask_question" listening for question started for job $jobId');
    // Shorter settle window than prepare_estimate/site_condition/
    // change_order's default (see GlobalVoiceService.askQuestionSettleWindow,
    // 2000ms vs. their 3500ms) — a troubleshooting question is typically one
    // short spoken sentence, not multi-sentence pricing prose, so it doesn't
    // need as much pause tolerance before finalizing. Still well above
    // _commandSettleWindow's 1800ms single-command window.
    final question = await service.captureDictation(
      settleWindow: GlobalVoiceService.askQuestionSettleWindow,
      handlerTag: 'ask_question',
    );
    debugPrint('VOICE: "ask_question" question captured for job $jobId: "$question"');

    if (question.trim().isEmpty) {
      debugPrint('VOICE: "ask_question" captured nothing for job $jobId, not calling the troubleshooting Lambda');
      await service.speak("Sorry, I didn't catch that");
      return;
    }

    await _handleTroubleshoot(ref, jobId, question);
  } catch (e, stackTrace) {
    debugPrint('VOICE ERROR (ask_question): $e\n$stackTrace');
    await service.speak("Sorry, I couldn't reach the troubleshooting assistant.");
  }
}

Future<void> _handleTroubleshoot(WidgetRef ref, String jobId, String question) async {
  // Nullable and obtained inside the try: if `ref.read` itself throws
  // (registering screen disposed before this ran), there's no live screen
  // to speak an error to either — `service` just stays null and the catch
  // below skips the speak rather than crashing on a null service.
  GlobalVoiceService? service;
  try {
    service = ref.read(globalVoiceServiceProvider.notifier);
    // CONFIRMED gap (real log evidence) — captureDictation() above leaves
    // phase at `listening`, and nothing set it to `processing` for the
    // real Lambda round-trip that follows, so the full-screen overlay had
    // nothing to show for the entire wait. Same pattern already used
    // elsewhere in this file for a real backend call about to start
    // (confirmation-capture writes) — re-assert `processing` until the
    // resulting speak() below takes over.
    service!.markProcessing();
    final answer = await fetchTroubleshootingAnswer(question: question, jobId: jobId);
    await service.speak(answer);
    debugPrint('VOICE: troubleshooting answer spoken for job $jobId');
  } catch (e, stackTrace) {
    debugPrint('VOICE ERROR (troubleshoot): $e\n$stackTrace');
    await service?.speak("Sorry, I couldn't reach the troubleshooting assistant.");
  }
}

/// Calls the `/voice/troubleshoot` Lambda (`backend/functions/ask-
/// troubleshooting`) and returns its answer — extracted out of
/// [_handleTroubleshoot] so the Gemini function-calling dispatcher
/// (`get_kb_answer`, see `lib/services/gemini_function_dispatcher.dart`) can
/// reuse the exact same tested request shape instead of duplicating it.
/// Behavior is unchanged from before this was pulled out: same endpoint,
/// same body shape, same "Sorry, I couldn't find an answer." fallback for a
/// missing/empty `answer` field, same auth/logging.
///
/// [jobId], when given, lets the Lambda look up that job's `trade_category`
/// and route the knowledge-base lookup to the right trade rather than a
/// generic search — every existing caller (this file) always sends it, but
/// it's optional here since the Lambda itself falls back to
/// 'general_contractor' when it's omitted.
///
/// [timeout], when given, bounds the HTTP round trip — a `TimeoutException`
/// is thrown past it (the Gemini `get_kb_answer` path passes one; a DNS
/// failure otherwise took ~20s to surface — a7d30b48 log). `null` keeps the
/// original unbounded behavior for the other caller.
Future<String> fetchTroubleshootingAnswer({required String question, String? jobId, Duration? timeout}) async {
  // ISSUE 3(a) (CRITICAL, CONFIRMED via f5a8bd8b-flutter_run_log.txt: this
  // round trip took 17.7s end to end for "who is the president of India?",
  // and has been "flagged as slow before" without ever being root-caused).
  // A single Stopwatch spanning auth-token read -> request-sent ->
  // response-received -> answer-parsed, each logged with its own elapsed
  // time, so the next real log can directly tell apart dispatch-side delay
  // (time before request_sent), network/Lambda-side delay (request_sent ->
  // response_received — cold start, KB search, or the network itself all
  // land here and are indistinguishable from the client alone, but this at
  // least isolates them AS A GROUP from Dart-side delay), and
  // response-parsing delay (should be ~instant).
  final callStopwatch = Stopwatch()..start();
  debugPrint('VOICE: troubleshooting Lambda called for job $jobId: "$question"');
  final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
  if (accessToken == null) {
    throw StateError('No active session — please sign in again.');
  }

  debugPrint(
    'KB TIMING [get_kb_answer]: request_sent at ${DateTime.now()} (${callStopwatch.elapsedMilliseconds}ms since '
    'fetchTroubleshootingAnswer entry) -> POST $apiBaseUrl/voice/troubleshoot',
  );
  final request = http.post(
    Uri.parse('$apiBaseUrl/voice/troubleshoot'),
    headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
    body: jsonEncode({'question': question, 'jobId': jobId}),
  );
  final response = timeout == null ? await request : await request.timeout(timeout);
  debugPrint(
    'KB TIMING [get_kb_answer]: response_received at ${DateTime.now()} — network round trip took '
    '${callStopwatch.elapsedMilliseconds}ms (status=${response.statusCode}); this span is network + Lambda '
    '(cold start/KB search) combined — the client cannot distinguish the two further than this.',
  );
  if (response.statusCode != 200) {
    throw StateError('Troubleshooting request failed (${response.statusCode}): ${response.body}');
  }

  // DIAGNOSTIC (0-char answer investigation) — logs exactly what the
  // Lambda sent back, before any parsing/fallback logic touches it, so a
  // shape mismatch (wrong field name, nested differently than expected,
  // etc.) is visible directly instead of inferred from the parsed result.
  debugPrint('VOICE TROUBLESHOOT RAW RESPONSE: ${response.body}');

  final decoded = jsonDecode(response.body);
  final answer =
      (decoded is Map<String, dynamic> ? decoded['answer'] as String? : null) ?? "Sorry, I couldn't find an answer.";
  debugPrint('VOICE: troubleshooting answer received for job $jobId (${answer.length} chars)');
  debugPrint('VOICE LOG: question="$question" answer="$answer"');
  debugPrint(
    'KB TIMING [get_kb_answer]: answer_parsed at ${DateTime.now()} — total fetchTroubleshootingAnswer duration '
    '${callStopwatch.elapsedMilliseconds}ms',
  );
  return answer;
}
