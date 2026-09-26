/// Detects Gemini claiming, in its OWN free text, that a photo action has
/// already completed — see
/// `_GeminiLiveTestScreenState._auditGeminiCompletionClaim` in
/// `gemini_live_test_screen.dart`, which owns the timestamps, the licensing
/// window and the spoken correction; this module only answers "does this
/// sentence assert that something finished, and if so, which function's
/// success would have to license it".
///
/// P0 TRUST FIX (CONFIRMED, twice in ONE real session): Gemini said "It's
/// captured." and, later, "Both taken. Anything else you need help with?"
/// in a session where `capture_photo` never once succeeded — a whole-file
/// search of all 3131 log lines for "PHOTO FLOW: capture" and
/// "platform_capture_call" returned zero matches. That is categorically
/// worse than a UX bug: the technician leaves the site believing the job is
/// documented when it is not.
///
/// The primary fix is the system instruction, which reserves completed-
/// action vocabulary for the app's own constrained verbatim path. This
/// module is the runtime backstop behind it, split out as its own file for
/// the same reason `photo_decision_classifier.dart` was: the decision is
/// high-stakes, it is pure text-in/answer-out, and it needs real regression
/// tests rather than a device run to trust.
library;

/// Surface forms of COMPLETED photo actions, keyed by the deterministic
/// function whose SUCCESS is the only thing that licenses them.
///
/// Deliberately RAW past-tense surface forms, and deliberately NOT run
/// through `trigger_phrase_matcher.dart`'s stemmer: stemming would collapse
/// "captured" into "capture" and flag the perfectly honest "I'll capture it
/// as soon as you're ready" as a false claim. This is the one place in the
/// codebase where the difference between tenses is the entire point.
const Map<String, List<String>> photoCompletionClaimPhrases = {
  'capture_photo': [
    'captured',
    'snapped',
    // The exact phrasing from the confirmed session ("Both taken.").
    'taken',
    'took the photo',
    'took the picture',
    'got the shot',
  ],
  'confirm_photo_upload': [
    'uploaded',
    // P0 FIX (CONFIRMED via a real session: "Got it. I've saved that
    // photo for this job." was never caught — the phrase list only had
    // "saved THE photo", an exact-word-sequence match that a different,
    // equally natural determiner ("that") silently defeats). Every
    // determiner variant listed explicitly for each phrase below, the
    // same fix already applied to `photo_decision_classifier.dart` for
    // the identical "that" vs "the" gap — this module's own fuzzy pass
    // (see [completionClaimFunctionIn]'s doc comment) can't bridge this
    // either: "that"/"the" are both short, common words with no shared
    // stem, so no edit-distance/stemming tolerance would ever equate them
    // — only an explicit listed variant does.
    'saved the photo',
    'saved that photo',
    'saved this photo',
    'saved the picture',
    'saved that picture',
    'saved this picture',
    'saved that one',
    'saved this one',
    'attached the photo',
    'attached that photo',
    'attached this photo',
    'attached the picture',
    'attached that picture',
    'attached this picture',
    'attached it to the job',
    'added it to the job',
    'added that to the job',
    'uploaded it',
    'uploaded that',
    'uploaded the photo',
    'uploaded that photo',
    'uploaded this photo',
    'photo is saved',
    'photo s saved',
    'that s saved',
    'thats saved',
    'thats uploaded',
    'that s uploaded',
  ],
  // P0 FIX (CONFIRMED in a real session: Gemini's free text said "Camera's
  // open — ready when you are." 71ms into an open_camera call whose native
  // open didn't return for another 30.2s). "Camera's" normalizes to
  // "camera s" (see [_words]).
  'open_camera': [
    'camera s open',
    'camera is open',
    'camera s now open',
    'camera is now open',
    'camera s already open',
    'camera is already open',
    'camera s up',
    'camera is up',
    'camera s ready',
    'camera is ready',
    'opened the camera',
    'opened up the camera',
  ],
  'retake_photo': [
    'retaken',
    'discarded',
  ],
};

/// Words that, appearing within [_suppressorReach] words BEFORE a phrase
/// from [photoCompletionClaimPhrases], mean Gemini is NOT asserting the
/// action completed — so the phrase is honest and the audit must stay
/// quiet. Two kinds, suppressing for the same reason:
///
///  - DENIAL — "no photo has been taken yet", "that hasn't been uploaded".
///    A wider reach than `trigger_phrase_matcher.dart`'s own 2-word veto,
///    because the passive voice this vocabulary appears in puts real
///    distance between the negation and the verb ("hasn't been uploaded" is
///    three tokens once the apostrophe splits "hasn't").
///  - FUTURE / HYPOTHETICAL / INTERROGATIVE — "would you like the photo
///    taken?", "I'll get it uploaded once you're happy". These are offers
///    and intentions, which the system instruction explicitly still permits
///    ("describing an action you are about to perform is fine"). Flagging
///    them would make the audit cry wolf on correct behavior, which is how
///    a safety check gets ignored.
const Set<String> _suppressors = {
  // Denial.
  'no', 'not', 'never', 'nothing', 'yet', 'hasn', 'haven', 'havent', 'hasnt', 'wasn', 'wasnt',
  'isn', 'isnt', 'didn', 'didnt', 'dont', 'don', 'wont', 'won', 'cant', 'can',
  // Offer / intention / question / condition.
  'want', 'like', 'shall', 'should', 'will', 'would', 'could', 'll', 'to', 'ready',
  'once', 'when', 'after', 'before', 'if', 'about', 'going', 'gonna', 'let', 'say',
};

const int _suppressorReach = 4;

/// Idioms that merely CONTAIN a claim word without claiming anything — "get
/// that taken care of". Checked as the words immediately FOLLOWING a match.
const Map<String, List<String>> _followerExclusions = {
  'taken': ['care'],
};

List<String> _words(String text) => text
    .toLowerCase()
    .replaceAll(RegExp('[^a-z ]'), ' ')
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .toList();

bool _suppressedBefore(List<String> words, int index) {
  for (var back = 1; back <= _suppressorReach && index - back >= 0; back++) {
    if (_suppressors.contains(words[index - back])) return true;
  }
  return false;
}

/// Returns the name of the photo function whose success would have to
/// license [spoken], or `null` when [spoken] claims nothing.
///
/// Only the FIRST un-suppressed claim is reported: the caller corrects a
/// turn once, not once per phrase, and the correction is the same either
/// way.
String? completionClaimFunctionIn(String spoken) {
  final words = _words(spoken);
  if (words.isEmpty) return null;
  for (final entry in photoCompletionClaimPhrases.entries) {
    for (final phrase in entry.value) {
      final phraseWords = phrase.split(' ');
      for (var i = 0; i + phraseWords.length <= words.length; i++) {
        var hit = true;
        for (var j = 0; j < phraseWords.length; j++) {
          if (words[i + j] != phraseWords[j]) {
            hit = false;
            break;
          }
        }
        if (!hit) continue;
        if (_suppressedBefore(words, i)) continue;
        final excluded = _followerExclusions[phrase];
        final next = i + phraseWords.length < words.length ? words[i + phraseWords.length] : null;
        if (excluded != null && next != null && excluded.contains(next)) continue;
        return entry.key;
      }
    }
  }
  return null;
}
