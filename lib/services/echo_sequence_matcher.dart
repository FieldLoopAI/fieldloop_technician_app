/// Word-sequence similarity check used by
/// `_GeminiLiveTestScreenState._looksLikeGeminiEcho` in
/// `gemini_live_test_screen.dart` to decide whether a mic-captured
/// transcript chunk is very likely Gemini's own voice leaking back through
/// the mic, rather than genuine technician speech.
///
/// P0 FIX (CONFIRMED, a real ~2.5 minute session): the PREVIOUS echo
/// matcher scored an UNORDERED word-overlap ratio ("what fraction of the
/// chunk's words appear somewhere nearby, in any order") against a
/// comparison pool that — regardless of its own separate bounding bug —
/// was too permissive for that scoring shape even at moderate size. A
/// genuine "Take the photo." was discarded as echo because "take"/"the"/
/// "photo" each happened to occur SOMEWHERE close together in Gemini's
/// prior speech, unrelated to anything actually just said moments ago.
/// `capture_photo` fired ZERO times in the whole session as a direct
/// result — the technician was never heard.
///
/// This module provides the stricter replacement: word-level EDIT DISTANCE
/// between the chunk and a candidate text, which — unlike an unordered
/// overlap ratio — penalizes words being out of ORDER or POSITION, not
/// just absent. It only reports a close match when the word SEQUENCES
/// genuinely resemble each other ("is this chunk essentially an
/// ASR-drifted re-transcription of that specific utterance"), not merely
/// "do these two texts happen to share some vocabulary."
///
/// Deliberately a SEPARATE algorithm from the unordered overlap ratio
/// `_bestWordOverlapRatio` still uses elsewhere in `gemini_live_test_screen.dart`
/// (for `_auditGeminiDuplicateResponse`'s turn-to-turn duplicate check,
/// left untouched by this fix — that comparison is turn-vs-discrete-turn,
/// never turn-vs-growing-blob, so the failure mode that motivated this
/// module doesn't apply there).
library;

/// Word-level edit distance between two WORD SEQUENCES — each word treated
/// as one unit, exactly like a "character" in classic Levenshtein
/// character-level edit distance, just operating one level up.
int wordEditDistance(List<String> a, List<String> b) {
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

/// Up to roughly 1 wrong word per 3 (rounded down, minimum 1 word of
/// tolerance so even a 2-word chunk can survive a single swapped word) —
/// sized directly against the CONFIRMED real ASR-drift case this matcher
/// must still catch: Gemini said "...take another one when you're ready.";
/// the echoed mic capture transcribed as "Pick another one when you're
/// ready." (7 words, 1 substitution: take/pick). 1/7 ≈ 0.14, comfortably
/// inside this fraction.
///
/// Deliberately much STRICTER than the old unordered-overlap threshold
/// (0.8 overlap allowed up to 20% of words to be entirely MISSING, with no
/// position requirement at all) — this asks for the OPPOSITE shape of
/// tolerance: almost every word must be right AND close to the right
/// place, with only a small, genuinely ASR-plausible amount of drift
/// allowed.
const double maxErrorFraction = 0.34;

/// Whether [chunkWords] closely matches SOME window of [poolWords] of
/// about the same length — checking one word shorter/longer too, so a
/// single genuinely dropped/inserted boundary word doesn't misalign the
/// rest, scored by [wordEditDistance] rather than unordered containment.
///
/// Sliding a same-sized window across [poolWords] (rather than diffing the
/// whole two texts directly) is what lets this correctly find a close
/// match to a SHORT chunk that echoes only PART of a longer pool entry —
/// the window itself never needs to be longer than the chunk for that;
/// scanning every position already covers "does some slice of the pool
/// closely resemble the chunk," wherever in the pool that slice falls.
bool looksLikeCloseSequenceMatch(List<String> chunkWords, List<String> poolWords) {
  if (chunkWords.isEmpty || poolWords.isEmpty) return false;
  final maxErrors = (chunkWords.length * maxErrorFraction).floor().clamp(1, chunkWords.length);
  for (final windowLen in {chunkWords.length - 1, chunkWords.length, chunkWords.length + 1}) {
    if (windowLen <= 0 || windowLen > poolWords.length) continue;
    for (var start = 0; start <= poolWords.length - windowLen; start++) {
      final window = poolWords.sublist(start, start + windowLen);
      if (wordEditDistance(chunkWords, window) <= maxErrors) return true;
    }
  }
  return false;
}

/// P0 FIX (CONFIRMED via a real session: "Show me the estimate. Try me
/// again. For example, show the job history or take a photo." — the
/// technician's real request, followed in the SAME STT segment by this
/// app's OWN scripted fallback prompt leaking back and being transcribed
/// as one continuous chunk). [looksLikeCloseSequenceMatch] is whole-input:
/// it can only say "this ENTIRE word sequence is (or isn't) a close match"
/// — correct for [_looksLikeGeminiEcho]'s own all-or-nothing discard
/// decision, but wrong here, where the chunk ALSO carries genuine
/// technician speech that must never be discarded along with the
/// contamination.
///
/// Finds the LONGEST trailing run of [chunkWords] that EXACTLY matches the
/// end of ANY of [candidates] — used by
/// `_GeminiLiveTestScreenState._stripTrailingEchoContamination` to strip
/// just that tail off before trigger matching ever sees the chunk.
/// Returns 0 (strip nothing) if no candidate shares an exact trailing run
/// at least [minWords] long.
///
/// EXACT matching, deliberately — NOT [looksLikeCloseSequenceMatch]'s
/// fuzzy, edit-distance-tolerant scoring, even though this module already
/// has that available. CONFIRMED the fuzzy version is actively unsafe
/// here: sliding a fuzzy window lets a tolerated substitution "absorb" the
/// FIRST genuine word of the technician's own request as if it were part
/// of the echoed tail — a real case, caught by this file's own test
/// suite, where the fuzzy version stripped ONE WORD TOO MANY (cutting
/// "estimate" itself off "show me the estimate", the single most
/// important word of the request, because it happened to fuzzy-match an
/// unrelated word at the same position in the candidate). Exact matching
/// has no such failure mode: every word it strips is PROVEN, not
/// estimated, to be part of the leaked echo. The cost — a genuinely
/// ASR-drifted echoed tail (a word or two transcribed differently on the
/// leak than in the original) won't be recognized/stripped at all — is
/// the same conservative trade-off this whole file already makes
/// elsewhere ("a false positive here is worse than occasionally missing a
/// genuine echo"), just applied to STRIPPING instead of DISCARDING: never
/// risk removing a genuine word from the technician's real request.
///
/// Deliberately SUFFIX-only: the confirmed real case is the technician
/// speaking FIRST (their utterance is what prompted the app's own spoken
/// reply in the first place), with the app's leaked speech arriving
/// after — the natural shape, and the only one this function attempts.
/// Deliberately conservative like every other echo mechanism in this
/// module: never strips so much that fewer than [minWords] words would
/// remain, so a genuinely short, entirely real utterance can never have
/// words removed from it — there has to be plausible room for BOTH a real
/// request and a separately-recognizable echoed tail.
int longestTrailingEchoStrip(List<String> chunkWords, List<List<String>> candidates, {required int minWords}) {
  if (chunkWords.length < minWords * 2) return 0;
  var bestStripCount = 0;
  for (final candidateWords in candidates) {
    if (candidateWords.isEmpty) continue;
    // How far back BOTH lists can be compared at all, without either
    // running past minWords remaining in the chunk or past the start of
    // the (possibly shorter) candidate.
    final maxPossible = (chunkWords.length - minWords).clamp(0, candidateWords.length);
    var matchLen = 0;
    while (matchLen < maxPossible &&
        chunkWords[chunkWords.length - 1 - matchLen] == candidateWords[candidateWords.length - 1 - matchLen]) {
      matchLen++;
    }
    if (matchLen >= minWords && matchLen > bestStripCount) {
      bestStripCount = matchLen;
    }
  }
  return bestStripCount;
}
