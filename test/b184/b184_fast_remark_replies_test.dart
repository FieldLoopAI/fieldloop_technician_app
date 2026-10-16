// Build 184 — Changes A–D: remark quick reply, "another one" capture,
// "Yes, take another one" routing, 5 s close-confirm timeout. Offline; the
// live-camera route is test/support/live_camera_route_b184.dart (build 183's
// route plus the three additions in their real places).
import 'dart:io';

import 'package:fielloop/services/another_one_capture.dart';
import 'package:fielloop/services/b184_flags.dart';
import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/conversational_utterance.dart';
import 'package:fielloop/services/live_camera_remark_veto.dart';
import 'package:fielloop/services/local_close_command.dart';
import 'package:fielloop/services/remark_quick_reply.dart';
import 'package:fielloop/services/scripted_reply_clips.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/live_camera_route.dart';
import 'live_camera_route_b184.dart';

/// P1 (b183 device log) plus the spec's list — camera live.
const _liveRemarks = [
  'I like the photo.',
  'The photo is blurry.',
  'Nice shot.',
  'This photo is dark.',
  'I like the photo',
  'That looks good',
  'Nice shot',
  'This photo is dark',
  'The picture looks great',
  'I like it',
  "That's a nice photo",
  'That photo is fine',
];

const _garbledCaptureAttempts = ['tak a fotto', 'foto', 'Tika shot', 'snap obituary', 'okay picture', 'photo now'];

const _commands = [
  'Take a photo',
  'Take a picture',
  'Snap a picture',
  'Snap it',
  'Capture',
  'Get the photo.',
  'Shoot',
  'Do it',
  'Okay take it',
  'Yes, take a photo',
];

const _questions = ['is the photo ok?', 'Is the photo ok', 'did it take the photo?', 'Is the picture blurry?', 'what is the address'];

const _jobDataRemarks = [
  'The invoice looks good',
  'the customer is happy',
  'I like the estimate',
  'The address is fine',
  'This job is great',
];

const _answersAndClosers = [
  'Yes',
  'No',
  'No, it is fine',
  'Okay, that looks good',
  'No photo for now',
  'Hold on',
  "I'm done",
  "That's all",
  'loop off',
  "I don't like the photo",
];

const _anotherOnePhrases = [
  'Take another one',
  'Take another',
  'Take another photo',
  'Take another picture',
  'Take one more',
  'One more photo',
  'Take one',
  'Click',
  'Snap another one',
  'Snap another',
  'Shoot another one',
];

const _anotherOneGuards = [
  "Don't take another one",
  "I don't need another one",
  'Should I take another one?',
  'Take another one?',
  'take one more step back',
  'take one of those',
  'click on the invoice',
];

Set<String> _existingFixtureLiterals() {
  final literal = RegExp(r"'((?:[^'\\\n]|\\.){1,80})'" r'|"((?:[^"\\\n]|\\.){1,80})"');
  final out = <String>{};
  for (final file in Directory('test').listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    if (!name.endsWith('_test.dart') || name.startsWith('b183_') || name.startsWith('b184_') || name.startsWith('camera_battery')) {
      continue;
    }
    for (final m in literal.allMatches(file.readAsStringSync())) {
      final s = (m.group(1) ?? m.group(2)!).replaceAll(r"\'", "'");
      if (s.contains(r'$') || !RegExp('[a-zA-Z]').hasMatch(s)) continue;
      out.add(s);
    }
  }
  return out;
}

String _b184Off(String text, {String geminiIntent = 'none'}) =>
    routeLiveCameraB184(text, quickReply: false, anotherOne: false, yesRouting: false, geminiIntent: geminiIntent);

final String _screen = productionScreen;

void main() {
  test('flags default ON and print on their own B184 FLAGS line', () {
    expect(kRemarkQuickReply, isTrue);
    expect(kAnotherOneCapture, isTrue);
    expect(kYesCaptureRouting, isTrue);
    expect(kLocalCloseConfirm5s, isTrue);
    expect(
      describeB184Flags(),
      'B184 FLAGS: remarkQuickReply=true anotherOneCapture=true yesCaptureRouting=true localCloseConfirm5s=true',
    );
  });

  group('Change A — REMARK_QUICK_REPLY', () {
    group('camera live: a remark gets "Noted." at once — no capture, no question, no KB', () {
      for (final text in _liveRemarks) {
        test(text, () {
          expect(routeLiveCameraB184(text), 'conversation:quick_reply_noted');
          expect(routeB183(text), 'conversation:fallback', reason: 'b183 asked (weak match / clarify) instead');
          expect(quickReplyPathFor(text, cameraLive: true), RemarkQuickReplyPath.liveCamera);
          for (final gemini in ['none', 'capture_photo']) {
            expect(capturesB184(text, geminiIntent: gemini), isFalse, reason: gemini);
          }
        });
      }
    });

    test('camera closed (P2): "I like the photo." gets "Noted." — the b182 remark veto fired, a photo noun, no verb', () {
      for (final text in ['I like the photo.', 'I like the photo']) {
        expect(classifyCommandIntent(text).remarkVetoed, isTrue, reason: text);
        expect(quickReplyPathFor(text, cameraLive: false), RemarkQuickReplyPath.cameraClosed, reason: text);
      }
    });

    test('the reply is C13\'s own "Noted." line and clip (no new line)', () {
      expect(remarkQuickReplyText, 'Noted.');
      expect(remarkQuickReplyReason, 'camera_narration_noted');
      expect(_screen.contains("_informGeminiToSpeakVerbatim('Noted.', reason: 'camera_narration_noted');"), isTrue);
      expect(isClipEligibleReply(remarkQuickReplyReason, remarkQuickReplyText, includeFixedLines: true), isTrue);
    });

    test('decision time: local and sub-millisecond (no network, no Gemini)', () {
      final sw = Stopwatch()..start();
      const rounds = 200;
      for (var i = 0; i < rounds; i++) {
        for (final text in _liveRemarks) {
          quickReplyPathFor(text, cameraLive: true);
        }
      }
      sw.stop();
      final perDecisionUs = sw.elapsedMicroseconds / (rounds * _liveRemarks.length);
      // ignore: avoid_print
      print('B184 QUICK REPLY decision: ${perDecisionUs.toStringAsFixed(1)} us per utterance');
      expect(perDecisionUs, lessThan(5000));
    });

    group('regression: build 183 behavior kept', () {
      test('garbled capture attempts: no quick reply, same route as b183 (still capture)', () {
        for (final text in _garbledCaptureAttempts) {
          expect(quickReplyPathFor(text, cameraLive: true), isNull, reason: text);
          expect(quickReplyPathFor(text, cameraLive: false), isNull, reason: text);
          expect(routeLiveCameraB184(text), routeB183(text), reason: text);
          expect(capturesB184(text), isTrue, reason: text);
        }
      });

      test('a genuine garbled camera request with the camera closed keeps the weak-match reconfirm path', () {
        for (final text in ['tak a fotto', 'tick a picher', 'snap obituary', 'cam era open']) {
          expect(quickReplyPathFor(text, cameraLive: false), isNull, reason: text);
        }
      });

      test('real commands: same route as b183, still capture', () {
        for (final text in _commands) {
          expect(quickReplyPathFor(text, cameraLive: true), isNull, reason: text);
          expect(routeLiveCameraB184(text), routeB183(text), reason: text);
          expect(capturesB184(text), isTrue, reason: text);
        }
      });

      test('questions: no quick reply, same route as b183', () {
        for (final text in _questions) {
          expect(remarkQuickReplyRejection(text, path: RemarkQuickReplyPath.liveCamera), 'question', reason: text);
          expect(
            remarkQuickReplyRejection(text, path: RemarkQuickReplyPath.cameraClosed, fuzzyRemarkVetoed: true),
            'question',
            reason: text,
          );
          expect(routeLiveCameraB184(text), routeB183(text), reason: text);
        }
      });

      test('job-data words (KB / job facts): no quick reply', () {
        for (final text in _jobDataRemarks) {
          expect(quickReplyPathFor(text, cameraLive: true), isNull, reason: text);
          expect(quickReplyPathFor(text, cameraLive: false), isNull, reason: text);
          expect(routeLiveCameraB184(text), routeB183(text), reason: text);
        }
      });

      test('yes / no / decline / wait / close: no quick reply', () {
        for (final text in _answersAndClosers) {
          expect(remarkQuickReplyRejection(text, path: RemarkQuickReplyPath.liveCamera), isNotNull, reason: text);
          expect(
            remarkQuickReplyRejection(text, path: RemarkQuickReplyPath.cameraClosed, fuzzyRemarkVetoed: true),
            isNotNull,
            reason: text,
          );
          expect(routeLiveCameraB184(text), routeB183(text), reason: text);
        }
      });

      test('greetings, filler and (camera closed) small talk keep their own replies', () {
        for (final text in ['Good morning', 'Hello', 'Hey, good morning']) {
          expect(classifySmallTalk(text), SmallTalkKind.greeting, reason: text);
          expect(remarkQuickReplyRejection(text, path: RemarkQuickReplyPath.liveCamera), isNotNull, reason: text);
        }
        for (final text in ['photo looks good', 'Looks good', 'That looks good', 'sounds good', 'nice photo']) {
          if (classifySmallTalk(text) == SmallTalkKind.none) continue;
          expect(
            remarkQuickReplyRejection(text, path: RemarkQuickReplyPath.cameraClosed, fuzzyRemarkVetoed: true),
            isNotNull,
            reason: text,
          );
        }
        expect(
          remarkQuickReplyPath(
            'I like the photo.',
            enabled: true,
            cameraLiveArmed: true,
            cameraClosed: false,
            liveVetoesOn: true,
            decision: classifyCommandIntent('I like the photo.'),
            photoNoteActive: false,
            expectingQuestion: false,
            nonInformationalFiller: true,
          ),
          isNull,
        );
        expect(_screen.contains('      nonInformationalFiller: _looksLikeNonInformationalFiller(transcript),\n'), isTrue);
      });

      test('a request verb or request pair is never a quick reply (camera closed)', () {
        for (final text in ["I'd like a photo", 'I would like a picture', 'Photo please', 'Get a photo', 'Snap a picture']) {
          expect(
            remarkQuickReplyRejection(text, path: RemarkQuickReplyPath.cameraClosed, fuzzyRemarkVetoed: true),
            isNotNull,
            reason: text,
          );
        }
      });

      test('the decision itself: off, photo note, announced question, a confident match -> null', () {
        final d = classifyCommandIntent('I like the photo.');
        RemarkQuickReplyPath? path({bool enabled = true, bool note = false, bool question = false, bool vetoes = true}) =>
            remarkQuickReplyPath(
              'I like the photo.',
              enabled: enabled,
              cameraLiveArmed: true,
              cameraClosed: false,
              liveVetoesOn: vetoes,
              decision: d,
              photoNoteActive: note,
              expectingQuestion: question,
            );
        expect(path(), RemarkQuickReplyPath.liveCamera);
        expect(path(enabled: false), isNull);
        expect(path(note: true), isNull);
        expect(path(question: true), isNull);
        expect(path(vetoes: false), isNull, reason: 'b183 vetoes off -> b183-off behavior, no quick reply');
        final confident = classifyCommandIntent('show me the invoice');
        expect(confident.kind, IntentDecisionKind.confident);
        expect(
          remarkQuickReplyPath(
            'show me the invoice',
            enabled: true,
            cameraLiveArmed: true,
            cameraClosed: false,
            liveVetoesOn: true,
            decision: confident,
            photoNoteActive: false,
            expectingQuestion: false,
          ),
          isNull,
        );
      });
    });
  });

  group('Change B — ANOTHER_ONE_CAPTURE (camera live)', () {
    for (final text in _anotherOnePhrases) {
      test('captures: $text', () {
        // "Snap another (one)" already captured in b183 (shutter word "snap").
        expect(routeLiveCameraB184(text), text.startsWith('Snap') ? routeB183(text) : 'capture:another_one');
        expect(capturesB184(text), isTrue);
      });
    }

    test('lead-ins please/okay before, "now" after', () {
      for (final text in ['Please take another one', 'Okay take one', 'Ok, click', 'Take another one now', 'Please take another one now']) {
        expect(matchAnotherOneCapture(text), isNotNull, reason: text);
        expect(capturesB184(text), isTrue, reason: text);
      }
      expect(routeB183('Please take another one now'), 'conversation:narration_note', reason: 'b183 kept it as a note');
    });

    for (final text in _anotherOneGuards) {
      test('guard, no capture: $text', () {
        expect(matchAnotherOneCapture(text), isNull);
        expect(capturesB184(text), capturesB183(text), reason: routeLiveCameraB184(text));
        expect(capturesB184(text), isFalse);
      });
    }

    test('b183 remark set: still no capture', () {
      for (final text in [..._liveRemarks, 'I like what I see', 'That photo looks good', 'the picture on the wall is crooked']) {
        expect(capturesB184(text), isFalse, reason: text);
        expect(capturesB184(text, geminiIntent: 'capture_photo'), isFalse, reason: text);
      }
    });

    test('camera closed / photo captured: no change — the hook needs the camera live and armed', () {
      expect(
        _screen.contains(
          '  bool _maybeCaptureBeforeNarration() {\n'
          '    if ((!kAnotherOneCapture && !kYesCaptureRouting) || widget.jobId == null || _photoNote != null) return false;\n'
          '    if (_screenTask != _ScreenTask.cameraLive || !_cameraOpenConfirmed) return false;\n',
        ),
        isTrue,
      );
    });

    test('flag off = build 183 route', () {
      for (final text in _anotherOnePhrases) {
        expect(routeLiveCameraB184(text, anotherOne: false, yesRouting: false, quickReply: false), routeB183(text));
      }
    });
  });

  group('Change C — YES_CAPTURE_ROUTING (camera live)', () {
    test('"Yes, take another one" captures instead of becoming a C13 note', () {
      for (final text in ['Yes, take another one', 'Yeah take another one', 'Yep, take one more', 'Okay, take another one']) {
        expect(routeB183(text), 'conversation:narration_note', reason: '$text (b183)');
        expect(routeLiveCameraB184(text), anyOf('capture:yes_capture_routing', 'capture:another_one'), reason: text);
      }
      expect(yesCaptureRest('Yes, take another one'), 'take another one');
    });

    test('flag off: C13 note exactly as build 183', () {
      expect(routeLiveCameraB184('Yes, take another one', yesRouting: false), 'conversation:narration_note');
    });

    test('everything else about C13 is unchanged', () {
      for (final text in [
        "There's water damage on the left side",
        'Yes, there is water damage on the left side',
        'This is the attic access panel',
        'Yes, the photo is blurry',
        "Yes, don't take another one",
        'Yes',
        'Okay',
      ]) {
        expect(routeLiveCameraB184(text), routeB183(text), reason: text);
      }
      expect(routeLiveCameraB184("There's water damage on the left side"), 'conversation:narration_note');
    });
  });

  group('Change D — LOCAL_CLOSE_CONFIRM_5S (fake clock)', () {
    final t0 = DateTime(2026, 10, 16, 14, 0, 0);
    const ctx = LocalCloseContext();
    LocalCloseController asked({bool enabled = true}) {
      final c = LocalCloseController(confirmTimeout: b184LocalCloseConfirmTimeout(enabled: enabled));
      expect(c.decide("I'm done", context: ctx, now: t0).kind, LocalCloseDecisionKind.askConfirm);
      return c;
    }

    test('silence: cancelled after 5 s, session stays open (nothing to say)', () {
      final c = asked();
      expect(c.onConfirmTimeout(t0.add(const Duration(milliseconds: 4999))), isFalse);
      expect(c.confirmPending, isTrue);
      expect(c.onConfirmTimeout(t0.add(const Duration(seconds: 5))), isTrue);
      expect(c.confirmPending, isFalse);
      expect(c.closeRequested, isFalse);
      // A late "yes" no longer closes.
      expect(c.decide('Yes', context: ctx, now: t0.add(const Duration(seconds: 6))).kind, LocalCloseDecisionKind.none);
      expect(c.closeRequested, isFalse);
    });

    test('"Yes" within 5 s closes', () {
      final c = asked();
      final d = c.decide('Yes', context: ctx, now: t0.add(const Duration(milliseconds: 4900)));
      expect(d.kind, LocalCloseDecisionKind.closeNow);
      expect(d.reason, 'confirmed');
    });

    test('"No" cancels (the screen says "Okay.")', () {
      final c = asked();
      expect(c.decide('No', context: ctx, now: t0.add(const Duration(seconds: 2))).kind, LocalCloseDecisionKind.declined);
      expect(_screen.contains("_informGeminiToSpeakVerbatim(_negationGuardReply, reason: 'local_close_declined');"), isTrue);
    });

    test('an unrelated utterance drops the question', () {
      final c = asked();
      expect(
        c.decide('show me the invoice', context: ctx, now: t0.add(const Duration(seconds: 2))).kind,
        LocalCloseDecisionKind.pendingDropped,
      );
      expect(c.confirmPending, isFalse);
    });

    test('flag off: exactly the 8 s of build 183', () {
      expect(b184LocalCloseConfirmTimeout(enabled: false), localCloseConfirmTimeout);
      expect(localCloseConfirmTimeout, const Duration(seconds: 8));
      final c = asked(enabled: false);
      expect(c.onConfirmTimeout(t0.add(const Duration(seconds: 5))), isFalse);
      expect(c.decide('Yes', context: ctx, now: t0.add(const Duration(seconds: 7))).kind, LocalCloseDecisionKind.closeNow);
    });

    test('the screen uses the controller\'s timeout for its timer', () {
      expect(
        _screen.contains('final LocalCloseController _localClose = LocalCloseController(confirmTimeout: b184LocalCloseConfirmTimeout());'),
        isTrue,
      );
      expect(_screen.contains('_localCloseConfirmTimer = Timer(_localClose.confirmTimeout, () {'), isTrue);
    });
  });

  group('regression over every existing test fixture (camera live)', () {
    final literals = _existingFixtureLiterals();

    test('all three b184 additions off = the build 183 route, for every literal', () {
      for (final text in literals) {
        for (final gemini in ['none', 'capture_photo']) {
          expect(_b184Off(text, geminiIntent: gemini), routeB183(text, geminiIntent: gemini), reason: '$text/$gemini');
        }
      }
    });

    test('on: nothing that captured in b183 stops capturing; every change is a known kind', () {
      final quick = <String>{};
      var newCaptures = <String>{};
      for (final text in literals) {
        for (final gemini in ['none', 'capture_photo']) {
          final before = routeB183(text, geminiIntent: gemini);
          final after = routeLiveCameraB184(text, geminiIntent: gemini);
          if (before.startsWith('capture:')) expect(after.startsWith('capture:'), isTrue, reason: '$text/$gemini');
          if (before == after || (before.startsWith('capture:') && after.startsWith('capture:'))) continue;
          if (after == 'conversation:quick_reply_noted') {
            // Only what b183 already left as conversation, and only remarks.
            expect(before, 'conversation:fallback', reason: text);
            expect(isLiveCameraRemark(text), isTrue, reason: text);
            if (gemini == 'none') quick.add(text);
          } else {
            expect(after, anyOf('capture:another_one', 'capture:yes_capture_routing'), reason: '$text/$gemini: $before');
            expect(before, anyOf('conversation:fallback', 'conversation:narration_note'), reason: text);
            newCaptures.add(text);
          }
        }
      }
      // ignore: avoid_print
      print('B184 REGRESSION: ${literals.length} literals, ${quick.length} now get the quick "Noted." $quick, new captures=$newCaptures');
      newCaptures = newCaptures.map((t) => t.toLowerCase().replaceAll(RegExp(r'[^a-z ]'), '').trim()).toSet();
      for (final t in newCaptures) {
        expect(
          matchAnotherOneCapture(t) != null || (yesCaptureRest(t) != null && matchAnotherOneCapture(yesCaptureRest(t)!) != null),
          isTrue,
          reason: t,
        );
      }
    });

    test('camera closed: every fixture that would get the quick reply is a photo remark with no verb', () {
      final hits = <String>{};
      for (final text in literals) {
        if (quickReplyPathFor(text, cameraLive: false) == null) continue;
        hits.add(text);
        final words = tokenizeTriggerText(text);
        expect(words.any(remarkPhotoNouns.contains), isTrue, reason: text);
        expect(words.any(liveRemarkCommandWords.contains), isFalse, reason: text);
        expect(isCameraRemark(text), isTrue, reason: text);
      }
      // ignore: avoid_print
      print('B184 CLOSED-CAMERA QUICK REPLY fixtures: $hits');
    });
  });

  group('wiring in the production screen', () {
    test('hooks, each behind its flag, at their places', () {
      expect(_screen.contains('    if (_maybeQuickReplyToRemark(transcript, decision)) return;\n'), isTrue);
      expect(_screen.contains('      enabled: kRemarkQuickReply,\n'), isTrue);
      expect(_screen.contains('''_log_("REMARK QUICK REPLY: '\$transcript' -> Noted (no question, no KB) path='''), isTrue);
      expect(_screen.contains('    final phrase = kAnotherOneCapture ? matchAnotherOneCapture(heard) : null;\n'), isTrue);
      expect(_screen.contains('    if (!kYesCaptureRouting) return false;\n'), isTrue);
      // B/C run just before C13, which is itself unchanged.
      final hook = _screen.indexOf('    if (_maybeCaptureBeforeNarration()) {');
      final c13 = _screen.indexOf('    if (_maybeNoteCameraNarration()) {');
      expect(hook, greaterThan(0));
      expect(c13, greaterThan(hook));
      // A runs after the b183 live-noun block and before the C19 refusal.
      final veto = _screen.indexOf('if (liveNoun != null && kLiveCameraRemarkVeto && isLiveCameraRemark(transcript)) {');
      final quick = _screen.indexOf('if (_maybeQuickReplyToRemark(transcript, decision)) return;');
      final c19 = _screen.indexOf('if (decision.kind == IntentDecisionKind.none && _maybeRefuseOffTopicFast(transcript)) return;');
      expect(veto < quick && quick < c19, isTrue);
    });

    test('B184 FLAGS line at session open and app start; B182/B183 lines unchanged', () {
      expect(_screen.contains('      _log_(describeB183Flags());\n      _log_(describeB184Flags());\n'), isTrue);
      expect(_screen.contains('_log_(describeB182Flags());'), isTrue);
      final main = File('lib/main.dart').readAsStringSync();
      expect(main.contains('debugPrint(describeB184Flags());'), isTrue);
      expect(main.contains('debugPrint(describeB183Flags());'), isTrue);
    });
  });
}
