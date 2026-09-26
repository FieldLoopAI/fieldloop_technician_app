/// Recognizes an English greeting / presence-check that Gemini's speech
/// recognition rendered in a non-Latin script — CONFIRMED in a real trace:
/// "hello hello hello hello", spoken in English, transcribed as Devanagari
/// "हेलो हेलो हेलो हेलो". The non-Latin-script guard in
/// `gemini_live_test_screen.dart` discards such text (no English matcher can
/// read it); this lets greeting-shaped small talk through to the same
/// acknowledge-presence reply "hello" gets, and NOTHING else.
///
/// Deliberately narrow, not transliteration: every word must be a known
/// greeting / presence-check word, and at least one must be an actual
/// greeting or presence cue. A transliterated command ("फोटो लो") or any
/// other content keeps being discarded exactly as before, so this can never
/// widen what the assistant acts on or answers.
///
/// Scripts: Devanagari (the one observed) and Gujarati, whose renderings of
/// these English words are the most likely for this app's technicians.
/// Extend [_greetingWords]/[_supportingWords] from real traces, never
/// speculatively with content words.
library;

/// A greeting or presence cue on its own — enough to count as small talk.
const Set<String> _greetingWords = {
  // hello
  'हेलो', 'हैलो', 'हलो', 'हेल्लो', 'हेलौ', 'हल्लो', 'હેલો', 'હૅલો', 'હલો', 'હેલ્લો',
  // hi / hey
  'हाय', 'हाई', 'हे', 'हेय', 'हेई', 'હાય', 'હાઈ', 'હે', 'હેય',
  // namaste (a greeting in its own right)
  'नमस्ते', 'नमस्कार', 'નમસ્તે', 'નમસ્કાર',
  // testing
  'टेस्टिंग', 'ટેસ્ટિંગ',
  // hear / there — the cue words of "can you hear me" / "are you there"
  'हियर', 'हीयर', 'હિયર', 'देयर', 'दैर', 'ધેર', 'ડેર',
};

/// Words allowed around a greeting ("can you hear me", "are you there",
/// "hello, anyone there") that mean nothing on their own.
const Set<String> _supportingWords = {
  'कैन', 'केन', 'यू', 'यु', 'मी', 'आर', 'डू', 'डिड', 'एनीवन', 'इज़', 'इज',
  'કેન', 'યુ', 'યૂ', 'મી', 'આર', 'ડુ', 'એનીવન',
};

/// Splits on whitespace and the punctuation Gemini's transcripts carry,
/// including the Devanagari danda.
List<String> _words(String text) =>
    text.split(RegExp(r'[\s,.!?;:।॥"“”()\-]+')).where((w) => w.isNotEmpty).toList();

/// Whether [text] is nothing but a non-Latin rendering of a greeting /
/// presence check.
bool looksLikeTransliteratedGreeting(String text) {
  final words = _words(text);
  if (words.isEmpty) return false;
  var sawGreeting = false;
  for (final word in words) {
    if (_greetingWords.contains(word)) {
      sawGreeting = true;
    } else if (!_supportingWords.contains(word)) {
      return false;
    }
  }
  return sawGreeting;
}
