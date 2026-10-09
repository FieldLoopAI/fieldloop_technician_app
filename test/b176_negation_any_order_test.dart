import 'dart:io';

import 'package:fielloop/services/camera_narration.dart';
import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/camera_request_matcher.dart';
import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/photo_decision_classifier.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 176 Step 2 — the negation guard, word-order independent.

List<String> _productionPhrases(String listName) {
  final source = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();
  final block = RegExp('const List<String> $listName = \\[(.*?)\\n\\];', dotAll: true).firstMatch(source);
  if (block == null) throw StateError('$listName not found in the production file');
  return [
    for (final m in RegExp(r'''^\s*(?:'([^']*)'|"([^"]*)"),''', multiLine: true).allMatches(block.group(1)!))
      m.group(1) ?? m.group(2)!,
  ];
}

enum Cam { closed, live, captured }

/// The screen's routing in its real order (same shape as
/// bob_photo_phrases_test.dart's `route`), with build 176's two additions:
/// every camera action's guard also asks [negatedCameraMention]
/// (`_blockNegatedCameraAction`), and at utterance end a negated camera
/// sentence is answered "Okay." BEFORE the KB early match, site note and
/// C13 narration (`_maybeBlockNegatedCameraSentence`).
String route(String text, Cam cam, {required List<String> open, required List<String> capture}) {
  final up = cam != Cam.closed;
  bool negated() => cameraActionNegation(text) != null || negatedCameraMention(text, cameraUp: up) != null;
  String fire(String action) => negated() ? 'blocked:$action' : action;

  if (cam == Cam.captured) {
    final decision = classifyPhotoDecision(text);
    if (decision == PhotoDecision.retake) return fire('retake_photo');
    if (decision == PhotoDecision.confirm) return 'confirm_photo_upload';
  }
  final openHit = matchAnyTriggerPhrase(text, open) != null || matchLooseCameraRequest(text) is CameraRequestMatch;
  if (openHit) {
    if (negated()) return 'blocked:open_camera';
    if (cam == Cam.closed) return 'open_camera';
  }
  if (cam == Cam.live && matchAnyTriggerPhrase(text, capture) != null) return fire('capture_photo');

  // End of utterance — build 176 check first.
  if (negatedCameraMention(text, cameraUp: up) != null) return 'cancel';
  if (cam != Cam.closed && cameraNarrationRejection(text, cameraLive: cam == Cam.live) == null) return 'narration';
  if (standaloneCameraCancel(text) != null) return 'cancel';
  final decision = classifyCommandIntent(text);
  if (cam == Cam.live && liveCameraShotNoun(text) != null) return fire('capture_photo');
  if (decision.kind == IntentDecisionKind.confident) return fire(decision.best!.trigger);
  if (cam != Cam.captured) return 'gemini_intent_check_or_fallback';
  return 'fallback';
}

/// "No action and no note": blocked, cancelled ("Okay."), never a fired
/// action, never narration.
bool _noActionNoNote(String outcome) => outcome == 'cancel' || outcome.startsWith('blocked:');

void main() {
  final open = _productionPhrases('_openCameraIndicatorPhrases');
  final capture = _productionPhrases('_capturePhotoIndicatorPhrases');
  String r(String text, Cam cam) => route(text, cam, open: open, capture: capture);

  group('the b175 failure', () {
    const text = "Actually, I don't want to photo take now.";
    test('build 175 guard missed it (it became a photo note)', () {
      expect(cameraActionNegation(text), isNull);
      expect(cameraNarrationRejection(text, cameraLive: true), isNull);
    });
    test('build 176: no action, no note, in every camera state', () {
      expect(negatedCameraMention(text, cameraUp: true), 'do not');
      for (final cam in Cam.values) {
        expect(_noActionNoNote(r(text, cam)), isTrue, reason: '${cam.name}: ${r(text, cam)}');
      }
    });
  });

  group('5+ scrambled word-order cases -> no action, no note', () {
    const scrambled = [
      'Photo, I don\'t want to take one.',
      'Take a photo, no, forget it.',
      "I'd rather not take the picture now.",
      'Not now, the photo can wait.',
      'Never mind the photo for now.',
      'The picture, cancel it.',
      "I no longer need the photo.",
      "Camera, hold on, I've changed my mind.",
      'A shot? Stop, not now.',
    ];
    for (final text in scrambled) {
      test('"$text"', () {
        for (final cam in Cam.values) {
          expect(_noActionNoNote(r(text, cam)), isTrue, reason: '${cam.name}: ${r(text, cam)}');
        }
      });
    }
  });

  group('30-utterance table: zero actions, zero notes', () {
    final table = [
      for (var i = 0; i < 10; i++) "I don't want to take a photo.",
      for (var i = 0; i < 10; i++) 'Forget the photo.',
      for (var i = 0; i < 10; i++) 'Hold on, forget the photo for now.',
    ];
    test('30 rows x 3 camera states', () {
      expect(table, hasLength(30));
      var actions = 0;
      var notes = 0;
      for (final text in table) {
        for (final cam in Cam.values) {
          final outcome = r(text, cam);
          if (outcome == 'narration') notes++;
          if (!_noActionNoNote(outcome)) actions++;
        }
      }
      expect(actions, 0);
      expect(notes, 0);
    });
    test('"No, this photo is dark." -> retake', () {
      expect(negatedCameraMention('No, this photo is dark.', cameraUp: true), isNull);
      expect(r('No, this photo is dark.', Cam.captured), 'retake_photo');
    });
  });

  group('keep working', () {
    test('"No, this photo is dark." still retakes', () {
      expect(r('No, this photo is dark.', Cam.captured), 'retake_photo');
    });
    test('"No, that photo didn\'t come out right, let\'s retake it" retakes', () {
      const text = "No, that photo didn't come out right, let's retake it";
      expect(negatedCameraMention(text, cameraUp: true), isNull);
      expect(r(text, Cam.captured), 'retake_photo');
    });
    test('"No, go back" still goes back (no camera word, nothing blocked)', () {
      expect(negatedCameraMention('No, go back', cameraUp: true), isNull);
      expect(matchAnyTriggerPhrase('No, go back', const ['go back']), isNotNull);
    });
    test('"Forget the photo, take a picture of the roof" takes the photo', () {
      const text = 'Forget the photo, take a picture of the roof';
      expect(negatedCameraMention(text, cameraUp: true), isNull);
      expect(r(text, Cam.closed), 'open_camera');
      // Camera live: the same camera routing as build 175 (not blocked).
      expect(_noActionNoNote(r(text, Cam.live)), isFalse);
    });
    test('"Capture this, there\'s water damage here" works', () {
      const text = "Capture this, there's water damage here";
      expect(negatedCameraMention(text, cameraUp: true), isNull);
      expect(r(text, Cam.closed), 'open_camera');
    });
    test('bare "hold on" / "wait" -> no camera word, so this check never claims it (filler path)', () {
      for (final text in ['Hold on.', 'Wait.', 'Hold on a second']) {
        expect(negatedCameraMention(text, cameraUp: true), isNull, reason: text);
        expect(standaloneCameraCancel(text), isNull, reason: text);
      }
      expect(_productionPhrases('_holdOnFillerPhrases'), containsAll(['hold on', 'wait']));
    });
    test('leading Yes / No', () {
      for (final text in ['Yes, take a photo', 'No, take a photo', 'Yes, keep it', 'No, retake it']) {
        expect(negatedCameraMention(text, cameraUp: true), isNull, reason: text);
      }
      expect(r('Yes, take a photo', Cam.closed), 'open_camera');
      expect(r('No, retake it', Cam.captured), 'retake_photo');
    });
    test('standard negations that passed in 175 still block', () {
      for (final text in [
        "I don't want to take a photo.",
        "Actually, I don't want to take a photo right now.",
        'Hold on, forget the photo for now.',
      ]) {
        for (final cam in Cam.values) {
          expect(_noActionNoNote(r(text, cam)), isTrue, reason: '$text / ${cam.name}');
        }
      }
    });
    test('a real command after the cancellation, or a positive "don\'t", is not blocked', () {
      for (final text in [
        "Don't worry, take a photo",
        "I don't want a note, take a photo",
        "Don't forget to take a photo of the meter",
        "I've changed my mind, take a photo",
        'Never mind the photo, open the estimate',
        'Get a shot of that',
        'Can you get a shot of that for me',
      ]) {
        expect(negatedCameraMention(text, cameraUp: true), isNull, reason: text);
      }
    });
    test('every phrase build 175 allowed is still allowed', () {
      // camera_negation_guard_test.dart "leaves existing commands alone" +
      // the extended-cue allowed list.
      for (final text in [
        'Take a photo', 'Take a picture', 'Snap a picture', 'Capture this', 'Snap a photo', 'Get a photo',
        'Open the camera', 'Open camera', 'I need a photo', "Let's take photo",
        'Keep it', 'Keep', "That's good", 'That looks good', 'Save that', 'Retake', 'Retake it', 'No, retake it',
        'Take another one', "No, that's not right, take it again", "No, this photo didn't look good",
        "No, this photo didn't looks good.", 'No, go back.', 'Go back', 'Yes, take a photo', 'No, take a photo',
        'Take it', 'Ready', 'Capture it',
        "Don't worry, take a photo", "I don't know, take a picture of the panel", 'Never mind, take a photo',
        'Forget it, take a photo', "This doesn't look right",
        'Forget the photo, take a picture of the roof', "I've changed my mind, take a photo",
        'Not right now, but take a picture of the panel',
      ]) {
        expect(negatedCameraMention(text, cameraUp: true), isNull, reason: text);
      }
    });
    test('a descriptive "not" is not a cancellation', () {
      for (final text in ["This photo isn't sharp", "The picture doesn't look right", 'That photo was not good']) {
        expect(negatedCameraMention(text, cameraUp: true), isNull, reason: text);
      }
    });
    test('no camera word -> never claimed (take/capture count only with the camera up)', () {
      expect(negatedCameraMention("Don't take that off the estimate"), isNull);
      expect(negatedCameraMention("I don't want to take one", cameraUp: true), 'do not');
      expect(negatedCameraMention("I don't want to take one"), isNull);
    });
  });
}
