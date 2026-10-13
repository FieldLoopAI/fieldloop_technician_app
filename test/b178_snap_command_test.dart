import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/camera_request_matcher.dart';
import 'package:fielloop/services/garbled_transcript.dart';
import 'package:fielloop/services/snap_command.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 178 Step 5 (SNAP_IT_FIX) — b177 part 4: "Snap it." (camera
/// closed) got "say that again" after a 902ms intent-check timeout.
void main() {
  group('(i) short camera commands open the camera (screen routes them to open_camera at once)', () {
    for (final t in [
      'Snap it.',
      'Snap it',
      'snap it please',
      'Okay, snap it.',
      'Snap a photo.',
      'Snap a picture.',
      'Get a shot of this.',
      'Get a shot of that',
      'Grab a shot.',
    ]) {
      test('"$t" -> request', () => expect(classifySnapCommand(t), SnapCommand.request));
    }
  });

  group('(i) negated forms answer "Okay." and never open the camera', () {
    for (final t in [
      "Don't snap it.",
      'Dont snap it',
      'No, snap it',
      'no snap it',
      'Do not snap it.',
      "I don't want to snap a photo.",
      'Never snap a picture.',
    ]) {
      test('"$t" -> negated', () => expect(classifySnapCommand(t), SnapCommand.negated));
    }

    test('the negation guard itself finds a cue for the "do not" forms (same "Okay." path as today)', () {
      expect(cameraActionNegation("Don't snap it."), isNotNull);
      expect(cameraActionNegation("I don't want to snap a photo."), isNotNull);
    });
  });

  group('everything else is routed exactly as before (null)', () {
    for (final t in [
      'The camera app on my phone is different.', // D3: must NOT open the camera
      'Can you got a sort that for me?', // b175 garbled — still the garbled quick repeat
      'snap',
      'it',
      'oh snap',
      'snap it shut',
      'did you snap it',
      'I snap it every time',
      'take a photo',
      'what is the job address',
      '',
    ]) {
      test('"$t" -> null', () => expect(classifySnapCommand(t), isNull));
    }

    test('D3 sentence is still rejected by the loose camera matcher, and stays out of snap handling', () {
      expect(matchLooseCameraRequest('The camera app on my phone is different.'), isA<CameraRequestRejection>());
      expect(classifySnapCommand('The camera app on my phone is different.'), isNull);
    });

    test('garbled quick repeat for real noise is unchanged', () {
      expect(looksLikeGarbledShortUtterance('Can you got a sort that for me?'), isTrue);
      expect(classifySnapCommand('Can you got a sort that for me?'), isNull);
    });
  });
}
