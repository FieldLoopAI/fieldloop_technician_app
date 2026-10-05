/// "I have a question" — an utterance announcing that a question is coming,
/// with none of the question itself in it. 98284112 log: "one question"
/// fell through every matcher, waited out the camera-intent check, and was
/// sent to the knowledge base as the literal query (then timed out) — for
/// something that was never a question at all.
///
/// Deliberately a whole-utterance test, not a phrase search: EVERY word must
/// be announcement vocabulary, so "I have a question about the water
/// heater" (real content) is not an announcement and still reaches the KB
/// normally, while "one question", "quick question", "I've got a question",
/// "question for you", "can I ask you something" are.
library;

import 'trigger_phrase_matcher.dart';

/// Words an announcement is made of (apostrophes split, so "I've" arrives as
/// "i" + "ve").
const Set<String> _announcementWords = {
  'i', 've', 'd', 'have', 'got', 'a', 'an', 'one', 'quick', 'small', 'little', 'more', 'another', 'just', 'hey',
  'so', 'okay', 'ok', 'um', 'uh', 'can', 'could', 'may', 'might', 'ask', 'you', 'something', 'question',
  'questions', 'for', 'like', 'to', 'want', 'wanna', 'let', 'me', 'real',
};

bool isQuestionAnnouncement(String text) {
  final words = tokenizeTriggerText(text);
  if (words.isEmpty || words.length > 8) return false;
  if (!words.every(_announcementWords.contains)) return false;
  final namesQuestion = words.contains('question') || words.contains('questions');
  final asksToAsk = words.contains('ask') && (words.contains('something') || words.contains('you'));
  return namesQuestion || asksToAsk;
}
