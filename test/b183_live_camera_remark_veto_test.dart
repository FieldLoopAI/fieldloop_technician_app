// Build 183 Change A — LIVE_CAMERA_REMARK_VETO: with the camera live, a
// remark about the photo is conversation (no capture); every phrase that
// captures today still captures. Offline.
import 'dart:io';

import 'package:fielloop/services/b183_flags.dart';
import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/live_camera_remark_veto.dart';
import 'package:fielloop/services/wider_capture.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_camera_route.dart';

const _remarks = [
  'That looks good',
  'The photo is blurry',
  'I like what I see',
  'I like the photo',
  "That's a nice photo",
  'The picture looks great',
  'I like it',
  'Nice shot',
  'This photo is dark',
  'That photo is fine',
];

const _commands = [
  'Take a photo',
  'Take a picture',
  'Snap a picture',
  'Snap it',
  'Take another one',
  'Capture',
  'Get the photo.',
  'Take one',
  'Shoot',
  'Click',
];

/// Captured with no help from Gemini (phrase list, shutter word, wider
/// capture or the fuzzy live noun) — in build 182 and still now.
const _deterministicCommands = ['Take a photo', 'Take a picture', 'Snap a picture', 'Snap it', 'Capture', 'Get the photo.', 'Shoot'];

/// Existing fixtures that the build 182 deterministic path captured and the
/// veto now leaves as conversation — every one a remark.
const _expectedVetoedFixtures = {
  'I like the photo.',
  'That photo looks good',
  'The photo is blurry',
  'the picture on the wall is crooked',
  'Nice, got the shot.',
  'this photo is very blur',
};

/// Every short string literal in the EXISTING test files (read, not edited).
Set<String> _existingFixtureLiterals() {
  final literal = RegExp(r"'((?:[^'\\\n]|\\.){1,80})'" r'|"((?:[^"\\\n]|\\.){1,80})"');
  final out = <String>{};
  for (final file in Directory('test').listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    if (!name.endsWith('_test.dart') || name.startsWith('b183_') || name == 'camera_battery_test.dart') continue;
    for (final m in literal.allMatches(file.readAsStringSync())) {
      final s = (m.group(1) ?? m.group(2)!).replaceAll(r"\'", "'");
      if (s.contains(r'$') || !RegExp('[a-zA-Z]').hasMatch(s)) continue;
      out.add(s);
    }
  }
  return out;
}

void main() {
  test('flags default ON and print on their own B183 FLAGS line', () {
    expect(kLiveCameraRemarkVeto, isTrue);
    expect(kLiveRemarkIntentCheckVeto, isTrue);
    expect(describeB183Flags(), 'B183 FLAGS: liveCameraRemarkVeto=true liveRemarkIntentCheckVeto=true');
  });

  group('camera live: a remark is conversation — no capture, whatever Gemini answers', () {
    for (final text in _remarks) {
      test(text, () {
        expect(capturesB183(text), isFalse, reason: routeLiveCamera(text, remarkVeto: true, intentCheckVeto: true));
        expect(capturesB183(text, geminiIntent: 'capture_photo'), isFalse);
      });
    }

    test('b182 log 14:27:18 "I like the photo." — was FUZZY LIVE-CAMERA MATCH capture, now vetoed', () {
      expect(routeLiveCamera('I like the photo.', remarkVeto: false, intentCheckVeto: false), 'capture:fuzzy_live_noun');
      expect(routeLiveCamera('I like the photo.', remarkVeto: true, intentCheckVeto: true), 'conversation:fallback');
      expect(liveCameraRemarkWord('I like the photo.'), 'like');
    });
  });

  group('camera live: every listed command still captures exactly as in build 182', () {
    for (final text in _commands) {
      test(text, () {
        for (final gemini in ['none', 'capture_photo']) {
          expect(capturesB183(text, geminiIntent: gemini), capturesB182(text, geminiIntent: gemini), reason: '$text/$gemini');
        }
        expect(capturesB183(text, geminiIntent: 'capture_photo'), isTrue, reason: text);
        expect(isLiveCameraRemark(text), isFalse, reason: text);
      });
    }

    test('deterministic ones capture with no Gemini answer at all', () {
      for (final text in _deterministicCommands) {
        expect(capturesB183(text), isTrue, reason: text);
      }
    });
  });

  group('regression over the existing capture-phrase set', () {
    test('every production capture_photo phrase (and its open_camera list) is never a remark', () {
      final open = productionPhrases('_openCameraIndicatorPhrases');
      for (final text in [...capturePhrases, ...open, ...widerShutterUtterances, ...widerOpenCameraPhrases]) {
        expect(isLiveCameraRemark(text), isFalse, reason: text);
        expect(capturesB183(text), capturesB182(text), reason: text);
      }
    });

    test('existing test fixtures: the deterministic path changes only for the known remarks', () {
      final literals = _existingFixtureLiterals();
      var captured = 0;
      final changed = <String>{};
      for (final text in literals) {
        if (!capturesB182(text)) continue;
        captured++;
        if (!capturesB183(text)) changed.add(text);
      }
      // ignore: avoid_print
      print('B183 REGRESSION: ${literals.length} fixture literals, $captured captured in b182, '
          '${captured - changed.length} still capture, vetoed=$changed');
      expect(captured, greaterThan(100));
      expect(changed, _expectedVetoedFixtures);
    });

    test('existing test fixtures: with Gemini answering capture_photo, only remarks lose the capture', () {
      for (final text in _existingFixtureLiterals()) {
        if (!capturesB182(text, geminiIntent: 'capture_photo') || capturesB183(text, geminiIntent: 'capture_photo')) {
          continue;
        }
        expect(isLiveCameraRemark(text), isTrue, reason: text);
        expect(tokensHaveNoCommandWord(text), isTrue, reason: text);
      }
    });
  });

  group('the rule itself', () {
    test('a command word or request pair always wins over an opinion word', () {
      for (final text in [
        "I'd like a photo",
        'I would like a picture',
        'Looks good, take it',
        'Nice, snap another',
        'Good, one more',
        'Yes, looks good',
        'Looks good, go ahead',
        'That is good, shoot',
        'Photo please, it looks fine',
        'Nice, do it',
      ]) {
        expect(isLiveCameraRemark(text), isFalse, reason: text);
      }
    });

    test('no opinion word -> not a remark (bare nouns keep capturing)', () {
      for (final text in ['photo', 'shot', 'Tika shot', 'the pic', 'okay picture', 'image', 'photo now']) {
        expect(isLiveCameraRemark(text), isFalse, reason: text);
        expect(capturesB183(text), isTrue, reason: text);
      }
    });

    test('the general matcher still scores the remarks as before (veto acts after it)', () {
      expect(classifyCommandIntent('The photo is blurry').kind, IntentDecisionKind.weak);
      expect(classifyCommandIntent('I like the photo.').remarkVetoed, isTrue); // b182 open_camera veto
    });
  });

  group('wiring in the production screen', () {
    test('fuzzy live-camera path and Gemini intent check, each behind its own flag', () {
      expect(productionScreen.contains('if (liveNoun != null && kLiveCameraRemarkVeto && isLiveCameraRemark(transcript)) {'), isTrue);
      expect(productionScreen.contains("\"LIVE REMARK VETO: '\$transcript' score="), isTrue);
      expect(
        productionScreen.contains(
          "if (trigger == 'capture_photo' && kLiveRemarkIntentCheckVeto && isLiveCameraRemark(check.transcript)) {",
        ),
        isTrue,
      );
      expect(productionScreen.contains('_log_(describeB183Flags());'), isTrue);
      expect(File('lib/main.dart').readAsStringSync().contains('debugPrint(describeB183Flags());'), isTrue);
    });

    test('B182 line and the build 182 open_camera veto are unchanged', () {
      expect(productionScreen.contains('_log_(describeB182Flags());'), isTrue);
      expect(
        productionScreen.contains("if (trigger == 'open_camera' && kFuzzyRemarkVeto && isCameraRemark(check.transcript)) {"),
        isTrue,
      );
    });

    test("the harness's copy of the shutter-word matcher matches the screen's literals", () {
      for (final w in shutterConfirmWords) {
        expect(productionScreen.contains("const shutterConfirmWords = ['capture', 'snap', 'take it', 'confirm', 'keep it'];"), isTrue, reason: w);
      }
      for (final p in shutterOpenCameraOnly) {
        expect(productionScreen.contains("    '$p',\n"), isTrue, reason: p);
      }
    });
  });
}

bool tokensHaveNoCommandWord(String text) =>
    !RegExp(r'[a-z]+').allMatches(text.toLowerCase()).any((m) => liveRemarkCommandWords.contains(m.group(0)));
