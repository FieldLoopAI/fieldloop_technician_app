import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/echo_sequence_matcher.dart';

/// P0 regression suite for the echo false-positive fix — see
/// `echo_sequence_matcher.dart`'s doc comment for the confirmed session
/// this comes from: a genuine "Take the photo." was discarded as echo
/// because "take"/"the"/"photo" each happened to appear somewhere near
/// each other across a long, session-spanning comparison pool.
///
/// The pool-bounding half of this fix (comparing only the current/last
/// turn, never the whole session) lives in `gemini_live_test_screen.dart`
/// and isn't independently testable here; this file covers the OTHER
/// half — the matching algorithm itself — proving it correctly rejects
/// coincidental vocabulary overlap while still catching genuine,
/// near-verbatim ASR-drifted echo.
List<String> _words(String text) =>
    text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

void main() {
  group('the actual P0 false positive', () {
    test('"take the photo" does NOT closely match an unrelated pool entry that merely contains those words', () {
      // Representative of what a long, unbounded blob used to look like —
      // "take"/"the"/"photo" each appear, but scattered across UNRELATED
      // phrasing, never clustered into anything resembling "take the
      // photo" itself. Even compared directly here (bypassing the
      // separate pool-bounding fix entirely), the SEQUENCE algorithm
      // alone must reject this.
      final pool = _words(
        "Camera's open, ready when you are. Once you're set, just let me know and I'll get it uploaded for "
        "you. This photo will show up right here so you can look it over, or you can go back and try again.",
      );
      expect(looksLikeCloseSequenceMatch(_words('take the photo'), pool), isFalse);
    });

    test('"I\'m ready when you are. Just tell me when to capture it." does not match a broad camera-flow blob', () {
      final pool = _words(
        "Camera's open, ready when you are. Once you're set, just say the word and I'll capture it right "
        "away. No rush at all, take your time.",
      );
      expect(
        looksLikeCloseSequenceMatch(
          _words("I'm ready when you are. Just tell me when to capture it."),
          pool,
        ),
        isFalse,
      );
    });
  });

  group('genuine ASR-drifted echo is still caught', () {
    // The confirmed case this backstop must never lose: a single swapped
    // word in an otherwise-verbatim echo.
    test('"Pick another one when you\'re ready." closely matches "...take another one when you\'re ready."', () {
      final pool = _words("go ahead and take another one when you're ready");
      expect(looksLikeCloseSequenceMatch(_words("Pick another one when you're ready."), pool), isTrue);
    });

    test('an exact verbatim echo matches', () {
      final pool = _words('Is that correct?');
      expect(looksLikeCloseSequenceMatch(_words('Is that correct?'), pool), isTrue);
    });

    test('a short chunk closely matches a same-length prior utterance with one substitution', () {
      expect(looksLikeCloseSequenceMatch(_words('keep it please'), _words('keep it thanks')), isTrue);
    });

    test('one inserted/dropped boundary word still matches (length tolerance)', () {
      final pool = _words('would you like to keep it or retake it');
      expect(looksLikeCloseSequenceMatch(_words('like to keep it or retake'), pool), isTrue);
    });

    test('a short chunk echoing only PART of a longer prior turn still matches', () {
      final pool = _words(
        "Camera's open — ready when you are. Just let me know when you'd like to take the picture and I'll "
        "capture it right away.",
      );
      expect(looksLikeCloseSequenceMatch(_words("ready when you are"), pool), isTrue);
    });
  });

  group('coincidental word overlap is rejected even in a SHORT pool', () {
    test('two shared words out of four do not clear the threshold', () {
      expect(looksLikeCloseSequenceMatch(_words('open the camera now'), _words('close the door now')), isFalse);
    });

    test('words present but badly out of order do not match', () {
      expect(
        looksLikeCloseSequenceMatch(_words('the camera can you open'), _words('open the camera')),
        isFalse,
      );
    });

    test('completely unrelated short phrases never match', () {
      expect(looksLikeCloseSequenceMatch(_words('what time is it'), _words('take the photo now please')), isFalse);
    });
  });

  group('edge cases', () {
    test('empty chunk or empty pool never matches', () {
      expect(looksLikeCloseSequenceMatch([], _words('take the photo')), isFalse);
      expect(looksLikeCloseSequenceMatch(_words('take the photo'), []), isFalse);
    });

    test('wordEditDistance of identical sequences is zero', () {
      expect(wordEditDistance(_words('take the photo'), _words('take the photo')), 0);
    });

    test('wordEditDistance counts a single substitution as one', () {
      expect(wordEditDistance(_words('take the photo'), _words('pick the photo')), 1);
    });
  });

  group('longestTrailingEchoStrip — P0 transcript contamination fix', () {
    // The actual confirmed evidence: the technician's real request
    // followed, in the SAME transcript chunk, by this app's own spoken
    // fallback prompt leaking back and merging into one STT segment.
    test('the actual confirmed case: fallback prompt tail is stripped, leaving only the real request', () {
      final chunk = _words(
        'show me the estimate try me again for example show the job history or take a photo',
      );
      final candidates = [
        _words('i missed that one try me again for example show the job history or take a photo'),
      ];
      final stripCount = longestTrailingEchoStrip(chunk, candidates, minWords: 3);
      expect(stripCount, 13);
      final kept = chunk.sublist(0, chunk.length - stripCount).join(' ');
      expect(kept, 'show me the estimate');
    });

    test('an entirely genuine, uncontaminated utterance is never stripped', () {
      final chunk = _words('show me the estimate please');
      final candidates = [_words("i missed that one try me again for example show the job history or take a photo")];
      expect(longestTrailingEchoStrip(chunk, candidates, minWords: 3), 0);
    });

    test('a chunk too short to plausibly contain both a real request and an echoed tail is never stripped', () {
      // Below 2x minWords — not enough room for genuinely BOTH a real
      // request and a separately-recognizable echoed tail.
      final chunk = _words('take a photo');
      final candidates = [_words('take a photo')];
      expect(longestTrailingEchoStrip(chunk, candidates, minWords: 3), 0);
    });

    test('never strips so much that fewer than minWords would remain', () {
      // The whole chunk closely matches the candidate — stripping must
      // still leave at least minWords behind, never strip to nothing.
      final chunk = _words('yes please take the photo now for me thanks');
      final candidates = [_words('yes please take the photo now for me thanks')];
      final stripCount = longestTrailingEchoStrip(chunk, candidates, minWords: 3);
      expect(chunk.length - stripCount, greaterThanOrEqualTo(3));
    });

    test('picks the LONGEST match across multiple candidates', () {
      final chunk = _words('show me the estimate try me again for example show the job history or take a photo');
      final candidates = [
        // A shorter, weaker match (just the tail end).
        _words('take a photo'),
        // The genuine, longer match.
        _words('i missed that one try me again for example show the job history or take a photo'),
      ];
      expect(longestTrailingEchoStrip(chunk, candidates, minWords: 3), 13);
    });

    test('empty candidates list or all-empty candidates never strip anything', () {
      final chunk = _words('show me the estimate try me again for example show the job history');
      expect(longestTrailingEchoStrip(chunk, [], minWords: 3), 0);
      expect(longestTrailingEchoStrip(chunk, [[], []], minWords: 3), 0);
    });

    test('a completely unrelated candidate never causes a strip', () {
      final chunk = _words('show me the estimate for this job right now please');
      final candidates = [_words('the weather today is sunny with a light breeze')];
      expect(longestTrailingEchoStrip(chunk, candidates, minWords: 3), 0);
    });

    // REGRESSION GUARD: a first implementation used fuzzy (edit-distance
    // tolerant) matching for the strip boundary itself, which could
    // "absorb" the FIRST genuine word of the request as a tolerated
    // substitution for an unrelated word at the same position in the
    // candidate — confirmed here: "estimate" sits right where the
    // candidate has "one", close enough for the fuzzy matcher's tolerance
    // to treat as a substitution and strip it too. Exact-only matching
    // must never do this — "estimate" is the single most important word
    // of the request and must always survive.
    test('never strips a genuine word that only FUZZY-matches the candidate at the boundary', () {
      final chunk = _words('show me the estimate try me again for example show the job history or take a photo');
      final candidates = [
        _words('i missed that one try me again for example show the job history or take a photo'),
      ];
      final stripCount = longestTrailingEchoStrip(chunk, candidates, minWords: 3);
      final kept = chunk.sublist(0, chunk.length - stripCount).join(' ');
      expect(kept, 'show me the estimate');
    });
  });
}
