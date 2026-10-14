/// Build 179 item D — local "no photo" / "not now" / "skip it" declines.
///
/// b178 (log 14:48:34): "No photo for now." with the camera closed matched
/// nothing locally, waited 900 ms on the Gemini intent check, then went to
/// the knowledge base ("One moment, checking that."); with the camera live
/// it got a clarification. The negation guards miss it because "no" is not
/// a cancel cue (`camera_negation_guard.dart`).
///
/// A decline answers "Okay." and never opens the camera; with the camera
/// live it also closes the camera through the existing go-back camera path.
///
/// Whole-utterance only: after dropping filler words, the utterance must be
/// a decline phrase, optionally followed by one short tail ("for now",
/// "right now", "yet"). Pure Dart and deterministic.
library;

import 'trigger_phrase_matcher.dart';

/// `--dart-define=WIDER_CLOSE_DECLINE_PHRASES=false` turns item D off.
const bool kWiderCloseDeclinePhrases = bool.fromEnvironment('WIDER_CLOSE_DECLINE_PHRASES', defaultValue: true);

const List<String> photoDeclinePhrases = [
  'no photo',
  'no photo for now',
  'no picture',
  'no photos right now',
  'not now',
  'not right now',
  'skip the photo',
  'skip photo',
  'skip it',
  'no thanks',
  'no thank you',
  'maybe later',
  'never mind the photo',
  'forget the photo',
  // Same phrases with the other nouns (additions only).
  'no photos',
  'no pictures',
  'no picture for now',
  'skip the picture',
  'never mind the picture',
  'forget the picture',
];

/// Build 180 item E — `--dart-define=WIDER_DECLINE_B180=false` turns these
/// additions off.
const bool kWiderDeclineB180 = bool.fromEnvironment('WIDER_DECLINE_B180', defaultValue: true);

/// Build 180 item E — more declines, same whole-utterance / tail / leading-
/// filler rules (b178: "Actually I don't want to take now." fell through to
/// a clarification). Tokenized ("don't" -> "don t"). "actually" is already
/// dropped as filler, so "Actually I don't want to take now." matches
/// 'i don t want to take now'. "skip the picture" and "no picture for now"
/// are already in [photoDeclinePhrases].
const List<String> photoDeclinePhrasesB180 = [
  'i don t want to take one',
  'i don t want to take a photo',
  'i don t want to take a picture',
  'i don t want a photo',
  'i don t want a picture',
  'i don t want to take now',
  'no i don t want to take one',
  'i don t need a photo',
  'not taking a photo',
];

/// The phrases [matchPhotoDecline] uses: build 179's, plus build 180's when
/// [b180] is on.
List<String> activePhotoDeclinePhrases({bool b180 = kWiderDeclineB180}) =>
    b180 ? [...photoDeclinePhrases, ...photoDeclinePhrasesB180] : photoDeclinePhrases;

const Set<String> _fillerWords = {'um', 'umm', 'uh', 'okay', 'ok', 'well', 'so', 'actually', 'please', 'just'};

const List<List<String>> _leadingFillerPairs = [
  ['hold', 'on'],
  ['hang', 'on'],
];

const List<List<String>> _allowedTails = [
  ['for', 'now'],
  ['right', 'now'],
  ['now'],
  ['yet'],
  ['then'],
  ['thanks'],
  ['today'],
];

bool _startsWith(List<String> words, List<String> prefix) {
  if (prefix.length > words.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (words[i] != prefix[i]) return false;
  }
  return true;
}

/// The decline phrase [text] consists of, or null.
String? matchPhotoDecline(String text, {bool b180 = kWiderDeclineB180}) {
  var words = tokenizeTriggerText(text).where((w) => !_fillerWords.contains(w)).toList();
  for (final pair in _leadingFillerPairs) {
    if (_startsWith(words, pair)) words = words.sublist(pair.length);
  }
  if (words.isEmpty) return null;
  // Longest phrase first, so "no photo for now" is reported as itself.
  final phrases = [...activePhotoDeclinePhrases(b180: b180)]..sort((a, b) => b.length.compareTo(a.length));
  for (final phrase in phrases) {
    final p = phrase.split(' ');
    if (!_startsWith(words, p)) continue;
    final rest = words.sublist(p.length);
    if (rest.isEmpty) return phrase;
    for (final tail in _allowedTails) {
      if (rest.length == tail.length && _startsWith(rest, tail)) return phrase;
    }
  }
  return null;
}
