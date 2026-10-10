import 'dart:io';

import 'package:fielloop/services/cached_clip_player_wait.dart';
import 'package:fielloop/services/confirmation_clip.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 177 Step 2 — a cached clip skipped only because the player was
/// "re-initialising" (b176: 8 of 9 skips) waits up to 150ms for it.
void main() {
  group('clipPlayBlocker — build 176 order and wording', () {
    test('ready player, nothing playing -> no blocker', () {
      expect(clipPlayBlocker(playerReady: true, cameraNativeCallInProgress: false, otherAudioPlaying: false), isNull);
    });
    test('re-initialising is checked first', () {
      final b = clipPlayBlocker(playerReady: false, cameraNativeCallInProgress: true, otherAudioPlaying: true);
      expect(b, ClipPlayBlocker.playerReinitialising);
      expect(describeClipBlocker(b!), 'audio player re-initialising');
    });
    test('camera call, then other audio', () {
      expect(
        describeClipBlocker(
          clipPlayBlocker(playerReady: true, cameraNativeCallInProgress: true, otherAudioPlaying: true)!,
        ),
        'camera native call in progress',
      );
      expect(
        describeClipBlocker(
          clipPlayBlocker(playerReady: true, cameraNativeCallInProgress: false, otherAudioPlaying: true)!,
        ),
        'other audio still playing',
      );
    });
  });

  group('clipShouldWaitForPlayer — only the re-initialising blocker waits', () {
    test('re-initialising + flag on -> wait', () {
      expect(clipShouldWaitForPlayer(ClipPlayBlocker.playerReinitialising, enabled: true), isTrue);
    });
    test('flag off -> build 176 immediate fallback', () {
      expect(clipShouldWaitForPlayer(ClipPlayBlocker.playerReinitialising, enabled: false), isFalse);
    });
    test('other audio playing or a camera call never waits (no clip over other audio)', () {
      expect(clipShouldWaitForPlayer(ClipPlayBlocker.otherAudioPlaying, enabled: true), isFalse);
      expect(clipShouldWaitForPlayer(ClipPlayBlocker.cameraNativeCall, enabled: true), isFalse);
    });
    test('no blocker -> no wait (the clip plays at once, as before)', () {
      expect(clipShouldWaitForPlayer(null, enabled: true), isFalse);
    });
  });

  group('waitForClipPlayer', () {
    test('player ready -> ready at once', () async {
      final r = await waitForClipPlayer(ready: () => true, superseded: () => false);
      expect(r.outcome, ClipWaitOutcome.ready);
      expect(r.waitedMs, lessThan(cachedClipPlayerPoll.inMilliseconds + 5));
    });

    test('b176 race: readiness set by a chained Future (idle-player skip) -> ready after one microtask', () async {
      var pcmReady = false;
      // What _interruptGeminiForDeterministicTrigger does when the player is
      // idle: ready=false now, ready=true from `_pcmReinitChain.then(...)`.
      Future<void>.value().then((_) => pcmReady = true);
      expect(pcmReady, isFalse, reason: 'the synchronous clip check saw "re-initialising"');
      final r = await waitForClipPlayer(ready: () => pcmReady, superseded: () => false);
      expect(r.outcome, ClipWaitOutcome.ready);
      expect(r.waitedMs, lessThan(20));
    });

    test('re-initialising, then ready inside the wait -> ready', () async {
      var pcmReady = false;
      Future<void>.delayed(const Duration(milliseconds: 60), () => pcmReady = true);
      final r = await waitForClipPlayer(ready: () => pcmReady, superseded: () => false);
      expect(r.outcome, ClipWaitOutcome.ready);
      expect(r.waitedMs, inInclusiveRange(55, cachedClipPlayerMaxWait.inMilliseconds));
    });

    test('player not ready within 150ms -> timedOut (Gemini speaks it, today\'s fallback)', () async {
      final r = await waitForClipPlayer(ready: () => false, superseded: () => false);
      expect(r.outcome, ClipWaitOutcome.timedOut);
      expect(r.waitedMs, greaterThanOrEqualTo(cachedClipPlayerMaxWait.inMilliseconds));
      expect(r.waitedMs, lessThan(cachedClipPlayerMaxWait.inMilliseconds + 60));
    });

    test('player ready but other audio started playing -> still not played (timedOut)', () async {
      var pcmReady = false;
      const otherAudioPlaying = true;
      Future<void>.value().then((_) => pcmReady = true);
      final r = await waitForClipPlayer(
        ready: () =>
            clipPlayBlocker(
              playerReady: pcmReady,
              cameraNativeCallInProgress: false,
              otherAudioPlaying: otherAudioPlaying,
            ) ==
            null,
        superseded: () => false,
      );
      expect(r.outcome, ClipWaitOutcome.timedOut);
    });

    test('a newer reply / utterance during the wait -> superseded, never played', () async {
      var generation = 1;
      Future<void>.delayed(const Duration(milliseconds: 30), () => generation++);
      final r = await waitForClipPlayer(ready: () => false, superseded: () => generation != 1);
      expect(r.outcome, ClipWaitOutcome.superseded);
    });
  });

  group('stale-audio rule unchanged', () {
    test('a clip is only ever saved for the exact line', () {
      expect(confirmationTranscriptMatches('Okay.', 'Okay.'), isTrue);
      expect(confirmationTranscriptMatches('Okay, sure.', 'Okay.'), isFalse);
    });

    test('the screen only waits when a clip exists and re-initialising is the blocker, behind the flag', () {
      final src = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();
      expect(src, contains('const bool _cachedClipWaitForPlayer = true;'));
      expect(
        src,
        contains(
          'clipShouldWaitForPlayer(_currentClipBlocker(DateTime.now()), enabled: _cachedClipWaitForPlayer) &&\n'
          '        _cachedClipFor(text, reason) != null',
        ),
      );
      // After the wait the clip goes through the same _playCachedConfirmation
      // (same lookup, same blockers re-checked) or falls back to Gemini.
      expect(src, contains('result.outcome == ClipWaitOutcome.ready && _playCachedConfirmation(text, reason: reason)'));
    });
  });
}
