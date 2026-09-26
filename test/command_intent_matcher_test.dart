import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';

/// Reads a `const List<String> name = [...]` straight out of the production
/// screen file, so the regression cases below are always the phrase lists
/// that actually ship — never a copy that can drift.
List<String> _productionPhrases(String listName) {
  final source = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();
  final block = RegExp('const List<String> $listName = \\[(.*?)\\n\\];', dotAll: true).firstMatch(source);
  if (block == null) throw StateError('$listName not found in the production file');
  return [
    for (final m in RegExp(r'''^\s*(?:'([^']*)'|"([^"]*)"),''', multiLine: true).allMatches(block.group(1)!))
      m.group(1) ?? m.group(2)!,
  ];
}

const _coveredLists = {
  'open_camera': '_openCameraIndicatorPhrases',
  'view_estimate': '_viewEstimateIndicatorPhrases',
  'view_invoice': '_viewInvoiceIndicatorPhrases',
  'view_change_orders': '_viewChangeOrdersIndicatorPhrases',
  'view_job_history': '_viewJobHistoryIndicatorPhrases',
  'get_last_photo': '_getLastPhotoIndicatorPhrases',
};

IntentDecision _decide(String text) => classifyCommandIntent(text);

void _expectConfident(String text, String trigger) {
  final d = _decide(text);
  expect(d.kind, IntentDecisionKind.confident, reason: d.describe(text));
  expect(d.best!.trigger, trigger, reason: d.describe(text));
}

void main() {
  group('regression: every current phrase still resolves to its own trigger', () {
    for (final entry in _coveredLists.entries) {
      final phrases = _productionPhrases(entry.value);

      test('${entry.key}: ${phrases.length} production phrases', () {
        expect(phrases, isNotEmpty);
        for (final phrase in phrases) {
          // The existing matcher (which runs first, unchanged) still matches.
          expect(matchAnyTriggerPhrase(phrase, phrases), isNotNull, reason: phrase);
          // And the new layer never points the same words somewhere else,
          // or turns a known command into a question back to the technician.
          final d = _decide(phrase);
          expect(
            d.kind == IntentDecisionKind.none ||
                (d.kind == IntentDecisionKind.confident && d.best!.trigger == entry.key),
            isTrue,
            reason: '"$phrase" -> ${d.describe(phrase)}',
          );
        }
      });
    }

    test('go-back phrases are never claimed by the new layer', () {
      for (final phrase in _productionPhrases('_intentionalGoBackPhrases')) {
        expect(_decide(phrase).kind, IntentDecisionKind.none, reason: phrase);
      }
    });
  });

  group('natural phrasing (not in any list) now resolves', () {
    for (final text in [
      "let's get a picture of this",
      'grab a shot of that',
      'can you snap a pic of the panel',
      'I need a photo of the water heater',
      'shoot a quick image of the damage',
      'um, take a snapshot please',
    ]) {
      test('"$text" -> open_camera', () => _expectConfident(text, 'open_camera'));
    }

    test('"bring up the invoice" -> view_invoice', () => _expectConfident('bring up the invoice', 'view_invoice'));
    test('"pull the quote" -> view_estimate', () => _expectConfident('pull the quote', 'view_estimate'));
    test('"check the change order" -> view_change_orders',
        () => _expectConfident('check the change order', 'view_change_orders'));
    test('"look at the previous photo" -> get_last_photo',
        () => _expectConfident('look at the previous photo', 'get_last_photo'));
  });

  group('truncated / noisy transcripts', () {
    test('"foto" (the reported case) -> open_camera', () => _expectConfident('foto', 'open_camera'));
    test('"Foto." with punctuation -> open_camera', () => _expectConfident('Foto.', 'open_camera'));
    test('"uh, camara" -> open_camera', () => _expectConfident('uh, camara', 'open_camera'));
    test('"the invoise" -> view_invoice', () => _expectConfident('the invoise', 'view_invoice'));
    test('"estimate please" -> view_estimate', () => _expectConfident('estimate please', 'view_estimate'));
  });

  group('never silently guesses', () {
    test('two commands at once -> ambiguous, asks which', () {
      final d = _decide('take a photo and show the estimate');
      expect(d.kind, IntentDecisionKind.ambiguous, reason: d.describe('...'));
      expect({d.best!.trigger, d.runnerUp!.trigger}, {'open_camera', 'view_estimate'});
    });

    test('two bare nouns -> ambiguous', () {
      expect(_decide('estimate invoice').kind, IntentDecisionKind.ambiguous);
    });

    test('a noun with no action in a short phrase -> weak, not acted on', () {
      final d = _decide('photo of the leak maybe');
      expect(d.kind, IntentDecisionKind.weak, reason: d.describe('...'));
    });

    test('invoice and estimate wording never cross-match', () {
      _expectConfident('open the invoice', 'view_invoice');
      _expectConfident('open the estimate', 'view_estimate');
    });

    test('"last photo" is never open_camera', () {
      final d = _decide('show me the last photo');
      expect(d.best?.trigger, isNot('open_camera'));
    });
  });

  group('questions and negation stay with the existing paths', () {
    for (final text in [
      "what's the history of this unit",
      "what's the difference between an estimate and an invoice",
      'how long should a water heater photo cell last',
      'is the estimate usually higher than the invoice',
    ]) {
      test('"$text" -> none (goes to the knowledge base as today)', () {
        expect(_decide(text).kind, IntentDecisionKind.none, reason: _decide(text).describe(text));
      });
    }

    for (final text in ["don't open the camera", 'no photo', "don't take a picture", 'cancel the camera']) {
      test('"$text" -> none', () => expect(_decide(text).kind, IntentDecisionKind.none));
    }

    test('empty / filler-only -> none', () {
      expect(_decide('').kind, IntentDecisionKind.none);
      expect(_decide('um uh okay').kind, IntentDecisionKind.none);
    });
  });
}
