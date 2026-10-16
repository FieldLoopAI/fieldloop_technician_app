// Build 183 — what the screen does with one finished utterance while the
// camera preview is LIVE and armed, layer by layer in its real order
// (`_onInputTranscription` per-chunk capture trigger, then
// `_finalizeUtteranceEndDeterministicTriggers` -> `_maybeResolveByIntent`
// -> `_resolveGeminiIntentCheck`). Same approach as the route() helpers in
// bob_photo_phrases_test.dart / b176_negation_any_order_test.dart, extended
// with the b179 wider capture, b179/b180 decline + wait/hold, the photo
// offer answer and the b183 vetoes. Not a test file itself (no _test).
import 'dart:io';

import 'package:fielloop/services/camera_narration.dart';
import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/continuation_answer.dart';
import 'package:fielloop/services/live_camera_remark_veto.dart';
import 'package:fielloop/services/photo_decline.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:fielloop/services/wait_hold_intent.dart';
import 'package:fielloop/services/wider_capture.dart';

final String productionScreen = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();

/// A `const List<String>` from the production screen, read as-is.
List<String> productionPhrases(String listName) {
  final block = RegExp('const List<String> $listName = \\[(.*?)\\n\\];', dotAll: true).firstMatch(productionScreen);
  if (block == null) throw StateError('$listName not found in the production file');
  return [
    for (final m in RegExp(r'''^\s*(?:'([^']*)'|"([^"]*)"),''', multiLine: true).allMatches(block.group(1)!))
      m.group(1) ?? m.group(2)!,
  ];
}

final List<String> capturePhrases = productionPhrases('_capturePhotoIndicatorPhrases');

/// `_looksLikeCapturePhotoConfirmation(readyRule: false)` (private in the
/// screen; a source test below pins its literals so this copy can't drift).
const List<String> shutterOpenCameraOnly = ['take a photo', 'take a picture', 'let s take a photo', 'let s take a picture'];
const List<String> shutterConfirmWords = ['capture', 'snap', 'take it', 'confirm', 'keep it'];

bool shutterWordMatch(String text) {
  final padded = stemmedPaddedTriggerText(text);
  for (final phrase in shutterOpenCameraOnly) {
    if (padded.contains(' ${stemTriggerPhrase(phrase)} ')) return false;
  }
  for (final word in shutterConfirmWords) {
    if (!padded.contains(' ${stemTriggerPhrase(word)} ')) continue;
    if (triggerPhraseIsNegated(padded, word)) continue;
    return true;
  }
  return false;
}

/// The path taken; starts with `capture:` when a photo is taken.
String routeLiveCamera(
  String text, {
  required bool remarkVeto,
  required bool intentCheckVeto,
  String geminiIntent = 'none',
  String? heardQuestion,
}) {
  String fire(String via) => cameraActionNegation(text) != null ? 'blocked:capture_photo' : 'capture:$via';

  // Per chunk — capture_photo's trigger (its guard passes: camera live).
  if (matchAnyTriggerPhrase(text, capturePhrases) != null) return fire('phrase_list');
  if (shutterWordMatch(text)) return fire('shutter_word');
  if (matchWiderCapture(text) is WiderCaptureMatch) return fire('wider_capture');

  // Utterance end.
  if (matchPhotoDecline(text) != null) return 'conversation:photo_decline';
  if (waitHoldApplies(cameraLiveOrOpening: true, photoNoteActive: false, closeQuestionPending: false) &&
      matchWaitHold(text) != null) {
    return 'conversation:wait_hold';
  }
  if (negatedCameraMention(text, cameraUp: true) != null) return 'blocked:negated_camera_sentence';
  if (cameraNarrationRejection(text, cameraLive: true) == null) return 'conversation:narration_note';

  // _maybeResolveByIntent.
  if (heardQuestion != null && looksLikePhotoOfferQuestion(heardQuestion)) {
    final answer = classifyContinuationAnswer(text);
    if (answer == ContinuationAnswer.affirmative) return fire('photo_offer_yes');
    if (answer == ContinuationAnswer.negative) return 'conversation:photo_offer_declined';
  }
  final decision = classifyCommandIntent(text);
  if (standaloneCameraCancel(text) != null) return 'conversation:camera_cancel';
  final otherConfident = decision.kind == IntentDecisionKind.confident && decision.best!.trigger != 'open_camera';
  var liveNoun = otherConfident ? null : liveCameraShotNoun(text);
  if (liveNoun != null && remarkVeto && isLiveCameraRemark(text)) liveNoun = null;
  if (liveNoun != null) return fire('fuzzy_live_noun');
  if (otherConfident) return 'other:${decision.best!.trigger}';

  // Gemini intent check (context capture_photo) — its answer is an input.
  if (geminiIntent == 'capture_photo' && !(intentCheckVeto && isLiveCameraRemark(text))) {
    return fire('gemini_intent_check');
  }
  return 'conversation:fallback';
}

bool capturesB182(String text, {String geminiIntent = 'none', String? heardQuestion}) => routeLiveCamera(
  text,
  remarkVeto: false,
  intentCheckVeto: false,
  geminiIntent: geminiIntent,
  heardQuestion: heardQuestion,
).startsWith('capture:');

bool capturesB183(String text, {String geminiIntent = 'none', String? heardQuestion}) => routeLiveCamera(
  text,
  remarkVeto: true,
  intentCheckVeto: true,
  geminiIntent: geminiIntent,
  heardQuestion: heardQuestion,
).startsWith('capture:');
