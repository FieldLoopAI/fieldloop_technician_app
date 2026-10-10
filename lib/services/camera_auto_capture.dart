/// Build 177 Step 5 (C13 one sentence) — "Capture this - there's water damage
/// here." with the camera closed: open the camera, then take the photo, and
/// keep the description as the photo note, all from the one utterance.
///
/// Build 176 already opened the camera and kept the note
/// (`cameraRequestNarrationAnyPunctuation` in `camera_narration.dart`); the
/// shutter was left to the technician. Here the screen arms ONE capture when
/// (and only when) the camera request carried such a description, then fires
/// the normal deterministic capture_photo — the same dispatch "take a photo"
/// uses with the camera live — once the camera is confirmed open and its
/// "Camera's open." line has finished. A plain request ("Open the camera",
/// "Take a photo", "Capture this.") has no description, so it never arms.
library;

import 'camera_narration.dart';

/// The note an auto-capture is armed for, or null = do not arm (plain
/// request, or no description the C13 narration rules accept).
String? cameraRequestAutoCaptureNote(String requestText, {required List<String> requestPhrases}) =>
    cameraRequestNarrationAnyPunctuation(requestText, requestPhrases: requestPhrases);

/// The shortest time between arming (open_camera succeeded) and the shutter,
/// so the preview's exposure/focus has a moment to settle.
const Duration cameraAutoCaptureSettle = Duration(milliseconds: 800);

/// Armed but never fired by then -> dropped (the camera simply stays open,
/// exactly as in build 176).
const Duration cameraAutoCaptureDeadline = Duration(seconds: 6);

enum AutoCaptureStep { wait, fire, abort }

/// One poll of an armed auto-capture. Anything that means the technician or
/// the app has moved on aborts; nothing fires until every condition holds.
({AutoCaptureStep step, String why}) cameraAutoCaptureStep({
  required bool sessionClosing,
  required bool newUtteranceSinceArmed,
  required bool cameraLiveAndConfirmed,
  required bool cameraClosedOrPhotoTaken,
  required bool photoNoteOpen,
  required bool cameraNativeCallInProgress,
  required bool replyStillPlaying,
  required Duration sinceArmed,
}) {
  if (sessionClosing) return (step: AutoCaptureStep.abort, why: 'session closing');
  if (newUtteranceSinceArmed) return (step: AutoCaptureStep.abort, why: 'the technician spoke again');
  if (cameraClosedOrPhotoTaken) return (step: AutoCaptureStep.abort, why: 'camera closed or photo already taken');
  if (photoNoteOpen) return (step: AutoCaptureStep.abort, why: 'photo note flow open');
  if (sinceArmed > cameraAutoCaptureDeadline) {
    return (step: AutoCaptureStep.abort, why: 'not ready within ${cameraAutoCaptureDeadline.inSeconds}s');
  }
  if (!cameraLiveAndConfirmed) return (step: AutoCaptureStep.wait, why: 'camera not confirmed open yet');
  if (cameraNativeCallInProgress) return (step: AutoCaptureStep.wait, why: 'camera native call in progress');
  if (replyStillPlaying) return (step: AutoCaptureStep.wait, why: 'camera-open reply still playing');
  if (sinceArmed < cameraAutoCaptureSettle) return (step: AutoCaptureStep.wait, why: 'preview settling');
  return (step: AutoCaptureStep.fire, why: 'camera open and quiet');
}
