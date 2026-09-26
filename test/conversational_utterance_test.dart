import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/conversational_utterance.dart';
import 'package:fielloop/services/photo_decision_classifier.dart';

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
  group('KB-only guarantee: questions and problem reports never become small talk', () {
    test('every production knowledge-base cue phrase stays on the KB path', () {
      final phrases = _productionPhrases('_getKbAnswerIndicatorPhrases');
      expect(phrases, isNotEmpty);
      for (final phrase in phrases) {
        expect(classifySmallTalk(phrase), SmallTalkKind.none, reason: phrase);
        expect(classifySmallTalk('$phrase reset the breaker'), SmallTalkKind.none, reason: phrase);
      }
    });

    for (final text in [
      'How do I reset the breaker?',
      'why is the compressor short cycling',
      'is it normal for the pipe to sweat',
      "what's the torque spec for this fitting",
      'the breaker keeps tripping',
      'the unit is making a grinding noise',
      'looks good but why is it leaking',
      "it looks fine but it's not working",
      'look up the part number',
      'tell me the warranty terms',
      "Is today Modi's birthday?", // off-topic question — keeps getting the KB boundary decline
      'put president name of India', // same
      'Sí. ¿Qué me quieres ver?', // non-English question — handled by the non-English path, not small talk
      'the water heater pilot light keeps going out and the thermocouple looks fine to me honestly',
    ]) {
      test('"$text" -> none (KB as before)', () => expect(classifySmallTalk(text), SmallTalkKind.none));
    }
  });

  group('clear reactions get a direct reply', () {
    for (final text in [
      'No, this provision looks good.', // the exact utterance from the real trace
      'these look good',
      'that works',
      'perfect, thanks',
      'no problem',
      'okay that makes sense',
      'all right, sounds good',
      'Vale, gracias.',
      'Está bien.',
      'haan theek hai',
      'accha',
    ]) {
      test('"$text" -> reaction', () => expect(classifySmallTalk(text), SmallTalkKind.reaction));
    }
  });

  group('greetings get the acknowledge-presence reply', () {
    for (final text in [
      'good morning',
      'Hola.',
      '¿Me escuchas?',
      'are you there',
      'hey, can you hear me',
      'namaste ji',
    ]) {
      test('"$text" -> greeting', () => expect(classifySmallTalk(text), SmallTalkKind.greeting));
    }

    test('a bare "there" is not a greeting', () => expect(classifySmallTalk('there'), SmallTalkKind.none));
    test('empty -> none', () => expect(classifySmallTalk('  '), SmallTalkKind.none));
  });

  group('photo decision: "take it" no longer silently discards', () {
    test('"I\'ll take it" -> keep', () => expect(classifyPhotoDecision("I'll take it"), PhotoDecision.confirm));
    test('"I will take that one" -> keep', () {
      expect(classifyPhotoDecision('I will take it.'), PhotoDecision.confirm);
    });
    for (final text in ['Take it.', 'take it', 'take this one', 'Take that one.', 'Take.']) {
      test('"$text" -> ambiguous (asks keep or retake)', () {
        expect(classifyPhotoDecision(text), PhotoDecision.ambiguous);
      });
    }
    for (final text in ['take it again', 'retake it', 'take another', 'take another one', 'Re-take.']) {
      test('"$text" -> retake (unchanged)', () => expect(classifyPhotoDecision(text), PhotoDecision.retake));
    }
    test('"keep it" -> keep (unchanged)', () => expect(classifyPhotoDecision('keep it'), PhotoDecision.confirm));
  });
}
