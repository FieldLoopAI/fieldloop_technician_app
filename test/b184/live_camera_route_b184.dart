// Build 184 — `live_camera_route.dart`'s live-camera routing (build 183,
// both b183 vetoes on) with the three build 184 additions in their real
// places: Changes B and C just before C13 narration, Change A right after
// the live-noun veto. Each can be
// switched off; all three off is the build 183 route. Not a test file.
import 'package:fielloop/services/another_one_capture.dart';
import 'package:fielloop/services/camera_narration.dart';
import 'package:fielloop/services/camera_negation_guard.dart';
import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/continuation_answer.dart';
import 'package:fielloop/services/live_camera_remark_veto.dart';
import 'package:fielloop/services/photo_decline.dart';
import 'package:fielloop/services/remark_quick_reply.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:fielloop/services/wait_hold_intent.dart';
import 'package:fielloop/services/wider_capture.dart';

import '../support/live_camera_route.dart';

/// The b183 route's result for the same input (b183 flags on).
String routeB183(String text, {String geminiIntent = 'none', String? heardQuestion}) =>
    routeLiveCamera(text, remarkVeto: true, intentCheckVeto: true, geminiIntent: geminiIntent, heardQuestion: heardQuestion);

String routeLiveCameraB184(
  String text, {
  bool quickReply = true,
  bool anotherOne = true,
  bool yesRouting = true,
  String geminiIntent = 'none',
  String? heardQuestion,
}) {
  String fire(String via) => cameraActionNegation(text) != null ? 'blocked:capture_photo' : 'capture:$via';

  // Per chunk — unchanged.
  if (matchAnyTriggerPhrase(text, capturePhrases) != null) return fire('phrase_list');
  if (shutterWordMatch(text)) return fire('shutter_word');
  if (matchWiderCapture(text) is WiderCaptureMatch) return fire('wider_capture');

  // Utterance end — unchanged.
  if (matchPhotoDecline(text) != null) return 'conversation:photo_decline';
  if (waitHoldApplies(cameraLiveOrOpening: true, photoNoteActive: false, closeQuestionPending: false) &&
      matchWaitHold(text) != null) {
    return 'conversation:wait_hold';
  }
  if (negatedCameraMention(text, cameraUp: true) != null) return 'blocked:negated_camera_sentence';

  // Changes B and C — before C13 (`_maybeCaptureBeforeNarration`).
  if (anotherOne && matchAnotherOneCapture(text) != null) return fire('another_one');
  if (yesRouting) {
    final rest = yesCaptureRest(text);
    if (rest != null &&
        (matchAnyTriggerPhrase(rest, capturePhrases) != null ||
            matchWiderCapture(rest) is WiderCaptureMatch ||
            (anotherOne && matchAnotherOneCapture(rest) != null))) {
      return fire('yes_capture_routing');
    }
  }
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
  if (liveNoun != null && isLiveCameraRemark(text)) liveNoun = null;
  if (liveNoun != null) return fire('fuzzy_live_noun');
  // Change A (`_maybeQuickReplyToRemark`).
  if (quickReply && quickReplyPathFor(text, cameraLive: true) != null) return 'conversation:quick_reply_noted';
  if (otherConfident) return 'other:${decision.best!.trigger}';

  if (geminiIntent == 'capture_photo' && !isLiveCameraRemark(text)) return fire('gemini_intent_check');
  return 'conversation:fallback';
}

/// What `_maybeQuickReplyToRemark` decides (job open, no photo note, no
/// announced question).
RemarkQuickReplyPath? quickReplyPathFor(String text, {required bool cameraLive}) => remarkQuickReplyPath(
  text,
  enabled: true,
  cameraLiveArmed: cameraLive,
  cameraClosed: !cameraLive,
  liveVetoesOn: true,
  decision: classifyCommandIntent(text),
  photoNoteActive: false,
  expectingQuestion: false,
);

bool capturesB184(String text, {String geminiIntent = 'none', String? heardQuestion}) =>
    routeLiveCameraB184(text, geminiIntent: geminiIntent, heardQuestion: heardQuestion).startsWith('capture:');
