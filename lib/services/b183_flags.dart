/// Build 183 switches, all default ON. Logged on their own `B183 FLAGS:`
/// line at app start and at every session open — the BUILD, B179, B180 and
/// B182 FLAGS lines are left exactly as before. Each flag set to false gives
/// exactly the build 182 behavior for its item.
library;

/// Change A — with the camera live, a remark about the photo ("I like the
/// photo.", "Nice shot") no longer fires capture_photo from the FUZZY
/// LIVE-CAMERA MATCH (bare shutter noun) path. See
/// `live_camera_remark_veto.dart`. `--dart-define=LIVE_CAMERA_REMARK_VETO=false`.
const bool kLiveCameraRemarkVeto = bool.fromEnvironment('LIVE_CAMERA_REMARK_VETO', defaultValue: true);

/// Change A, second half — the Gemini intent check's "capture_photo" answer
/// is not acted on for the same kind of remark ("That looks good" has no
/// shutter noun, so only Gemini could turn it into a photo). Same rule as
/// [kLiveCameraRemarkVeto]. `--dart-define=LIVE_REMARK_INTENT_CHECK_VETO=false`.
const bool kLiveRemarkIntentCheckVeto = bool.fromEnvironment('LIVE_REMARK_INTENT_CHECK_VETO', defaultValue: true);

String describeB183Flags() =>
    'B183 FLAGS: liveCameraRemarkVeto=$kLiveCameraRemarkVeto '
    'liveRemarkIntentCheckVeto=$kLiveRemarkIntentCheckVeto';
