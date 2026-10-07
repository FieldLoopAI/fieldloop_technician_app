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

  group('TURN TIMING (change 5)', () {
    test('per-turn line shows every part, n/a where not observed', () {
      const t = TurnTiming(
        speechEndToTranscriptMs: 1300,
        transcriptToActionMs: 1,
        actionToFirstAudioMs: 25,
        totalMs: 1326,
        replyFromClip: true,
      );
      expect(
        t.describe(),
        'TURN TIMING: speech end -> transcript 1300ms, transcript -> action done 1ms, action done -> first audio '
        '25ms, total 1326ms (reply=cached clip)',
      );
      expect(const TurnTiming(totalMs: 900, replyFromClip: false).describe(), contains('transcript n/a'));
    });

    test('session summary: p50/p90 per part, skipping parts not observed', () {
      final turns = [
        const TurnTiming(speechEndToTranscriptMs: 1200, transcriptToActionMs: 0, actionToFirstAudioMs: 800, totalMs: 2000, replyFromClip: false),
        const TurnTiming(speechEndToTranscriptMs: 1300, transcriptToActionMs: 1, actionToFirstAudioMs: 20, totalMs: 1321, replyFromClip: true),
        const TurnTiming(totalMs: 1500, replyFromClip: false),
      ];
      final line = describeTurnTimingSummary(turns);
      expect(line, contains('n=3'));
      expect(line, contains('speechEnd->transcript p50=1200ms p90=1300ms (n=2)'));
      expect(line, contains('action->firstAudio p50=20ms p90=800ms (n=2)'));
      expect(line, contains('total p50=1500ms p90=2000ms (n=3)'));
      expect(line, contains('replies from cached clip: 1/3'));
      expect(line, isNot(contains('late_transcripts')));
      final withExtras = describeTurnTimingSummary(
        turns,
        lateTranscripts: 3,
        maxLateMs: 7548,
        vadSetting: 'vad_silence_ms=400 vad_end_sensitivity=default',
      );
      expect(withExtras, startsWith(line));
      expect(withExtras, endsWith('; late_transcripts=3 max_late_ms=7548; vad_silence_ms=400 vad_end_sensitivity=default'));
      expect(
        describeTurnTimingSummary(const [], lateTranscripts: 0),
        'TURN TIMING SUMMARY: n=0; late_transcripts=0 max_late_ms=0',
      );
      expect(describeTurnTimingSummary(const []), 'TURN TIMING SUMMARY: n=0');
    });
  });
}
