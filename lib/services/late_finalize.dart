/// Build 180 item B — the late-transcript settle before end-of-utterance
/// routing re-runs.
///
/// End of utterance is an app timer (500ms of mic quiet), and Gemini's
/// transcript arrives about 1.1s after speech ends, i.e. after it. The
/// routing that only runs at utterance end (decline, negation sentence, KB,
/// site note, C13 narration, intent layer, catch-all) therefore re-runs on
/// the late transcript once it "settles". Build 179 waited 700ms for that:
/// b179 part 4 "No photo for now." — transcript_received 15:37:40.971,
/// late_transcript_finalize 15:37:41.682, DECLINE 15:37:41.683.
///
/// WHY 700ms EXISTED (c86bb035, 2026-09-26): "How long a late transcript
/// must be quiet (no further chunks) before end-of-utterance routing
/// re-runs on it" — i.e. to wait for a SECOND chunk of the same utterance.
///
/// WHY 100ms IS SAFE (evidence, builds 173–179, 57 sessions, 538 transcript
/// chunks): 455 of 496 utterances arrived as one chunk; the 41 multi-chunk
/// ones were all separate commands ("Show me the estimate." … "Go back."),
/// their second chunk 4.27s or more after the first. The closest any two
/// transcript chunks ever arrived was 1476ms apart (b175 part 1, a separate
/// "Are you there?"). No chunk ever followed another within 700ms, so no
/// logged utterance would have routed differently with a shorter settle.
/// 100ms (not 0) keeps a margin for a transcript the server splits across
/// back-to-back messages, which never happened in the logs.
///
/// BURST FIX: build 179 dropped the re-run when a mic burst started during
/// the wait ("Photo, I don't want to take one.", b178 part 6 14:48:52, got
/// no reply: the burst started a new utterance, whose reset cancelled the
/// timer). Now the pending re-run runs at once before that reset, or — if
/// the burst continues the same utterance — the burst's own end-of-utterance
/// edge runs it. An utterance a per-chunk trigger already resolved is
/// skipped exactly as before.
///
/// `--dart-define=LATE_FINALIZE_MS=700` restores build 179 exactly (700ms
/// settle, burst fix off). Values are clamped to 0–700.
library;

/// The settle in ms (0–700).
const int kLateFinalizeMsDefine = int.fromEnvironment('LATE_FINALIZE_MS', defaultValue: 100);

/// Build 179's settle.
const int lateFinalizeLegacyMs = 700;

int clampLateFinalizeMs(int ms) => ms < 0 ? 0 : (ms > lateFinalizeLegacyMs ? lateFinalizeLegacyMs : ms);

final int kLateFinalizeMs = clampLateFinalizeMs(kLateFinalizeMsDefine);

/// What the screen does at one late-finalize decision point.
enum LateFinalizeStep {
  /// Nothing to do here.
  none,

  /// Run the end-of-utterance routing now — reason `settled`.
  runSettled,

  /// Run it now, before a new utterance's reset — reason `immediate`.
  runImmediate,

  /// The routing will run on the burst's own end-of-utterance edge (it is
  /// already the normal path); only log reason `after_burst`.
  logAfterBurst,

  /// The utterance was already resolved — reason `skipped_already_resolved`.
  skippedAlreadyResolved,

  /// Build 179 behaviour with the burst fix off: dropped silently.
  droppedLegacy,
}

/// Log reason for a step (`LATE FINALIZE: delay=<ms> reason=<…>`).
String? lateFinalizeReason(LateFinalizeStep step) => switch (step) {
  LateFinalizeStep.runSettled => 'settled',
  LateFinalizeStep.runImmediate => 'immediate',
  LateFinalizeStep.logAfterBurst => 'after_burst',
  LateFinalizeStep.skippedAlreadyResolved => 'skipped_already_resolved',
  LateFinalizeStep.none || LateFinalizeStep.droppedLegacy => null,
};

/// Per-session bookkeeping for the late re-run of ONE utterance at a time:
/// armed when a late transcript arrives, resolved exactly once.
class LateFinalizeController {
  LateFinalizeController({int? delayMs}) : delayMs = clampLateFinalizeMs(delayMs ?? kLateFinalizeMs);

  final int delayMs;

  /// The burst fix is part of the shorter settle: [lateFinalizeLegacyMs]
  /// keeps build 179's behaviour exactly.
  bool get burstFix => delayMs < lateFinalizeLegacyMs;

  Duration get delay => Duration(milliseconds: delayMs);

  int? _armedSeq;
  int? _deferredSeq;

  int? get armedSeq => _armedSeq;
  int? get deferredSeq => _deferredSeq;

  /// A late transcript arrived for utterance [seq]; the screen (re)starts
  /// its timer.
  void armed(int seq) {
    _armedSeq = seq;
    if (_deferredSeq != seq) _deferredSeq = null;
  }

  /// The settle timer fired.
  LateFinalizeStep onTimerFired({required int seq, required bool isSpeaking, required bool alreadyResolved}) {
    if (_armedSeq != seq) return LateFinalizeStep.none;
    _armedSeq = null;
    if (!isSpeaking) return LateFinalizeStep.runSettled;
    if (!burstFix) return LateFinalizeStep.droppedLegacy;
    if (alreadyResolved) return LateFinalizeStep.skippedAlreadyResolved;
    _deferredSeq = seq;
    return LateFinalizeStep.none;
  }

  /// A new utterance is about to reset everything for [seq] (the old one).
  LateFinalizeStep onNewUtterance({required int seq, required bool alreadyResolved}) {
    final pending = _armedSeq == seq || _deferredSeq == seq;
    _armedSeq = null;
    _deferredSeq = null;
    if (!pending) return LateFinalizeStep.none;
    if (!burstFix) return LateFinalizeStep.droppedLegacy;
    if (alreadyResolved) return LateFinalizeStep.skippedAlreadyResolved;
    return LateFinalizeStep.runImmediate;
  }

  /// The mic went quiet for utterance [seq]; its normal end-of-utterance
  /// routing runs right after this. A deferred re-run is covered by it.
  LateFinalizeStep onSpeechEnded({required int seq}) {
    if (_deferredSeq != seq) return LateFinalizeStep.none;
    _deferredSeq = null;
    return LateFinalizeStep.logAfterBurst;
  }

  /// Session teardown.
  void reset() {
    _armedSeq = null;
    _deferredSeq = null;
  }
}
