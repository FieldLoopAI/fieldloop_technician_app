// Build 179 item C — more capture / open-camera phrasing, the fixed
// "ready" word count, negation and question vetoes, the narrow "sort of"
// ASR mishear, and the "camera still opening" reply. Offline.
import 'dart:io';

import 'package:fielloop/services/camera_request_matcher.dart';
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
final _capture = _productionPhrases('_capturePhotoIndicatorPhrases');

/// Mirror of the screen's unchanged shutter-word rule
/// (`_looksLikeCapturePhotoConfirmation` with readyRule: false).
bool _shutterWord(String text) {
  final padded = stemmedPaddedTriggerText(text);
  for (final word in ['capture', 'snap', 'take it', 'confirm', 'keep it']) {
    if (!padded.contains(' ${stemTriggerPhrase(word)} ')) continue;
    if (triggerPhraseIsNegated(text, word)) continue;
    return true;
  }
  return false;
}

/// What capture_photo's trigger matches with the camera live (b179 order:
/// phrase list, shutter words, then [matchWiderCapture]).
bool _capturesLive(String text) =>
    matchAnyTriggerPhrase(text, _capture) != null || _shutterWord(text) || matchWiderCapture(text) is WiderCaptureMatch;

/// What open_camera's trigger matches with the camera closed.
bool _opensCamera(String text) =>
    matchAnyTriggerPhrase(text, _open) != null ||
    matchWiderOpenCamera(text) != null ||
    matchLooseCameraRequest(text) is CameraRequestMatch;

void main() {
  test('flag defaults ON', () => expect(kWiderCapturePhrases, isTrue));

  group('"ready" variants capture (fixed count: filler removed, up to 5 content words)', () {
    for (final text in [
      'ready',
      'Ready.',
      "I'm ready",
      'Ok ready',
      'Okay, ready.',
      'Ready to go.',
      "Yes, I'm ready.",
      "I'm ready now.",
      "Okay, I'm ready.",
      'Yes I am ready',
      "We're ready.",
      'Go ahead.',
      'Yes, go ahead.',
      'Okay go ahead now',
    ]) {
      test(text, () {
        final r = matchWiderCapture(text);
        expect(r, isA<WiderCaptureMatch>(), reason: text);
        expect((r as WiderCaptureMatch).via, 'ready_rule');
        expect(_capturesLive(text), isTrue);
      });
    }
  });

  group('negatives never capture', () {
    for (final (text, reason) in [
      ('Not ready.', 'negation'),
      ("I'm not ready.", 'negation'),
      ('Not ready yet', 'negation'),
      ('Wait, not ready', 'negation'),
      ('Hold on, ready in a second', 'negation'),
      ('No, not ready', 'negation'),
      ('Are you ready?', 'question'),
      ('are you ready', 'question'),
      ('Ready for what?', 'question'),
      ('ready for what', 'question'),
      ('Is it ready', 'question'),
    ]) {
      test(text, () {
        final r = matchWiderCapture(text);
        expect(r, isA<WiderCaptureBlocked>(), reason: text);
        expect((r as WiderCaptureBlocked).reason, reason);
        expect(_capturesLive(text), isFalse);
      });
    }
    for (final text in [
      'Wait.',
      'Hold on.',
      'One second.',
      'Give me a second.',
      'Stop.',
      "Don't take it.",
      "It's sort of a mess.",
      'Ready when the customer gets back home from the store',
    ]) {
      test(text, () => expect(_capturesLive(text), isFalse));
    }
  });

  group('more live-camera capture phrasing', () {
    for (final text in ['Go.', 'Now.', 'Shoot.', 'Do it.', 'Take it now.', 'Okay, do it.', 'Yes, now.', 'Go now.']) {
      test(text, () {
        final r = matchWiderCapture(text);
        expect(r, isA<WiderCaptureMatch>(), reason: text);
        expect((r as WiderCaptureMatch).via, 'phrase_list');
      });
    }
    // These already capture through the unchanged "take it" shutter rule.
    for (final text in ['Okay, take it.', 'Yes, take it.', "That's good, take it.", 'Looks good, take it.']) {
      test(text, () => expect(_capturesLive(text), isTrue));
    }
    test('shutter words are whole-utterance only', () {
      for (final text in ['Go back.', 'Do it later.', 'Now show me the estimate', 'Shoot, I forgot the ladder']) {
        expect(matchWiderCapture(text), isNot(isA<WiderCaptureMatch>()), reason: text);
      }
    });
  });

  group('more open-camera phrasing (camera closed)', () {
    for (final text in [
      "I'd like a photo.",
      "I'd like a photo please.",
      'I want a photo.',
      'I need a photo.',
      'I need a picture.',
      "Let's take a photo.",
      "Let's get a photo.",
      'Can I get a photo?',
      'Can you get a shot of that?',
      'Get a shot of that for me.',
      'Take a shot of this.',
      'Grab a photo of this.',
      'Photo please.',
      'Picture please.',
    ]) {
      test(text, () => expect(_opensCamera(text), isTrue));
    }
    test('negated forms do not match the added phrases', () {
      for (final text in ["I don't want a photo.", 'No photo please.', "Don't grab a photo"]) {
        expect(matchWiderOpenCamera(text), isNull, reason: text);
      }
    });
  });

  group('ASR mishear "get a shot of that" -> "get sort of that" (verb required)', () {
    for (final text in [
      'Can you get sort of that for me?',
      'Get sort of this.',
      'Grab sort of that.',
      'Take sort of this',
    ]) {
      test(text, () => expect(matchWiderOpenCamera(text), isNotNull));
    }
    for (final text in ["It's sort of a mess.", 'Sort of damaged.', 'That is sort of old.', 'sort of', 'Sort of that']) {
      test('never opens: $text', () => expect(_opensCamera(text), isFalse));
    }
  });

  group('source: wiring in the screen', () {
    test('capture_photo: shutter words unchanged, ready rule replaced by the wider matcher', () {
      expect(_screen, contains('(padded) => _looksLikeCapturePhotoConfirmation(padded, readyRule: false)'));
      expect(_screen, contains('rawExtraMatcher: kWiderCapturePhrases ? _looksLikeWiderCapture : null'));
      expect(_screen, contains('if (!readyRule) return false;'));
    });
    test('open_camera: added phrases first, then the existing D3 matcher', () {
      expect(_screen, contains('rawExtraMatcher: kWiderCapturePhrases ? _looksLikeWiderOrLooseOpenCamera : _looksLikeOpenCameraRequest'));
      expect(_screen, contains('return _looksLikeOpenCameraRequest(rawText);'));
    });
    test('camera still opening: reply only then (camera-closed "snap it" keeps falling through)', () {
      expect(
        _screen,
        contains('onGuardFailed: kWiderCapturePhrases && _cameraStillOpening ? _replyCaptureWhileCameraOpening : null'),
      );
      expect(_screen, contains('"The camera\'s still opening — give it a moment."'));
    });
    test('5 s repeat-block and job-id check unchanged; repeat is logged', () {
      expect(_screen, contains('const Duration _deterministicTriggerDebounce = Duration(seconds: 5);'));
      expect(_screen, contains('WIDER CAPTURE: blocked reason=repeat'));
      expect(_screen, contains('if (requireJobId && jobId == null) {'));
    });
    test('existing phrase lists unchanged (no entries removed)', () {
      expect(_open.length, 33);
      expect(_capture.length, 46);
    });
  });
}
