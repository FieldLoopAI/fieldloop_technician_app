/// FIX 7 (Module B metrics) — the per-session numbers the Acceptance Test
/// scores (p50 <= 1000ms, p90 <= 1500ms, zero dead stretches >= 3s),
/// computed from the same per-turn values each
/// `LATENCY (stopped speaking -> first response byte)` line logs, so the
/// `LATENCY SUMMARY` line and a hand count of those lines always agree.
library;

/// Nearest-rank percentile ([p] in 0..100) of [values]; `null` when empty.
/// Nearest-rank (not interpolated) so every reported figure is a latency
/// that actually happened and can be found in the log.
int? nearestRankPercentile(List<int> values, double p) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  var rank = (p / 100 * sorted.length).ceil();
  if (rank < 1) rank = 1;
  if (rank > sorted.length) rank = sorted.length;
  return sorted[rank - 1];
}

/// One-line summary for the log.
///
/// [estimated] (build 176 Step 1): how many of [latenciesMs] were timed
/// from an ESTIMATED speech end (see [estimateSpeechEnd]) — appended only
/// when given, so the line is otherwise unchanged.
String describeLatencySummary(List<int> latenciesMs, {required int deadStretches, required int hangs, int? estimated}) {
  final est = estimated == null ? '' : ' estimated_speech_end=$estimated/${latenciesMs.length}';
  if (latenciesMs.isEmpty) {
    return 'LATENCY SUMMARY: n=0 (no timed technician turns this session) deadStretches(>=3s)=$deadStretches '
        'hangs=$hangs$est';
  }
  final p50 = nearestRankPercentile(latenciesMs, 50);
  final p90 = nearestRankPercentile(latenciesMs, 90);
  final max = latenciesMs.reduce((a, b) => a > b ? a : b);
  return 'LATENCY SUMMARY: n=${latenciesMs.length} p50=${p50}ms p90=${p90}ms max=${max}ms '
      'deadStretches(>=3s)=$deadStretches hangs=$hangs$est (all values: ${latenciesMs.join(', ')})';
}

/// Change 5 — one turn's split, logged as `TURN TIMING` next to the
/// unchanged `LATENCY` line. Any part can be null when that moment wasn't
/// observed (e.g. no transcript before the reply, or no app action).
class TurnTiming {
  const TurnTiming({
    this.speechEndToTranscriptMs,
    this.transcriptToActionMs,
    this.actionToFirstAudioMs,
    required this.totalMs,
    required this.replyFromClip,
    this.replyKind,
    this.estimatedSpeechEnd,
  });

  final int? speechEndToTranscriptMs;
  final int? transcriptToActionMs;
  final int? actionToFirstAudioMs;
  final int totalMs;
  final bool replyFromClip;

  /// Build 176 Step 1 — one of [TurnReplyKind]'s labels; `null` keeps the
  /// older `reply=cached clip|gemini` wording.
  final String? replyKind;

  /// Build 176 Step 1 — set when no true speech-end edge existed and the
  /// turn was timed from [estimateSpeechEnd]'s estimate; names its source.
  final String? estimatedSpeechEnd;

  bool get isEstimated => estimatedSpeechEnd != null;

  String describe() {
    String ms(int? v) => v == null ? 'n/a' : '${v}ms';
    return 'TURN TIMING: speech end -> transcript ${ms(speechEndToTranscriptMs)}, transcript -> action done '
        '${ms(transcriptToActionMs)}, action done -> first audio ${ms(actionToFirstAudioMs)}, total ${totalMs}ms '
        '(reply=${replyKind ?? (replyFromClip ? 'cached clip' : 'gemini')})'
        '${estimatedSpeechEnd == null ? '' : ' (estimated speech end: $estimatedSpeechEnd)'}';
  }
}

/// Build 176 Step 1 — the reply-kind labels a `TURN TIMING` line carries.
abstract final class TurnReplyKind {
  static const clip = 'cached clip';
  static const liveGemini = 'live gemini';
  static const deterministic = 'deterministic';
  static const refusal = 'refusal';

  /// [fromClip]: the reply played from a saved clip; [appReplyReason]: the
  /// `reason` of the app's own first (non-filler) reply request this turn,
  /// `null` when the app asked for none (Gemini answered on its own).
  static String classify({required bool fromClip, String? appReplyReason}) {
    if (fromClip) return clip;
    if (appReplyReason == null) return liveGemini;
    final r = appReplyReason.toLowerCase();
    if (r.contains('out_of_scope') || r.contains('out of scope') || r.contains('refus')) return refusal;
    return deterministic;
  }
}

/// Build 176 Step 1 — the speech end a turn is timed from when the mic's
/// RMS-500 edge never fired (b175: 73 of 83 turns; quiet speech at avg RMS
/// ~110 / peak ~440 never crosses 500). Logging only.
///
/// Prefers the last mic chunk Gemini received at or above the lower,
/// measurement-only level ([lastVoiceLikeChunkAt]) when it falls inside
/// `[transcriptAt - maxGap, transcriptAt]`; otherwise the transcript's own
/// arrival (a lower bound — the real speech end was earlier). `null` when
/// there is no transcript to anchor on.
({DateTime at, String source})? estimateSpeechEnd({
  required DateTime? transcriptAt,
  DateTime? lastVoiceLikeChunkAt,
  Duration maxGap = const Duration(seconds: 8),
  int voiceLikeRms = 300,
}) {
  if (transcriptAt == null) return null;
  final chunk = lastVoiceLikeChunkAt;
  if (chunk != null && !chunk.isAfter(transcriptAt) && transcriptAt.difference(chunk) <= maxGap) {
    return (at: chunk, source: 'last mic chunk at RMS >= $voiceLikeRms');
  }
  return (at: transcriptAt, source: 'transcript arrival, a lower bound');
}

/// `TURN TIMING SUMMARY` — p50/p90 of each part, logged at session end
/// next to `LATENCY SUMMARY`.
///
/// [lateTranscripts]/[maxLateMs]: transcripts that arrived after the 3s
/// timeout (the `TRANSCRIPT LATE` lines) and the latest of them, in ms
/// after speech end; [vadSetting]: which end-of-speech A/B setting this
/// session ran with. Each is appended only when given, so the line is
/// otherwise unchanged.
String describeTurnTimingSummary(List<TurnTiming> turns, {int? lateTranscripts, int? maxLateMs, String? vadSetting}) {
  final extra = '${lateTranscripts == null ? '' : '; late_transcripts=$lateTranscripts max_late_ms=${maxLateMs ?? 0}'}'
      '${vadSetting == null ? '' : '; $vadSetting'}';
  if (turns.isEmpty) return 'TURN TIMING SUMMARY: n=0$extra';
  String part(String label, Iterable<int?> values) {
    final present = [for (final v in values) ?v];
    if (present.isEmpty) return '$label n/a';
    return '$label p50=${nearestRankPercentile(present, 50)}ms p90=${nearestRankPercentile(present, 90)}ms '
        '(n=${present.length})';
  }

  final clips = turns.where((t) => t.replyFromClip).length;
  // Build 176 Step 1 — only when a turn carries a reply kind or an
  // estimated speech end, so older lines read exactly as before.
  final estimated = turns.where((t) => t.isEstimated).length;
  final kinds = <String, int>{};
  for (final t in turns) {
    final k = t.replyKind;
    if (k != null) kinds[k] = (kinds[k] ?? 0) + 1;
  }
  final b176 = estimated == 0 && kinds.isEmpty
      ? ''
      : '; estimated_speech_end=$estimated/${turns.length}'
            '${kinds.isEmpty ? '' : '; reply kinds: ${kinds.entries.map((e) => '${e.key}=${e.value}').join(', ')}'}';
  return 'TURN TIMING SUMMARY: n=${turns.length}; '
      '${part('speechEnd->transcript', turns.map((t) => t.speechEndToTranscriptMs))}; '
      '${part('transcript->action', turns.map((t) => t.transcriptToActionMs))}; '
      '${part('action->firstAudio', turns.map((t) => t.actionToFirstAudioMs))}; '
      '${part('total', turns.map((t) => t.totalMs))}; replies from cached clip: $clips/${turns.length}$b176$extra';
}

/// Step 5 (build 175 second pass) — whether a speech-end edge must be
/// ignored for timing: the utterance already has a speech end
/// ([currentSpeechEnd]) AND its transcript has already arrived
/// ([transcriptAt]), so a later edge in the same utterance is noise after
/// the words, not the end of them. Logging only — DEAD STRETCH, LATENCY and
/// TURN TIMING then measure from the true speech end.
bool ignoreLaterSpeechEndEdge({required bool enabled, DateTime? currentSpeechEnd, DateTime? transcriptAt}) =>
    enabled && currentSpeechEnd != null && transcriptAt != null;

/// Build 177 Step 6 — "action done -> first audio" for a TURN TIMING line,
/// never more than the turn's own total. b176 14:06:09.369: 11745ms vs
/// total 1212ms — the action time was the session greeting's (requested
/// 14:05:57.622, before the technician's transcript), kept by `??=` for the
/// first real reply. An action time from before the turn began (earlier
/// than `firstAudioAt - totalMs`) belongs to an earlier line: `null` (n/a).
int? turnActionToFirstAudioMs({required DateTime? actionAt, required DateTime firstAudioAt, required int totalMs}) {
  if (actionAt == null) return null;
  final ms = firstAudioAt.difference(actionAt).inMilliseconds;
  if (ms < 0 || ms > totalMs) return null;
  return ms;
}

/// Build 177 Step 6 — one line per session: how many turns were timed and
/// how many of them from an estimated speech end.
String describeTurnTimingSessionTotal(List<TurnTiming> turns) =>
    'TURN TIMING SESSION TOTAL: turns=${turns.length} estimated=${turns.where((t) => t.isEstimated).length}';
