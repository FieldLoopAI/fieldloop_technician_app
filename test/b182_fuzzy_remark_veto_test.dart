// Build 182 item B — a remark that only mentions a photo/the camera is not
// scored as an open_camera request by the fuzzy layer (classifyCommandIntent)
// nor acted on from the Gemini intent check; real requests still open it.
// Offline.
import 'dart:io';

import 'package:fielloop/services/b182_flags.dart';
import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/camera_request_matcher.dart';
import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/snap_command.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
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

/// Any deterministic open_camera path (phrase list, wider phrases, loose
/// matcher, short snap command) or a confident fuzzy open_camera.
bool _opensCamera(String text) {
  if (cameraActionNegation(text) != null || negatedCameraMention(text) != null) return false;
  if (matchAnyTriggerPhrase(text, _open) != null ||
      matchWiderOpenCamera(text) != null ||
      matchLooseCameraRequest(text) is CameraRequestMatch ||
      classifySnapCommand(text) == SnapCommand.request) {
    return true;
  }
  final d = classifyCommandIntent(text);
  return d.kind == IntentDecisionKind.confident && d.best!.trigger == 'open_camera';
}

const _requests = [
  'Take a photo',
  'Open the camera',
  'Snap it',
  'Snap a photo',
  "Let's take a picture",
  'Can you get a shot of that for me',
  "I'd like a photo",
  'I would like a photo',
  'photo',
  'camera',
  'Camera please',
  'a photo please',
];

const _remarks = [
  'I like the photo.',
  'That photo looks good',
  'The photo is blurry',
  'I took a photo earlier',
  'The camera app on my phone is different',
];

void main() {
  test('flag defaults ON', () => expect(kFuzzyRemarkVeto, isTrue));

  group('still opens the camera', () {
    for (final text in _requests) {
      test(text, () {
        expect(_opensCamera(text), isTrue, reason: classifyCommandIntent(text).describe(text));
        expect(isCameraRemark(text), isFalse, reason: text);
        expect(classifyCommandIntent(text).remarkVetoed, isFalse, reason: text);
      });
    }

    test('"Ready" in camera states still captures (wider capture rule, untouched)', () {
      expect(matchWiderCapture('Ready'), isA<WiderCaptureMatch>());
      expect(matchWiderCapture("Yes, I'm ready"), isA<WiderCaptureMatch>());
      expect(isCameraRemark('Ready'), isFalse);
    });

    test('every production open_camera phrase is unaffected by the veto', () {
      for (final text in _open) {
        final on = classifyCommandIntent(text);
        final off = classifyCommandIntent(text, remarkVeto: false);
        expect(on.remarkVetoed, isFalse, reason: text);
        expect(on.kind, off.kind, reason: text);
        expect(on.best?.trigger, off.best?.trigger, reason: text);
      }
    });
  });

  group('a remark never opens it', () {
    for (final text in _remarks) {
      test(text, () {
        expect(_opensCamera(text), isFalse, reason: classifyCommandIntent(text).describe(text));
        expect(isCameraRemark(text), isTrue, reason: text);
        final d = classifyCommandIntent(text);
        expect(d.kind == IntentDecisionKind.confident && d.best?.trigger == 'open_camera', isFalse);
      });
    }

    test('b181 14:29:21 "I like the photo." — was FUZZY MATCH open_camera 0.80, now vetoed to none', () {
      final off = classifyCommandIntent('I like the photo.', remarkVeto: false);
      expect(off.kind, IntentDecisionKind.confident);
      expect(off.best!.trigger, 'open_camera');
      expect(off.best!.confidence, 0.8);
      final on = classifyCommandIntent('I like the photo.');
      expect(on.remarkVetoed, isTrue);
      expect(on.kind, IntentDecisionKind.none);
      expect(on.best, isNull);
    });

    test('the Gemini intent check applies the same veto to open_camera only', () {
      expect(
        _screen.contains(
          "if (trigger == 'open_camera' && kFuzzyRemarkVeto && isCameraRemark(check.transcript)) {\n"
          "      _log_('FUZZY REMARK VETO: open_camera text=\${check.transcript}');\n"
          '      trigger = null;',
        ),
        isTrue,
      );
      expect(_screen.contains("if (decision.remarkVetoed) _log_('FUZZY REMARK VETO: open_camera text=\$transcript');"), isTrue);
    });
  });

  group('no other trigger changes', () {
    for (final text in [
      'show me the estimate',
      'the invoice',
      'estimate invoice',
      'show me the last photo',
      'photo of the leak maybe',
      'Toma una foto.',
      'take a photo and show the estimate',
      'I like the invoice',
    ]) {
      test(text, () {
        final on = classifyCommandIntent(text);
        final off = classifyCommandIntent(text, remarkVeto: false);
        expect(on.kind, off.kind, reason: text);
        expect(on.best?.trigger, off.best?.trigger, reason: text);
        expect(on.best?.confidence, off.best?.confidence, reason: text);
      });
    }
  });

  test('flag off = build 181 scoring for every remark', () {
    for (final text in _remarks) {
      final off = classifyCommandIntent(text, remarkVeto: false);
      expect(off.remarkVetoed, isFalse);
    }
  });
}
