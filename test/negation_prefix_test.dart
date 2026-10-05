// 9948b4d log: a leading "No," (a reaction/correction, set off by a comma)
// vetoed the command after it. Both directions are pinned here: the
// reaction no longer blocks, a real negation still does.
import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/continuation_answer.dart';
import 'package:fielloop/services/photo_decision_classifier.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

const goBackPhrases = [
  'go back', 'take me back', 'go home', 'back to home', 'back to the job', 'back to job details', 'return to the job',
];

void main() {
  group('clauseBoundariesBefore', () {
    test('is aligned with tokenizeTriggerText and sees punctuation', () {
      const text = "No, go back. Don't—stop";
      expect(tokenizeTriggerText(text), ['no', 'go', 'back', 'don', 't', 'stop']);
      expect(clauseBoundariesBefore(text), [false, true, false, true, false, true]);
    });

    test('a spaced dash is a boundary, a hyphenated word is not', () {
      expect(clauseBoundariesBefore('no - go back'), [false, true, false]);
      expect(clauseBoundariesBefore('follow-up photo'), [false, false, false]);
    });
  });

  group('phrase matcher: leading reaction vs real negation', () {
    test('"No, go back." matches go back and reports the ignored prefix (u=20)', () {
      final match = matchAnyTriggerPhrase('No, go back.', goBackPhrases);
      expect(match, isNotNull);
      expect(match!.phrase, 'go back');
      expect(match.ignoredNegationPrefix, 'no');
    });

    test('"I said go back." still matches with no prefix noted (u=21)', () {
      final match = matchAnyTriggerPhrase('I said go back.', goBackPhrases);
      expect(match, isNotNull);
      expect(match!.ignoredNegationPrefix, isNull);
    });

    test('other reactions and punctuation', () {
      for (final text in ['Nope, go back.', 'Nah. Take me back', 'No - go home', 'No! Go back.', 'No... go back']) {
        expect(matchAnyTriggerPhrase(text, goBackPhrases), isNotNull, reason: text);
      }
    });

    test('a real negation still vetoes', () {
      for (final text in ["Don't go back.", "No, don't go back.", 'Never go back', 'not go back']) {
        expect(matchAnyTriggerPhrase(text, goBackPhrases), isNull, reason: text);
      }
    });

    test('with no punctuation at all, "no go back" stays vetoed (ambiguous without the comma)', () {
      expect(matchAnyTriggerPhrase('no go back', goBackPhrases), isNull);
    });

    test('the shutter: "No, take it" fires, "No, don\'t take it" does not', () {
      expect(matchAnyTriggerPhrase('No, take it.', ['take it']), isNotNull);
      expect(matchAnyTriggerPhrase("No, don't take it.", ['take it']), isNull);
      expect(matchAnyTriggerPhrase('no take it', ['take it']), isNull);
    });

    test('triggerPhraseIsNegated follows the same rule', () {
      expect(triggerPhraseIsNegated('No, capture it.', 'capture it'), isFalse);
      expect(triggerPhraseIsNegated("No, don't capture it.", 'capture it'), isTrue);
      expect(triggerPhraseIsNegated('no capture it', 'capture it'), isTrue);
    });
  });

  group('fuzzy intent layer: negation stays inside its clause', () {
    test('a leading "No," no longer vetoes a request', () {
      final decision = classifyCommandIntent('No, I want to see the invoice.');
      expect(decision.kind, IntentDecisionKind.confident);
      expect(decision.best!.trigger, 'view_invoice');
      expect(decision.best!.reason, contains('NEGATION PREFIX IGNORED'));
    });

    test("\"Don't worry, show me the estimate\" is a request", () {
      final decision = classifyCommandIntent("Don't worry, show me the estimate.");
      expect(decision.kind, IntentDecisionKind.confident);
      expect(decision.best!.trigger, 'view_estimate');
    });

    test('a negation inside the same clause still vetoes', () {
      expect(classifyCommandIntent("No, don't open the camera.").kind, IntentDecisionKind.none);
      expect(classifyCommandIntent("I don't want the invoice").kind, IntentDecisionKind.none);
      expect(classifyCommandIntent('no camera').kind, isNot(IntentDecisionKind.confident));
    });
  });

  group('photo decision: "No," before the decision', () {
    test('"No, keep it." is no longer read as retake (it asks instead of discarding)', () {
      expect(classifyPhotoDecision('No, keep it.'), isNot(PhotoDecision.retake));
    });

    test('"No, retake it." is a retake', () {
      expect(classifyPhotoDecision('No, retake it.'), PhotoDecision.retake);
    });

    test('in-clause negation still inverts', () {
      expect(classifyPhotoDecision("don't keep it"), PhotoDecision.retake);
      expect(classifyPhotoDecision('no keep it'), PhotoDecision.retake);
    });
  });

  group('continuation answers', () {
    test('affirmative answers', () {
      for (final text in [
        'Yes, take another one.', 'Yeah.', 'Sure, go ahead.', 'Okay, yes please.', 'Go ahead.', 'Yep, one more.',
        'Yes, take another photo', 'Of course',
      ]) {
        expect(classifyContinuationAnswer(text), ContinuationAnswer.affirmative, reason: text);
      }
    });

    test('negative answers', () {
      for (final text in ["No, I'm done.", 'No thanks.', "That's fine.", 'Nope.', "I'm done", 'No, that\'s all']) {
        expect(classifyContinuationAnswer(text), ContinuationAnswer.negative, reason: text);
      }
    });

    test('anything with content of its own is not an answer', () {
      for (final text in [
        "Yes, but what's the pressure rating?", 'No, show me the invoice.', 'No, go back.', 'Okay.', 'Yes — no, wait',
        'Yeah, don\'t', 'Show me the estimate',
      ]) {
        expect(classifyContinuationAnswer(text), ContinuationAnswer.none, reason: text);
      }
    });

    test('photo offer questions', () {
      expect(looksLikePhotoOfferQuestion('Want to take one more?'), isTrue);
      expect(looksLikePhotoOfferQuestion('Should I grab another shot'), isTrue);
      expect(looksLikePhotoOfferQuestion('Got it. Do you need another picture'), isTrue);
      expect(looksLikePhotoOfferQuestion("I've uploaded the photo."), isFalse);
      expect(looksLikePhotoOfferQuestion('Anything else I can help with?'), isFalse);
      expect(looksLikePhotoOfferQuestion(''), isFalse);
    });
  });
}
