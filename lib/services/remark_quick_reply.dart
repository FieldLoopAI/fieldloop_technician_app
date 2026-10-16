/// Build 184 Change A (REMARK_QUICK_REPLY) — b183 device log: with the
/// camera live, "I like the photo." / "The photo is blurry." / "Nice shot."
/// were correctly NOT captured (LIVE REMARK VETO), but then waited out the
/// 900 ms Gemini intent check and got "Did you mean take a photo?" or
/// "Sorry, I missed that — say 'ready' or 'capture it'..." (2.2–4.5 s). With
/// the camera closed, "I like the photo." went to the KB catch-all: "One
/// moment, checking that." and, 9 s later, "I can only help with this job."
///
/// A remark is conversation: it now gets the stored "Noted." at once (the
/// same line and clip C13 narration uses) — no intent check, no
/// clarification, no KB, no camera action, nothing saved.
///
/// When it applies (everything else keeps the build 183 path):
///  - camera live and armed: the b183 live remark rule
///    ([isLiveCameraRemark]: an opinion word, no command word, no request
///    pair) — the rule both b183 vetoes use;
///  - camera closed: the b182 FUZZY REMARK VETO fired (the matcher's own
///    `remarkVetoed`), a photo/picture/camera/shot noun is in it, and no
///    request verb or request pair is;
///  - and in both: the fuzzy matcher is not confident/ambiguous about any
///    command, it is not filler or a greeting (camera closed: not any small
///    talk — those keep their own replies), not a question, has no
///    yes/no/negation word and no job data word (those reach the KB), and is
///    not a decline, wait/hold or close phrase.
///
/// Pure Dart and deterministic: no network, no Gemini call.
library;

import 'command_intent_matcher.dart';
import 'continuation_answer.dart';
import 'conversational_utterance.dart';
import 'live_camera_remark_veto.dart';
import 'local_close_command.dart';
import 'photo_decline.dart';
import 'photo_note_classifier.dart';
import 'trigger_phrase_matcher.dart';
import 'wait_hold_intent.dart';

/// The reply: C13 narration's line, word for word.
const String remarkQuickReplyText = 'Noted.';

/// Requested under C13's own reason, so the SAME stored clip plays (clips
/// are cacheable only per reason/text — `cacheableFixedReplyLines`). The
/// log line `REMARK QUICK REPLY:` tells the two apart.
const String remarkQuickReplyReason = 'camera_narration_noted';

/// Camera closed: the remark has to be about the photo.
const Set<String> remarkPhotoNouns = {
  'photo', 'photos', 'picture', 'pictures', 'pic', 'pics', 'camera', 'shot', 'shots', 'image', 'images',
  'snapshot',
};

/// Job-data words: an utterance with any of these keeps its route to the
/// KB / job facts exactly as before.
const Set<String> remarkJobDataWords = {
  'invoice', 'invoices', 'estimate', 'estimates', 'customer', 'customers', 'client', 'homeowner', 'owner',
  'address', 'job', 'jobs', 'order', 'orders', 'history', 'report', 'schedule', 'appointment', 'price', 'cost',
  'costs', 'quote', 'payment', 'paid', 'bill', 'balance', 'total', 'phone', 'email', 'warranty', 'permit',
  'note', 'notes', 'material', 'materials', 'part', 'parts', 'code', 'gate', 'contact', 'site',
};

/// Answer, negation and stop words — "No, it's fine", "I don't like it",
/// "Okay, that's good" keep their existing handling.
const Set<String> remarkAnswerWords = {
  'yes', 'yeah', 'yep', 'yup', 'no', 'nope', 'nah', 'okay', 'ok', 'sure', 'not', 'never', 'don', 'dont', 'didn',
  'doesn', 'isn', 'wasn', 'cancel', 'stop', 'wait', 'hold', 'hang', 'close', 'done', 'bye', 'off', 'skip',
};

/// A first word that makes it a question ("is the photo ok").
const Set<String> remarkQuestionOpeners = {
  'is', 'are', 'was', 'were', 'am', 'do', 'does', 'did', 'can', 'could', 'will', 'would', 'should', 'has', 'have',
  'had', 'may', 'shall', 'what', 'when', 'where', 'why', 'how', 'who', 'which',
};

/// Question words anywhere ("the photo is what").
const Set<String> remarkQuestionWords = {'what', 'when', 'where', 'why', 'how', 'who', 'which'};

enum RemarkQuickReplyPath { liveCamera, cameraClosed }

/// Why [text] gets no quick reply on [path], or `null` when it does.
/// [fuzzyRemarkVetoed]: the b182 FUZZY REMARK VETO fired for it (camera
/// closed path only).
String? remarkQuickReplyRejection(String text, {required RemarkQuickReplyPath path, bool fuzzyRemarkVetoed = false}) {
  final words = tokenizeTriggerText(text);
  if (words.isEmpty) return 'empty';
  if (text.contains('?') ||
      remarkQuestionOpeners.contains(words.first) ||
      words.any(remarkQuestionWords.contains) ||
      looksLikeQuestion(text) ||
      looksLikeRequestOrQuestion(text)) {
    return 'question';
  }
  if (words.any(remarkAnswerWords.contains)) return 'answer_or_negation_word';
  // A greeting keeps its "hello" reply; with the camera closed every small
  // talk kind keeps its own reply (none of them waits on the KB).
  final smallTalk = classifySmallTalk(text);
  if (smallTalk == SmallTalkKind.greeting) return 'greeting';
  if (path == RemarkQuickReplyPath.cameraClosed && smallTalk != SmallTalkKind.none) return 'small_talk';
  final jobWord = words.where(remarkJobDataWords.contains).firstOrNull;
  if (jobWord != null) return 'job_data_word:$jobWord';
  if (classifyContinuationAnswer(text) != ContinuationAnswer.none) return 'yes_no_answer';
  if (matchPhotoDecline(text) != null) return 'decline';
  if (matchWaitHold(text) != null) return 'wait_hold';
  if (matchLocalClose(text) != null) return 'close';
  switch (path) {
    case RemarkQuickReplyPath.liveCamera:
      if (!isLiveCameraRemark(text)) return 'not_a_remark';
    case RemarkQuickReplyPath.cameraClosed:
      if (!fuzzyRemarkVetoed) return 'no_fuzzy_remark_veto';
      if (!words.any(remarkPhotoNouns.contains)) return 'no_photo_noun';
      final padded = ' ${words.join(' ')} ';
      if (words.any(liveRemarkCommandWords.contains) ||
          liveRemarkRequestPairs.any((p) => padded.contains(' ${p.join(' ')} '))) {
        return 'request_verb';
      }
  }
  return null;
}

/// The screen's whole decision for one finished utterance that reached the
/// intent layer: the path the quick reply takes, or `null` (build 183
/// routing). [liveVetoesOn]: both b183 live remark flags are on.
/// [nonInformationalFiller]: the screen's own filler check ("okay", "um",
/// "hold on") — filler keeps its silent handling.
RemarkQuickReplyPath? remarkQuickReplyPath(
  String text, {
  required bool enabled,
  required bool cameraLiveArmed,
  required bool cameraClosed,
  required bool liveVetoesOn,
  required IntentDecision decision,
  required bool photoNoteActive,
  required bool expectingQuestion,
  bool nonInformationalFiller = false,
}) {
  if (!enabled || photoNoteActive || expectingQuestion || nonInformationalFiller) return null;
  if (decision.kind != IntentDecisionKind.none && decision.kind != IntentDecisionKind.weak) return null;
  final path = cameraLiveArmed && liveVetoesOn
      ? RemarkQuickReplyPath.liveCamera
      : (cameraClosed && decision.remarkVetoed ? RemarkQuickReplyPath.cameraClosed : null);
  if (path == null) return null;
  return remarkQuickReplyRejection(text, path: path, fuzzyRemarkVetoed: decision.remarkVetoed) == null ? path : null;
}
