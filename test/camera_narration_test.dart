import 'package:fielloop/services/camera_narration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('C13 camera narration', () {
    test('the client narration is a description, in both camera states', () {
      const text = "This is the attic access panel, there's water damage on the left side";
      expect(cameraNarrationRejection(text, cameraLive: true), isNull);
      expect(cameraNarrationRejection(text, cameraLive: false), isNull);
    });

    test('commands, questions, decisions and small talk are never narration', () {
      const live = [
        'Take a photo',
        'Take the picture now please',
        'Go back to the job screen',
        'Can you take the picture?',
        "What's the address of this job?",
        'Show me the estimate please',
        'The camera app on my phone is different',
      ];
      for (final text in live) {
        expect(cameraNarrationRejection(text, cameraLive: true), isNotNull, reason: text);
      }
      const captured = [
        'Keep it',
        "That's good, keep that one",
        "No, that's not right, take it again",
        'Okay thanks a lot',
      ];
      for (final text in captured) {
        expect(cameraNarrationRejection(text, cameraLive: false), isNotNull, reason: text);
      }
    });

    test('too short to be a note', () {
      expect(cameraNarrationRejection('Water damage here', cameraLive: true), isNotNull);
    });
  });
}
