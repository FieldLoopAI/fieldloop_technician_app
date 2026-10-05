import 'package:fielloop/services/latency_stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nearest-rank percentiles over a 20-turn session', () {
    final values = [for (var i = 1; i <= 20; i++) i * 100]; // 100..2000
    expect(nearestRankPercentile(values, 50), 1000);
    expect(nearestRankPercentile(values, 90), 1800);
  });

  test('order does not matter and every result is a real sample', () {
    const values = [1200, 400, 900, 3100, 700];
    expect(nearestRankPercentile(values, 50), 900);
    expect(nearestRankPercentile(values, 90), 3100);
    expect(values, contains(nearestRankPercentile(values, 90)));
  });

  test('empty and single-value sessions', () {
    expect(nearestRankPercentile(const [], 50), isNull);
    expect(nearestRankPercentile(const [850], 90), 850);
    expect(describeLatencySummary(const [], deadStretches: 0, hangs: 0), contains('n=0'));
  });

  test('summary line carries every figure the acceptance test scores', () {
    final line = describeLatencySummary(const [800, 950, 1400, 3200], deadStretches: 1, hangs: 0);
    expect(line, contains('n=4'));
    expect(line, contains('p50=950ms'));
    expect(line, contains('p90=3200ms'));
    expect(line, contains('deadStretches(>=3s)=1'));
    expect(line, contains('hangs=0'));
  });
}
