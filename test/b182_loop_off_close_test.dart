// Build 182 item C — "loop off" (and ASR's "loop of" / "field look off")
// closes the session through the existing local-close tiers. Offline.
import 'package:fielloop/services/b182_flags.dart';
import 'package:fielloop/services/local_close_command.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime(2026, 10, 15, 12);

LocalCloseDecision _decide(String text, {LocalCloseContext context = const LocalCloseContext(), bool loopOff = true}) =>
    LocalCloseController(loopOffClose: loopOff).decide(text, context: context, now: _t0);

void main() {
  test('flag defaults ON', () => expect(kLoopOffClose, isTrue));

  group('new EXPLICIT phrases close immediately', () {
    for (final text in [
      'loop off', 'Loop off.', 'Field loop off', 'FieldLoop off!', 'field look off', 'Field look, off.',
      'Okay, loop off.', 'Um, field look off please',
    ]) {
      test(text, () {
        final d = _decide(text);
        expect(d.kind, LocalCloseDecisionKind.closeNow, reason: text);
        expect(d.tier, LocalCloseTier.explicit);
      });
    }
  });

  group('new SOFT phrases ask "Do you want me to close the session?" first', () {
    for (final text in ['loop of', 'Loop of.', 'field loop of', 'Field look of.', 'Okay, loop of']) {
      test(text, () {
        final d = _decide(text);
        expect(d.kind, LocalCloseDecisionKind.askConfirm, reason: text);
        expect(d.tier, LocalCloseTier.soft);
      });
    }

    test('"loop of" then "yes" closes; "no" keeps it open', () {
      final c = LocalCloseController();
      expect(c.decide('Loop of.', context: const LocalCloseContext(), now: _t0).kind, LocalCloseDecisionKind.askConfirm);
      expect(
        c.decide('Yes.', context: const LocalCloseContext(), now: _t0.add(const Duration(seconds: 2))).kind,
        LocalCloseDecisionKind.closeNow,
      );
      final c2 = LocalCloseController();
      c2.decide('loop of', context: const LocalCloseContext(), now: _t0);
      expect(
        c2.decide('No.', context: const LocalCloseContext(), now: _t0.add(const Duration(seconds: 2))).kind,
        LocalCloseDecisionKind.declined,
      );
    });

    test('the confirm and closing lines are the existing ones', () {
      expect(localCloseConfirmQuestion, 'Do you want me to close the session?');
      expect(localCloseClosingLine, 'Okay, closing the session.');
    });
  });

  group('never closes', () {
    for (final text in [
      'loop of wire',
      'the loop of the cable',
      'Grab that loop of wire for me',
      'a loop of',
      'loop off the pipe and the valve and the tank',
    ]) {
      test('"$text" -> not a close', () {
        final d = _decide(text);
        expect(d.kind, isNot(anyOf(LocalCloseDecisionKind.closeNow, LocalCloseDecisionKind.askConfirm)), reason: text);
      });
    }
    test('"the loop of the cable" is not even a close phrase (no too_long log)', () {
      expect(matchLocalClose('the loop of the cable'), isNull);
      expect(matchLocalClose('loop of wire'), isNull);
    });

    for (final text in ["Don't loop off.", 'Do not loop off', "don't loop of", 'Do not field look off']) {
      test('negation: "$text" -> blocked', () {
        final d = _decide(text);
        expect(d.kind, LocalCloseDecisionKind.blocked, reason: text);
        expect(d.reason, 'negation');
      });
    }

    for (final text in ['loop off', 'loop of', 'field look off']) {
      test('camera_live: "$text" -> blocked', () {
        final d = _decide(text, context: const LocalCloseContext(cameraActive: true));
        expect(d.kind, LocalCloseDecisionKind.blocked);
        expect(d.reason, 'camera_live');
      });
      test('photo_note: "$text" -> blocked', () {
        final d = _decide(text, context: const LocalCloseContext(photoNoteActive: true));
        expect(d.kind, LocalCloseDecisionKind.blocked);
        expect(d.reason, 'photo_note');
      });
    }

    test('too_long still applies (over 6 words)', () {
      final r = matchLocalClose('loop off loop off loop off loop off');
      expect(r, isA<LocalCloseBlocked>());
      expect((r! as LocalCloseBlocked).reason, 'too_long');
    });
  });

  group('flag off = build 181 behavior', () {
    test('"loop of" / "field look off" match nothing', () {
      expect(_decide('loop of', loopOff: false).kind, LocalCloseDecisionKind.none);
      expect(_decide('field look off', loopOff: false).kind, LocalCloseDecisionKind.none);
      expect(matchLocalClose('field look of', loopOff: false), isNull);
    });
    test('"loop off" was already explicit before build 182 and still is', () {
      expect(_decide('loop off', loopOff: false).kind, LocalCloseDecisionKind.closeNow);
      expect(_decide('field loop off', loopOff: false).kind, LocalCloseDecisionKind.closeNow);
    });
  });

  test('existing phrase lists are unchanged', () {
    expect(localCloseExplicitPhrases.length, 18);
    expect(localCloseSoftPhrases.length, 12);
    expect(loopOffExplicitPhrases, ['loop off', 'field loop off', 'fieldloop off', 'field look off']);
    expect(loopOffSoftPhrases, ['loop of', 'field loop of', 'field look of']);
  });
}
