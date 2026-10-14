/// Build 180 item C — "not ready" / "hold on" with the camera up get "Okay."
///
/// b179 part 3, camera live: "Not ready." got "I didn't catch that. The
/// camera's open — say 'capture it' when you're set." 3.4s later (700ms
/// settle + 900ms intent check + a generated line), and "Hold on." let the
/// tail of Gemini's own reply play (" to proceed." right after "PREEMPTIVE
/// DEFAULT MUTE: cleared silently", 15:35:47.254). Here they are answered
/// locally: the camera stays as it is, nothing is captured, the reply is
/// "Okay." (the decline line, so the same clip), and the utterance is
/// resolved so the intent check, KB catch-all, clarification and filler
/// un-mute do not run for it.
///
/// Camera live or opening only — never Job Detail, a photo note, or while
/// the close question is pending. Whole utterance only, at most
/// [waitHoldMaxWords] words after filler; a question never matches.
///
/// Pure Dart and deterministic: no network, no Gemini call.
library;

import 'trigger_phrase_matcher.dart';

/// `--dart-define=WAIT_HOLD_INTENT=false` turns item C off.
const bool kWaitHoldIntent = bool.fromEnvironment('WAIT_HOLD_INTENT', defaultValue: true);

const int waitHoldMaxWords = 6;

/// Whole-utterance phrases, tokenized ("i'm" -> "i m").
const List<String> waitHoldPhrases = [
  'not ready',
  'not ready yet',
  'i am not ready',
  'i m not ready',
  'not yet',
  'hold on',
  'hang on',
  'wait',
  'wait a second',
  'wait a minute',
  'one second',
  'just a second',
  'give me a second',
  'give me a minute',
  'hold on a second',
];

/// Dropped before matching ("Okay, hold on.", "Um, not yet").
const Set<String> _fillerWords = {'um', 'umm', 'uh', 'uhh', 'okay', 'ok', 'so', 'well', 'please', 'actually', 'hey'};

/// The wait phrase [text] consists of, or null. A question (`?`) never
/// matches, and neither does anything longer than [waitHoldMaxWords] words
/// after filler.
String? matchWaitHold(String text) {
  if (text.contains('?')) return null;
  final words = tokenizeTriggerText(text).where((w) => !_fillerWords.contains(w)).toList();
  if (words.isEmpty || words.length > waitHoldMaxWords) return null;
  final joined = words.join(' ');
  for (final phrase in waitHoldPhrases) {
    if (joined == phrase) return phrase;
  }
  return null;
}

/// Where the wait intent applies: the camera live or opening, no photo
/// note on screen, no close question waiting for its yes/no.
bool waitHoldApplies({
  required bool cameraLiveOrOpening,
  required bool photoNoteActive,
  required bool closeQuestionPending,
}) =>
    cameraLiveOrOpening && !photoNoteActive && !closeQuestionPending;
