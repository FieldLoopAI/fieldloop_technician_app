// Build 180 item C — "Not ready." / "Hold on." with the camera live or
// opening get "Okay."; nothing is captured; Job Detail, the photo note and a
// pending close question keep their existing handling. Offline.
import 'dart:io';

import 'package:fielloop/services/local_close_command.dart';
import 'package:fielloop/services/photo_decline.dart';
import 'package:fielloop/services/wait_hold_intent.dart';
import 'package:fielloop/services/wider_capture.dart';
import 'package:flutter_test/flutter_test.dart';

final String _screen = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();

/// The screen's state check, by name.
bool _applies(String state, {bool photoNote = false, bool closePending = false}) => waitHoldApplies(
  cameraLiveOrOpening: state == 'cameraLive' || state == 'cameraOpening',
  photoNoteActive: photoNote,
  closeQuestionPending: closePending,
);

/// Whether the wait path answers [text] in [state].
bool _waits(String text, String state, {bool photoNote = false, bool closePending = false}) =>
    kWaitHoldIntent && _applies(state, photoNote: photoNote, closePending: closePending) && matchWaitHold(text) != null;

void main() {
  test('flag defaults ON', () => expect(kWaitHoldIntent, isTrue));

  const spoken = [
    ('Not ready.', 'not ready'),
    ('Not ready yet.', 'not ready yet'),
    ('I am not ready.', 'i am not ready'),
    ("I'm not ready.", 'i m not ready'),
    ('Not yet.', 'not yet'),
    ('Hold on.', 'hold on'),
    ('Hang on.', 'hang on'),
    ('Wait.', 'wait'),
    ('Wait a second.', 'wait a second'),
    ('Wait a minute.', 'wait a minute'),
    ('One second.', 'one second'),
    ('Just a second.', 'just a second'),
    ('Give me a second.', 'give me a second'),
    ('Give me a minute.', 'give me a minute'),
    ('Hold on a second.', 'hold on a second'),
    ('Okay, hold on.', 'hold on'),
    ('Um, not yet.', 'not yet'),
  ];

  group('each phrase is recognized', () {
    for (final (text, phrase) in spoken) {
      test(text, () => expect(matchWaitHold(text), phrase));
    }
  });

  group('camera live and camera opening -> wait path', () {
    for (final state in ['cameraLive', 'cameraOpening']) {
      for (final (text, _) in spoken) {
        test('$state: $text', () => expect(_waits(text, state), isTrue));
      }
    }
  });

  group('NOT this path: Job Detail, captured photo, photo note, close question pending', () {
    for (final (text, _) in spoken) {
      test('Job Detail: $text', () => expect(_waits(text, 'none'), isFalse));
      test('camera closing: $text', () => expect(_waits(text, 'cameraClosing'), isFalse));
      test('captured photo: $text', () => expect(_waits(text, 'cameraCaptured'), isFalse));
      test('photo note (camera live): $text', () => expect(_waits(text, 'cameraLive', photoNote: true), isFalse));
      test('close question pending: $text', () => expect(_waits(text, 'cameraLive', closePending: true), isFalse));
    }
  });

  group('never a question, never a long sentence, never a capture word', () {
    for (final text in [
      'Are you ready?',
      'Not ready?',
      'Hold on?',
      'Wait, what?',
      'Hold on, let me move the ladder over there first',
      'ready',
      'I am ready now.',
      'Go ahead.',
      'Capture it.',
      'Take it now.',
      "Wait, I'm ready.",
    ]) {
      test(text, () => expect(matchWaitHold(text), isNull));
    }
  });

  group('capture still works, and "not ready" never captures', () {
    for (final text in ['ready', 'I am ready now.', 'Go ahead.', 'I am ready.', 'Yes, I am ready.']) {
      test('captures: $text', () {
        expect(matchWiderCapture(text), isA<WiderCaptureMatch>());
        expect(matchWaitHold(text), isNull);
      });
    }
    for (final text in ['Not ready.', 'Not ready yet.', "I'm not ready.", 'Not yet.', 'Hold on.', 'Wait a second.']) {
      test('never captures: $text', () => expect(matchWiderCapture(text), isNot(isA<WiderCaptureMatch>())));
    }
  });

  group('no overlap with decline or local close (they run first and keep their phrases)', () {
    for (final (text, _) in spoken) {
      test(text, () {
        expect(matchPhotoDecline(text), isNull);
        expect(matchLocalClose(text), isNot(isA<LocalCloseMatch>()));
      });
    }
  });

  group('source: routing in the screen', () {
    final finalizeAt = _screen.indexOf('void _finalizeUtteranceEndDeterministicTriggers() {');
    final finalize = _screen.substring(finalizeAt, _screen.indexOf('_maybeFallBackToKbAnswerCatchAll();', finalizeAt));
    test('after decline, before the negation check, the KB, the intent layer', () {
      final waitAt = finalize.indexOf('_maybeHandleWaitHold(heardSoFar)');
      expect(waitAt, greaterThan(finalize.indexOf('_maybeHandlePhotoDecline(heardSoFar)')));
      expect(waitAt, lessThan(finalize.indexOf('_maybeBlockNegatedCameraSentence(heardSoFar)')));
      expect(waitAt, lessThan(finalize.indexOf("_deterministicTriggers['get_kb_answer']!,")));
      expect(waitAt, lessThan(finalize.indexOf('_maybeResolveByIntent();')));
    });
    final methodAt = _screen.indexOf('bool _maybeHandleWaitHold(String heard) {');
    final method = _screen.substring(methodAt, _screen.indexOf('Future<void> _executeDeclineCloseCamera()', methodAt));
    test('answers "Okay." (the decline line) and resolves the utterance; no camera action', () {
      expect(method, contains("_informGeminiToSpeakVerbatim(_negationGuardReply, reason: 'wait_hold')"));
      expect(method, contains('_clearAllTriggerBuffersAfterSuccess('));
      expect(method, isNot(contains('_fireIntentTrigger')));
      expect(method, isNot(contains('_executeDeterministic')));
      expect(method, isNot(contains('_maybeCloseCameraFlowForGoBack')));
      expect(method, isNot(contains('await ')));
    });
    test('camera live or opening only; photo note and close question excluded', () {
      expect(method, contains('_screenTask == _ScreenTask.cameraLive || _screenTask == _ScreenTask.cameraOpening'));
      expect(method, contains('_photoNote != null || _keptPhotoPreviewFile != null'));
      expect(method, contains('_localClose.confirmPending'));
    });
    test('log tag', () => expect(method, contains('WAIT: matched phrase=')));
  });
}
