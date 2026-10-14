// Build 180 — the B180 FLAGS line, and regression rows straight from the
// b179 logs: what worked in build 179 still resolves the same way through
// the pure matchers. Offline.
import 'dart:io';

import 'package:fielloop/services/b180_flags.dart';
import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/camera_request_matcher.dart';
import 'package:fielloop/services/local_close_command.dart';
import 'package:fielloop/services/photo_decision_classifier.dart';
import 'package:fielloop/services/photo_decline.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:fielloop/services/wait_hold_intent.dart';
import 'package:fielloop/services/wider_capture.dart';
import 'package:flutter_test/flutter_test.dart';

final String _screen = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();

List<String> _productionPhrases(String listName) {
  final block = RegExp('const List<String> $listName = \\[(.*?)\\n\\];', dotAll: true).firstMatch(_screen);
  if (block == null) throw StateError('$listName not found in the production file');
  return [
    for (final m in RegExp(r'''^\s*(?:'([^']*)'|"([^"]*)"),''', multiLine: true).allMatches(block.group(1)!))
      m.group(1) ?? m.group(2)!,
  ];
}

final _open = _productionPhrases('_openCameraIndicatorPhrases');
final _capture = _productionPhrases('_capturePhotoIndicatorPhrases');

bool _opensCamera(String text) =>
    (matchAnyTriggerPhrase(text, _open) != null ||
        matchWiderOpenCamera(text) != null ||
        matchLooseCameraRequest(text) is CameraRequestMatch) &&
    cameraActionNegation(text) == null &&
    negatedCameraMention(text) == null;

bool _captures(String text) => matchAnyTriggerPhrase(text, _capture) != null || matchWiderCapture(text) is WiderCaptureMatch;

LocalCloseDecision _decide(LocalCloseController c, String text, {int atMs = 0}) =>
    c.decide(text, context: const LocalCloseContext(), now: DateTime(2026, 10, 14).add(Duration(milliseconds: atMs)));

void main() {
  group('B180 FLAGS line', () {
    test('format', () {
      expect(
        describeB180Flags(),
        'B180 FLAGS: scriptedReplyClips=true lateFinalizeMs=100 waitHoldIntent=true closeLineFullPlayback=true '
        'widerDeclineB180=true',
      );
    });
    test('logged at app start and at every session open, after the B179 line', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main.indexOf('debugPrint(describeB180Flags());'), greaterThan(main.indexOf('debugPrint(describeB179Flags());')));
      expect(_screen.indexOf('_log_(describeB180Flags());'), greaterThan(_screen.indexOf('_log_(describeB179Flags());')));
    });
    test('the BUILD line flags are unchanged (no B180 fields in it)', () {
      expect(_screen, contains("final String kBuildLineFlags = '\$kVoiceFlagsSummary \${describeB178Flags()}';"));
    });
  });

  group('b179 log regression rows', () {
    test('"No photo for now." (camera closed) -> decline "Okay."', () {
      expect(matchPhotoDecline('No photo for now.'), 'no photo for now');
      expect(_opensCamera('No photo for now.'), isFalse);
    });
    test('"Forget the photo." -> decline', () => expect(matchPhotoDecline('Forget the photo.'), 'forget the photo'));
    test('"Don\'t take a photo." -> negation "Okay." (guard blocks, no decline, no capture)', () {
      expect(cameraActionNegation("Don't take a photo."), isNotNull);
      expect(_opensCamera("Don't take a photo."), isFalse);
      expect(matchPhotoDecline("Don't take a photo."), isNull);
    });
    for (final text in ['ready', 'I am ready.', 'Yes, I am ready.', 'Go ahead.', 'I am ready now.']) {
      test('"$text" captures (camera live), wait path does not claim it', () {
        expect(_captures(text), isTrue);
        expect(matchWaitHold(text), isNull);
      });
    }
    test('"Not ready." must not capture; with the camera live it is a wait', () {
      expect(_captures('Not ready.'), isFalse);
      expect(matchWaitHold('Not ready.'), 'not ready');
    });
    for (final text in ['Close the session', 'End the session', 'Stop listening', 'good bye']) {
      test('"$text" closes', () {
        final m = matchLocalClose(text);
        expect(m, isA<LocalCloseMatch>());
        expect((m! as LocalCloseMatch).tier, LocalCloseTier.explicit);
      });
    }
    test('"I am done." + "Yes." closes', () {
      final c = LocalCloseController();
      expect(_decide(c, 'I am done.').kind, LocalCloseDecisionKind.askConfirm);
      expect(_decide(c, 'Yes.', atMs: 2000).kind, LocalCloseDecisionKind.closeNow);
    });
    test('"That\'s all." + "No." stays open', () {
      final c = LocalCloseController();
      expect(_decide(c, "That's all.").kind, LocalCloseDecisionKind.askConfirm);
      expect(_decide(c, 'No.', atMs: 2000).kind, LocalCloseDecisionKind.declined);
      expect(c.closeRequested, isFalse);
    });
    test('"I need a picture." opens the camera', () => expect(_opensCamera('I need a picture.'), isTrue));
    test('"Retake it." retakes', () {
      expect(classifyPhotoDecision('Retake it.'), PhotoDecision.retake);
    });
    test('"Go back to home screen" is a navigation, not a decline/wait/close', () {
      expect(matchPhotoDecline('Go back to home screen'), isNull);
      expect(matchWaitHold('Go back to home screen'), isNull);
      expect(matchLocalClose('Go back to home screen'), isNot(isA<LocalCloseMatch>()));
      expect(_opensCamera('Go back to home screen'), isFalse);
    });
  });
}
