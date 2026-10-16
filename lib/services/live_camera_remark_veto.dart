/// Build 183 Change A (LIVE_CAMERA_REMARK_VETO) — b182 device log: with the
/// camera live, "I like the photo." took a photo ("FUZZY LIVE-CAMERA MATCH
/// noun=photo -> capture_photo"). The b182 FUZZY_REMARK_VETO only covers
/// open_camera; this is the capture_photo side, for the live-camera fuzzy
/// path (and the Gemini intent check's answer) ONLY. The exact/strong
/// capture matchers (phrase list, shutter words, wider capture) run per
/// chunk before either of those and are not touched.
///
/// A remark = an opinion word ([liveRemarkOpinionWords]) AND none of the
/// command words ([liveRemarkCommandWords], "one more", the request
/// markers). Anything with a command word keeps today's behavior, so the
/// rule can only ever remove a capture from an utterance that has no verb
/// asking for one. Separate lists on purpose: no existing list is edited.
///
/// Pure Dart and deterministic: no network, no Gemini call.
library;

import 'trigger_phrase_matcher.dart';

/// Opinion / description words ("that LOOKS good", "the photo IS blurry").
const Set<String> liveRemarkOpinionWords = {
  'like', 'love', 'nice', 'good', 'great', 'fine', 'blurry', 'dark', 'bright', 'looks', 'looking', 'is', 'was',
  'seems',
};

/// Any of these makes it a command, never a remark ("take", "snap",
/// "another", "yes", "do it", "go", "now", "please", ...).
const Set<String> liveRemarkCommandWords = {
  'take', 'takes', 'taking', 'snap', 'snapping', 'capture', 'capturing', 'shoot', 'shooting', 'get', 'getting',
  'grab', 'grabbing', 'click', 'clicking', 'another', 'again', 'photograph', 'retake', 'go', 'now', 'ready',
  'yes', 'yeah', 'yep', 'sure', 'please', 'do', 'let',
};

/// Word pairs that make a request out of an opinion word ("I'd LIKE A
/// photo", "one more") — the same shape as build 182's request markers,
/// kept as a separate copy here.
const List<List<String>> liveRemarkRequestPairs = [
  ['one', 'more'], ['like', 'a'], ['like', 'an'], ['d', 'like'], ['would', 'like'], ['love', 'a'], ['d', 'love'],
  ['would', 'love'], ['for', 'me'],
];

/// Why [transcript] is a remark (the opinion word that made it one), or
/// null when it is not — the caller then behaves exactly as build 182.
String? liveCameraRemarkWord(String transcript) {
  final words = tokenizeTriggerText(transcript);
  if (words.isEmpty) return null;
  if (words.any(liveRemarkCommandWords.contains)) return null;
  final padded = ' ${words.join(' ')} ';
  if (liveRemarkRequestPairs.any((p) => padded.contains(' ${p.join(' ')} '))) return null;
  for (final w in words) {
    if (liveRemarkOpinionWords.contains(w)) return w;
  }
  return null;
}

bool isLiveCameraRemark(String transcript) => liveCameraRemarkWord(transcript) != null;
