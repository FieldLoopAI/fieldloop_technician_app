/// Build 182 item A ([kOneReplyPerUtterance]) — one reply per utterance.
///
/// b181 log 14:21:16: "Don't close the session" got the stored clip "Sorry,
/// can you say that again?" (reason=garbled_quick_repeat), then ~1.9 s later
/// the PREEMPTIVE DEFAULT MUTE 2 s safety timeout asked for a SECOND line for
/// the same utterance (reason=preemptive_default_mute_timeout). A clip plays
/// locally and never reaches `_interruptGeminiForDeterministicTrigger`, the
/// one place that cancels that timer — so the timer still fired.
///
/// With this guard the timeout, for an utterance the app already answered,
/// clears the mute silently instead (log `ONE REPLY: suppressed ...`). It
/// still counts the utterance once in the UNCLEAR INPUT streak, exactly where
/// the timeout counted it before, so the 1st full / 2nd short / 3rd+ quiet
/// escalation of later unanswered utterances is unchanged. An utterance
/// nothing answered still gets the timeout's reply as before.
///
/// Pure Dart and deterministic: no network, no Gemini call.
library;

import 'b182_flags.dart';

/// What the safety timeout does for the current utterance.
class TimeoutReplyDecision {
  const TimeoutReplyDecision._(this.suppress, this.countUnclear, this.answeredBy);

  /// Nothing answered it: the existing timeout reply runs (it counts).
  static const speak = TimeoutReplyDecision._(false, false, null);

  /// true = clear the mute silently, no reply.
  final bool suppress;

  /// true = count this utterance in the unclear streak now (the reply that
  /// answered it did not already count it).
  final bool countUnclear;

  /// The `_informGeminiToSpeakVerbatim` reason that already answered it.
  final String? answeredBy;
}

/// Per-session record of which utterance the app last answered and which
/// one the UNCLEAR INPUT streak last counted.
class OneReplyGuard {
  OneReplyGuard({this.enabled = kOneReplyPerUtterance});

  final bool enabled;

  ({int seq, String reason})? _answered;
  int? _countedSeq;

  ({int seq, String reason})? get answered => _answered;

  /// The app asked for a reply (clip or spoken) to utterance [seq].
  void recordReply(int seq, String reason) => _answered = (seq: seq, reason: reason);

  /// The unclear streak counted utterance [seq].
  void recordUnclearCounted(int seq) => _countedSeq = seq;

  /// The 2 s safety timeout fired while utterance [seq] is current.
  TimeoutReplyDecision onSafetyTimeout(int seq) {
    final answered = _answered;
    if (!enabled || answered == null || answered.seq != seq) return TimeoutReplyDecision.speak;
    return TimeoutReplyDecision._(true, _countedSeq != seq, answered.reason);
  }
}
