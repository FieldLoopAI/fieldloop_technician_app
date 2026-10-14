// Build 180 item D — the spoken close line plays to the end (4s cap) before
// _stopTest(voice_close); flag off restores build 179's rule and 2s cap.
// Offline.
import 'dart:io';

import 'package:fielloop/services/close_line_playback.dart';
import 'package:fielloop/services/local_close_command.dart';
import 'package:flutter_test/flutter_test.dart';

final String _screen = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();

void main() {
  test('flag defaults ON', () => expect(kCloseLineFullPlayback, isTrue));

  group('cap', () {
    test('4s with the flag on', () => expect(closeLineWaitCap(fullPlayback: true), const Duration(seconds: 4)));
    test('flag off restores build 179\'s 2s', () {
      expect(closeLineWaitCap(fullPlayback: false), localCloseReplyWaitCap);
      expect(localCloseReplyWaitCap, const Duration(seconds: 2));
    });
  });

  group('teardown waits for the whole line (flag on)', () {
    for (final (name, started, playing, delivered, prebufferEmpty, expected) in [
      ('not started yet', false, false, true, true, false),
      // b179 part 2 15:26:16.915: the only audio still in the prebuffer.
      ('started, audio still in the jitter prebuffer', true, false, false, false, false),
      ('started, frames still playing', true, true, false, true, false),
      ('server still sending (no turnComplete yet)', true, false, false, true, false),
      ('all delivered, still playing', true, true, true, true, false),
      ('all delivered and played', true, false, true, true, true),
    ]) {
      test(name, () {
        expect(
          closeLineFinished(
            started: started,
            playing: playing,
            turnDelivered: delivered,
            prebufferEmpty: prebufferEmpty,
            fullPlayback: true,
          ),
          expected,
        );
      });
    }
  });

  test('flag off: build 179\'s rule (started and not playing) exactly', () {
    for (final started in [true, false]) {
      for (final playing in [true, false]) {
        for (final delivered in [true, false]) {
          for (final empty in [true, false]) {
            expect(
              closeLineFinished(
                started: started,
                playing: playing,
                turnDelivered: delivered,
                prebufferEmpty: empty,
                fullPlayback: false,
              ),
              started && !playing,
            );
          }
        }
      }
    }
  });

  group('source: wiring in the screen', () {
    final at = _screen.indexOf('void _closeSessionByVoice() {');
    final method = _screen.substring(at, _screen.indexOf('\n  }\n', at));
    test('one reply request per close from the close path itself', () {
      expect(RegExp(r'_informGeminiToSpeakVerbatim\(').allMatches(method).length, 1);
      expect(method, contains("_informGeminiToSpeakVerbatim(localCloseClosingLine, reason: 'local_close')"));
    });
    test('waits on the build 180 rule and cap, then the same _stopTest', () {
      expect(method, contains('closeLineFinished('));
      expect(method, contains('turnDelivered: _turnComplete'));
      expect(method, contains('prebufferEmpty: _pcmPrebuffer.isEmpty'));
      expect(method, contains('final waitCap = closeLineWaitCap();'));
      expect(method, contains('waited < waitCap'));
      expect(method, contains("unawaited(_stopTest(reason: 'voice_close'));"));
    });
    test('the LOCAL CLOSE ending line is unchanged in shape', () {
      expect(method, contains("'LOCAL CLOSE: ending the session (closing line \${finished ? 'finished' : 'not finished"));
      expect(method, contains("'after \${waited.inMilliseconds}ms) -> _stopTest(voice_close)'"));
    });
  });
}
