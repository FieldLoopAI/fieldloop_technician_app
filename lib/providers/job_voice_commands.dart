import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../models/mock_job.dart';
import 'arrival_provider.dart';
import 'auth_provider.dart';
import 'estimate_invoice_providers.dart';
import 'global_voice_service_provider.dart';
import 'job_runtime_provider.dart';
import 'jobs_provider.dart';
import 'voice_command_registry_provider.dart';

const _questionStarters = [
  'what', 'why', 'how', 'when', 'where', 'who', 'which',
  'can', 'could', 'should', 'is', 'are', 'does', 'do', 'will', 'would',
];

bool _looksLikeQuestion(String lowerText) {
  if (lowerText.endsWith('?')) return true;
  final firstWord = lowerText.split(' ').first;
  return _questionStarters.contains(firstWord);
}

/// Commands that make sense from anywhere within a job's context —
/// arrival, job completion, a site-condition note, and the troubleshooting
/// fallback. Every job-scoped screen (Job Detail, Photo Capture, Photo
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
      handler: (_) => _handleSiteCondition(ref, jobId),
    ),
    VoiceCommand(
      id: 'troubleshoot',
      matches: (t) => t.startsWith('troubleshoot') || _looksLikeQuestion(t),
      handler: (text) => _handleTroubleshoot(ref, jobId, text),
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

/// Navigates to the Estimate screen for [jobId]. See [openCameraVoiceCommand]
/// for why [navigate] is injected rather than importing EstimateScreen here.
VoiceCommand prepareEstimateVoiceCommand({
  required WidgetRef ref,
  required String jobId,
  required VoidCallback navigate,
}) {
  return VoiceCommand(
    id: 'prepare_estimate',
    matches: (t) => t.contains('prepare estimate'),
    handler: (_) async {
      try {
        debugPrint('VOICE ACTION: opening estimate for job $jobId');
        navigate();
        unawaited(ref.read(globalVoiceServiceProvider.notifier).speak('Opening estimate'));
      } catch (e, stackTrace) {
        debugPrint('VOICE ERROR (open estimate): $e\n$stackTrace');
      }
    },
  );
}

/// Mirrors the exact same already-arrived check and `markArrived` call the
/// on-screen "I've Arrived" button uses (`arrivalEventProvider` /
/// `arrivalActionProvider`).
Future<void> _handleArrived(WidgetRef ref, String jobId) async {
  try {
    final service = ref.read(globalVoiceServiceProvider.notifier);
    debugPrint('VOICE: "arrived" command matched for job $jobId');
    final alreadyArrivedAt = await ref.read(arrivalEventProvider(jobId).future);
    if (alreadyArrivedAt != null) {
      debugPrint('VOICE: arrival already logged for job $jobId');
      unawaited(service.speak('Arrival already logged'));
      return;
    }

    final technicianId = ref.read(authControllerProvider).value?.id;
    if (technicianId == null) {
      debugPrint('VOICE ERROR: no signed-in technician id, cannot log arrival for job $jobId');
      unawaited(service.speak("Sorry, I didn't catch that"));
      return;
    }

    // The write itself must finish before we know which confirmation to
    // speak, so this part stays sequential — FIX 3 only applies to not
    // blocking on the confirmation's playback afterward (below).
    await ref.read(arrivalActionProvider(jobId).notifier).markArrived(technicianId: technicianId);
    final result = ref.read(arrivalActionProvider(jobId));
    if (result.hasError) {
      debugPrint('VOICE ERROR: arrival logging failed for job $jobId: ${result.error}');
      unawaited(service.speak("Sorry, I didn't catch that"));
    } else {
      debugPrint('VOICE: arrival logged for job $jobId');
      unawaited(service.speak('Arrival logged'));
    }
  } catch (e, stackTrace) {
    debugPrint('VOICE ERROR (arrived): $e\n$stackTrace');
  }
}

/// Mirrors the exact same readiness check `_JobCompleteButton` on Job
/// Detail uses before calling the same `jobRuntimeProvider(...).markComplete()`
/// the tap button calls.
Future<void> _handleJobComplete(WidgetRef ref, String jobId) async {
  try {
    final service = ref.read(globalVoiceServiceProvider.notifier);
    debugPrint('VOICE: "job complete" command matched for job $jobId');
    final runtime = ref.read(jobRuntimeProvider(jobId));
    final estimateStatus = ref.read(estimateStatusProvider(jobId));
    final invoiceStatus = ref.read(invoiceStatusProvider(jobId));
    final ready =
        runtime.status == JobStatus.onSite &&
        estimateStatus == EstimateStatus.signed &&
        invoiceStatus != InvoiceStatus.notYetInvoiced;

    if (!ready) {
      debugPrint(
        'VOICE: job $jobId not ready to complete '
        '(status=${runtime.status}, estimate=$estimateStatus, invoice=$invoiceStatus)',
      );
      unawaited(service.speak('Job cannot be completed yet'));
      return;
    }

    ref.read(jobRuntimeProvider(jobId).notifier).markComplete();
    debugPrint('VOICE: job $jobId marked complete');
    unawaited(service.speak('Job marked complete'));
  } catch (e, stackTrace) {
    debugPrint('VOICE ERROR (job complete): $e\n$stackTrace');
  }
}

/// Prompts for a spoken note, then captures the next thing said as plain
/// text. Real storage is a later step; for now this just proves the
/// capture path end-to-end via debugPrint.
Future<void> _handleSiteCondition(WidgetRef ref, String jobId) async {
  try {
    final service = ref.read(globalVoiceServiceProvider.notifier);
    debugPrint('VOICE: "site condition" command matched for job $jobId, prompting for note');
    await service.speak('Say your note after the tone');
    final note = await service.captureFreeText();
    debugPrint('VOICE: site condition note captured for job $jobId: "$note"');
  } catch (e, stackTrace) {
    debugPrint('VOICE ERROR (site condition): $e\n$stackTrace');
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
    debugPrint('VOICE: troubleshooting request sent for job $jobId: "$question"');
    final job = ref.read(jobByIdProvider(jobId));
    final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
    if (accessToken == null) {
      throw StateError('No active session — please sign in again.');
    }

    final response = await http.post(
      Uri.parse('$apiBaseUrl/voice/troubleshoot'),
      headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
      body: jsonEncode({
        'question': question,
        'tradeCategory': job?.tradeCategory,
        'jobDescription': job?.description,
      }),
    );
    if (response.statusCode != 200) {
      throw StateError('Troubleshooting request failed (${response.statusCode}): ${response.body}');
    }

    final decoded = jsonDecode(response.body);
    final answer = (decoded is Map<String, dynamic> ? decoded['answer'] as String? : null) ??
        "Sorry, I couldn't find an answer.";
    debugPrint('VOICE: troubleshooting response received (${answer.length} chars)');
    debugPrint('VOICE LOG: question="$question" answer="$answer"');
    await service!.speak(answer);
  } catch (e, stackTrace) {
    debugPrint('VOICE ERROR (troubleshoot): $e\n$stackTrace');
    await service?.speak("Sorry, I couldn't reach the troubleshooting assistant.");
  }
}
