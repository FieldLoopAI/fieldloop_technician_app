import 'dart:io';

import 'package:fielloop/services/camera_narration.dart';
import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/camera_request_matcher.dart';
import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/photo_decision_classifier.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real phrase list, read from the production file (same approach as
/// client_photo_phrases_test.dart).
List<String> _productionPhrases(String listName) {
  final source = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();
  final block = RegExp('const List<String> $listName = \\[(.*?)\\n\\];', dotAll: true).firstMatch(source);
  if (block == null) throw StateError('$listName not found in the production file');
  return [
    for (final m in RegExp(r'''^\s*(?:'([^']*)'|"([^"]*)"),''', multiLine: true).allMatches(block.group(1)!))
      m.group(1) ?? m.group(2)!,
  ];
}

/// Camera state the utterance is heard in (`_ScreenTask` in the screen).
enum Cam { closed, live, captured }

/// What the screen's routing does with [text] in [cam], layer by layer in
/// its real order (`_onInputTranscription` per-chunk evaluators, then
/// `_finalizeUtteranceEndDeterministicTriggers` -> camera narration ->
/// `_maybeResolveByIntent`), with every camera action passed through the
/// negation guard first, exactly as `_maybeTriggerDeterministic` /
/// `_maybeDetectPhotoDecision` / a forced intent trigger do.
String route(String text, Cam cam, {required List<String> open, required List<String> capture}) {
  String fire(String action) => cameraActionNegation(text) != null ? 'blocked:$action' : action;

  // Per-chunk: photo decision (captured only), then open_camera, capture_photo.
  if (cam == Cam.captured) {
    final decision = classifyPhotoDecision(text);
    if (decision == PhotoDecision.retake) return fire('retake_photo');
    if (decision == PhotoDecision.confirm) return 'confirm_photo_upload';
  }
  final openHit = matchAnyTriggerPhrase(text, open) != null || matchLooseCameraRequest(text) is CameraRequestMatch;
  if (openHit) {
    if (cameraActionNegation(text) != null) return 'blocked:open_camera';
    if (cam == Cam.closed) return 'open_camera';
    // Guard failed (camera already up) — only a queued clarification; the
    // capture trigger below still gets its turn.
  }
  if (cam == Cam.live && matchAnyTriggerPhrase(text, capture) != null) return fire('capture_photo');

  // End of utterance: C13 narration, then the intent layer.
  if (cam != Cam.closed && cameraNarrationRejection(text, cameraLive: cam == Cam.live) == null) return 'narration';
  if (standaloneCameraCancel(text) != null) return 'cancel';
  final decision = classifyCommandIntent(text);
  if (cam == Cam.live && liveCameraShotNoun(text) != null) return fire('capture_photo');
  if (decision.kind == IntentDecisionKind.confident) return fire(decision.best!.trigger);
  if (cam != Cam.captured && decision.kind != IntentDecisionKind.confident) return 'gemini_intent_check_or_fallback';
  return 'fallback';
}

void main() {
  final open = _productionPhrases('_openCameraIndicatorPhrases');
  final capture = _productionPhrases('_capturePhotoIndicatorPhrases');
  String r(String text, Cam cam) => route(text, cam, open: open, capture: capture);

  group("Bob's 8 conversational photo phrases (utterance -> what the app does)", () {
    test('1. "Take a photo." -> opens the camera (exact phrase-list match)', () {
      expect(r('Take a photo.', Cam.closed), 'open_camera');
      expect(matchAnyTriggerPhrase('Take a photo.', open)?.exact, isTrue);
    });

    test('2. "Snap a picture of this." -> opens the camera (exact "snap a picture")', () {
      expect(r('Snap a picture of this.', Cam.closed), 'open_camera');
      expect(matchAnyTriggerPhrase('Snap a picture of this.', open)?.phrase, 'snap a picture');
    });

    test('3. "Capture this, there\'s water damage here." -> opens the camera AND keeps the description', () {
      const text = "Capture this, there's water damage here.";
      expect(r(text, Cam.closed), 'open_camera');
      expect(cameraRequestTrailingNarration(text, requestPhrases: open), "there's water damage here");
    });

    test('4. "Can you get a shot of that for me?" -> opens the camera (exact "get a shot")', () {
      expect(r('Can you get a shot of that for me?', Cam.closed), 'open_camera');
    });

    test('5. "Actually, I don\'t want to take a photo right now." -> no camera in any state (guard, "Okay.")', () {
      const text = "Actually, I don't want to take a photo right now.";
      expect(r(text, Cam.closed), 'blocked:open_camera');
      expect(r(text, Cam.live), 'blocked:open_camera');
      expect(r(text, Cam.captured), 'blocked:retake_photo');
    });

    test('6. "No, that photo didn\'t come out right, let\'s retake it." -> retake (photo captured), not blocked', () {
      const text = "No, that photo didn't come out right, let's retake it.";
      expect(r(text, Cam.captured), 'retake_photo');
      expect(cameraActionNegation(text), isNull);
    });

    test('7. "Hold on, forget the photo for now." -> no camera, no capture, no retake ("Okay.")', () {
      const text = 'Hold on, forget the photo for now.';
      for (final cam in Cam.values) {
        expect(r(text, cam), 'cancel', reason: cam.name);
      }
      expect(standaloneCameraCancel(text), 'forget the photo');
      // Before this pass: no cue, so the live "photo" shutter noun took a
      // photo, and on Job Detail the Gemini intent check could open it.
      expect(standaloneCameraCancel(text, extendedCues: false), isNull);
      expect(liveCameraShotNoun(text), isNotNull);
    });

    test('8. "Toma una foto." (Spanish, V1.5) -> no phrase fires; left to the intent layer (report only)', () {
      const text = 'Toma una foto.';
      expect(matchAnyTriggerPhrase(text, open), isNull);
      expect(matchAnyTriggerPhrase(text, capture), isNull);
      expect(matchLooseCameraRequest(text), isNull);
      expect(cameraActionNegation(text), isNull);
      expect(classifyCommandIntent(text).kind, IntentDecisionKind.weak);
      expect(r(text, Cam.closed), 'gemini_intent_check_or_fallback');
      // With the camera live, "foto" reads as the shutter noun: it takes the
      // photo — the request's own meaning, nothing destructive.
      expect(r(text, Cam.live), 'capture_photo');
      expect(r(text, Cam.captured), isNot(anyOf('retake_photo', 'confirm_photo_upload')));
    });
  });

  group('extended negation cues (only when they modify the camera action)', () {
    const blocked = {
      'Take a photo. Actually, forget the photo.': 'forget the photo',
      'Forget the picture': 'forget the picture',
      'Forget about the photo': 'forget about the photo',
      "I've changed my mind about the photo": 'changed my mind',
      'Take a picture, I changed my mind': 'changed my mind',
      'Take a photo, not right now': 'not right now',
      'Never mind the photo': 'never mind',
    };
    blocked.forEach((text, cue) {
      test('"$text" -> blocked by "$cue"', () => expect(cameraActionNegation(text), cue));
    });

    const allowed = [
      'Forget the photo, take a picture of the roof',
      "I've changed my mind, take a photo",
      'Not right now, but take a picture of the panel',
      "No, that photo didn't come out right, let's retake it.",
      'No, go back',
      "No, this photo didn't look good",
      'Yes, take a photo',
      'No, take a photo',
      'Yes, keep it',
    ];
    for (final text in allowed) {
      test('"$text" -> not blocked', () => expect(cameraActionNegation(text), isNull));
    }

    test('extendedCues: false is build 175 first-pass behavior', () {
      expect(cameraActionNegation('Forget the picture', extendedCues: false), isNull);
      expect(cameraActionNegation('Take a photo, not right now', extendedCues: false), isNull);
      expect(cameraActionNegation("Don't take a photo", extendedCues: false), isNotNull);
    });
  });

  group('a bare pause with no camera word does nothing', () {
    for (final text in ['Hold on.', 'Wait.', 'Hold on a second', 'Wait a minute', 'One second', "I've changed my mind"]) {
      test('"$text"', () {
        expect(standaloneCameraCancel(text), isNull);
        expect(matchAnyTriggerPhrase(text, open), isNull);
        expect(matchAnyTriggerPhrase(text, capture), isNull);
        expect(classifyCommandIntent(text).kind, IntentDecisionKind.none);
      });
    }

    test('the bare pauses are whole-utterance filler in the production file', () {
      final holdOn = _productionPhrases('_holdOnFillerPhrases');
      expect(holdOn, containsAll(['hold on', 'wait', 'one second', 'hang on']));
    });
  });

  group('description after a camera request (cameraRequestTrailingNarration)', () {
    test('kept: a description in a later clause', () {
      expect(
        cameraRequestTrailingNarration("Take a photo of the attic, the panel's cracked on the left side", requestPhrases: open),
        "the panel's cracked on the left side",
      );
    });
    test('not kept: nothing after the request, one clause, a command or too short', () {
      for (final text in [
        'Take a photo.',
        'Snap a picture of this.',
        'Take a photo of the water damage here',
        'Take a photo, then show me the invoice',
        'Take a photo, please',
        'Take a photo. What time is it?',
        "There's water damage here, can you help",
      ]) {
        expect(cameraRequestTrailingNarration(text, requestPhrases: open), isNull, reason: text);
      }
    });
  });
}
