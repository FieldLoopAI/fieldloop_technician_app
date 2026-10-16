/// Build 184 Change B (ANOTHER_ONE_CAPTURE) and Change C
/// (YES_CAPTURE_ROUTING), camera live and armed only.
///
/// B — b183: "Take another one", "Take one" and "Click" captured only when
/// the Gemini intent check answered capture_photo (no deterministic
/// phrase). [anotherOneCapturePhrases] capture directly, but only as the
/// WHOLE utterance (optionally "please"/"okay" before, "now" after), so a
/// negation ("don't take another one"), a question ("should I take another
/// one?") or a longer sentence ("take one more step back") never matches.
/// Checked on the finished utterance, not per chunk, for the same reason.
///
/// C — b183: "Yes, take another one" (4 words) was kept as a C13 photo note
/// ("Noted.") before the photo-offer answer could see it. [yesCaptureRest]
/// strips one leading yes/yeah/yep/okay/ok/sure; the screen captures only
/// when the rest is itself a live-camera capture phrase.
///
/// Pure Dart and deterministic: no network, no Gemini call.
library;

import 'trigger_phrase_matcher.dart';

/// Whole-utterance capture phrases (camera live only).
const List<String> anotherOneCapturePhrases = [
  'take another one',
  'take another',
  'take another photo',
  'take another picture',
  'take one more',
  'one more photo',
  'take one',
  'click',
  'snap another one',
  'snap another',
  'shoot another one',
];

/// Allowed before the phrase.
const Set<String> anotherOneLeadIns = {'please', 'okay', 'ok'};

/// Allowed after the phrase.
const Set<String> anotherOneTails = {'now'};

/// The [anotherOneCapturePhrases] entry [text] is, or null.
String? matchAnotherOneCapture(String text) {
  if (text.contains('?')) return null;
  var words = tokenizeTriggerText(text);
  while (words.isNotEmpty && anotherOneLeadIns.contains(words.first)) {
    words = words.sublist(1);
  }
  if (words.isNotEmpty && anotherOneTails.contains(words.last)) words = words.sublist(0, words.length - 1);
  final core = words.join(' ');
  return anotherOneCapturePhrases.contains(core) ? core : null;
}

/// Change C — the first word that makes "yes, take another one" a yes.
const Set<String> yesCaptureLeadWords = {'yes', 'yeah', 'yep', 'okay', 'ok', 'sure'};

final RegExp _firstWord = RegExp(r'^[^A-Za-z]*([A-Za-z]+)[^A-Za-z]*');

/// The text after a leading [yesCaptureLeadWords] word ("Yes, take another
/// one" -> "take another one"), or null when it doesn't start with one or
/// nothing follows.
String? yesCaptureRest(String text) {
  final m = _firstWord.firstMatch(text);
  if (m == null || !yesCaptureLeadWords.contains(m.group(1)!.toLowerCase())) return null;
  final rest = text.substring(m.end).trim();
  return tokenizeTriggerText(rest).isEmpty ? null : rest;
}
