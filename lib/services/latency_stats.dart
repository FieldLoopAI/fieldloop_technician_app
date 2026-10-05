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
