import 'dart:async';

/// Result of a single, successful [DeepgramCommandCapture.capture] attempt.
class DeepgramCaptureResult {
  const DeepgramCaptureResult({required this.transcript});
  final String transcript;
}

/// STUBBED OUT — this path is permanently disabled behind
/// `GlobalVoiceService._useDeepgramCapture = false` and is never
/// constructed or invoked at runtime (the only call site,
/// `_tryDeepgramCommandCapture`, is itself gated behind that same flag).
///
/// The real implementation streamed raw mic PCM to Deepgram over a
/// WebSocket using the `record` package. `record` was removed from the
/// project entirely (`record_android` had an unresolved Kotlin compile
/// error), which would otherwise leave this file failing to resolve
/// `package:record/record.dart` and breaking the whole app's build —
/// even though nothing ever calls into it. Since it's confirmed
/// unreachable dead code, it's stubbed down to a compiling no-op here
/// rather than migrated to a new audio library; re-implement for real
/// (mic capture included) before ever flipping `_useDeepgramCapture` back
/// on.
class DeepgramCommandCapture {
  DeepgramCommandCapture({required this.wakeWordDetectedAt, required this.onPartialTranscript});

  final DateTime wakeWordDetectedAt;
  final void Function(String partial) onPartialTranscript;

  Future<DeepgramCaptureResult?> capture({required String supabaseAccessToken}) async => null;

  void cancel() {}
}
