import 'trigger_phrase_matcher.dart' show clauseBoundariesBefore, matchTriggerPhrase;

/// Classifies a technician's utterance, while a captured photo awaits a
/// keep/retake decision, as [confirm], [retake], [ambiguous], or [none] —
/// see [classifyPhotoDecision]'s doc comment for the algorithm and why it
/// exists as a standalone, unit-testable module rather than inline in
/// `gemini_live_test_screen.dart` (`_GeminiLiveTestScreenState
/// ._maybeDetectPhotoDecision`, which owns arming/debouncing/dispatching
/// the actual decision this only classifies).
///
/// `ambiguous` means genuine, un-negated evidence exists on BOTH sides at
/// once (e.g. "yes retake") with nothing to resolve the conflict — the
/// caller must ask the technician to repeat clearly rather than guessing,
/// since a wrong guess here either uploads unwanted content or discards
/// wanted content.
enum PhotoDecision { confirm, retake, ambiguous, none }

/// Whole-phrase cues for "keep this photo" — checked as padded whole-word
/// substrings, not naive `contains`, so e.g. 'good' alone in
/// [_fuzzyConfirmWords] doesn't also make 'goodness' match. Apostrophes
/// normalize to a SPACE under [classifyPhotoDecision]'s own tokenization
/// (`replaceAll(RegExp('[^a-z ]'), ' ')`), so "that's good" becomes "that s
/// good" (three words) — both that form and the no-apostrophe STT form are
/// listed throughout so this matches either way.
const List<String> _photoConfirmIndicatorPhrases = [
  'keep it',
  'save it',
  'upload it',
  'looks good',
  'that works',
  'use that',
  'keep that',
  'yes keep',
  'confirm',
  'that s good',
  'thats good',
  'yes upload',
  'use this one',
  'that s fine',
  'thats fine',
  'yes that s fine',
  'yes thats fine',
  'good keep it',
  'yeah keep that one',
  'keep that one',
  // P0 FIX (CONFIRMED via a real session: "This looks good." and a
  // garbled "Keep this for rock." — an STT mishearing of a bare "keep" —
  // both matched nothing; root-caused to a stale ambiguous-streak
  // escalation, not actually a vocabulary gap, but this round's report
  // explicitly asked for the wider natural-affirmation vocabulary below
  // too, so it's added as real defense-in-depth regardless). "keep this
  // one" specifically closes a determiner gap next to the existing "keep
  // that one" above — same phrase, different (equally natural)
  // determiner.
  'keep this one',
  'looks great',
  // "That'll do." normalizes to "that ll do" (apostrophe -> space, same
  // as every other punctuation mark in this file).
  'that ll do',
  'good one',
  'thats the one',
  'that s the one',
];

/// Whole-phrase cues for "retake this photo" — see
/// [_photoConfirmIndicatorPhrases]'s doc comment for the matching approach.
const List<String> _photoRetakeIndicatorPhrases = [
  'retake',
  // "Re-take." normalizes to "re take" (hyphen -> space, same as every
  // other punctuation mark) — never matches the bare "retake" entry above.
  // The fuzzy word pass separately catches "take" alone via edit distance
  // to "retake", but this phrase makes the common hyphenated-STT case
  // match directly and explicitly too.
  're take',
  // P0 FIX (CONFIRMED real STT capture): a technician's actual retake
  // attempt came through as "or re-ticket." — logged as "PHOTO DECISION:
  // no confirm/retake match". Normalizes the same way "re take" above
  // does (hyphen -> space) to "re ticket" (2 tokens). This is a genuine
  // ASR mishearing of "retake it" as one run-on word ("re-ticket") that no
  // general edit-distance/stemming pass can bridge — "ticket" and "retake"
  // are too different character-for-character (edit distance ~5) to ever
  // clear any reasonable fuzzy threshold, and the words don't even split
  // the same way ("re"+"ticket" vs "re"+"take"+"it"). Listed explicitly,
  // the same established pattern already used elsewhere in this codebase
  // for a confirmed-real garbled STT string too idiosyncratic for a
  // general algorithm (see e.g. `_openCameraIndicatorPhrases`'s "open the
  // camera" entry). Safe: this classifier only ever runs while a photo
  // decision is genuinely pending (see this file's own top doc comment),
  // a narrow context where "ticket" has no other plausible meaning.
  're ticket',
  'try again',
  'take another',
  'redo that',
  'redo it',
  'doesnt look right',
  'take it again',
  'no retake',
  'retake it',
  'no good',
  'delete it',
  'take another one',
  'do it again',
  'not good',
  'that s not good',
  'thats not good',
  'not good enough',
  'i don t like',
  'i dont like',
  'don t like',
  'dont like',
  'not clear',
  'not right',
  'isn t right',
  'doesn t look right',
  'blurry',
  'try that again',
  'once more',
  'one more',
  'another one',
  'another photo',
  'another picture',
  'start over',
  'not this one',
  'bad photo',
  'discard',
  'again',
  'blur',
  'too dark',
  'too bright',
  'out of focus',
  'not in focus',
  'not visible',
  'cant see it',
  'cant see',
  'can t see it',
  'can t see',
];

/// See the top of [classifyPhotoDecision]. Apostrophes normalize to a space
/// ("i'll" -> "i ll").
const Set<String> _takeItKeepUtterances = {
  'i ll take it', 'i will take it', 'we ll take it', 'we will take it', 'i ll take that', 'i ll take that one',
  'i ll take this one',
};
const Set<String> _takeItAmbiguousUtterances = {
  'take', 'take it', 'take that', 'take this', 'take that one', 'take this one',
};

const Set<String> _fuzzyConfirmWords = {
  'keep', 'confirm', 'upload', 'save', 'submit', 'approve', 'yes', 'yeah', 'yep', 'good', 'fine', 'perfect',
};
const Set<String> _fuzzyRetakeWords = {
  'retake', 'redo', 'discard', 'delete', 'again', 'another', 'retry', 'reshoot', 'no', 'nope', 'new',
};

/// Negation words/stems checked immediately before a matched keep/retake
/// cue — a negated cue INVERTS to the opposite side rather than just
/// cancelling ("no keep it" is retake evidence, not merely "not confirm
/// evidence"). Apostrophes normalize to a space elsewhere in this file,
/// splitting "don't"/"didn't"/etc. into two tokens ("don"/"didn" + "t") —
/// both the whole contraction (already-space-free STT output) and the
/// split stem are listed so this matches either way; the trailing "t" case
/// is handled separately (see [_negatedBefore] — it needs one more word of
/// reach to find the stem behind the "t").
const Set<String> _photoDecisionNegationWords = {
  'no', 'not', 'dont', 'didnt', 'doesnt', 'isnt', 'wasnt', 'arent', 'never', 'nope',
};

const Set<String> _negationStems = {
  'didn', 'doesn', 'isn', 'wasn', 'aren', 'don', 'couldn', 'wouldn', 'shouldn', 'hadn', 'hasn',
};

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

bool _fuzzyWordMatches(String word, Set<String> vocab) {
  if (vocab.contains(word)) return true;
  if (word.length < 4) return false;
  for (final v in vocab) {
    if (v.length < 4) continue;
    final maxDist = v.length >= 6 ? 2 : 1;
    if (_editDistance(word, v) <= maxDist) return true;
  }
  return false;
}

/// P0 FIX (CONFIRMED via flutter_run_log_new.txt, build #59): "No, this
/// image didn't looks good. Re-take." fired confirm_photo_upload — the OLD
/// design ran a confirm phrase-list check (exact phrase list, zero negation
/// handling) and a retake phrase-list check independently; "didn't looks
/// good" satisfied the confirm list's "looks good" substring with the
/// negation simply ignored, while "Re-take" — hyphen normalized to a
/// space, like every other punctuation mark — split into two tokens ("re",
/// "take") that never matched the retake list's single-token "retake"
/// entry at all. Since exactly one of the two old independent checks came
/// back true, the fuzzy fallback (which DID have negation handling) never
/// even ran.
///
/// Replaced with a single evidence-scoring pass instead of two independent
/// yes/no checks: every matched cue (phrase-list OR fuzzy word) is
/// classified as retake- or confirm-evidence, but a cue found within 2
/// words of a negation word flips to the OPPOSITE side instead of just
/// cancelling ("no keep it" -> retake evidence, "don't retake" -> confirm
/// evidence) — negation inverts meaning, it doesn't erase it. Retake and
/// confirm evidence are otherwise symmetric: if a genuine, UNnegated cue
/// exists on both sides at once (e.g. "yes retake" — "yes" and "retake"
/// directly contradicting each other, nothing to resolve it), that's a
/// real ambiguity, not a coin flip — returns [PhotoDecision.ambiguous] so
/// the caller can ask the technician to repeat clearly instead of guessing
/// which way to gamble a real upload/discard decision.
///
/// Verified against the paired test cases in `test/photo_decision_classifier_test.dart`:
///  - "no keep it" -> retake (negated confirm cue inverts)
///  - "yes retake" -> ambiguous (genuine conflict, no negation to resolve it)
///  - "it's fine, don't retake" -> confirm (negated retake cue inverts)
///  - "this doesn't look good, take another" -> retake (negated confirm cue
///    inverts, PLUS an explicit unnegated retake cue — not a conflict)
///  - "looks good, keep it" -> confirm (unchanged, already worked)
///  - "No, this image didn't looks good. Re-take." -> retake (the actual
///    bug: negated "looks good" inverts to retake evidence, AND "take"
///    fuzzy-matches "retake" by edit distance even though "re"/"take" never
///    rejoin into one token — two independent signals agree)
///
/// P0 FIX (a later round, CONFIRMED via a real capture: "or re-ticket."
/// logged as "no confirm/retake match" — the technician's real retake
/// attempt never resolved): the phrase-list/fuzzy-word passes above are
/// now ALSO backed by `trigger_phrase_matcher.dart`'s stemmed,
/// filler-tolerant matching (see `scoreFuzzyPhrase` below) — the same
/// mechanism already proven for open_camera/capture_photo, applied here
/// for consistency across every trigger matcher in the app rather than
/// leaving this one decision on its own narrower scheme. Additive only:
/// negation inversion still lives entirely in the literal pass above.
/// "or re-ticket." itself needed a third, separate fix — an explicit
/// `'re ticket'` phrase entry, since "ticket" and "retake" are too
/// different character-for-character for any edit-distance/stemming pass
/// to ever bridge (see that phrase's own doc comment).
PhotoDecision classifyPhotoDecision(String text) {
  final words = text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return PhotoDecision.none;

  // Whole-utterance "take ..." phrasings the scoring below reads as retake
  // (bare "take" fuzzy-matches "retake") — CONFIRMED in a real trace: "Take
  // it." discarded the photo. "I'll take it" is the everyday idiom for
  // accepting something, so it's a keep; a bare "take it" / "take this one"
  // could equally mean "use this one" or be "retake it" with the "re"
  // clipped by the recognizer, so it asks instead of silently discarding.
  // Exact matches only — every other phrasing ("take it again", "take
  // another", "retake it") is scored below exactly as before.
  final whole = words.join(' ');
  if (_takeItKeepUtterances.contains(whole)) return PhotoDecision.confirm;
  if (_takeItAmbiguousUtterances.contains(whole)) return PhotoDecision.ambiguous;

  // Negation doesn't reach across punctuation: "No, keep it." answers a
  // "retake?" with "no" and then says keep — it is NOT "no keep it" (which
  // inverts to retake). Without this the comma was invisible and that
  // answer scored as RETAKE, discarding the photo the technician wanted.
  // The bare "No" still counts as retake evidence on its own, so that
  // phrasing now comes out ambiguous and is asked about, never guessed.
  final boundaries = clauseBoundariesBefore(text);
  bool negatedBefore(int index) {
    for (var back = 1; back <= 2 && index - back >= 0; back++) {
      if (index - back + 1 < boundaries.length && boundaries[index - back + 1]) return false;
      final w = words[index - back];
      if (_photoDecisionNegationWords.contains(w)) return true;
      if (w == 't' && index - back - 1 >= 0 && _negationStems.contains(words[index - back - 1])) return true;
    }
    return false;
  }

  var retakeEvidence = 0;
  var confirmEvidence = 0;

  void scorePhrase(String phrase, bool phraseIsRetake) {
    final phraseWords = phrase.split(' ');
    for (var i = 0; i <= words.length - phraseWords.length; i++) {
      var matches = true;
      for (var j = 0; j < phraseWords.length; j++) {
        if (words[i + j] != phraseWords[j]) {
          matches = false;
          break;
        }
      }
      if (!matches) continue;
      final negated = negatedBefore(i);
      if (phraseIsRetake == negated) {
        confirmEvidence++;
      } else {
        retakeEvidence++;
      }
    }
  }

  for (final phrase in _photoRetakeIndicatorPhrases) {
    scorePhrase(phrase, true);
  }
  for (final phrase in _photoConfirmIndicatorPhrases) {
    scorePhrase(phrase, false);
  }

  // P0 FIX — apply the same fuzzy, stemmed, filler-tolerant matching
  // already proven for open_camera/capture_photo/echo detection
  // (`trigger_phrase_matcher.dart`) to this classifier too, consistently,
  // instead of leaving this one decision on its own separate, narrower
  // scheme (`scorePhrase` above requires an EXACT word-for-word match;
  // [_fuzzyWordMatches] below only catches single-word drift against a
  // small fixed vocabulary). This is what lets word-form drift ("retaking"
  // for "retake") or one inserted filler word ("let's just retake that
  // one") resolve against the SAME phrase lists above without having to
  // duplicate them.
  //
  // Deliberately ADDITIVE, not a replacement: only counts a match
  // `matchTriggerPhrase` itself considers NON-exact — an exact match was
  // already scored by `scorePhrase` above, so re-counting it here would
  // only inflate the evidence tally without changing the binary
  // confirm/retake/ambiguous outcome (harmless, but pointless work).
  //
  // Negation is handled ENTIRELY by `scorePhrase` above, on purpose:
  // `trigger_phrase_matcher.dart`'s own negation veto only SKIPS a negated
  // match (returns no match at all) — it has no notion of INVERTING
  // evidence to the opposite side the way this classifier's `negatedBefore`
  // does ("no keep it" -> retake evidence, not just "not confirm
  // evidence"). So this pass only ever adds evidence for phrasings that are
  // NOT negated; a negated-and-also-fuzzy phrasing (e.g. a garbled "no,
  // don't retake it") simply adds nothing from this pass and falls back to
  // whatever the literal/fuzzy-word passes elsewhere in this function
  // already determine — never a regression, only occasionally less extra
  // coverage for that narrower combination.
  void scoreFuzzyPhrase(String phrase, bool phraseIsRetake) {
    final match = matchTriggerPhrase(text, phrase);
    if (match == null || match.exact) return;
    if (phraseIsRetake) {
      retakeEvidence++;
    } else {
      confirmEvidence++;
    }
  }

  for (final phrase in _photoRetakeIndicatorPhrases) {
    scoreFuzzyPhrase(phrase, true);
  }
  for (final phrase in _photoConfirmIndicatorPhrases) {
    scoreFuzzyPhrase(phrase, false);
  }

  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    final matchesRetakeWord = _fuzzyWordMatches(word, _fuzzyRetakeWords);
    final matchesConfirmWord = _fuzzyWordMatches(word, _fuzzyConfirmWords);
    if (!matchesRetakeWord && !matchesConfirmWord) continue;
    final negated = negatedBefore(i);
    if (matchesRetakeWord) {
      if (negated) {
        confirmEvidence++;
      } else {
        retakeEvidence++;
      }
    }
    if (matchesConfirmWord) {
      if (negated) {
        retakeEvidence++;
      } else {
        confirmEvidence++;
      }
    }
  }

  // "take/shoot/capture + photo|picture|image|another|again" while a
  // decision is pending always means "not this one" — asking for a photo
  // while one is already pending is itself a retake signal.
  final hasTake = words.any((w) => w == 'take' || w == 'shoot' || w == 'capture');
  final hasPhotoNoun = words.any((w) => const {'photo', 'picture', 'image', 'pic', 'shot', 'another', 'again'}.contains(w));
  if (hasTake && hasPhotoNoun) retakeEvidence++;

  if (retakeEvidence > 0 && confirmEvidence > 0) return PhotoDecision.ambiguous;
  if (retakeEvidence > 0) return PhotoDecision.retake;
  if (confirmEvidence > 0) return PhotoDecision.confirm;
  return PhotoDecision.none;
}

/// P0 FIX (CONFIRMED via flutter_run_log_new.txt, build #61): the "ask for
/// a clear repeat" resolution for [PhotoDecision.ambiguous] could loop
/// indefinitely — Gemini's own repeated clarification prompt ("Keep it or
/// retake it?") is short enough, and itself matches BOTH keep and retake
/// evidence, to legitimately win the echo backstop's own "a short command
/// must always beat an echo guess" exemption (see
/// `_GeminiLiveTestScreenState._looksLikeGeminiEcho`'s doc comment) — so
/// the mic picking up Gemini's own re-prompt just re-triggers the SAME
/// ambiguous result, forever, with no bounded exit.
///
/// Used as a bounded escape once [PhotoDecision.ambiguous] has fired
/// repeatedly for the same pending photo (see
/// `_GeminiLiveTestScreenState._photoDecisionAmbiguousStreak`) — REPLACES
/// [classifyPhotoDecision] entirely rather than supplementing it: the next
/// utterance must be JUST the bare word "keep"/"confirm" or JUST "retake"
/// to resolve. This breaks the loop even without a perfect echo fix: an
/// echoed FULL sentence (the strict prompt or the original question)
/// always has far more non-filler words than this tolerates, so it can
/// never satisfy a bare-word-only check.
///
/// Deliberately whole-buffer, not substring: allows trivial filler ("um",
/// "okay") around the bare word since a technician saying it under
/// repeated pressure plausibly hedges slightly, but anything resembling a
/// full sentence correctly falls through to [PhotoDecision.none].
PhotoDecision classifyStrictBareWordPhotoDecision(String text) {
  final words = text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  const filler = {'um', 'uh', 'okay', 'ok', 'please', 'the', 'word', 'its', 'it'};
  final meaningful = words.where((w) => !filler.contains(w)).toList();
  if (meaningful.length != 1) return PhotoDecision.none;
  final word = meaningful.single;
  if (word == 'keep' || word == 'confirm') return PhotoDecision.confirm;
  if (word == 'retake') return PhotoDecision.retake;
  return PhotoDecision.none;
}
