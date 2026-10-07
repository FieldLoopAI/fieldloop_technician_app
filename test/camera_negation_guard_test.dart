import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/photo_decision_classifier.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('blocks a negated camera action', () {
    const blocked = [
      // The two Part 2 (14:23:17) phrases.
      "I don't want to take photo.",
      "I said I don't want to take photo.",
      "Don't take the picture",
      'Do not open the camera',
      "No, I don't want to snap a picture",
      "I don't need to retake it",
      "Don't retake it",
      'I do not want you to capture this',
      'Never take a photo here',
      'Take a photo, never mind',
      'Cancel that',
      'Never mind',
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
      // Keep / retake / go back, including the "No, ..." forms.
      'Keep it', "That's good", 'Save that', 'Retake it', 'No, retake it',
      "No, that's not right, take it again", "No, this photo didn't looks good.", 'No, go back.', 'Go back',
      'Take it', 'Ready', 'Capture it',
      // A negation that isn't about the camera action.
      "Don't worry, take a photo", "I don't know, take a picture of the panel", 'Never mind, take a photo',
      "This doesn't look right",
    ];
    for (final text in allowed) {
      test('"$text"', () => expect(cameraActionNegation(text), isNull));
    }
  });

  group('the existing keep/retake classifier is unchanged for these phrases', () {
    test('"No, this photo didn\'t looks good." still means retake', () {
      expect(classifyPhotoDecision("No, this photo didn't looks good."), PhotoDecision.retake);
    });
    test('"No, go back." still matches go back past the leading "No,"', () {
      expect(matchAnyTriggerPhrase('No, go back.', ['go back']), isNotNull);
    });
    test('"Keep it" is still confirm', () {
      expect(classifyPhotoDecision('Keep it'), PhotoDecision.confirm);
    });
  });
}
