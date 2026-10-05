/// Recognizes an utterance that names Job Details (the job's main/home
/// screen) as an explicit DESTINATION — "take me back to the job screen",
/// "show me the job screen", "go home" — as opposed to a plain "go back",
/// which means "one screen back", whatever that screen is.
///
/// 1b059096 log: "Take me back to the job screen." on the Invoice screen
/// matched go_back's "take me back" and popped ONE screen — to Change
/// Orders, which is what was underneath — then said "Okay, I've taken you
/// back." as if it had worked. "Show me the job screen." matched nothing at
/// all. The back stack itself was right both times; the destination the
/// technician named was simply never read.
///
/// Two ways to match, both negation-aware (via `trigger_phrase_matcher`):
///  - a self-contained destination phrase ("go home", "back to the job"),
///  - or a destination NOUN ("job screen", "main screen", "job details")
///    together with a navigation verb anywhere in the utterance that isn't
///    itself negated. A bare "job details" with no verb is left alone — that
///    is get_job_details' "tell me about this job" territory.
library;

import 'trigger_phrase_matcher.dart';

/// Complete on their own: they already say "go there".
const List<String> jobDetailsDestinationPhrases = [
  'go home',
  'take me home',
  'head home',
  'back home',
  'back to home',
  'go to the job',
  'back to the job',
  'return to the job',
  'back to job details',
  'go to job details',
];

/// Names of the Job Details screen.
const List<String> jobDetailsDestinationNouns = [
  'job details',
  'job detail',
  'job details screen',
  'job screen',
  'job page',
  'details screen',
  'details page',
  'job overview',
  'main screen',
  'main page',
  'home screen',
  'home page',
  'job home',
];

/// Navigation verbs that, next to a destination noun, make it a request to
/// go there.
const List<String> _navigationVerbs = [
  'go', 'take', 'back', 'return', 'show', 'open', 'bring', 'switch', 'head', 'jump', 'navigate', 'pull', 'see',
  'view', 'move', 'get me', 'lead',
];

class DestinationMatch {
  const DestinationMatch(this.how);

  /// Which phrase/noun+verb matched — for the log.
  final String how;
}

/// "Which screen am I on?" in any word order. 1b059096 log (u=25): "By the
/// way, we are on which screen?" — the get_current_screen phrase list only
/// held fixed orders ("which screen are we on", "which screen we are on"),
/// so the question-word-last form matched none and went to clarification.
/// Structural instead: a screen/page noun, a which/what, and a cue that
/// it's about where they are NOW ("on", "this", "am I", "are we",
/// "current"). Anything with a navigation verb ("what screen should I go
/// to", "which page shows the estimate") is a different question.
bool looksLikeCurrentScreenQuestion(String text) {
  final words = tokenizeTriggerText(text);
  if (words.isEmpty || words.length > 14) return false;
  final hasScreenNoun = words.any((w) => w == 'screen' || w == 'page');
  if (!hasScreenNoun) return false;
  if (!words.any((w) => w == 'which' || w == 'what')) return false;
  final wordSet = words.toSet();
  final aboutNow = wordSet.contains('on') ||
      wordSet.contains('this') ||
      wordSet.contains('current') ||
      wordSet.contains('currently') ||
      (wordSet.contains('right') && wordSet.contains('now')) ||
      (wordSet.contains('am') && wordSet.contains('i')) ||
      (wordSet.contains('are') && wordSet.contains('we')) ||
      (wordSet.contains('we') && wordSet.contains('re')) ||
      (wordSet.contains('i') && wordSet.contains('m'));
  if (!aboutNow) return false;
  const navigationWords = {
    'show', 'shows', 'opens', 'take', 'go', 'going', 'switch', 'navigate', 'bring', 'pull', 'has', 'have',
    'should', 'find',
  };
  return !words.any(navigationWords.contains);
}

/// The Job Details destination named in [text], or null.
DestinationMatch? matchJobDetailsDestination(String text) {
  final phrase = matchAnyTriggerPhrase(text, jobDetailsDestinationPhrases);
  if (phrase != null) return DestinationMatch('phrase "${phrase.phrase}"');

  final noun = matchAnyTriggerPhrase(text, jobDetailsDestinationNouns);
  if (noun == null) return null;
  final padded = stemmedPaddedTriggerText(text);
  for (final verb in _navigationVerbs) {
    if (!padded.contains(' ${stemTriggerPhrase(verb)} ')) continue;
    if (triggerPhraseIsNegated(text, verb)) continue;
    return DestinationMatch('destination "${noun.phrase}" + verb "$verb"');
  }
  return null;
}
