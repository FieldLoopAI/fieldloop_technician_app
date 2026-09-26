import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/echo_override_policy.dart';

/// Replays the six echo-flagged transcripts from the real trace (all of
/// which were our own speech, heard after the mic watchdog force-resumed
/// while the reply was still playing) plus the cases the override exists
/// for: a technician mirroring the app's wording after it finished.
void main() {
  final t0 = DateTime(2026, 9, 25, 16, 48);
  DateTime at(num seconds) => t0.add(Duration(milliseconds: (seconds * 1000).round()));

  EchoDecision decide({
    bool echo = true,
    bool command = true,
    required num? speechStart,
    required num? confirmedEnd,
    num? playbackStart,
  }) => decideEcho(
    textLooksLikeEcho: echo,
    commandMatched: command,
    speechStartedAt: speechStart == null ? null : at(speechStart),
    playbackConfirmedEndedAt: confirmedEnd == null ? null : at(confirmedEnd),
    lastPlaybackStartedAt: playbackStart == null ? null : at(playbackStart),
  );

  group('echoes from the real trace stay suppressed', () {
    test('"Yes, I\'m ready to capture it. Are you ready for me to take it?" — speech began 59.03, '
        'player confirmed done only at 63.5', () {
      expect(decide(speechStart: 59.03, confirmedEnd: 63.5, playbackStart: 47.9), EchoDecision.suppress);
    });

    test('an echo whose playback is not confirmed finished at all', () {
      expect(decide(speechStart: 21.5, confirmedEnd: null, playbackStart: 11.0), EchoDecision.suppress);
    });

    test('confirmation belongs to an OLDER playback, not the one that just played', () {
      expect(decide(speechStart: 30, confirmedEnd: 10, playbackStart: 20), EchoDecision.suppress);
    });

    test('genuine mic bleed within ~1s of playback ending (inside the tail margin)', () {
      expect(decide(speechStart: 10.2, confirmedEnd: 10.0, playbackStart: 5), EchoDecision.suppress);
    });

    test('echo-like text with no command in it (e.g. "Sorry, I misspoke…") is never overridden', () {
      expect(decide(command: false, speechStart: 40, confirmedEnd: 10, playbackStart: 5), EchoDecision.suppress);
    });
  });

  group('a technician mirroring the app\'s wording after it finished speaking fires', () {
    test('"go ahead and take it" said 1.2s after playback confirmed done', () {
      expect(decide(speechStart: 11.2, confirmedEnd: 10.0, playbackStart: 5), EchoDecision.override);
    });

    test('"capture it" said well after', () {
      expect(decide(speechStart: 25, confirmedEnd: 10, playbackStart: 5), EchoDecision.override);
    });
  });

  test('text that does not look like echo is not this policy\'s business', () {
    expect(decide(echo: false, speechStart: 1, confirmedEnd: 2), EchoDecision.notEcho);
  });
}
