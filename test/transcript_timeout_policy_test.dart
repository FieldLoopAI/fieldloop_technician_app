import 'package:fielloop/services/transcript_timeout_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('missing-transcript decision (change 1b)', () {
    test('decided at 3s, not 8s', () {
      expect(transcriptTimeoutFallbackAfter, const Duration(seconds: 3));
    });

    test('default: a missing transcript is silent, a late transcript still handled', () {
      expect(
        decideTranscriptTimeout(
          triggerCommittedThisUtterance: false,
          replyAlreadySpokenThisUtterance: false,
          functionCallsInFlight: 0,
        ),
        TranscriptTimeoutAction.silentAwaitLate,
      );
    });

    test('switch off: the old ask-to-repeat behavior', () {
      expect(
        decideTranscriptTimeout(
          triggerCommittedThisUtterance: false,
          replyAlreadySpokenThisUtterance: false,
          functionCallsInFlight: 0,
          silent: false,
        ),
        TranscriptTimeoutAction.askToRepeat,
      );
    });

    // No double-fire: if anything already answered or is answering this
    // utterance, the timeout does nothing in either mode.
    for (final silent in [true, false]) {
      test('nothing when a trigger already committed (silent=$silent)', () {
        expect(
          decideTranscriptTimeout(
            triggerCommittedThisUtterance: true,
            replyAlreadySpokenThisUtterance: false,
            functionCallsInFlight: 0,
            silent: silent,
          ),
          TranscriptTimeoutAction.nothing,
        );
      });
      test('nothing when a reply was already spoken (silent=$silent)', () {
        expect(
          decideTranscriptTimeout(
            triggerCommittedThisUtterance: false,
            replyAlreadySpokenThisUtterance: true,
            functionCallsInFlight: 0,
            silent: silent,
          ),
          TranscriptTimeoutAction.nothing,
        );
      });
      test('nothing while a function call is in flight (silent=$silent)', () {
        expect(
          decideTranscriptTimeout(
            triggerCommittedThisUtterance: false,
            replyAlreadySpokenThisUtterance: false,
            functionCallsInFlight: 1,
            silent: silent,
          ),
          TranscriptTimeoutAction.nothing,
        );
      });
    }
  });

  test('TRANSCRIPT LATE line says how late it was, what was done, and no claimed cause', () {
    final line =
        describeTranscriptLate(msAfterSpeechEnd: 7548, action: 'negation_guard', text: "I don't want to take photo.");
    expect(
      line,
      'TRANSCRIPT LATE ms=7548 action=negation_guard cause=unconfirmed (4548ms after the 3000ms timeout) '
      'text="I don\'t want to take photo."',
    );
    expect(line, isNot(contains('silent_non_speech')));
  });
}
