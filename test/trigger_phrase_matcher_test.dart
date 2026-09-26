import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/trigger_phrase_matcher.dart';

/// P0 regression suite for deterministic trigger phrase matching — see
/// `trigger_phrase_matcher.dart`'s own doc comment for the confirmed bug
/// this covers ("All right, taking the picture may." matching nothing at
/// all, so the technician's real capture command silently did nothing).
///
/// Two things are being defended here at once, and they pull in opposite
/// directions, so both sides are tested explicitly:
///  1. Real, slightly-imperfect ASR output must still resolve (word-form
///     drift, leading acknowledgments, trailing noise, one inserted word).
///  2. Every distinction a PRIOR confirmed regression fix depends on must
///     survive the loosening — articles (open_camera vs. capture_photo),
///     negation ("no, don't take it"), and scope words ("last photo").

/// The real phrase lists these triggers use in
/// `gemini_live_test_screen.dart`, copied here so the tests exercise the
/// actual production strings rather than toy inputs. Kept to the entries
/// these cases touch.
const _openCameraPhrases = [
  'take a photo',
  'take a picture',
  'take a pic',
  'lets take the image',
  'lets take a picture',
  'lets take a photo',
  'capture this',
  'snap a photo',
  'get a picture',
  'get a photo',
  'open the camera',
  'open camera',
  'turn on the camera',
  'start the camera',
];

const _capturePhotoPhrases = [
  'take it',
  'capture it',
  'snap it',
  'take the photo',
  'take photo',
  'capture the photo',
  'take the picture',
  'take picture',
  'capture the picture',
  'snap the picture',
  'confirm',
  'keep it',
  'upload it',
];

void main() {
  group('the actual P0 bug', () {
    test('"All right, taking the picture may." resolves capture_photo', () {
      final match = matchAnyTriggerPhrase('All right, taking the picture may.', _capturePhotoPhrases);
      expect(match, isNotNull);
      expect(match!.phrase, 'take the picture');
      expect(match.exact, isFalse, reason: 'this is the fuzzy path — the old literal substring check missed it');
    });
  });

  group('realistic ASR drift still resolves', () {
    test('verb form drift: "taking a photo" -> open_camera', () {
      expect(matchAnyTriggerPhrase('so I am taking a photo now', _openCameraPhrases)?.phrase, 'take a photo');
    });

    test('plural drift: "take a pictures" -> open_camera', () {
      expect(matchAnyTriggerPhrase('lets take a pictures', _openCameraPhrases)?.phrase, 'take a picture');
    });

    test('one inserted filler word: "open up the camera" -> open_camera', () {
      final match = matchAnyTriggerPhrase('can you open up the camera', _openCameraPhrases);
      expect(match?.phrase, 'open the camera');
      expect(match?.gapWords, 1);
    });

    test('trailing noise only: "capture it uh" -> capture_photo', () {
      expect(matchAnyTriggerPhrase('capture it uh', _capturePhotoPhrases)?.phrase, 'capture it');
    });

    test('leading acknowledgment: "Okay yeah, snap the picture." -> capture_photo', () {
      expect(matchAnyTriggerPhrase('Okay yeah, snap the picture.', _capturePhotoPhrases)?.phrase, 'snap the picture');
    });

    test('single-character garble in a long content word: "turn on the camara"', () {
      expect(matchAnyTriggerPhrase('turn on the camara', _openCameraPhrases)?.phrase, 'turn on the camera');
    });

    test('past-tense drift: "captured it" -> capture_photo', () {
      expect(matchAnyTriggerPhrase('captured it', _capturePhotoPhrases)?.phrase, 'capture it');
    });

    test('apostrophe-split possessive still matches: "let\'s take the image"', () {
      expect(matchAnyTriggerPhrase("let's take the image", _openCameraPhrases)?.phrase, 'lets take the image');
    });
  });

  group('negation still vetoes (keep-vs-retake safety preserved)', () {
    test('"no, don\'t take it" does NOT fire capture_photo', () {
      expect(matchAnyTriggerPhrase("no, don't take it", _capturePhotoPhrases), isNull);
    });

    test('"don\'t take the picture" does NOT fire capture_photo', () {
      expect(matchAnyTriggerPhrase("don't take the picture", _capturePhotoPhrases), isNull);
    });

    test('"I can\'t confirm" does NOT fire capture_photo', () {
      expect(matchAnyTriggerPhrase("I can't confirm", _capturePhotoPhrases), isNull);
    });

    test('"not yet, keep it open" does NOT fire on the negated keep cue', () {
      expect(matchAnyTriggerPhrase('not keep it', _capturePhotoPhrases), isNull);
    });

    test('"don\'t open the camera" does NOT fire open_camera', () {
      expect(matchAnyTriggerPhrase("don't open the camera", _openCameraPhrases), isNull);
    });

    test('a negation elsewhere in the sentence does NOT veto an un-negated cue', () {
      // "no problem" is not negating the command that follows it.
      expect(matchAnyTriggerPhrase('no problem, take the picture', _capturePhotoPhrases)?.phrase, 'take the picture');
    });

    test('triggerPhraseIsNegated reports a negated occurrence', () {
      expect(triggerPhraseIsNegated("no, don't take it", 'take it'), isTrue);
      expect(triggerPhraseIsNegated('take it', 'take it'), isFalse);
      expect(triggerPhraseIsNegated('nothing relevant here', 'take it'), isFalse);
    });
  });

  group('load-bearing distinctions survive the loosening', () {
    test('the indefinite article is never skipped: "let\'s take a photo" does NOT match "take photo"', () {
      // CONFIRMED accidental-capture regression (3ebd9995-flutter_run_log.txt):
      // restating the open-camera request while the camera is already open
      // must never fire a real shutter.
      expect(matchTriggerPhrase("let's take a photo", 'take photo'), isNull);
      expect(matchTriggerPhrase("let's take a photo", 'take the photo'), isNull);
    });

    test('"take a picture" does NOT match capture_photo\'s "take picture"', () {
      expect(matchTriggerPhrase('take a picture', 'take picture'), isNull);
    });

    test('"the" and "a" never fuzzy-match each other', () {
      expect(matchTriggerPhrase('get the photo', 'get a photo'), isNull);
    });

    test('scope words are never skipped as filler', () {
      expect(matchTriggerPhrase('take another picture', 'take picture'), isNull);
      expect(matchTriggerPhrase('show me the last photo', 'show me the photo'), isNull);
    });

    test('at most one filler word is skipped', () {
      expect(matchTriggerPhrase('open it up right now the camera', 'open the camera'), isNull);
    });

    test('word order is load-bearing — a bag of words does not match', () {
      expect(matchTriggerPhrase('the camera, can you open', 'open the camera'), isNull);
    });

    test('short function words never fuzzy-match by edit distance', () {
      // 'it' vs 'is', 'on' vs 'of' etc. must stay distinct.
      expect(matchTriggerPhrase('take is', 'take it'), isNull);
    });
  });

  group('stemmer', () {
    test('verb forms converge', () {
      expect(stemTriggerWord('taking'), stemTriggerWord('take'));
      expect(stemTriggerWord('takes'), stemTriggerWord('take'));
      expect(stemTriggerWord('captured'), stemTriggerWord('capture'));
      expect(stemTriggerWord('capturing'), stemTriggerWord('capture'));
      expect(stemTriggerWord('snapping'), stemTriggerWord('snap'));
      expect(stemTriggerWord('opening'), stemTriggerWord('open'));
      expect(stemTriggerWord('going'), stemTriggerWord('go'));
    });

    test('noun plurals converge', () {
      expect(stemTriggerWord('pictures'), stemTriggerWord('picture'));
      expect(stemTriggerWord('photos'), stemTriggerWord('photo'));
      expect(stemTriggerWord('cameras'), stemTriggerWord('camera'));
      expect(stemTriggerWord('invoices'), stemTriggerWord('invoice'));
    });

    test('short function words are left completely untouched', () {
      for (final w in ['a', 'an', 'the', 'it', 'no', 'not', 'is', 'go', 'me']) {
        expect(stemTriggerWord(w), w, reason: '"$w" must stem to itself');
      }
    });

    test('distinct function words do not collide', () {
      expect(stemTriggerWord('a'), isNot(stemTriggerWord('the')));
      expect(stemTriggerWord('photo'), isNot(stemTriggerWord('picture')));
      expect(stemTriggerWord('last'), isNot(stemTriggerWord('latest')));
    });

    test('irregular PAST tenses deliberately do NOT converge', () {
      // See [_irregularStems]'s doc comment: "I took the picture yesterday"
      // describes, it does not command — and `_looksLikeIntentionalGoBack`
      // documents that "gone" must never match "go".
      expect(stemTriggerWord('took'), isNot(stemTriggerWord('take')));
      expect(stemTriggerWord('gone'), isNot(stemTriggerWord('go')));
      expect(stemTriggerWord('went'), isNot(stemTriggerWord('go')));
      expect(stemTriggerWord('seen'), isNot(stemTriggerWord('see')));
    });

    test('progressive forms with short roots still converge', () {
      expect(stemTriggerWord('going'), stemTriggerWord('go'));
      expect(stemTriggerWord('seeing'), stemTriggerWord('see'));
    });

    test('stemmedPaddedTriggerText keeps the padded shape extraMatchers expect', () {
      expect(stemmedPaddedTriggerText("let's take a photo"), ' let s tak a photo ');
      expect(stemTriggerPhrase('take a photo'), 'tak a photo');
    });
  });
}
