import 'dart:io';

import 'package:fielloop/services/latency_stats.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/analyze_voice_logs.dart';

/// Build 177 Step 6 — "first audio" never exceeds "total", and one session
/// total line.
void main() {
  final source = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();

  group('turnActionToFirstAudioMs', () {
    // b176 14:06:09.369: greeting requested 14:05:57.624 (the stale action
    // time), transcript 14:06:08.157, first audio 14:06:09.369, total 1212ms.
    final firstAudio = DateTime(2026, 10, 9, 14, 6, 9, 369);

    test('b176 glitch: an action time from before the turn began is n/a, not 11745ms', () {
      final stale = DateTime(2026, 10, 9, 14, 5, 57, 624);
      expect(firstAudio.difference(stale).inMilliseconds, 11745, reason: 'what build 176 logged');
      expect(turnActionToFirstAudioMs(actionAt: stale, firstAudioAt: firstAudio, totalMs: 1212), isNull);
    });

    test('a real action inside the turn is unchanged', () {
      final action = DateTime(2026, 10, 9, 14, 6, 8, 160);
      expect(turnActionToFirstAudioMs(actionAt: action, firstAudioAt: firstAudio, totalMs: 1212), 1209);
    });

    test('a clip that played at the action is 0ms; no action is n/a', () {
      expect(turnActionToFirstAudioMs(actionAt: firstAudio, firstAudioAt: firstAudio, totalMs: 1711), 0);
      expect(turnActionToFirstAudioMs(actionAt: null, firstAudioAt: firstAudio, totalMs: 1711), isNull);
    });

    test('never greater than total, whatever the inputs', () {
      for (final back in [0, 1, 500, 1211, 1212, 1213, 5000, 11745]) {
        final ms = turnActionToFirstAudioMs(
          actionAt: firstAudio.subtract(Duration(milliseconds: back)),
          firstAudioAt: firstAudio,
          totalMs: 1212,
        );
        if (ms != null) expect(ms, lessThanOrEqualTo(1212));
      }
    });
  });

  group('the cause: app-initiated lines no longer set the turn\'s action time', () {
    test('session greeting / inactivity warning are excluded, behind the flag', () {
      expect(source, contains('const bool _turnTimingFirstAudioFix = true;'));
      expect(
        source,
        contains(
          'final timesTurn = !isFiller && !(_turnTimingFirstAudioFix && _systemInitiatedReplyLabels.containsKey(reason));',
        ),
      );
      for (final reason in ['inactivity_warning', 'session_greeting', 'session_greeting_replay']) {
        expect(source, contains("'$reason': "));
      }
    });

    test('both TURN TIMING sites use the clamp', () {
      expect(RegExp(r'turnActionToFirstAudioMs\(actionAt: actionAt, firstAudioAt: now').allMatches(source).length, 2);
    });
  });

  group('TURN TIMING SESSION TOTAL', () {
    test('counts turns and estimated turns', () {
      const turns = [
        TurnTiming(totalMs: 1000, replyFromClip: true),
        TurnTiming(totalMs: 2000, replyFromClip: false, estimatedSpeechEnd: 'transcript arrival, a lower bound'),
        TurnTiming(totalMs: 3000, replyFromClip: false, estimatedSpeechEnd: 'last mic chunk at RMS >= 300'),
      ];
      expect(describeTurnTimingSessionTotal(turns), 'TURN TIMING SESSION TOTAL: turns=3 estimated=2');
      expect(describeTurnTimingSessionTotal(const []), 'TURN TIMING SESSION TOTAL: turns=0 estimated=0');
    });

    test('logged once per session, right after TURN TIMING SUMMARY', () {
      final summary = source.indexOf('describeTurnTimingSummary(_sessionTurnTimings');
      final total = source.indexOf('describeTurnTimingSessionTotal(_sessionTurnTimings)');
      expect(total, greaterThan(summary));
      expect(total - summary, lessThan(400));
    });

    test('the log analyzer shows it and does not count it as a turn', () {
      const log =
          '10-09 14:08:37.457 11446 11446 I flutter : GEMINI LIVE TEST: TURN TIMING SESSION TOTAL: turns=10 '
          'estimated=6\n';
      final report = analyzeVoiceLogs({'p': log});
      expect(report, contains('turns=10 estimated=6'));
      expect(report, contains('p: turns=0'));
    });
  });

  test('speechEdgeRms default is still 500 (not changed by this step)', () {
    expect(source, contains('const double _speechRmsThreshold = kSpeechEdgeRms;'));
  });
}
