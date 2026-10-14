// Build 180 item E — more decline phrases, whole utterance only: each is
// recognized, none opens the camera, none closes the session, and the
// flag off restores build 179's list. Offline.
import 'dart:io';

import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/camera_request_matcher.dart';
import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/local_close_command.dart';
import 'package:fielloop/services/photo_decline.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:fielloop/services/wider_capture.dart';
import 'package:flutter_test/flutter_test.dart';

final String _screen = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();

List<String> _productionPhrases(String listName) {
  final block = RegExp('const List<String> $listName = \\[(.*?)\\n\\];', dotAll: true).firstMatch(_screen);
  if (block == null) throw StateError('$listName not found in the production file');
  return [
    for (final m in RegExp(r'''^\s*(?:'([^']*)'|"([^"]*)"),''', multiLine: true).allMatches(block.group(1)!))
      m.group(1) ?? m.group(2)!,
  ];
}

final _open = _productionPhrases('_openCameraIndicatorPhrases');

/// Same definition as test/b179_decline_test.dart: a match the negation
/// guards don't block.
bool _cameraOpens(String text) =>
    (matchAnyTriggerPhrase(text, _open) != null ||
        matchWiderOpenCamera(text) != null ||
        matchLooseCameraRequest(text) is CameraRequestMatch) &&
    cameraActionNegation(text) == null &&
    negatedCameraMention(text) == null;

const _spoken = [
  ("I don't want to take one.", 'i don t want to take one'),
  ("I don't want to take a photo.", 'i don t want to take a photo'),
  ("I don't want to take a picture.", 'i don t want to take a picture'),
  ("I don't want a photo.", 'i don t want a photo'),
  ("I don't want a picture.", 'i don t want a picture'),
  ("Actually I don't want to take now.", 'i don t want to take now'),
  ("No, I don't want to take one.", 'no i don t want to take one'),
  ("I don't need a photo.", 'i don t need a photo'),
  ('Skip the picture.', 'skip the picture'),
  ('No picture for now.', 'no picture for now'),
  ('Not taking a photo.', 'not taking a photo'),
  ("Okay, I don't want a photo for now.", 'i don t want a photo'),
  ("Hold on, I don't need a photo.", 'i don t need a photo'),
];

void main() {
  test('flag defaults ON', () => expect(kWiderDeclineB180, isTrue));

  group('every build 180 decline is recognized', () {
    for (final (text, phrase) in _spoken) {
      test(text, () => expect(matchPhotoDecline(text), phrase));
    }
  });

  group('negatives: none of them opens the camera', () {
    for (final (text, _) in _spoken) {
      test(text, () {
        expect(_cameraOpens(text), isFalse);
        final fuzzy = classifyCommandIntent(text);
        expect(fuzzy.kind == IntentDecisionKind.confident && fuzzy.best?.trigger == 'open_camera', isFalse);
        expect(matchWiderCapture(text), isNot(isA<WiderCaptureMatch>()));
      });
    }
  });

  group('none of them closes the session', () {
    for (final (text, _) in _spoken) {
      test(text, () => expect(matchLocalClose(text), isNot(isA<LocalCloseMatch>())));
    }
  });

  group('whole utterance only — longer sentences are not declines', () {
    for (final text in [
      "I don't want to take one of the old pipes out",
      "I don't want a photo of the kitchen, take one of the roof",
      "I don't need a photo of that, show me the invoice",
    ]) {
      test(text, () => expect(matchPhotoDecline(text), isNull));
    }
  });

  test('flag off restores build 179\'s list exactly', () {
    expect(activePhotoDeclinePhrases(b180: false), same(photoDeclinePhrases));
    for (final (text, _) in _spoken) {
      if (photoDeclinePhrases.any((p) => matchPhotoDecline(text, b180: false) == p)) continue;
      expect(matchPhotoDecline(text, b180: false), isNull, reason: text);
    }
    expect(matchPhotoDecline("Actually I don't want to take now.", b180: false), isNull);
  });

  test('build 179 phrases are unchanged and still match', () {
    expect(photoDeclinePhrases.length, 20);
    for (final phrase in photoDeclinePhrases) {
      expect(matchPhotoDecline(phrase), phrase);
    }
  });

  test('additions only: no duplicate of a build 179 phrase', () {
    for (final phrase in photoDeclinePhrasesB180) {
      expect(photoDeclinePhrases, isNot(contains(phrase)));
    }
  });
}
