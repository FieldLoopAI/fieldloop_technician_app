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

import 'camera_request_matcher.dart';
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

/// Build 175 (second pass) — Bob's cancel phrasings ("Hold on, forget the
/// photo for now.", "I've changed my mind", "not right now"). Same rule as
/// [_cancelCues]: they block only when no camera verb follows them, so
/// "Forget the photo, take a picture of the roof" still goes through.
const List<List<String>> _extendedCancelCues = [
  ['forget', 'the', 'photo'],
  ['forget', 'the', 'picture'],
  ['forget', 'about', 'the', 'photo'],
  ['forget', 'about', 'the', 'picture'],
  ['changed', 'my', 'mind'],
  ['not', 'right', 'now'],
  ['never', 'mind', 'the', 'photo'],
  ['never', 'mind', 'the', 'picture'],
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
/// [extendedCues]: also the build 175 second-pass cues
/// ([_extendedCancelCues]).
String? cameraActionNegation(String text, {bool extendedCues = true}) {
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
    for (final cue in [..._cancelCues, if (extendedCues) ..._extendedCancelCues]) {
      if (!cueAt(cue, i)) continue;
      final verbAfter = [for (var j = i + cue.length; j < words.length; j++) j].any(isVerb);
      if (!verbAfter) return cue.join(' ');
    }
  }
  return null;
}

/// Build 175 (second pass) — a camera cancel that names the camera but
/// asks for nothing ("Hold on, forget the photo for now."): no phrase
/// fires on it, so the guard above never ran, and the intent layer could
/// still open the camera (Gemini intent check) or take a photo (the live
/// "photo" shutter noun). Returns the blocking cue when [text] mentions a
/// camera/photo word AND [cameraActionNegation] blocks; `null` otherwise —
/// a bare "hold on"/"wait" (no camera word) is never one.
String? standaloneCameraCancel(String text, {bool extendedCues = true}) {
  if (matchLooseCameraRequest(text) == null) return null; // no camera/photo word at all
  return cameraActionNegation(text, extendedCues: extendedCues);
}

// --- Build 176 Step 2: word-order independent camera negation -----------
//
// b175 15:00:11 "Actually, I don't want to photo take now." with the camera
// live was kept as a photo note ("Noted."): [cameraActionNegation] only
// looks for a camera VERB after "do not" across filler, and "photo" (a noun)
// stopped that scan. [negatedCameraMention] takes the cue and the camera
// word in ANY order, and lets a real command said AFTER the cancellation
// ("Forget the photo, take a picture of the roof") through.

/// Camera nouns — always a camera word.
const Set<String> _b176CameraNouns = {
  'photo', 'photos', 'picture', 'pictures', 'pic', 'pics', 'shot', 'shots', 'camera', 'snapshot', 'image',
};

/// Camera verbs — the action a real command would ask for.
const Set<String> _b176CameraVerbs = {
  'take', 'taking', 'capture', 'snap', 'shoot', 'retake', 'reshoot', 'redo', 'grab', 'get', 'open',
};

/// Verbs that count as a camera word on their own (no noun) only while
/// the camera is up ("I don't want to take one" with the preview live);
/// elsewhere "take"/"capture" are too general ("don't take that off").
const Set<String> _b176ContextVerbs = {'take', 'taking', 'capture', 'snap', 'shoot', 'retake'};

/// Words a negation may reach across to the camera word it negates.
const Set<String> _b176NegationReach = {
  ..._negationFiller, 'a', 'an', 'the', 'this', 'that', 'one', 'another', 'now', 'right', 'yet', 'rather',
  'photo', 'picture', 'pic', 'shot', 'camera',
};

/// Words before "not" that make it a description, not a cancellation
/// ("this photo did not come out right").
const Set<String> _b176DescriptiveBeforeNot = {'did', 'does', 'is', 'was', 'are', 'were', 'has', 'had', 's'};

/// Cancel phrases (whole words, after [normalizeNegationText]).
const List<List<String>> _b176CancelPhrases = [
  ['never', 'mind'],
  ['nevermind'],
  ['forget'],
  ['hold', 'on'],
  ['changed', 'my', 'mind'],
  ['change', 'my', 'mind'],
  ['cancel'],
  ['stop'],
  ['no', 'longer'],
];

/// The cue when [text] cancels or refuses a camera action in any word
/// order — "Photo, I don't want to take one.", "Take a photo, no, forget
/// it.", "Not now, the photo can wait." — and nothing after the
/// cancellation asks for one again; `null` otherwise. Never blocks
/// without a camera word, or a sentence with only a descriptive "not"
/// ("No, that photo didn't come out right, let's retake it"), or a bare
/// "No, ..." ("No, this photo is dark."). [cameraUp]: the preview or a
/// captured photo is showing, so a bare "take"/"capture" is a camera word.
String? negatedCameraMention(String text, {bool cameraUp = false}) {
  final (:words, :boundaries) = normalizeNegationText(text);
  if (words.isEmpty) return null;
  bool isNoun(int i) => _b176CameraNouns.contains(words[i]);
  bool isCameraWord(int i) => isNoun(i) || (cameraUp && _b176ContextVerbs.contains(words[i]));
  if (![for (var i = 0; i < words.length; i++) i].any(isCameraWord)) return null;
  bool isVerb(int i) => _b176CameraVerbs.contains(words[i]);
  bool phraseAt(List<String> p, int i) {
    if (i + p.length > words.length) return false;
    for (var k = 0; k < p.length; k++) {
      if (words[i + k] != p[k]) return false;
    }
    return true;
  }

  // Each cue: where it starts and ends, and — for a negation ("do not",
  // "never", "rather not") — the verbs it covers in its own clause.
  String? firstCue;
  var lastCueEnd = -1;
  final covered = <int>{};
  for (var i = 0; i < words.length; i++) {
    String? cue;
    var end = i;
    var negation = false;
    // "do not forget to take a photo" is a request, not a cancel.
    final doNotForget = phraseAt(const ['do', 'not', 'forget'], i);
    if (doNotForget) {
      i += 2;
      continue;
    }
    for (final p in _b176CancelPhrases) {
      if (phraseAt(p, i)) {
        cue = p.join(' ');
        end = i + p.length - 1;
        break;
      }
    }
    if (cue == null) {
      if (words[i] == 'never') {
        cue = 'never';
        negation = true;
      } else if (words[i] == 'not' && (i == 0 || !_b176DescriptiveBeforeNot.contains(words[i - 1]))) {
        cue = i > 0 && words[i - 1] == 'do' ? 'do not' : (i > 0 && words[i - 1] == 'will' ? 'will not' : 'not');
        negation = true;
        // A bare "not" ("I'm not sure the photo is good") is a cue only when
        // it reaches a camera word, or is "not now / not yet".
        if (cue == 'not') {
          final next = i + 1 < words.length ? words[i + 1] : null;
          var reaches = next == 'now' || next == 'yet' || (i > 0 && (words[i - 1] == 'rather' || words[i - 1] == 'd'));
          for (var j = i + 1; !reaches && j < words.length && j <= i + 3 && !boundaries[j]; j++) {
            if (isCameraWord(j) || isVerb(j)) reaches = true;
            if (!_b176NegationReach.contains(words[j])) break;
          }
          if (!reaches) cue = null;
        }
      }
    }
    if (cue == null) continue;
    firstCue ??= cue;
    if (end > lastCueEnd) lastCueEnd = end;
    if (negation) {
      for (var j = i + 1, gap = 0; j < words.length && !boundaries[j] && gap <= 4; j++, gap++) {
        if (isVerb(j)) covered.add(j);
        if (!_b176NegationReach.contains(words[j]) && !isVerb(j)) break;
      }
    }
    i = end;
  }
  if (firstCue == null) return null;
  // A camera verb after the last cue that no negation covers is a real
  // command said after the cancellation — not blocked here.
  for (var j = lastCueEnd + 1; j < words.length; j++) {
    if (isVerb(j) && !covered.contains(j)) return null;
  }
  return firstCue;
}
