/// FIX 3 (6 Oct b173 logs, Part 2, 14:23:17) — "I don't want to take
/// photo." with the camera live fired capture_photo and took a photo; then
/// "I said I don't want to take photo." fired retake_photo.
///
/// Why the existing veto missed it: `trigger_phrase_matcher.dart` only
/// checks the ONE word right before a phrase ("don't take it"), and here
/// "want to" sits between "don't" and "take photo". This guard looks a few
/// words further back — but only across "want/need/to/…"-type filler, and
/// never across a clause boundary — so "Don't worry, take a photo" and
/// "No, this photo didn't look good" (no camera verb after the negation)
/// still go through untouched.
///
/// Build 174: text is normalized first (lowercase, punctuation stripped,
/// contractions expanded — "don't"/"dont" -> "do not"), and three more
/// shapes block: a cancel phrase with no camera verb after it ("forget it",
/// "not now", "stop"), and a negation that ends the utterance ("No, I
/// don't.").
///
/// It only ever BLOCKS open_camera / capture_photo / retake_photo; it
/// never fires anything itself.
library;

import 'trigger_phrase_matcher.dart';

/// Contractions expanded before matching, keyed by their token form after
/// [tokenizeTriggerText] (the apostrophe becomes a space: "don't" ->
/// "don t"; STT also drops it: "dont").
const Map<String, List<String>> _contractions = {
  'don t': ['do', 'not'],
  'dont': ['do', 'not'],
  'didn t': ['did', 'not'],
  'didnt': ['did', 'not'],
  'won t': ['will', 'not'],
  'wont': ['will', 'not'],
};

/// Negation cues, on expanded tokens.
const List<List<String>> _negationCues = [
  ['do', 'not'],
  ['did', 'not'],
  ['will', 'not'],
  ['never'],
];

/// Words allowed between a negation and the camera verb ("I don't WANT TO
/// take", "do not NEED TO open", "don't YOU take").
const Set<String> _negationFiller = {
  'want', 'wanna', 'to', 'need', 'i', 'you', 'we', 'me', 'it', 'please', 'just', 'really', 'have', 'gonna',
  'going', 'even', 'any', 'more',
};

/// Max filler words between the negation and the verb.
const int _maxFillerWords = 3;

/// Camera action verbs (compared by stem, so "taking"/"takes" count).
final Set<String> _cameraVerbStems = {
  for (final v in const ['take', 'snap', 'capture', 'shoot', 'open', 'retake', 'redo', 'reshoot', 'click', 'grab'])
    stemTriggerWord(v),
};

/// Phrases that cancel whatever camera action came before them — blocking
/// only when no camera verb follows ("Never mind, take a photo" is a
/// correction followed by a real request and still goes through).
const List<List<String>> _cancelCues = [
  ['never', 'mind'],
  ['nevermind'],
  ['cancel', 'that'],
  ['cancel', 'it'],
  ['forget', 'it'],
  ['forget', 'that'],
  ['not', 'now'],
  ['stop'],
];

/// [text] lowercased, punctuation stripped, contractions expanded, with
/// whether a clause boundary (comma, period, dash…) comes before each word.
({List<String> words, List<bool> boundaries}) normalizeNegationText(String text) {
  final raw = tokenizeTriggerText(text);
  final rawBoundaries = clauseBoundariesBefore(text);
  bool boundaryAt(int i) => i < rawBoundaries.length && rawBoundaries[i];
  final words = <String>[];
  final boundaries = <bool>[];
  for (var i = 0; i < raw.length; i++) {
    final pair = i + 1 < raw.length ? '${raw[i]} ${raw[i + 1]}' : null;
    final expanded = (pair != null ? _contractions[pair] : null) ?? _contractions[raw[i]];
    if (expanded == null) {
      words.add(raw[i]);
      boundaries.add(boundaryAt(i));
      continue;
    }
    for (var k = 0; k < expanded.length; k++) {
      words.add(expanded[k]);
      boundaries.add(k == 0 && boundaryAt(i));
    }
    if (pair != null && _contractions.containsKey(pair)) i++;
  }
  return (words: words, boundaries: boundaries);
}

/// The cue that blocks a camera action in [text] ("do not ... take",
/// "never mind", "do not (end)"), or `null` when nothing does.
String? cameraActionNegation(String text) {
  final (:words, :boundaries) = normalizeNegationText(text);
  if (words.isEmpty) return null;
  bool isVerb(int i) => _cameraVerbStems.contains(stemTriggerWord(words[i]));
  bool cueAt(List<String> cue, int i) {
    if (i + cue.length > words.length) return false;
    for (var k = 0; k < cue.length; k++) {
      if (words[i + k] != cue[k]) return false;
    }
    return true;
  }

  for (var i = 0; i < words.length; i++) {
    for (final cue in _negationCues) {
      if (!cueAt(cue, i)) continue;
      // "never mind" is a cancel cue, not "never <verb>".
      if (cue.length == 1 && cue.first == 'never' && i + 1 < words.length && words[i + 1] == 'mind') continue;
      var j = i + cue.length;
      var filler = 0;
      while (j < words.length && !boundaries[j]) {
        if (isVerb(j)) return '${cue.join(' ')} ... ${words[j]}';
        if (!_negationFiller.contains(words[j]) || ++filler > _maxFillerWords) break;
        j++;
      }
      // "No, I don't." / "I do not want to." — the negation ends the
      // utterance with nothing but filler after it.
      if (j == words.length && cue.first == 'do') return '${cue.join(' ')} (end)';
    }
    for (final cue in _cancelCues) {
      if (!cueAt(cue, i)) continue;
      final verbAfter = [for (var j = i + cue.length; j < words.length; j++) j].any(isVerb);
      if (!verbAfter) return cue.join(' ');
    }
  }
  return null;
}
