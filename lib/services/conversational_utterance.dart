/// Tells ordinary conversational back-and-forth apart from real requests,
/// for utterances nothing else matched — so a reaction like "No, this
/// provision looks good" gets a quick in-character reply instead of a
/// 13-second knowledge-base round trip that can only ever come back "not
/// available" (CONFIRMED in a real trace).
///
/// POSITIVE EVIDENCE ONLY. An utterance is classified conversational only
/// when it clearly is one — a greeting, or a reaction/acknowledgment phrase
/// with no question, request or problem wording anywhere in it. Everything
/// else returns [SmallTalkKind.none] and keeps going to the knowledge base
/// exactly as before, so a real trade/technical question can never be
/// diverted away from it by this: question words, "?", request verbs and
/// problem words each veto the conversational reading on their own.
///
/// Covers English plus the languages Gemini's recognizer has actually drifted
/// into for this app's technicians (Spanish in one real trace) and the
/// romanized Hindi acknowledgments they commonly use ("haan", "theek hai").
library;

enum SmallTalkKind {
  /// Not clearly conversational — route as before (knowledge base).
  none,

  /// A greeting / "can you hear me" — same reply as acknowledge_presence.
  greeting,

  /// A reaction or acknowledgment ("looks good", "that works", "vale").
  reaction,
}

/// Greeting words that are a greeting on their own ("hello", "hola").
const Set<String> _greetingStrong = {
  'hello', 'hi', 'hey', 'hiya', 'howdy', 'hola', 'buenas', 'buenos', 'oye', 'escuchas', 'oyes', 'namaste',
  'namaskar', 'testing',
};

/// Greeting cues that need company ("good morning", "can you hear me",
/// "are you there") — a bare "there" is not a greeting.
const Set<String> _greetingWeak = {'morning', 'afternoon', 'evening', 'hear', 'there', 'ahi'};

/// Filler allowed around a greeting; means nothing on its own.
const Set<String> _greetingSupport = {
  'good', 'can', 'you', 'me', 'are', 'still', 'anyone', 'do', 'did', 'ji', 'dias', 'tardes', 'noches', 'estas',
  'the', 'is', 'just', 'so',
};

/// Reaction / acknowledgment phrases, matched as whole words on normalized
/// text.
const List<String> _reactionMarkers = [
  // English
  'looks good', 'look good', 'looks fine', 'looks great', 'looks right', 'looks okay', 'looks ok', 'looks nice',
  'that s good', 'thats good', 'that s fine', 'thats fine', 'that s great', 'that s perfect', 'that s right',
  'that works', 'sounds good', 'sounds great', 'all good', 'got it', 'perfect', 'great', 'awesome', 'nice',
  'cool', 'thanks', 'thank you', 'no problem', 'never mind', 'nevermind', 'understood', 'makes sense',
  'fair enough', 'okay', 'ok', 'alright', 'all right', 'good', 'fine',
  // Spanish
  'si', 'vale', 'bueno', 'bien', 'gracias', 'perfecto', 'claro', 'de acuerdo', 'esta bien', 'listo',
  // Romanized Hindi
  'haan', 'theek hai', 'thik hai', 'theek', 'thik', 'accha', 'acha', 'achha', 'chalo', 'shukriya',
  'dhanyavaad', 'dhanyavad',
];

/// Any of these means the utterance asks for or reports something — never
/// conversational, whatever else it contains.
const Set<String> _vetoWords = {
  // Question words (English, Spanish, Hindi)
  'what', 'whats', 'how', 'hows', 'why', 'when', 'where', 'which', 'who', 'whose', 'whom',
  'que', 'como', 'cuando', 'donde', 'cual', 'quien', 'porque', 'kya', 'kaise', 'kyun', 'kab', 'kahan', 'kaun',
  // Request verbs
  'tell', 'explain', 'show', 'open', 'take', 'find', 'check', 'need', 'want', 'give', 'help', 'send', 'call',
  'search', 'read', 'put', 'make', 'start', 'stop', 'cancel', 'delete', 'add', 'note', 'log', 'record',
  'retake', 'keep', 'capture', 'upload', 'confirm',
  // Problem / symptom words — a technician describing an issue expects help
  'leak', 'leaking', 'leaks', 'broken', 'broke', 'break', 'trip', 'trips', 'tripped', 'tripping', 'noise',
  'noisy', 'smell', 'smells', 'fault', 'error', 'problem', 'issue', 'issues', 'wrong', 'working', 'stuck',
  'failed', 'failing', 'damaged', 'damage', 'burnt', 'burning', 'overheating', 'hot', 'cold', 'wet',
};

/// Multi-word requests that [_vetoWords] can't express one word at a time.
const List<String> _vetoPhrases = ['look up', 'look at', 'look into', 'not working', 'doesn t work', 'won t'];

/// Acknowledgments whose words would otherwise trip [_vetoWords].
const List<String> _vetoExemptPhrases = ['no problem'];

/// Reactions are short; anything longer is left to the existing routing.
const int _maxReactionWords = 10;

/// Lowercase, fold common accents, letters only — apostrophes become a
/// space, the same way every other matcher in this app normalizes.
List<String> _normalizedWords(String text) {
  const folds = {'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ü': 'u', 'ñ': 'n'};
  final buffer = StringBuffer();
  for (final char in text.toLowerCase().split('')) {
    buffer.write(folds[char] ?? char);
  }
  return buffer
      .toString()
      .replaceAll(RegExp('[^a-z ]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
}

bool _containsPhrase(List<String> words, String phrase) =>
    ' ${words.join(' ')} '.contains(' $phrase ');

SmallTalkKind classifySmallTalk(String text) {
  final words = _normalizedWords(text);
  if (words.isEmpty) return SmallTalkKind.none;

  // Greeting: nothing but greeting words, with a strong cue, or a weak one
  // in company.
  final allGreetingWords = words.every(
    (w) => _greetingStrong.contains(w) || _greetingWeak.contains(w) || _greetingSupport.contains(w),
  );
  if (allGreetingWords &&
      (words.any(_greetingStrong.contains) || (words.length >= 2 && words.any(_greetingWeak.contains)))) {
    return SmallTalkKind.greeting;
  }

  if (words.length > _maxReactionWords) return SmallTalkKind.none;
  if (text.contains('?') || text.contains('¿')) return SmallTalkKind.none;
  var vetoText = ' ${words.join(' ')} ';
  for (final exempt in _vetoExemptPhrases) {
    vetoText = vetoText.replaceAll(' $exempt ', ' ');
  }
  final vetoWords = vetoText.split(' ').where((w) => w.isNotEmpty).toList();
  if (vetoWords.any(_vetoWords.contains) || _vetoPhrases.any((p) => _containsPhrase(vetoWords, p))) {
    return SmallTalkKind.none;
  }
  if (_reactionMarkers.any((marker) => _containsPhrase(words, marker))) return SmallTalkKind.reaction;
  return SmallTalkKind.none;
}
