import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/completion_claim_detector.dart';

/// P0 regression suite for the "Gemini said it happened when it didn't"
/// trust bug — see `completion_claim_detector.dart`'s doc comment for the
/// confirmed session this comes from.
///
/// Both directions matter and pull against each other, so both are tested:
///  1. Every confirmed false claim must be DETECTED. A missed one is a
///     technician leaving a site believing a photo exists.
///  2. Honest speech must NOT be detected. A safety check that cries wolf
///     on correct behavior is a safety check that gets switched off — and
///     every false positive here costs the technician a spoken "sorry, I
///     misspoke" over a sentence that was fine.
void main() {
  group('the actual P0 claims from the confirmed session', () {
    test('"It\'s captured." is a capture_photo claim', () {
      expect(completionClaimFunctionIn("It's captured."), 'capture_photo');
    });

    test('"Both taken. Anything else you need help with?" is a capture_photo claim', () {
      expect(
        completionClaimFunctionIn('Both taken. Anything else you need help with?'),
        'capture_photo',
      );
    });
  });

  group('other completed-action claims are detected', () {
    test('capture wording', () {
      expect(completionClaimFunctionIn('Got it, snapped.'), 'capture_photo');
      expect(completionClaimFunctionIn('I took the picture for you.'), 'capture_photo');
      expect(completionClaimFunctionIn('Nice, got the shot.'), 'capture_photo');
    });

    test('upload wording', () {
      expect(completionClaimFunctionIn("I've uploaded it."), 'confirm_photo_upload');
      expect(completionClaimFunctionIn('Great, saved the photo to the job.'), 'confirm_photo_upload');
      expect(completionClaimFunctionIn('I attached the picture.'), 'confirm_photo_upload');
    });

    test('retake wording', () {
      expect(completionClaimFunctionIn('Okay, discarded.'), 'retake_photo');
      expect(completionClaimFunctionIn("That one's retaken."), 'retake_photo');
    });

    test('a claim buried mid-sentence is still detected', () {
      expect(
        completionClaimFunctionIn("Alright, that's captured and we can move on to the next room."),
        'capture_photo',
      );
    });
  });

  group('honest speech is NOT flagged', () {
    test('denials', () {
      expect(completionClaimFunctionIn("No photo has been taken yet."), isNull);
      expect(completionClaimFunctionIn("That hasn't been uploaded."), isNull);
      expect(completionClaimFunctionIn("Nothing has been captured so far."), isNull);
      expect(completionClaimFunctionIn("I haven't taken it."), isNull);
    });

    test('offers and questions', () {
      expect(completionClaimFunctionIn('Would you like the photo taken now?'), isNull);
      expect(completionClaimFunctionIn('Do you want it uploaded?'), isNull);
      expect(completionClaimFunctionIn("I'll get it uploaded once you're happy with it."), isNull);
      expect(completionClaimFunctionIn('Say the word and it can be captured.'), isNull);
    });

    test('present and future tense — explicitly still allowed by the system instruction', () {
      expect(completionClaimFunctionIn("Opening the camera now."), isNull);
      expect(completionClaimFunctionIn("I'll capture it as soon as you're ready."), isNull);
      expect(completionClaimFunctionIn('Ready to capture whenever you are.'), isNull);
      expect(completionClaimFunctionIn('Uploading that for you.'), isNull);
    });

    test('the "taken care of" idiom', () {
      expect(completionClaimFunctionIn("I'll get that taken care of."), isNull);
    });

    test('ordinary conversation with no photo vocabulary at all', () {
      expect(completionClaimFunctionIn('The job is at 14 Mill Street for Dana Reyes.'), isNull);
      expect(completionClaimFunctionIn('Anything else on this job?'), isNull);
      expect(completionClaimFunctionIn(''), isNull);
    });

    test('the correction line itself can never re-trip the audit', () {
      // Guards against a future edit reintroducing a correction loop — see
      // `_photoCompletionClaimCorrectionText` in gemini_live_test_screen.dart.
      const correction =
          "Sorry, I misspoke — that hasn't actually happened yet. Tell me when you're ready and I'll do it.";
      expect(completionClaimFunctionIn(correction), isNull);
    });
  });

  group('P0 determiner-variation fix (CONFIRMED real session)', () {
    test('the actual missed claim: "Got it. I\'ve saved that photo for this job." is caught', () {
      expect(
        completionClaimFunctionIn("Got it. I've saved that photo for this job."),
        'confirm_photo_upload',
      );
    });

    test('every natural determiner variant of a save/attach/upload claim is caught', () {
      for (final phrase in [
        'saved that photo',
        'saved this photo',
        'saved that picture',
        'saved this picture',
        'saved that one',
        'saved this one',
        'attached that photo',
        'attached this photo',
        'uploaded that',
        'uploaded that photo',
      ]) {
        expect(completionClaimFunctionIn('Got it, $phrase.'), 'confirm_photo_upload', reason: '"$phrase" should be caught');
      }
    });

    test('an honest denial with the new determiner variants is still NOT flagged', () {
      expect(completionClaimFunctionIn("No, I haven't saved that photo yet."), isNull);
      expect(completionClaimFunctionIn("I'm about to get it uploaded."), isNull);
    });
  });

  group('claims map to the RIGHT function', () {
    test('an upload claim never reads as a capture claim', () {
      expect(completionClaimFunctionIn('Uploaded.'), 'confirm_photo_upload');
    });

    test('every phrase in the map is detected under its own key', () {
      photoCompletionClaimPhrases.forEach((function, phrases) {
        for (final phrase in phrases) {
          expect(
            completionClaimFunctionIn('Okay. $phrase.'),
            function,
            reason: '"$phrase" should map to $function',
          );
        }
      });
    });
  });

  group('open_camera claims (camera said open before the native open returned)', () {
    test('the confirmed premature claim is detected', () {
      expect(completionClaimFunctionIn("Camera's open — ready when you are."), 'open_camera');
    });
    test('other completed-open wording is detected', () {
      for (final s in ['The camera is open now.', "Okay, I've opened the camera.", "Camera's ready."]) {
        expect(completionClaimFunctionIn(s), 'open_camera', reason: s);
      }
    });
    test('in-progress and future wording is not a claim', () {
      for (final s in [
        'Just a moment, opening the camera.',
        "The camera's still opening — give it a moment.",
        "Sorry — the camera's still opening, give it a moment.",
        "Once the camera's open, say capture it.",
        "I'll open the camera for you.",
        "The camera isn't open yet.",
      ]) {
        expect(completionClaimFunctionIn(s), isNull, reason: s);
      }
    });
  });
}
