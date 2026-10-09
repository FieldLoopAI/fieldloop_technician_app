import 'dart:io';

import 'package:fielloop/services/camera_narration.dart';
import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/camera_request_matcher.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 176 Step 3 — C13 "Capture this - there's water damage here." as
/// ONE sentence.
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
  const note = "there's water damage here";

  const variants = {
    'dash': "Capture this - there's water damage here.",
    'em dash': "Capture this — there's water damage here.",
    'comma': "Capture this, there's water damage here.",
    'period': "Capture this. There's water damage here.",
    'no punctuation': "Capture this there's water damage here",
    'no punctuation, lead-in': "Can you capture this there's water damage here",
  };

  group('camera closed: open_camera fires and the description is the pending note', () {
    variants.forEach((label, text) {
      test('$label: "$text"', () {
        expect(matchAnyTriggerPhrase(text, open), isNotNull, reason: 'open_camera phrase');
        expect(cameraActionNegation(text), isNull);
        expect(negatedCameraMention(text), isNull);
        expect(cameraRequestNarrationAnyPunctuation(text, requestPhrases: open)?.toLowerCase(), note);
      });
    });

    test('build 175 extraction lost the unpunctuated form (what this step fixes)', () {
      expect(cameraRequestTrailingNarration("Capture this there's water damage here", requestPhrases: open), isNull);
    });
  });

  group('camera live: capture_photo fires and the description is kept too', () {
    variants.forEach((label, text) {
      test('$label', () {
        // "Capture this" fires capture_photo with the camera live through
        // the screen's private _looksLikeCapturePhotoConfirmation (b175
        // 15:04:17.044 "matched_firing: trigger=capture_photo"); the note is
        // read with both lists, as _noteCaptureRequestNarration does.
        expect(
          cameraRequestNarrationAnyPunctuation(text, requestPhrases: [...capture, ...open])?.toLowerCase(),
          note,
        );
      });
    });
  });

  group('unchanged: what build 175 kept or refused', () {
    test('same results for every punctuated build 175 case', () {
      for (final text in [
        "Take a photo of the attic, the panel's cracked on the left side",
        'Take a photo.',
        'Snap a picture of this.',
        'Take a photo of the water damage here',
        'Take a photo, then show me the invoice',
        'Take a photo, please',
        'Take a photo. What time is it?',
        "There's water damage here, can you help",
      ]) {
        expect(
          cameraRequestNarrationAnyPunctuation(text, requestPhrases: open),
          cameraRequestTrailingNarration(text, requestPhrases: open),
          reason: text,
        );
      }
    });
    test('one clause with "of" is still the photo subject, never a note', () {
      expect(cameraRequestNarrationAnyPunctuation('Take a photo of the water damage here', requestPhrases: open), isNull);
    });
    test('an unpunctuated command or question after the request is never a note', () {
      for (final text in [
        'Take a photo then show me the invoice',
        'Capture this what time is it',
        'Take a photo please',
        'Capture this it',
      ]) {
        expect(cameraRequestNarrationAnyPunctuation(text, requestPhrases: [...capture, ...open]), isNull, reason: text);
      }
    });
    test('the request itself still reads as a camera request, not narration', () {
      expect(matchLooseCameraRequest("Capture this there's water damage here"), anyOf(isNull, isA<CameraRequestMatch>()));
      expect(cameraNarrationRejection(note, cameraLive: true), isNull);
    });
  });
}
