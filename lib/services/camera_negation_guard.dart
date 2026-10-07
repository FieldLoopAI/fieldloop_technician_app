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
/// It only ever BLOCKS open_camera / capture_photo / retake_photo; it
/// never fires anything itself.
library;

import 'trigger_phrase_matcher.dart';

/// Negation cues, as token sequences after [tokenizeTriggerText] (the
/// apostrophe becomes a space: "don't" -> "don t").
const List<List<String>> _negationCues = [
  ['don', 't'],
  ['dont'],
  ['do', 'not'],
  ['didn', 't'],
  ['did', 'not'],
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

/// Phrases that cancel whatever camera action came before them.
const List<List<String>> _cancelCues = [
  ['never', 'mind'],
  ['nevermind'],
  ['cancel', 'that'],
];

/// The cue that blocks a camera action in [text] ("don't ... take",
/// "never mind"), or `null` when nothing does.
///
/// A cancel cue ("never mind", "cancel that") blocks only when no camera
/// verb follows it — "Never mind, take a photo" is a correction followed
/// by a real request and still goes through.
String? cameraActionNegation(String text) {
  final words = tokenizeTriggerText(text);
  if (words.isEmpty) return null;
  final boundaries = clauseBoundariesBefore(text);
  bool boundaryBefore(int i) => i < boundaries.length && boundaries[i];
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
      while (j < words.length && !boundaryBefore(j)) {
        if (isVerb(j)) return '${cue.join(' ').replaceAll(' t', "'t")} ... ${words[j]}';
        if (!_negationFiller.contains(words[j]) || ++filler > _maxFillerWords) break;
        j++;
      }
    }
    for (final cue in _cancelCues) {
      if (!cueAt(cue, i)) continue;
      final verbAfter = [for (var j = i + cue.length; j < words.length; j++) j].any(isVerb);
      if (!verbAfter) return cue.join(' ');
    }
  }
  return null;
}
