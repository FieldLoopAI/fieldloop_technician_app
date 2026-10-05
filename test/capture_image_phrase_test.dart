import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';

/// The real phrase lists, read from the production file.
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
  final capture = _productionPhrases('_capturePhotoIndicatorPhrases');
  final openCamera = _productionPhrases('_openCameraIndicatorPhrases');

  group('"image" means this shot while the camera is live (capture_photo)', () {
    for (final text in [
      'Yes, I am ready. Take the image.', // the exact transcript from the trace
      'take the image',
      'capture the image now',
      'okay snap the image',
    ]) {
      test('"$text" matches capture_photo', () => expect(matchAnyTriggerPhrase(text, capture), isNotNull));
    }

    test('"take an image" does not (article rule, same as "take a photo")', () {
      expect(matchAnyTriggerPhrase('take an image', capture), isNull);
    });
    test('"don\'t take the image" does not (negation)', () {
      expect(matchAnyTriggerPhrase("don't take the image", capture), isNull);
    });
  });

  group('camera not open yet: open_camera still resolves exactly as before', () {
    test('"let\'s take the image" still matches open_camera\'s own phrase', () {
      expect(matchAnyTriggerPhrase("let's take the image", openCamera)?.phrase, 'let s take the image');
    });
    test('"take the image" still reaches open_camera via the intent layer', () {
      final d = classifyCommandIntent('take the image');
      expect(d.kind, IntentDecisionKind.confident);
      expect(d.best!.trigger, 'open_camera');
    });
  });

  test('every existing capture phrase still matches its own list', () {
    for (final phrase in capture) {
      expect(matchAnyTriggerPhrase(phrase, capture), isNotNull, reason: phrase);
    }
  });
}
