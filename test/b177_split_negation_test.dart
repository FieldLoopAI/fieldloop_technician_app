import 'dart:io';

import 'package:fielloop/services/camera_auto_capture.dart';
import 'package:fielloop/services/camera_narration.dart';
import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 177 Step 7(c) — a shorter VAD silence can split one sentence into
/// two utterances. "Take a photo. No, forget it." as ONE utterance is
/// blocked by the negation guard (b176 14:18:29). Split, each half is
/// routed on its own.
List<String> _productionPhrases(String listName) {
  final source = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();
  final block = RegExp('const List<String> $listName = \\[(.*?)\\n\\];', dotAll: true).firstMatch(source);
  if (block == null) throw StateError('$listName not found in the production file');
  return [
    for (final m in RegExp(r'''^\s*(?:'([^']*)'|"([^"]*)"),''', multiLine: true).allMatches(block.group(1)!))
      m.group(1) ?? m.group(2)!,
  ];
}

void main() {
  final open = _productionPhrases('_openCameraIndicatorPhrases');
  final capture = _productionPhrases('_capturePhotoIndicatorPhrases');
  final siteNote = _productionPhrases('_siteConditionIndicatorPhrases');

  test('one utterance: "Take a photo. No, forget it." is blocked (unchanged)', () {
    const text = 'Take a photo. No, forget it.';
    expect(cameraActionNegation(text) ?? negatedCameraMention(text), isNotNull);
  });

  group('split: "Take a photo." then "No, forget it."', () {
    test('KNOWN LIMIT: the first half alone is a plain request and opens the camera', () {
      // Nothing in "Take a photo." says it will be cancelled; blocking it
      // would mean delaying every camera open. Reported, not changed.
      expect(matchAnyTriggerPhrase('Take a photo.', open), isNotNull);
      expect(cameraActionNegation('Take a photo.'), isNull);
      expect(negatedCameraMention('Take a photo.'), isNull);
      expect(cameraRequestAutoCaptureNote('Take a photo.', requestPhrases: open), isNull, reason: 'no auto shutter');
    });

    test('the second half takes no photo (camera live): no capture phrase, no shutter noun, and blocked anyway', () {
      const second = 'No, forget it.';
      expect(matchAnyTriggerPhrase(second, capture), isNull);
      expect(matchAnyTriggerPhrase(second, open), isNull);
      expect(liveCameraShotNoun(second), isNull);
      expect(classifyCommandIntent(second).kind, isNot(IntentDecisionKind.confident));
      // If any camera trigger did reach the guard on it, it is a cancel cue.
      expect(cameraActionNegation(second), isNotNull);
    });

    test('the second half saves no note: not C13 narration, not a site note', () {
      const second = 'No, forget it.';
      expect(cameraNarrationRejection(second, cameraLive: true), isNotNull);
      expect(cameraNarrationRejection(second, cameraLive: false), isNotNull);
      expect(matchAnyTriggerPhrase(second, siteNote), isNull);
    });

    test('other split cancels behave the same', () {
      for (final second in ['Never mind.', 'Cancel that.', 'No, not now.', 'Forget it.']) {
        expect(matchAnyTriggerPhrase(second, capture), isNull, reason: second);
        expect(liveCameraShotNoun(second), isNull, reason: second);
        expect(cameraNarrationRejection(second, cameraLive: true), isNotNull, reason: second);
        expect(matchAnyTriggerPhrase(second, siteNote), isNull, reason: second);
      }
    });
  });

  group('split C13 one-sentence form', () {
    test('"Capture this, there\'s water damage here." + "No, forget it.": the armed shutter is dropped', () {
      expect(cameraRequestAutoCaptureNote("Capture this, there's water damage here.", requestPhrases: open), isNotNull);
      final step = cameraAutoCaptureStep(
        sessionClosing: false,
        newUtteranceSinceArmed: true, // "No, forget it." transcribed
        cameraLiveAndConfirmed: true,
        cameraClosedOrPhotoTaken: false,
        photoNoteOpen: false,
        cameraNativeCallInProgress: false,
        replyStillPlaying: false,
        sinceArmed: const Duration(milliseconds: 1500),
      );
      expect(step.step, AutoCaptureStep.abort);
    });

    test('"Capture this." + "There\'s water damage here.": opens, then the second half is C13 narration (yes/no '
        'before saving, as in build 176)', () {
      expect(matchAnyTriggerPhrase('Capture this.', open), isNotNull);
      expect(cameraRequestAutoCaptureNote('Capture this.', requestPhrases: open), isNull);
      expect(cameraNarrationRejection("There's water damage here.", cameraLive: true), isNull);
    });
  });
}
