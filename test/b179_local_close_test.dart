// Build 179 item B — local close commands: phrases, the whole-utterance
// rule, the yes/no confirm flow, every guard, and duplicates. Offline.
import 'dart:io';

import 'package:fielloop/services/continuation_answer.dart';
import 'package:fielloop/services/local_close_command.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime(2026, 10, 13, 12);
const _free = LocalCloseContext();

LocalCloseDecision _decide(LocalCloseController c, String text, {LocalCloseContext context = _free, int atMs = 0}) =>
    c.decide(text, context: context, now: _t0.add(Duration(milliseconds: atMs)));

void main() {
  test('flag defaults ON', () => expect(kLocalCloseCommands, isTrue));

  group('EXPLICIT phrases close immediately (no question)', () {
    const spoken = [
      'Close this session.',
      'Close the session.',
      'Close session',
      'End this session.',
      'End the session',
      'End session.',
      'Stop the session.',
      'Stop this session',
      'Stop listening.',
      'Loop off.',
      'FieldLoop stop.',
      'FieldLoop off',
      'Field loop stop',
      'Goodbye!',
      'Bye.',
      'Okay, close the session please.',
      'FieldLoop, close the session.',
    ];
    for (final text in spoken) {
      test(text, () {
        final d = _decide(LocalCloseController(), text);
        expect(d.kind, LocalCloseDecisionKind.closeNow);
        expect(d.tier, LocalCloseTier.explicit);
      });
    }
  });

  group('SOFT phrases ask once', () {
    const spoken = [
      'I am done.',
      "I'm done.",
      "We're done.",
      'We are done',
      "That's all.",
      'That is all',
      "That's it.",
      'That is it.',
      'Nothing else.',
      'All done.',
      "I'm finished.",
      "That's all for now.",
      "We're done here.",
      "Okay, I'm done, thanks.",
    ];
    for (final text in spoken) {
      test(text, () {
        final d = _decide(LocalCloseController(), text);
        expect(d.kind, LocalCloseDecisionKind.askConfirm);
        expect(d.tier, LocalCloseTier.soft);
      });
    }
    test('the question is the one short line', () {
      expect(localCloseConfirmQuestion, 'Do you want me to close the session?');
    });
  });

  group('confirm: yes closes, no keeps it open, 8 s silence = no', () {
    for (final yes in ['Yes.', 'Yeah', 'Yep.', 'Sure.', 'Close it.', 'Correct.', 'Please do.', 'Yes please.']) {
      test('yes: $yes', () {
        final c = LocalCloseController();
        expect(_decide(c, "I'm done").kind, LocalCloseDecisionKind.askConfirm);
        final d = _decide(c, yes, atMs: 2000);
        expect(d.kind, LocalCloseDecisionKind.closeNow);
        expect(d.reason, 'confirmed');
        expect(c.closeRequested, isTrue);
      });
    }
    for (final no in ['No.', 'Nope.', 'Not yet.', 'Keep going.', "Don't.", "No, don't close it."]) {
      test('no: $no', () {
        final c = LocalCloseController();
        _decide(c, "That's all.");
        expect(_decide(c, no, atMs: 2000).kind, LocalCloseDecisionKind.declined);
        expect(c.closeRequested, isFalse);
        expect(c.confirmPending, isFalse);
      });
    }
    test('timeout: no answer within 8 s -> stays open, a late "yes" does not close', () {
      final c = LocalCloseController();
      _decide(c, "I'm done");
      expect(c.onConfirmTimeout(_t0.add(const Duration(seconds: 7))), isFalse);
      expect(c.onConfirmTimeout(_t0.add(const Duration(seconds: 8))), isTrue);
      expect(c.confirmPending, isFalse);
      expect(_decide(c, 'Yes.', atMs: 9000).kind, LocalCloseDecisionKind.none);
      expect(c.closeRequested, isFalse);
    });
    test('a "yes" after 8 s even without the timer firing does not close', () {
      final c = LocalCloseController();
      _decide(c, "I'm done");
      expect(_decide(c, 'Yes.', atMs: 8500).kind, LocalCloseDecisionKind.none);
    });
    test('something else while asking -> question dropped, utterance routed normally', () {
      final c = LocalCloseController();
      _decide(c, "I'm done");
      expect(_decide(c, 'Show me the estimate.', atMs: 1000).kind, LocalCloseDecisionKind.pendingDropped);
      expect(c.confirmPending, isFalse);
    });
    test('an explicit close while asking closes', () {
      final c = LocalCloseController();
      _decide(c, "I'm done");
      expect(_decide(c, 'Close the session.', atMs: 1000).kind, LocalCloseDecisionKind.closeNow);
    });
  });

  group('guards: the existing handling wins', () {
    test('photo offer: "I am done" answering it is blocked, continuation still says "no"', () {
      final d = _decide(LocalCloseController(), 'I am done.', context: const LocalCloseContext(answersPhotoOffer: true));
      expect(d.kind, LocalCloseDecisionKind.blocked);
      expect(d.reason, 'photo_offer');
      expect(classifyContinuationAnswer('I am done.'), ContinuationAnswer.negative);
    });
    test('camera live (or any camera step)', () {
      for (final text in ["I'm done", 'Close the session']) {
        final d = _decide(LocalCloseController(), text, context: const LocalCloseContext(cameraActive: true));
        expect(d.kind, LocalCloseDecisionKind.blocked, reason: text);
        expect(d.reason, 'camera_live');
      }
    });
    test('photo note dictation: text is never a close command', () {
      for (final text in ["That's all.", 'Stop listening']) {
        final d = _decide(LocalCloseController(), text, context: const LocalCloseContext(photoNoteActive: true));
        expect(d.kind, LocalCloseDecisionKind.blocked, reason: text);
        expect(d.reason, 'photo_note');
      }
    });
    group('negation never closes', () {
      for (final text in [
        "Don't close the session.",
        'Do not close this session.',
        "I'm not done.",
        "I'm not done yet",
        'Never mind, do not end the session',
      ]) {
        test(text, () {
          final d = _decide(LocalCloseController(), text);
          expect(d.kind, LocalCloseDecisionKind.blocked);
          expect(d.reason, 'negation');
        });
      }
      test('"Do not stop." -> not a close at all', () {
        final d = _decide(LocalCloseController(), 'Do not stop.');
        expect(d.kind, isNot(LocalCloseDecisionKind.closeNow));
        expect(d.kind, isNot(LocalCloseDecisionKind.askConfirm));
      });
    });
    group('whole-utterance rule: a close phrase inside a longer sentence never closes', () {
      for (final text in [
        "I'm done taking photos of the kitchen.",
        "That's all the damage on the roof.",
        'Close the session after I take one more photo.',
        'We are done with the attic, now the garage.',
        'Stop listening to the customer.',
      ]) {
        test(text, () {
          final d = _decide(LocalCloseController(), text);
          expect(d.kind, LocalCloseDecisionKind.blocked);
          expect(d.reason, 'too_long');
        });
      }
      test('the rule: at most $localCloseMaxWords words after filler, phrase + optional short tail', () {
        expect(matchLocalClose("Um, okay, that's all for now, thanks"), isA<LocalCloseMatch>());
        expect(matchLocalClose("I'm done with photos"), isA<LocalCloseBlocked>());
      });
    });
    test('unrelated speech is not a close phrase', () {
      for (final text in ['Show me the estimate.', 'Take a photo.', 'Ready', 'Go back.', 'What is the address?']) {
        expect(matchLocalClose(text), isNull, reason: text);
      }
    });
  });

  group('duplicates', () {
    test('Gemini end_session after a local close is ignored', () {
      final c = LocalCloseController();
      _decide(c, 'Close the session.');
      expect(c.onGeminiEndSession(), isTrue);
    });
    test('Gemini end_session first -> a later local close is a no-op', () {
      final c = LocalCloseController();
      expect(c.onGeminiEndSession(), isFalse);
      final d = _decide(c, 'Close the session.', atMs: 500);
      expect(d.kind, LocalCloseDecisionKind.duplicate);
    });
    test('a second identical close utterance is a no-op', () {
      final c = LocalCloseController();
      _decide(c, 'Stop listening.');
      expect(_decide(c, 'Stop listening.', atMs: 300).kind, LocalCloseDecisionKind.duplicate);
    });
    test('"I\'m done" again while the question is pending does not ask twice', () {
      final c = LocalCloseController();
      _decide(c, "I'm done");
      final d = _decide(c, "I'm done", atMs: 1500);
      expect(d.kind, LocalCloseDecisionKind.duplicate);
      expect(d.reason, 'already_asking');
    });
    test('5 s repeat-block after a "no", then asks again', () {
      final c = LocalCloseController();
      _decide(c, "I'm done");
      _decide(c, 'No.', atMs: 1000);
      expect(_decide(c, "I'm done", atMs: 3000).kind, LocalCloseDecisionKind.duplicate);
      expect(_decide(c, "I'm done", atMs: 7000).kind, LocalCloseDecisionKind.askConfirm);
    });
  });

  group('source: wiring in the screen', () {
    final screen = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();
    test('per-chunk evaluator, first in the list', () {
      final mapAt = screen.indexOf('return <String, void Function()>{');
      expect(screen.indexOf("'local_close': () => _maybeHandleLocalClose(textChunk)", mapAt), greaterThan(mapAt));
      expect(
        screen.indexOf("'local_close'", mapAt),
        lessThan(screen.indexOf("'view_job_details': () =>", mapAt)),
      );
    });
    test('closes through the existing _stopTest (no second teardown)', () {
      expect(screen, contains("unawaited(_stopTest(reason: 'voice_close'));"));
      expect(screen, contains('localCloseReplyWaitCap'));
    });
    test('Gemini end_session duplicate is acknowledged, not acted on', () {
      expect(screen, contains('kLocalCloseCommands && _localClose.onGeminiEndSession()'));
    });
    test('timers are cancelled at teardown', () {
      final teardownAt = screen.indexOf('Future<void> _teardown() async {');
      final block = screen.substring(teardownAt, teardownAt + 3000);
      expect(block, contains('_localCloseConfirmTimer?.cancel();'));
      expect(block, contains('_localCloseReplyWaitTimer?.cancel();'));
    });
    test('log tags present', () {
      for (final tag in [
        'LOCAL CLOSE: matched tier=explicit',
        'LOCAL CLOSE: matched tier=soft',
        'LOCAL CLOSE: confirm asked',
        'LOCAL CLOSE: confirmed',
        'LOCAL CLOSE: declined',
        'LOCAL CLOSE: timeout',
        'LOCAL CLOSE: blocked reason=',
      ]) {
        expect(screen, contains(tag), reason: tag);
      }
    });
  });
}
