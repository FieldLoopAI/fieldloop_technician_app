import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/trigger_phrase_matcher.dart';

/// The real phrase list, read from the production file (same approach as
/// capture_image_phrase_test.dart).
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
  final openCamera = _productionPhrases('_openCameraIndicatorPhrases');

  // Module C — the client's 10 named phrasings, scored PASS/FAIL by name.
  // Each must hit open_camera's deterministic PHRASE LIST (not the loose or
  // fuzzy fallback), as an EXACT match.
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

  group('Module C: all 10 client phrasings are deterministic phrase-list matches', () {
    for (final phrase in clientPhrases) {
      for (final spoken in [phrase, '${phrase[0].toUpperCase()}${phrase.substring(1)}.', 'Okay, $phrase please']) {
        test('"$spoken"', () {
          final match = matchAnyTriggerPhrase(spoken, openCamera);
          expect(match, isNotNull, reason: '"$spoken" did not match any open_camera phrase');
        });
      }
    }

    // The run log labels a non-exact match "FUZZY TRIGGER MATCH"; each of
    // the 10 must log as an exact phrase-list hit.
    for (final phrase in clientPhrases) {
      test('"$phrase" is an EXACT phrase-list match (not fuzzy)', () {
        final match = matchAnyTriggerPhrase(phrase, openCamera);
        expect(match?.exact, isTrue, reason: match?.describe());
      });
    }

    test('negated forms still do not match', () {
      expect(matchAnyTriggerPhrase("I don't need a photo", openCamera), isNull);
      expect(matchAnyTriggerPhrase("don't snap a picture", openCamera), isNull);
    });
  });
}
