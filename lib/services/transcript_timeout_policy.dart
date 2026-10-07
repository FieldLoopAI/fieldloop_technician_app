/// Change 1 (Goal A) — what to do when a level-detected utterance gets no
/// transcript.
///
/// MEASURED (acceptance logs, 5 Oct, SM-T837V, all four parts): every real
/// transcript arrived 0.1–1.75s after the app's speech-end edge. All 19
/// level-detected utterances that never got one were single loud spikes
/// (the app starts an utterance on ONE 20ms chunk over RMS 500) that
/// Gemini's own VAD and transcriber ignored — not lost speech. The old 8s
/// wait then showed "Thinking..." for 8s and answered with "say that
/// again", i.e. the app spoke up when nobody had said anything, and that
/// reply was timed as an 8.7s / 6.3s response (two of Part 1's dead
/// stretches).
///
/// Now: the decision is made at [transcriptTimeoutFallbackAfter] (3s, well
/// past the slowest real transcript seen then) and, by default, the app
/// stays silent — no reply. A transcript that still
/// arrives later is routed exactly as before (the existing late-transcript
/// path), and because nothing was spoken or fired here, there is nothing it
/// could double up with.
library;

/// When the missing-transcript decision is made (was 8s).
const Duration transcriptTimeoutFallbackAfter = Duration(seconds: 3);

/// Switch: true = stay silent when the transcript is missing at the timeout;
/// false = the old behavior, asking the technician to repeat.
const bool silentOnMissingTranscript = true;

enum TranscriptTimeoutAction {
  /// Something already answered or is still answering this utterance.
  nothing,

  /// Release "Thinking...", say nothing — and keep listening: a transcript
  /// that still arrives is routed normally (6 Oct b173 logs: real speech
  /// arrived 3.5s, 6.1s and 7.5s late), so this makes no claim about what
  /// the sound was.
  silentAwaitLate,

  /// Ask the technician to repeat (the pre-change behavior).
  askToRepeat,
}

TranscriptTimeoutAction decideTranscriptTimeout({
  required bool triggerCommittedThisUtterance,
  required bool replyAlreadySpokenThisUtterance,
  required int functionCallsInFlight,
  bool silent = silentOnMissingTranscript,
}) {
  if (triggerCommittedThisUtterance || replyAlreadySpokenThisUtterance || functionCallsInFlight > 0) {
    return TranscriptTimeoutAction.nothing;
  }
  return silent ? TranscriptTimeoutAction.silentAwaitLate : TranscriptTimeoutAction.askToRepeat;
}

/// The `LATE TRANSCRIPT` line for a transcript that arrived after the
/// timeout had already gone silent — how late it really was, and its text.
String describeLateTranscript({required int msAfterSpeechEnd, required String text}) =>
    'LATE TRANSCRIPT: late transcript arrived ${msAfterSpeechEnd}ms after speech end '
    '(${msAfterSpeechEnd - transcriptTimeoutFallbackAfter.inMilliseconds}ms after the '
    '${transcriptTimeoutFallbackAfter.inMilliseconds}ms timeout); text="$text" — routed normally';
