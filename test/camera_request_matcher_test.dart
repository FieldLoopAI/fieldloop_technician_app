import 'package:fielloop/services/camera_request_matcher.dart';
import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

bool _isRequest(String text) => matchLooseCameraRequest(text) is CameraRequestMatch;

void main() {
  group('Module D3 — remarks that mention the camera/photos never open it', () {
    const remarks = [
      // The acceptance-test example.
      'the camera app on my phone is different',
      'The camera app on my phone is different.',
      'my phone camera keeps going off',
      "the camera won't open on my phone",
      'the camera opens really slowly',
      'the camera on my phone takes better pictures',
      'I need to see the picture my wife sent',
      'I already took a picture of it',
      'did you take a picture of the panel',
      'have you taken a photo yet',
      'I take a lot of pictures on every job',
      'we usually snap a photo before we start',
      "don't open the camera",
      'no, do not take a photo',
      'the picture on the wall is crooked',
      'show me the last photo',
      'can you show me the picture',
      'my wife wants a picture of the dog',
      'the customer captured a photo of the leak',
    ];
    for (final text in remarks) {
      test('loose matcher: "$text"', () {
        expect(_isRequest(text), isFalse, reason: text);
      });
      test('fuzzy layer never CONFIDENT open_camera: "$text"', () {
        final decision = classifyCommandIntent(text);
        final confidentCamera =
            decision.kind == IntentDecisionKind.confident && decision.best?.trigger == 'open_camera';
        expect(confidentCamera, isFalse, reason: decision.describe(text));
      });
    }

    test('CAMERA GATE: the example is a statement, so a Gemini open_camera is blocked', () {
      expect(assessCameraRequest('the camera app on my phone is different').kind, CameraRequestAssessment.statement);
      expect(assessCameraRequest('my phone camera keeps going off').kind, CameraRequestAssessment.statement);
      expect(assessCameraRequest('what time is it').kind, CameraRequestAssessment.noMention);
    });
  });

  group('genuine requests still match', () {
    const requests = [
      'can you open up the camera',
      'open the camera please',
      'I want to take a photo of the panel',
      "let's get a picture of this",
      'snap a quick picture',
      'I need a photo',
      'I need a photo of this breaker',
      'take one more picture',
      'All right, taking the picture',
      'could you take a photo',
      "I'll take a picture",
      'I want the camera',
      'start the camera',
      'turn on the camera',
      'grab a shot of that',
    ];
    for (final text in requests) {
      test('loose matcher: "$text"', () {
        expect(_isRequest(text), isTrue, reason: '$text -> ${matchLooseCameraRequest(text)}');
      });
    }

    test('CAMERA GATE: short/garbled mentions stay unclear (left to Gemini)', () {
      expect(assessCameraRequest('photo').kind, CameraRequestAssessment.unclear);
      expect(assessCameraRequest('Tika shot').kind, CameraRequestAssessment.unclear);
      expect(assessCameraRequest('camera please').kind, CameraRequestAssessment.unclear);
    });
  });

  group('fuzzy layer still resolves paraphrased requests to open_camera', () {
    const requests = ['grab a shot of that', 'I want a pic', 'fire up the camera real quick', 'camera'];
    for (final text in requests) {
      test('"$text"', () {
        final decision = classifyCommandIntent(text);
        expect(decision.kind, IntentDecisionKind.confident, reason: decision.describe(text));
        expect(decision.best!.trigger, 'open_camera');
      });
    }
  });
}
