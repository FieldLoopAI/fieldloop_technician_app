import 'dart:io';

import 'package:fielloop/services/camera_auto_capture.dart';
import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 177 Step 5 — C13 one sentence also takes the photo.
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
  final source = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();
  final open = _productionPhrases('_openCameraIndicatorPhrases');

  group('arming: only a camera request that carries a description', () {
    const variants = {
      'dash': "Capture this - there's water damage here.",
      'em dash': "Capture this — there's water damage here.",
      'comma': "Capture this, there's water damage here.",
      'period': "Capture this. There's water damage here.",
      'no punctuation': "Capture this there's water damage here",
    };
    variants.forEach((label, text) {
      test('$label: arms with the note', () {
        expect(matchAnyTriggerPhrase(text, open), isNotNull);
        expect(cameraRequestAutoCaptureNote(text, requestPhrases: open)?.toLowerCase(), "there's water damage here");
      });
    });

    test('regression: plain "Open the camera" only opens the camera', () {
      expect(matchAnyTriggerPhrase('Open the camera', open), isNotNull);
      expect(cameraRequestAutoCaptureNote('Open the camera', requestPhrases: open), isNull);
      expect(cameraRequestAutoCaptureNote('Open the camera.', requestPhrases: open), isNull);
    });

    // The client's 10 Module C phrasings (client_photo_phrases_test.dart):
    // none carries a description, so none ever arms — they open the camera
    // exactly as before.
    const clientPhrases = [
      'take a photo',
      'take a picture',
      'snap a picture',
      'capture this',
      'snap a photo',
      'get a photo',
      'open the camera',
      'open camera',
      'I need a photo',
      "let's take the image",
    ];
    for (final phrase in clientPhrases) {
      for (final spoken in [phrase, '${phrase[0].toUpperCase()}${phrase.substring(1)}.', 'Okay, $phrase please']) {
        test('"$spoken" never arms', () {
          expect(cameraRequestAutoCaptureNote(spoken, requestPhrases: open), isNull);
        });
      }
    }

    test('"Forget the photo, take a picture of the roof" still only opens the camera (no auto shutter)', () {
      const text = 'Forget the photo, take a picture of the roof';
      expect(matchAnyTriggerPhrase(text, open), isNotNull);
      expect(cameraRequestAutoCaptureNote(text, requestPhrases: open), isNull);
    });

    test('"Take a photo. No, forget it." is blocked by the negation guard before anything is armed', () {
      const text = 'Take a photo. No, forget it.';
      expect(cameraActionNegation(text) != null || negatedCameraMention(text) != null, isTrue);
    });
  });

  group('cameraAutoCaptureStep', () {
    ({AutoCaptureStep step, String why}) step({
      bool sessionClosing = false,
      bool spoke = false,
      bool live = true,
      bool closedOrTaken = false,
      bool note = false,
      bool nativeCall = false,
      bool playing = false,
      int ms = 1000,
    }) => cameraAutoCaptureStep(
      sessionClosing: sessionClosing,
      newUtteranceSinceArmed: spoke,
      cameraLiveAndConfirmed: live,
      cameraClosedOrPhotoTaken: closedOrTaken,
      photoNoteOpen: note,
      cameraNativeCallInProgress: nativeCall,
      replyStillPlaying: playing,
      sinceArmed: Duration(milliseconds: ms),
    );

    test('camera confirmed open, reply done, settled -> fire', () {
      expect(step().step, AutoCaptureStep.fire);
    });
    test('waits while the camera is not confirmed, the native call runs, the reply plays, or it is settling', () {
      expect(step(live: false).step, AutoCaptureStep.wait);
      expect(step(nativeCall: true).step, AutoCaptureStep.wait);
      expect(step(playing: true).step, AutoCaptureStep.wait);
      expect(step(ms: 300).step, AutoCaptureStep.wait);
    });
    test('drops when the technician speaks again ("No, forget it."), the camera closes, or the note flow opens', () {
      expect(step(spoke: true).step, AutoCaptureStep.abort);
      expect(step(closedOrTaken: true).step, AutoCaptureStep.abort);
      expect(step(note: true).step, AutoCaptureStep.abort);
      expect(step(sessionClosing: true).step, AutoCaptureStep.abort);
    });
    test('drops after 6s without being ready (camera stays open, as in build 176)', () {
      expect(step(live: false, ms: 6100).step, AutoCaptureStep.abort);
    });
    test('speaking again wins over everything else, even when it would otherwise fire', () {
      expect(step(spoke: true, ms: 2000).step, AutoCaptureStep.abort);
    });
  });

  group('screen wiring', () {
    test('flag default and BUILD line', () {
      expect(source, contains('const bool _cameraRequestAutoCapture = true;'));
      expect(source, contains(r"'cameraRequestAutoCapture=$_cameraRequestAutoCapture'"));
    });

    test('armed only from the camera-request narration, after the note is kept', () {
      expect(RegExp(r'_armCameraAutoCapture\(').allMatches(source).length, 2, reason: 'definition + one call');
      final noteFn = source.indexOf('void _noteCameraRequestNarration()');
      final call = source.indexOf('_armCameraAutoCapture(text);');
      expect(call, greaterThan(noteFn));
      expect(call, lessThan(source.indexOf('void _noteCaptureRequestNarration()')));
    });

    test('fires through the same capture_photo dispatch and reply as "take a photo" with the camera live', () {
      expect(source, contains("buildSpokenText: _captureSpokenText,\n      ),\n      'get_last_photo'"));
      expect(
        source,
        contains(
          "unawaited(_executeDeterministic(trigger, args: {'job_id': jobId}, buildSpokenText: _captureSpokenText));",
        ),
      );
      final fire = source.substring(source.indexOf('void _fireCameraAutoCapture('));
      expect(fire.indexOf("_deterministicTriggers['capture_photo']!"), greaterThan(0));
      expect(fire, contains('_screenTask == _ScreenTask.cameraLive && _cameraOpenConfirmed'));
      expect(fire, contains('_deterministicTriggerDebounce'));
    });

    test('the native camera-open path and CAMERA PREWARM are not touched by the auto-capture', () {
      final start = source.indexOf('void _armCameraAutoCapture(');
      final end = source.indexOf('/// Build 176 Step 3 — the capture_photo twin');
      expect(end, greaterThan(start));
      final arm = source.substring(start, end);
      expect(arm, isNot(contains('_dispatchWithOpenCameraSafeguards')));
      expect(arm, isNot(contains('Prewarm')));
    });
  });
}
