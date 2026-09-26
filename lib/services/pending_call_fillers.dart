/// Short spoken "still working on it" lines for camera-flow calls that hard-
/// pause all conversation audio while a slow native call is in flight — see
/// `_GeminiLiveTestScreenState._speakPendingCallFiller` in
/// `gemini_live_test_screen.dart`, which owns the timers and the audio
/// passthrough that lets exactly this one line be heard during the pause.
///
/// P0 FIX (CONFIRMED on a real SM-A507FN: `takePicture()` alone took 55.03s
/// in one run, compress+upload 36.6s in another): without these the
/// technician heard total silence for the whole call.
///
/// Every line here is spoken through the constrained verbatim path but is
/// deliberately NOT recorded as `_lastVerbatimScriptText`, so it must never
/// itself contain completed-action wording — the completion-claim audit
/// would (correctly) flag it as an unlicensed claim. Enforced by
/// `test/pending_call_fillers_test.dart`.
library;

/// Filler line and how long the call must have been pending before it's
/// spoken, keyed by the camera-flow function name.
const Map<String, ({Duration delay, String text})> pendingCallFillers = {
  'open_camera': (delay: Duration(seconds: 5), text: 'Just a moment, opening the camera.'),
  'capture_photo': (delay: Duration(milliseconds: 1500), text: 'Just a second, still capturing.'),
  'confirm_photo_upload': (delay: Duration(milliseconds: 1500), text: 'Still uploading, one more second.'),
};

/// One follow-up line for a call still pending long after its first filler
/// — CONFIRMED in a real trace: a capture ran 88s with nothing heard after
/// "Just a second, still capturing." at 1.5s, and the technician closed the
/// session ~68s in, so the real result was never delivered. Spoken once, at
/// most, per call. Same no-completed-action-wording rule as
/// [pendingCallFillers].
const Map<String, ({Duration delay, String text})> pendingCallFollowUpFillers = {
  'capture_photo': (
    delay: Duration(seconds: 15),
    text: "Still working on the photo — the camera's slower than usual right now. Hang tight.",
  ),
  'confirm_photo_upload': (
    delay: Duration(seconds: 15),
    text: "Still uploading — the connection's slow right now. Hang tight.",
  ),
};
