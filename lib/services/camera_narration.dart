/// Acceptance Test v1.0 C13 — "This is the attic access panel, there's
/// water damage on the left side", said while the camera preview (or the
/// captured photo) is showing. Today nothing matches it and it gets a
/// CLARIFY FALLBACK question. This decides whether such an utterance is a
/// plain DESCRIPTION, safe to keep as the pending photo note.
///
/// Conservative on purpose: anything that could be a command, a question,
/// a keep/retake decision, a shutter word or small talk is NOT narration —
/// it keeps going through the normal routing exactly as before. Only the
/// leftovers nothing else wanted are kept as a note.
library;

import 'camera_request_matcher.dart';
import 'command_intent_matcher.dart';
import 'conversational_utterance.dart';
import 'photo_decision_classifier.dart';
import 'photo_note_classifier.dart';
import 'trigger_phrase_matcher.dart';

/// Shortest description kept — "Looks wet" / "Over here" are too short to
/// be a useful note and too easy to be a misheard command.
const int cameraNarrationMinWords = 4;

/// Why [text] is NOT camera narration, or `null` when it is.
/// [cameraLive]: the live preview is up (vs. a captured photo awaiting
/// keep/retake).
String? cameraNarrationRejection(String text, {required bool cameraLive}) {
  final words = tokenizeTriggerText(text);
  if (words.length < cameraNarrationMinWords) return 'shorter than $cameraNarrationMinWords words';
  if (looksLikeRequestOrQuestion(text) || looksLikeQuestion(text)) return 'a request or question';
  if (classifySmallTalk(text) != SmallTalkKind.none) return 'small talk';
  if (matchLooseCameraRequest(text) is CameraRequestMatch) return 'a camera request';
  if (cameraLive && liveCameraShotNoun(text) != null) return 'a shutter word with the camera live';
  if (!cameraLive && classifyPhotoDecision(text) != PhotoDecision.none) return 'a keep/retake decision';
  if (classifyCommandIntent(text).kind != IntentDecisionKind.none) return 'close to a known command';
  return null;
}

/// Build 175 (second pass) — "Capture this, there's water damage here.":
/// the camera request opens the camera, and the clause(s) AFTER it are a
/// description of what the photo is of. Returns that description when it
/// passes [cameraNarrationRejection] (as if said with the camera live), so
/// it can become the pending photo note exactly like C13 narration; `null`
/// when there is nothing after the request, the request isn't found, or
/// what follows is a command/question/too short ("Take a photo, then show
/// me the invoice" keeps no note).
///
/// Only text after a clause boundary (comma, period, semicolon, dash…)
/// counts — "Take a photo of the water damage" is one clause and keeps no
/// note. [requestPhrases]: open_camera's phrase list (it lives in the
/// screen); the loose verb-before-noun matcher is also tried.
String? cameraRequestTrailingNarration(String text, {required List<String> requestPhrases}) {
  final clauses = [
    for (final c in text.split(RegExp(r'[,;:.!?]+|\s[-–—]+\s|[–—]+'))) c.trim(),
  ].where((c) => c.isNotEmpty).toList();
  if (clauses.length < 2) return null;
  final requestAt = clauses.indexWhere(
    (c) => matchAnyTriggerPhrase(c, requestPhrases) != null || matchLooseCameraRequest(c) is CameraRequestMatch,
  );
  if (requestAt < 0 || requestAt == clauses.length - 1) return null;
  final description = clauses.sublist(requestAt + 1).join(', ');
  if (cameraNarrationRejection(description, cameraLive: true) != null) return null;
  return description;
}
