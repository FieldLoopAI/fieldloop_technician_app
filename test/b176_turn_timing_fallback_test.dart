import 'package:fielloop/services/latency_stats.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 176 Step 1 — TURN TIMING for every turn, including the ones whose
/// RMS-500 speech-end edge never fired (b175: ~73 of 83 turns).
void main() {
  group('estimateSpeechEnd — fallback when no true speech edge exists', () {
    // b175 14:53:17.232 "Show me the estimate." — mic RMS avg ~112, peak
    // 244, "last chunk over RMS 500 never", clip first audio at 17.240.
    final transcriptAt = DateTime(2026, 10, 8, 14, 53, 17, 232);

    test('no transcript -> no estimate (nothing to time)', () {
      expect(estimateSpeechEnd(transcriptAt: null), isNull);
    });

    test('quiet chunk shortly before the transcript is used', () {
      final chunk = transcriptAt.subtract(const Duration(milliseconds: 900));
      final e = estimateSpeechEnd(transcriptAt: transcriptAt, lastVoiceLikeChunkAt: chunk)!;
      expect(e.at, chunk);
      expect(e.source, contains('RMS >= 300'));
    });

    test('no voice-like chunk -> transcript arrival, labelled a lower bound', () {
      final e = estimateSpeechEnd(transcriptAt: transcriptAt)!;
      expect(e.at, transcriptAt);
      expect(e.source, contains('transcript arrival'));
    });

    test('a chunk after the transcript or older than the window is not used', () {
      final after = estimateSpeechEnd(
        transcriptAt: transcriptAt,
        lastVoiceLikeChunkAt: transcriptAt.add(const Duration(milliseconds: 50)),
      )!;
      expect(after.at, transcriptAt);
      final stale = estimateSpeechEnd(
        transcriptAt: transcriptAt,
        lastVoiceLikeChunkAt: transcriptAt.subtract(const Duration(seconds: 9)),
      )!;
      expect(stale.at, transcriptAt);
    });
  });

  group('TURN TIMING line for an estimated turn', () {
    test('is never skipped and says it is estimated', () {
      const t = TurnTiming(
        transcriptToActionMs: 8,
        actionToFirstAudioMs: 0,
        totalMs: 8,
        replyFromClip: true,
        replyKind: TurnReplyKind.clip,
        estimatedSpeechEnd: 'transcript arrival, a lower bound',
      );
      final line = t.describe();
      expect(line, startsWith('TURN TIMING: speech end -> transcript n/a'));
      expect(line, contains('(reply=cached clip)'));
      expect(line, endsWith('(estimated speech end: transcript arrival, a lower bound)'));
    });

    test('a normal (true speech end) line is unchanged apart from the reply kind', () {
      const t = TurnTiming(
        speechEndToTranscriptMs: 1871,
        transcriptToActionMs: 4,
        actionToFirstAudioMs: 1549,
        totalMs: 3425,
        replyFromClip: false,
      );
      expect(
        t.describe(),
        'TURN TIMING: speech end -> transcript 1871ms, transcript -> action done 4ms, '
        'action done -> first audio 1549ms, total 3425ms (reply=gemini)',
      );
    });
  });

  group('reply kinds', () {
    test('clip / live gemini / deterministic / refusal', () {
      expect(TurnReplyKind.classify(fromClip: true, appReplyReason: 'deterministic view_estimate'), 'cached clip');
      expect(TurnReplyKind.classify(fromClip: false), 'live gemini');
      expect(TurnReplyKind.classify(fromClip: false, appReplyReason: 'job_fact customer_name'), 'deterministic');
      expect(TurnReplyKind.classify(fromClip: false, appReplyReason: 'out_of_scope_fast'), 'refusal');
    });
  });

  group('summaries count every turn, estimated ones included', () {
    test('TURN TIMING SUMMARY shows the estimated count and reply kinds', () {
      final line = describeTurnTimingSummary(const [
        TurnTiming(speechEndToTranscriptMs: 900, totalMs: 1200, replyFromClip: false, replyKind: 'live gemini'),
        TurnTiming(totalMs: 20, replyFromClip: true, replyKind: 'cached clip', estimatedSpeechEnd: 'x'),
        TurnTiming(totalMs: 30, replyFromClip: true, replyKind: 'cached clip', estimatedSpeechEnd: 'x'),
      ]);
      expect(line, contains('n=3'));
      expect(line, contains('estimated_speech_end=2/3'));
      expect(line, contains('reply kinds: live gemini=1, cached clip=2'));
    });

    test('LATENCY SUMMARY shows how many were estimated', () {
      final line = describeLatencySummary(const [1200, 20, 30], deadStretches: 0, hangs: 0, estimated: 2);
      expect(line, contains('n=3'));
      expect(line, contains('estimated_speech_end=2/3'));
    });

    test('lines without the new fields read exactly as before', () {
      expect(
        describeLatencySummary(const [800], deadStretches: 0, hangs: 0),
        'LATENCY SUMMARY: n=1 p50=800ms p90=800ms max=800ms deadStretches(>=3s)=0 hangs=0 (all values: 800)',
      );
      expect(describeTurnTimingSummary(const [TurnTiming(totalMs: 900, replyFromClip: false)]), isNot(contains('estimated')));
    });
  });
}
