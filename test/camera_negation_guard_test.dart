import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/confirmation_clip.dart';
import 'package:fielloop/services/photo_decision_classifier.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('blocks a negated camera action', () {
    const blocked = [
      // Bob's two exact Part 2 (14:23:17) phrases, and his Module B #15.
      "I don't want to take photo.",
      "I said I don't want to take photo.",
      "I don't want to take a photo.",
      // The Step 1 coverage list.
      "Don't take a photo",
      'Do not take a photo',
      'Dont take a photo',
      "I don't want to",
      'I do not want to take a picture',
      "No I don't",
      "No, I don't.",
      "I said I don't",
      'Never mind',
      'Cancel that',
      'Forget it',
      'Not now',
      'Stop',
      "I don't need to take a photo",
      // Earlier cases, kept.
      "Don't take the picture",
      'Do not open the camera',
      "No, I don't want to snap a picture",
      "I don't need to retake it",
      "Don't retake it",
      'I do not want you to capture this',
      'Never take a photo here',
      'Take a photo, never mind',
      'Take a photo. Actually, forget it.',
    ];
    for (final text in blocked) {
      test('"$text"', () => expect(cameraActionNegation(text), isNotNull));
    }
  });

  group('leaves existing commands alone', () {
    const allowed = [
      // The 10 client photo phrasings.
      'Take a photo', 'Take a picture', 'Snap a picture', 'Capture this', 'Snap a photo', 'Get a photo',
      'Open the camera', 'Open camera', 'I need a photo', "Let's take photo",
      // Keep / retake / go back, including the "No, ..." / "Yes, ..." forms.
      'Keep it', 'Keep', "That's good", 'That looks good', 'Save that', 'Retake', 'Retake it', 'No, retake it',
      'Take another one', "No, that's not right, take it again", "No, this photo didn't look good",
      "No, this photo didn't looks good.", 'No, go back.', 'Go back', 'Yes, take a photo', 'No, take a photo',
      'Take it', 'Ready', 'Capture it',
      // A negation that isn't about the camera action.
      "Don't worry, take a photo", "I don't know, take a picture of the panel", 'Never mind, take a photo',
      'Forget it, take a photo', "This doesn't look right",
    ];
    for (final text in allowed) {
      test('"$text"', () => expect(cameraActionNegation(text), isNull));
    }
  });

  group('normalization', () {
    test('contractions expand and punctuation goes', () {
      expect(normalizeNegationText("I DON'T want to!").words, ['i', 'do', 'not', 'want', 'to']);
      expect(normalizeNegationText('dont').words, ['do', 'not']);
      expect(normalizeNegationText("didn't").words, ['did', 'not']);
    });
    test('a clause boundary before a contraction is kept on its first word', () {
      final n = normalizeNegationText("Okay, don't");
      expect(n.words, ['okay', 'do', 'not']);
      expect(n.boundaries, [false, true, false]);
    });
  });

  group('the existing keep/retake/go-back classifiers are unchanged for these phrases', () {
    test('"No, this photo didn\'t look good" still means retake', () {
      expect(classifyPhotoDecision("No, this photo didn't look good"), PhotoDecision.retake);
    });
    test('"No, this photo didn\'t looks good." still means retake', () {
      expect(classifyPhotoDecision("No, this photo didn't looks good."), PhotoDecision.retake);
    });
    test('"No, go back." still matches go back past the leading "No,"', () {
      expect(matchAnyTriggerPhrase('No, go back.', ['go back']), isNotNull);
    });
    test('"Keep it" / "That looks good" are still confirm', () {
      expect(classifyPhotoDecision('Keep it'), PhotoDecision.confirm);
      expect(classifyPhotoDecision('That looks good'), PhotoDecision.confirm);
    });
    test('"Retake" / "Take another one" are still retake', () {
      expect(classifyPhotoDecision('Retake'), PhotoDecision.retake);
      expect(classifyPhotoDecision('Take another one'), PhotoDecision.retake);
    });
  });

  test('the "Okay." reply is cached-clip eligible', () {
    expect(isCacheableConfirmation('negation_guard'), isTrue);
  });
}
