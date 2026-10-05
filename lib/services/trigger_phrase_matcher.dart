/// Shared, unit-testable matching layer for every deterministic voice
/// trigger's phrase list — see `_TranscriptTrigger.matches` in
/// `gemini_live_test_screen.dart`, which is this module's only production
/// caller today.
///
/// P0 FIX (CONFIRMED from a real session transcript): the technician's
/// actual capture attempt reached the app as
/// `"All right, taking the picture may."` — real speech-to-text output,
/// with a leading acknowledgment, the verb in a different form
/// ("taking" vs. the listed "take"), and a trailing noise word ("may").
/// Every trigger matched its phrase list by literal, space-padded
/// SUBSTRING containment, so `'take the picture'` did not match that text
/// at all: the shutter never fired, and the technician got no photo and no
/// "I didn't catch that" for a long time afterwards. This is the same root
/// cause as the earlier bare-"ready" miss seen from a different angle —
/// literal substring matching is too brittle for real ASR output, which
/// routinely drifts in word form, inserts filler, and appends trailing
/// noise.
///
/// The fix mirrors the approach already proven for echo detection
/// (`_looksLikeGeminiEcho`'s word-overlap fallback) and for the keep/retake
/// fork (`photo_decision_classifier.dart`'s per-word edit distance), but
/// deliberately does NOT reuse either one verbatim:
///
///  - Echo detection scores a loose bag-of-words OVERLAP RATIO, which is
///    right for "did Gemini already say roughly this sentence" but wrong
///    here: a trigger phrase list encodes word ORDER and specific function
///    words as real, load-bearing distinctions (see [_significantWords]).
///  - So this matcher keeps phrase words CONSECUTIVE and IN ORDER, and
///    only relaxes (a) each word's surface form, via [stemTriggerWord],
///    and (b) at most [_maxSkippableGapWords] inserted filler word(s)
///    between them.
///
/// What this deliberately does NOT relax, because prior confirmed
/// regressions depend on it:
///
///  - ARTICLES ARE LOAD-BEARING. `_capturePhotoIndicatorPhrases` lists
///    `'take photo'`/`'take the photo'` while `_openCameraIndicatorPhrases`
///    lists `'take a photo'`, and `_looksLikeCapturePhotoConfirmation`
///    vetoes the indefinite-article form explicitly — that distinction is
///    what stops a restated "let's take a photo" from firing a real,
///    unconfirmed shutter while the camera is already open (CONFIRMED
///    accidental-capture regression, 3ebd9995-flutter_run_log.txt). So
///    "a"/"an"/"the" can never be skipped as gap filler, and never
///    fuzzy-match each other.
///  - NEGATION STILL VETOES. "No, don't take it" must not fire
///    capture_photo. The old literal-substring path actually DID fire on
///    it (" take it " is right there as a substring); loosening matching
///    without adding this would have made that worse, not better. See
///    [_negatedAt]. The one exception: a "No,"/"Nope,"/"Nah," cut off from
///    the phrase by punctuation is a reaction, not a negation ("No, go
///    back." is a go-back request) — see [clauseBoundariesBefore]. "No,
///    don't take it" still vetoes on its "don't".
///  - SCOPE WORDS ARE LOAD-BEARING. 'last'/'another'/'again' separate
///    get_last_photo from open_camera/capture_photo, so they are
///    unskippable too.
library;

/// Lowercases and strips everything but letters and spaces — the exact
/// normalization every trigger matcher in this app already used, kept
/// identical so an apostrophe still becomes a SPACE ("let's" -> "let s",
/// "don't" -> "don t"), which several phrase lists are written against.
List<String> tokenizeTriggerText(String text) {
  return text
      .toLowerCase()
      .replaceAll(RegExp('[^a-z ]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
}

/// Irregular forms a suffix stripper can't reach, limited to two-letter and
/// three-letter roots the generic rules refuse to touch ("going" -> "go"
/// needs a >= 3-character remainder the generic 'ing' rule won't allow).
///
/// Deliberately EXCLUDES irregular PAST tenses — "took", "went", "gone",
/// "saw", "seen", "shown". Those forms describe something that already
/// happened rather than commanding it ("I took the picture yesterday"), so
/// folding them into the present stem would only widen the false-positive
/// surface. It would also break a documented property of
/// `_looksLikeIntentionalGoBack` ("'gone' never matches 'go'"). Regular
/// past tense is a different matter — the generic '-ed' rule below already
/// conflates "captured"/"capture", which is exactly the ASR drift this
/// module exists to absorb.
const Map<String, String> _irregularStems = {
  'going': 'go',
  'goes': 'go',
  'seeing': 'see',
  'pics': 'pic',
  'pix': 'pic',
};

/// Collapses a doubled final consonant left behind by suffix stripping
/// ("snapping" -> "snapp" -> "snap", "getting" -> "gett" -> "get").
String _collapseDoubledFinalConsonant(String base) {
  if (base.length < 3) return base;
  final last = base[base.length - 1];
  if (last != base[base.length - 2]) return base;
  if ('aeiou'.contains(last)) return base;
  return base.substring(0, base.length - 1);
}

/// Reduces a word to a coarse canonical stem so real ASR word-form drift
/// stops breaking a phrase match: "taking"/"takes" reach the same stem as
/// "take", "captured"/"capturing" as "capture", "pictures" as "picture".
///
/// Applied to BOTH sides (the transcript AND the phrase list), so the
/// phrase lists themselves never have to be rewritten — `'take the
/// picture'` stems to `tak the pictur`, which is what a stemmed
/// "...taking the picture..." also produces.
///
/// Words of 3 letters or fewer are returned untouched, which is what keeps
/// "a"/"an"/"the"/"it"/"no" intact — see this library's doc comment for why
/// those specifically must never blur into each other.
String stemTriggerWord(String word) {
  var w = _irregularStems[word] ?? word;
  if (w.length <= 3) return w;
  for (final suffix in const ['ings', 'ing', 'ed', 'es', 's']) {
    if (w.endsWith(suffix) && w.length - suffix.length >= 3) {
      w = _collapseDoubledFinalConsonant(w.substring(0, w.length - suffix.length));
      break;
    }
  }
  // Trailing silent 'e' — "take" -> "tak" so it meets "taking" -> "tak",
  // "picture" -> "pictur" so it meets "pictures" -> "picture" -> "pictur".
  if (w.length > 3 && w.endsWith('e')) w = w.substring(0, w.length - 1);
  return w;
}

List<String> stemTriggerWords(Iterable<String> words) => words.map(stemTriggerWord).toList();

/// Space-padded, STEMMED rendering of [text] — the same `' w1 w2 '` shape
/// every existing `extraMatcher` already does its own `contains(' x ')`
/// checks against, so those matchers can be re-run against stemmed text
/// without being rewritten. Their own hardcoded phrases must be stemmed
/// with [stemTriggerPhrase] before comparison.
String stemmedPaddedTriggerText(String text) =>
    ' ${stemTriggerWords(tokenizeTriggerText(text)).join(' ')} ';

/// Stems a fixed phrase written in a trigger list / matcher
/// ("take a photo" -> "tak a photo") so it can be compared against
/// [stemmedPaddedTriggerText] output.
String stemTriggerPhrase(String phrase) => stemTriggerWords(tokenizeTriggerText(phrase)).join(' ');

/// Words that must never be skipped as filler and never fuzzy-match
/// anything else — see this library's doc comment. Listed in STEMMED form
/// (each is <= 3 letters or otherwise stem-stable, so these are their own
/// stems).
const Set<String> _significantWords = {
  // Articles — the open_camera vs. capture_photo distinction.
  'a', 'an', 'the',
  // Negation.
  'no', 'not', 'never', 'nope', 'dont', 'didnt', 'doesnt', 'isnt', 'wasnt', 'arent', 'cant',
  'don', 'didn', 'doesn', 'isn', 'wasn', 'aren', 'can', 't',
  // Scope words separating get_last_photo from open_camera/capture_photo.
  'last', 'another', 'again', 'other', 'next',
};

/// Standalone negation tokens, checked directly before a matched phrase.
const Set<String> _negationWords = {
  'no', 'not', 'never', 'nope', 'dont', 'didnt', 'doesnt', 'isnt', 'wasnt', 'arent', 'cant', 'wont',
};

/// Contraction stems left behind when the apostrophe normalizes to a space
/// ("don't" -> "don t") — same list and same reasoning as
/// `photo_decision_classifier.dart`'s own `_negationStems`.
const Set<String> _negationStems = {
  'don', 'didn', 'doesn', 'isn', 'wasn', 'aren', 'won', 'couldn', 'wouldn', 'shouldn', 'hadn', 'hasn', 'can',
};

/// How many inserted filler words a single phrase match tolerates in total.
/// One, deliberately: enough for real ASR insertions ("open up the camera"
/// vs. the listed "open the camera") without letting a phrase match across
/// a genuinely different sentence. Words in [_significantWords] are never
/// skippable regardless of this budget.
const int _maxSkippableGapWords = 1;

int _editDistance(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost].reduce((x, y) => x < y ? x : y);
    }
    prev = cur;
  }
  return prev[b.length];
}

/// Whether an already-stemmed transcript word counts as the already-stemmed
/// phrase word. Exact first; a single-character edit is tolerated only when
/// BOTH stems are at least 5 characters and NEITHER is a significant word —
/// long content words are where real ASR garbling shows up ("camara",
/// "pictur"), while short function words are exactly the ones whose
/// identity the phrase lists depend on.
bool _wordMatches(String transcriptStem, String phraseStem) {
  if (transcriptStem == phraseStem) return true;
  if (_significantWords.contains(phraseStem) || _significantWords.contains(transcriptStem)) return false;
  if (phraseStem.length < 5 || transcriptStem.length < 5) return false;
  return _editDistance(transcriptStem, phraseStem) <= 1;
}

/// Negation words that are just as often a standalone REACTION as a
/// negation: "No, go back." / "Nope, show me the invoice." — a correction or
/// a verbal tic in front of the command, not "don't go back". Only these can
/// be cut off from what follows by punctuation; "not"/"never"/"don't" can't
/// stand alone like that, so they always negate.
const Set<String> interjectionNegationWords = {'no', 'nope', 'nah'};

final RegExp _clauseBoundaryGap = RegExp(r'[,.;:!?…—–]|\s-|-\s');

/// For each token [tokenizeTriggerText] produces from [text], whether a
/// clause boundary — `, . ; : ! ?`, a dash, or an ellipsis — sits between
/// it and the token before it. Token-for-token aligned with
/// [tokenizeTriggerText] (both split on every non-letter), so index `i`
/// here describes word `i` there.
///
/// 9948b4d log (u=20): "No, go back." on the Invoice screen was vetoed as
/// a negated "go back" — tokenizing had already thrown the comma away, so
/// the matcher saw "no go back". The comma is exactly what tells "No, go
/// back." (a correction, then a command) from "no go back".
List<bool> clauseBoundariesBefore(String text) {
  final lower = text.toLowerCase();
  final boundaries = <bool>[];
  var previousEnd = -1;
  for (final match in RegExp('[a-z]+').allMatches(lower)) {
    final gap = previousEnd < 0 ? '' : lower.substring(previousEnd, match.start);
    // A spaced hyphen ("No - go back") is a dash; an unspaced one
    // ("follow-up") joins a word and is not a boundary.
    boundaries.add(_clauseBoundaryGap.hasMatch(gap));
    previousEnd = match.end;
  }
  return boundaries;
}

/// The interjection a match was allowed past (see [interjectionNegationWords]),
/// or null. Pure; [_negatedAt] uses it, and callers log it.
String? _ignoredInterjectionAt(List<String> words, List<bool>? boundaries, int index) {
  if (index <= 0 || boundaries == null || index >= boundaries.length) return null;
  final prev = words[index - 1];
  if (interjectionNegationWords.contains(prev) && boundaries[index]) return prev;
  return null;
}

bool _negatedAt(List<String> words, int index, [List<bool>? boundaries]) {
  if (index <= 0) return false;
  final prev = words[index - 1];
  if (_ignoredInterjectionAt(words, boundaries, index) != null) return false;
  if (_negationWords.contains(prev)) return true;
  // "don t take it" / "didn t keep it" — the apostrophe already split the
  // contraction into two tokens, so the real negation sits one further back.
  if (prev == 't' && index - 2 >= 0 && _negationStems.contains(words[index - 2])) return true;
  return false;
}

/// How a phrase matched — carried back to the caller purely so the run log
/// can say which phrase fired and whether it needed the fuzzy path, making
/// this directly verifiable from a real log instead of inferred.
class TriggerPhraseMatch {
  const TriggerPhraseMatch({
    required this.phrase,
    required this.exact,
    required this.gapWords,
    this.ignoredNegationPrefix,
  });

  /// The phrase list entry that matched, verbatim as written in the list.
  final String phrase;

  /// Set when a leading "No,"/"Nope,"/"Nah," directly in front of the phrase
  /// was read as a reaction, not a negation, because punctuation separates
  /// it from the phrase (see [clauseBoundariesBefore]) — the word itself.
  /// Callers log this as `NEGATION PREFIX IGNORED`.
  final String? ignoredNegationPrefix;

  /// True when the phrase matched word-for-word with no stemming difference
  /// and no inserted filler — i.e. the old literal-substring path would
  /// have matched this too.
  final bool exact;

  /// How many filler words were skipped inside the phrase.
  final int gapWords;

  String describe() {
    if (exact) return 'phrase "$phrase" (exact)';
    final gapNote = gapWords > 0 ? ', $gapWords filler word(s) skipped' : '';
    return 'phrase "$phrase" (fuzzy: word-form drift$gapNote)';
  }
}

TriggerPhraseMatch? _matchStemmedPhrase(
  List<String> words,
  List<String> rawWords,
  List<String> phraseWords,
  List<String> rawPhraseWords,
  String phraseLabel,
  List<bool> boundaries,
) {
  for (var start = 0; start < words.length; start++) {
    var w = start;
    var p = 0;
    var gaps = 0;
    var anyFuzzyWord = false;
    while (p < phraseWords.length && w < words.length) {
      if (_wordMatches(words[w], phraseWords[p])) {
        // Raw against RAW: comparing against the stemmed phrase word logged
        // every verbatim "picture" phrase as fuzzy ("picture" vs "pictur").
        if (rawWords[w] != rawPhraseWords[p]) anyFuzzyWord = true;
        w++;
        p++;
        continue;
      }
      // A gap is only allowed BETWEEN matched phrase words (never before
      // the first one — that would just be a later start position, already
      // covered by the outer loop) and never over a significant word.
      if (p == 0 || gaps >= _maxSkippableGapWords || _significantWords.contains(words[w])) break;
      gaps++;
      w++;
    }
    if (p < phraseWords.length) continue;
    if (_negatedAt(words, start, boundaries)) continue;
    return TriggerPhraseMatch(
      phrase: phraseLabel,
      exact: !anyFuzzyWord && gaps == 0,
      gapWords: gaps,
      ignoredNegationPrefix: _ignoredInterjectionAt(words, boundaries, start),
    );
  }
  return null;
}

/// Tries to match [phrase] against [transcript] at each word position.
/// Returns the first non-negated match, or `null`.
TriggerPhraseMatch? matchTriggerPhrase(String transcript, String phrase) =>
    matchAnyTriggerPhrase(transcript, [phrase]);

/// Returns the first phrase in [phrases] that matches [transcript], or
/// `null` if none does. Phrase order is preserved, so a list's own
/// most-specific entries should stay listed first where that matters for
/// logging.
TriggerPhraseMatch? matchAnyTriggerPhrase(String transcript, List<String> phrases) {
  final rawWords = tokenizeTriggerText(transcript);
  if (rawWords.isEmpty) return null;
  final words = stemTriggerWords(rawWords);
  final boundaries = clauseBoundariesBefore(transcript);
  for (final phrase in phrases) {
    final rawPhraseWords = tokenizeTriggerText(phrase);
    final phraseWords = stemTriggerWords(rawPhraseWords);
    if (phraseWords.isEmpty) continue;
    final match = _matchStemmedPhrase(words, rawWords, phraseWords, rawPhraseWords, phrase, boundaries);
    if (match != null) return match;
  }
  return null;
}

/// Whether every occurrence of [phrase] in [transcript] sits in a NEGATED
/// position — for callers that do their own (non-phrase-list) keyword
/// checks and need the same "no, don't take it" veto this module applies
/// internally. Returns false when the phrase isn't present at all.
bool triggerPhraseIsNegated(String transcript, String phrase) {
  final words = stemTriggerWords(tokenizeTriggerText(transcript));
  final boundaries = clauseBoundariesBefore(transcript);
  final phraseWords = stemTriggerWords(tokenizeTriggerText(phrase));
  if (phraseWords.isEmpty || words.isEmpty) return false;
  var sawOccurrence = false;
  for (var start = 0; start + phraseWords.length <= words.length; start++) {
    var ok = true;
    for (var j = 0; j < phraseWords.length; j++) {
      if (!_wordMatches(words[start + j], phraseWords[j])) {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    sawOccurrence = true;
    if (!_negatedAt(words, start, boundaries)) return false;
  }
  return sawOccurrence;
}
