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
String describeLatencySummary(List<int> latenciesMs, {required int deadStretches, required int hangs}) {
  if (latenciesMs.isEmpty) {
    return 'LATENCY SUMMARY: n=0 (no timed technician turns this session) deadStretches(>=3s)=$deadStretches '
        'hangs=$hangs';
  }
  final p50 = nearestRankPercentile(latenciesMs, 50);
  final p90 = nearestRankPercentile(latenciesMs, 90);
  final max = latenciesMs.reduce((a, b) => a > b ? a : b);
  return 'LATENCY SUMMARY: n=${latenciesMs.length} p50=${p50}ms p90=${p90}ms max=${max}ms '
      'deadStretches(>=3s)=$deadStretches hangs=$hangs (all values: ${latenciesMs.join(', ')})';
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
  });

  final int? speechEndToTranscriptMs;
  final int? transcriptToActionMs;
  final int? actionToFirstAudioMs;
  final int totalMs;
  final bool replyFromClip;

  String describe() {
    String ms(int? v) => v == null ? 'n/a' : '${v}ms';
    return 'TURN TIMING: speech end -> transcript ${ms(speechEndToTranscriptMs)}, transcript -> action done '
        '${ms(transcriptToActionMs)}, action done -> first audio ${ms(actionToFirstAudioMs)}, total ${totalMs}ms '
        '(reply=${replyFromClip ? 'cached clip' : 'gemini'})';
  }
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
  return 'TURN TIMING SUMMARY: n=${turns.length}; '
      '${part('speechEnd->transcript', turns.map((t) => t.speechEndToTranscriptMs))}; '
      '${part('transcript->action', turns.map((t) => t.transcriptToActionMs))}; '
      '${part('action->firstAudio', turns.map((t) => t.actionToFirstAudioMs))}; '
      '${part('total', turns.map((t) => t.totalMs))}; replies from cached clip: $clips/${turns.length}$extra';
}

/// Step 5 (build 175 second pass) — whether a speech-end edge must be
/// ignored for timing: the utterance already has a speech end
/// ([currentSpeechEnd]) AND its transcript has already arrived
/// ([transcriptAt]), so a later edge in the same utterance is noise after
/// the words, not the end of them. Logging only — DEAD STRETCH, LATENCY and
/// TURN TIMING then measure from the true speech end.
bool ignoreLaterSpeechEndEdge({required bool enabled, DateTime? currentSpeechEnd, DateTime? transcriptAt}) =>
    enabled && currentSpeechEnd != null && transcriptAt != null;
