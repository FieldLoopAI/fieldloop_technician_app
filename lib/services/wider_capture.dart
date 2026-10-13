/// Build 179 item C — more ways to say "take the photo" (camera live) and
/// "open the camera" (camera closed). Only ADDS matches; every existing
/// phrase list and rule in `gemini_live_test_screen.dart` still runs first.
///
/// The "ready" / "go ahead" rule: b178 counted tokens of the stemmed text
/// (an apostrophe adds one), so "Yes, I'm ready" and "I'm ready now" (4
/// tokens) fell through, while "are you ready" and "not ready" (≤3 tokens)
/// would have fired. Here punctuation and filler words (yes, okay, I'm,
/// now, ...) are removed BEFORE counting, up to [widerReadyMaxContentWords]
/// content words are allowed, and negations and questions never capture.
///
/// Pure Dart and deterministic: no network, no Gemini call.
library;

import 'trigger_phrase_matcher.dart';

/// `--dart-define=WIDER_CAPTURE_PHRASES=false` turns item C off.
const bool kWiderCapturePhrases = bool.fromEnvironment('WIDER_CAPTURE_PHRASES', defaultValue: true);

const int widerReadyMaxContentWords = 5;

/// Dropped before counting (single words; "I'm"/"we're"/"I'd" arrive as two
/// tokens and are handled in [_fillerPairs]).
const Set<String> _readyFillerWords = {'yes', 'yeah', 'yep', 'okay', 'ok', 'alright', 'so', 'now', 'please'};

const List<List<String>> _fillerPairs = [
  ['i', 'm'],
  ['i', 'am'],
  ['we', 're'],
  ['we', 'are'],
  ['i', 'd'],
  ['all', 'right'],
];

/// Any of these anywhere: never a capture.
const Set<String> _vetoWords = {'not', 'never', 'no', 'wait', 'stop', 'dont', 'nope'};
const List<List<String>> _vetoPairs = [
  ['don', 't'],
  ['hold', 'on'],
  ['hang', 'on'],
  ['not', 'yet'],
  ['one', 'second'],
  ['a', 'second'],
  ['one', 'sec'],
  ['a', 'sec'],
  ['one', 'moment'],
  ['a', 'moment'],
  ['a', 'minute'],
];

/// A first word that makes it a question ("are you ready").
const Set<String> _questionOpeners = {
  'are', 'is', 'am', 'do', 'does', 'did', 'can', 'could', 'will', 'would', 'should', 'what', 'when', 'where',
  'why', 'how', 'who', 'which',
};

/// Question words anywhere ("ready for what").
const Set<String> _questionWords = {'what', 'why', 'how', 'when', 'where', 'who', 'which'};

/// Whole-utterance shutter words, camera live only ("go", "now", "shoot").
/// Matched after dropping yes/yeah/okay/ok/alright/so/please.
const Set<String> widerShutterUtterances = {
  'go', 'now', 'go now', 'shoot', 'shoot now', 'do it', 'do it now', 'take it now', 'go for it',
};

const Set<String> _shutterFillerWords = {'yes', 'yeah', 'yep', 'okay', 'ok', 'alright', 'so', 'please'};

/// Added open-camera phrasings (camera closed). Matched with the shared
/// trigger matcher, so its stemming, one-filler gap and negation veto apply.
/// The "sort of" entries are the b178 ASR mishear of "get a shot of that"
/// (log 14:37:18: "Can you get sort of that for me?") — ONLY with the verb,
/// never bare "sort of".
const List<String> widerOpenCameraPhrases = [
  'i d like a photo',
  'i d like a picture',
  'i want a photo',
  'i want a picture',
  'i need a picture',
  'let s take a photo',
  'let s take a picture',
  'let s get a photo',
  'let s get a picture',
  'can i get a photo',
  'can i get a picture',
  'get a shot of that',
  'get a shot of this',
  'take a shot of this',
  'take a shot of that',
  'grab a photo',
  'grab a picture',
  'photo please',
  'picture please',
  'get sort of that',
  'get sort of this',
  'grab sort of that',
  'grab sort of this',
  'take sort of that',
  'take sort of this',
];

sealed class WiderCaptureResult {
  const WiderCaptureResult();
}

class WiderCaptureMatch extends WiderCaptureResult {
  const WiderCaptureMatch(this.phrase, this.via);
  final String phrase;

  /// ready_rule | phrase_list
  final String via;
}

class WiderCaptureBlocked extends WiderCaptureResult {
  const WiderCaptureBlocked(this.reason);

  /// negation | question
  final String reason;
}

bool _hasPair(List<String> words, List<String> pair) {
  for (var i = 0; i + 1 < words.length; i++) {
    if (words[i] == pair[0] && words[i + 1] == pair[1]) return true;
  }
  return false;
}

List<String> _dropFillers(List<String> words) {
  final out = <String>[];
  for (var i = 0; i < words.length; i++) {
    final next = i + 1 < words.length ? words[i + 1] : null;
    if (next != null && _fillerPairs.any((p) => p[0] == words[i] && p[1] == next)) {
      i++;
      continue;
    }
    if (_readyFillerWords.contains(words[i])) continue;
    out.add(words[i]);
  }
  return out;
}

/// Camera live and confirmed: does [text] ask for the shutter? Covers the
/// ready/go-ahead rule and [widerShutterUtterances]. Returns null when it
/// has nothing to do with them.
WiderCaptureResult? matchWiderCapture(String text) {
  final words = tokenizeTriggerText(text);
  if (words.isEmpty) return null;
  final padded = ' ${words.join(' ')} ';
  final mentionsReady = words.contains('ready') || padded.contains(' go ahead ');
  final shutterCore = words.where((w) => !_shutterFillerWords.contains(w)).join(' ');
  final isShutterUtterance = widerShutterUtterances.contains(shutterCore);
  if (!mentionsReady && !isShutterUtterance) return null;

  if (words.any(_vetoWords.contains) || _vetoPairs.any((p) => _hasPair(words, p))) {
    return const WiderCaptureBlocked('negation');
  }
  if (text.contains('?')) return const WiderCaptureBlocked('question');
  // A whole-utterance shutter word is already an exact command ("do it" —
  // its "do" is not a question opener here).
  if (isShutterUtterance) return WiderCaptureMatch(shutterCore, 'phrase_list');
  final firstContent = _dropFillers(words).firstOrNull;
  if ((firstContent != null && _questionOpeners.contains(firstContent)) || words.any(_questionWords.contains)) {
    return const WiderCaptureBlocked('question');
  }
  final content = _dropFillers(words);
  if (content.length > widerReadyMaxContentWords) return null;
  return WiderCaptureMatch(words.contains('ready') ? 'ready' : 'go ahead', 'ready_rule');
}

/// Camera closed: one of [widerOpenCameraPhrases], or null.
String? matchWiderOpenCamera(String text) => matchAnyTriggerPhrase(text, widerOpenCameraPhrases)?.phrase;
