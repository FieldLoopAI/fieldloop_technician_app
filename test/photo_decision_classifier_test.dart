import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/photo_decision_classifier.dart';

/// P0 regression suite for the keep/retake fork (see
/// [classifyPhotoDecision]'s doc comment) — this is the highest-stakes
/// decision in the whole voice-camera flow: a wrong guess either uploads
/// unwanted content or discards wanted content. Every case here was either
/// the ACTUAL bug ("No, this image didn't looks good. Re-take." wrongly
/// firing confirm_photo_upload — see flutter_run_log_new.txt, build #59)
/// or a paired positive/negative case specified alongside that fix, so a
/// future change to this function that breaks any of these must fail loud
/// here before it ever reaches a real device.
void main() {
  group('classifyPhotoDecision', () {
    test('the actual P0 bug: negated confirm cue + hyphen-split retake cue -> retake', () {
      expect(
        classifyPhotoDecision("No, this image didn't looks good. Re-take."),
        PhotoDecision.retake,
      );
    });

    test('negated confirm phrase inverts to retake evidence', () {
      expect(classifyPhotoDecision('no keep it'), PhotoDecision.retake);
    });

    test('genuine conflicting cues with no negation to resolve them -> ambiguous', () {
      expect(classifyPhotoDecision('yes retake'), PhotoDecision.ambiguous);
    });

    test('negated retake cue inverts to confirm evidence', () {
      expect(classifyPhotoDecision("it's fine, don't retake"), PhotoDecision.confirm);
    });

    test('negated confirm cue plus an explicit unnegated retake cue -> retake (not ambiguous)', () {
      expect(
        classifyPhotoDecision("this doesn't look good, take another"),
        PhotoDecision.retake,
      );
    });

    test('unnegated confirm phrase, no retake cue -> confirm (baseline, already worked)', () {
      expect(classifyPhotoDecision('looks good, keep it'), PhotoDecision.confirm);
    });

    test('nothing matches either side -> none', () {
      expect(classifyPhotoDecision('what time is it'), PhotoDecision.none);
    });

    test('plain "retake" -> retake', () {
      expect(classifyPhotoDecision('retake'), PhotoDecision.retake);
    });

    test('plain "keep it" -> confirm', () {
      expect(classifyPhotoDecision('keep it'), PhotoDecision.confirm);
    });

    test('descriptive photo-quality complaint reads as an implicit retake', () {
      expect(classifyPhotoDecision('this photo is very blur'), PhotoDecision.retake);
    });

    test('"take another" (photo noun + take) reads as retake even without an explicit retake word', () {
      expect(classifyPhotoDecision('take another one'), PhotoDecision.retake);
    });

    test('empty transcript -> none', () {
      expect(classifyPhotoDecision(''), PhotoDecision.none);
    });
  });

  group('classifyStrictBareWordPhotoDecision', () {
    test('bare "keep" -> confirm', () {
      expect(classifyStrictBareWordPhotoDecision('keep'), PhotoDecision.confirm);
    });

    test('bare "retake" -> retake', () {
      expect(classifyStrictBareWordPhotoDecision('retake'), PhotoDecision.retake);
    });

    test('bare "confirm" -> confirm', () {
      expect(classifyStrictBareWordPhotoDecision('confirm'), PhotoDecision.confirm);
    });

    test('trivial filler around the bare word still resolves', () {
      expect(classifyStrictBareWordPhotoDecision('okay keep please'), PhotoDecision.confirm);
    });

    // The exact P0 loop this exists to break: Gemini's own echoed
    // clarification question must NOT satisfy the strict check, even
    // though it contains both bare words literally.
    test('the original ambiguous question, echoed back, does NOT resolve', () {
      expect(
        classifyStrictBareWordPhotoDecision('Keep it or retake it?'),
        PhotoDecision.none,
      );
    });

    // The escalated strict prompt itself, echoed back, must also not
    // resolve — otherwise the loop just recurs one level up.
    test('the escalated strict prompt, echoed back, does NOT resolve', () {
      expect(
        classifyStrictBareWordPhotoDecision(
          "I keep hearing both. Please say ONLY the word keep, or ONLY the word retake — nothing else.",
        ),
        PhotoDecision.none,
      );
    });

    test('unrelated speech -> none', () {
      expect(classifyStrictBareWordPhotoDecision('what time is it'), PhotoDecision.none);
    });

    test('empty transcript -> none', () {
      expect(classifyStrictBareWordPhotoDecision(''), PhotoDecision.none);
    });
  });

  group('classifyPhotoDecision P0 fuzzy-matching fix (real garbled STT)', () {
    // The actual reported bug: "or re-ticket." logged as "no confirm/retake
    // match" — a real ASR mishearing of "retake it" that no general
    // edit-distance pass can bridge (see the explicit 're ticket' phrase
    // entry's own doc comment).
    test('"or re-ticket." resolves to retake', () {
      expect(classifyPhotoDecision('or re-ticket.'), PhotoDecision.retake);
    });

    test('"re-ticket" alone resolves to retake', () {
      expect(classifyPhotoDecision('re-ticket'), PhotoDecision.retake);
    });

    // Word-form drift via the new trigger_phrase_matcher.dart pass —
    // "retaking" never appears in any phrase list, but stems to "retake".
    test('word-form drift: "I think I am retaking that" resolves to retake', () {
      expect(classifyPhotoDecision('I think I am retaking that'), PhotoDecision.retake);
    });

    test('word-form drift: "yeah confirmed" resolves to confirm', () {
      expect(classifyPhotoDecision('yeah confirmed'), PhotoDecision.confirm);
    });

    // One filler word inserted MID-PHRASE (not merely around it, which the
    // original literal pass already tolerated via plain substring
    // containment) — genuinely exercises the new trigger_phrase_matcher.dart
    // gap-tolerance: "take another one" with "good" inserted between
    // "another" and "one".
    test('one filler word inserted mid-phrase still resolves to retake', () {
      expect(classifyPhotoDecision('okay take another please one'), PhotoDecision.retake);
    });

    // Negation must still correctly invert — the new fuzzy pass is
    // additive-only and never overrides the literal pass's negation
    // handling.
    test('negation still inverts a fuzzy-adjacent phrase: "no, do not keep it" -> retake', () {
      expect(classifyPhotoDecision('no, do not keep it'), PhotoDecision.retake);
    });

    test('negated retake cue still inverts to confirm: "don\'t retake it, it\'s fine" -> confirm', () {
      expect(classifyPhotoDecision("don't retake it, it's fine"), PhotoDecision.confirm);
    });

    // Genuine conflicting un-negated evidence must still read as ambiguous,
    // not be tipped one way by the new additive pass.
    test('genuine conflict still reads as ambiguous with the new pass active', () {
      expect(classifyPhotoDecision('yes retake'), PhotoDecision.ambiguous);
    });

    // "ticket" alone (no "re" prefix) must NOT match — the explicit phrase
    // is the two-token "re ticket", not a bare fuzzy word, so unrelated
    // speech mentioning a ticket some other way doesn't misfire.
    test('"ticket" without "re" does not fire retake', () {
      expect(classifyPhotoDecision('close out the ticket'), PhotoDecision.none);
    });
  });

  group('P0 natural-affirmation vocabulary (CONFIRMED real session)', () {
    // The report's own evidence: NEITHER of these actually failed because
    // of a vocabulary gap in classifyPhotoDecision itself — both already
    // resolve correctly under NORMAL (non-escalated) matching, confirming
    // the real root cause was a stuck ambiguous-streak escalation in
    // gemini_live_test_screen.dart (fixed there, not testable at this
    // unit level). Verified here anyway, since it's exactly what a
    // regression in this classifier would look like if the streak fix
    // were ever undone.
    test('"This looks good." resolves to confirm', () {
      expect(classifyPhotoDecision('This looks good.'), PhotoDecision.confirm);
    });

    test('a bare "keep" inside real STT garble still resolves to confirm', () {
      // "Keep this for rock." — the actual garbled transcript from the
      // confirmed session (a mishearing of some bare "keep" phrasing).
      expect(classifyPhotoDecision('Keep this for rock.'), PhotoDecision.confirm);
    });

    test('every newly-added natural affirmation resolves to confirm', () {
      for (final phrase in ['looks great', 'that ll do', 'good one', 'keep this one']) {
        expect(classifyPhotoDecision(phrase), PhotoDecision.confirm, reason: '"$phrase" should resolve to confirm');
      }
    });

    test('"keep this one" and "keep that one" both resolve (determiner parity)', () {
      expect(classifyPhotoDecision('keep this one'), PhotoDecision.confirm);
      expect(classifyPhotoDecision('keep that one'), PhotoDecision.confirm);
    });

    test('negation still inverts the new phrases', () {
      expect(classifyPhotoDecision("no, that won't do"), PhotoDecision.retake);
    });
  });
}
