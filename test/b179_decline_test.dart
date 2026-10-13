// Build 179 item D — local photo declines ("No photo for now.", "skip it"):
// every phrase matches, none opens the camera, the b178 negation sentences
// still open nothing, and the screen routes declines before the intent
// check and the KB catch-all. Offline.
import 'dart:io';

import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/camera_request_matcher.dart';
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

/// Would open_camera's trigger match it (before the negation guard)?
bool _openMatch(String text) =>
    matchAnyTriggerPhrase(text, _open) != null ||
    matchWiderOpenCamera(text) != null ||
    matchLooseCameraRequest(text) is CameraRequestMatch;

/// Would the camera actually open: a match the negation guards don't block.
bool _cameraOpens(String text) =>
    _openMatch(text) && cameraActionNegation(text) == null && negatedCameraMention(text) == null;

void main() {
  test('flag defaults ON', () => expect(kWiderCloseDeclinePhrases, isTrue));

  group('every decline phrase is recognized', () {
    for (final (text, phrase) in [
      ('No photo.', 'no photo'),
      ('No photo for now.', 'no photo for now'),
      ('No picture.', 'no picture'),
      ('No photos right now.', 'no photos right now'),
      ('Not now.', 'not now'),
      ('Not right now.', 'not right now'),
      ('Skip the photo.', 'skip the photo'),
      ('Skip photo', 'skip photo'),
      ('Skip it.', 'skip it'),
      ('No thanks.', 'no thanks'),
      ('No, thank you.', 'no thank you'),
      ('Maybe later.', 'maybe later'),
      ('Never mind the photo.', 'never mind the photo'),
      ('Forget the photo.', 'forget the photo'),
      ('Hold on. Forget the photo for now.', 'forget the photo'),
      ('Okay, no photo for now.', 'no photo for now'),
      ('Um, skip it for now.', 'skip it'),
    ]) {
      test(text, () => expect(matchPhotoDecline(text), phrase));
    }
  });

  group('whole utterance only', () {
    for (final text in [
      'No photo of the kitchen yet, show me the estimate.',
      'Not now, take the photo.',
      'Take a photo.',
      'Show me the estimate.',
      "I'm done.",
      'No, go back.',
      'Skip it and go to the invoice',
    ]) {
      test(text, () => expect(matchPhotoDecline(text), isNull));
    }
  });

  group('no decline phrase opens the camera', () {
    for (final phrase in photoDeclinePhrases) {
      test(phrase, () => expect(_cameraOpens(phrase), isFalse));
    }
  });

  group('b178 negation sentences + the new declines: 0 camera opens', () {
    // From the b178 logs (Oct 12): every negated photo sentence heard.
    const negations = [
      "I don't want to take a photo.",
      "Don't take a picture.",
      "I don't want to snap a photo.",
      "Please don't take a photo.",
      "Photo, I don't want to take one.",
      "Actually, I don't want to photo take now.",
      "Actually I don't want to take now.",
      "I think I don't want to take a picture for now.",
      "I don't have a mood to click a picture.",
      'Hold on. Forget the photo for now.',
      'Forget the photo.',
      'Never mind the photo.',
      'No photo for now.',
      "Don't snap it.",
    ];
    for (final text in [...negations, ...photoDeclinePhrases]) {
      test(text, () => expect(_cameraOpens(text), isFalse));
    }
  });

  test('declines and soft close phrases do not overlap', () {
    for (final phrase in photoDeclinePhrases) {
      expect(matchLocalClose(phrase), isNot(isA<LocalCloseMatch>()), reason: phrase);
    }
  });

  group('source: routing in the screen', () {
    final finalizeAt = _screen.indexOf('void _finalizeUtteranceEndDeterministicTriggers() {');
    final finalize = _screen.substring(finalizeAt, _screen.indexOf('_maybeFallBackToKbAnswerCatchAll();', finalizeAt));

    test('"No photo for now." (camera closed or live) is answered before the intent check and the KB', () {
      final declineAt = finalize.indexOf('_maybeHandlePhotoDecline(heardSoFar)');
      expect(declineAt, greaterThan(0));
      expect(declineAt, lessThan(finalize.indexOf('_maybeBlockNegatedCameraSentence(heardSoFar)')));
      expect(declineAt, lessThan(finalize.indexOf('_maybeResolveByIntent();')));
      expect(declineAt, lessThan(finalize.indexOf("_deterministicTriggers['get_kb_answer']!,")));
    });

    final methodAt = _screen.indexOf('bool _maybeHandlePhotoDecline(String heard) {');
    final method = _screen.substring(methodAt, _screen.indexOf('// --- Module C: job facts', methodAt));
    test('camera closed -> "Okay."; camera live -> the existing go-back camera close', () {
      expect(method, contains("_informGeminiToSpeakVerbatim(_negationGuardReply, reason: 'decline')"));
      expect(method, contains('_maybeCloseCameraFlowForGoBack('));
      expect(method, contains("tornDownReason: 'voice_decline'"));
      expect(_screen, contains("const String _negationGuardReply = 'Okay.';"));
    });
    test('existing handling wins: photo offer answer, photo note, captured photo', () {
      expect(method, contains('looksLikePhotoOfferQuestion(heardTurn.text)'));
      expect(method, contains('if (_photoNote != null || _keptPhotoPreviewFile != null) return false;'));
      expect(method, contains('if (_screenTask != _ScreenTask.none && !cameraLive) return false;'));
    });
    test('log tag', () => expect(method, contains('DECLINE: matched phrase=')));
  });
}
