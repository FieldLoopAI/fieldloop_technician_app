/// Build 182 switches, all default ON. Logged on their own `B182 FLAGS:`
/// line at app start and at every session open — the BUILD, B179 FLAGS and
/// B180 FLAGS lines are left exactly as before.
library;

/// Item A — an utterance the app already answered (clip or spoken line) gets
/// no second line from the 2 s PREEMPTIVE DEFAULT MUTE safety timeout; the
/// mute is cleared silently instead. `--dart-define=ONE_REPLY_PER_UTTERANCE=false`.
const bool kOneReplyPerUtterance = bool.fromEnvironment('ONE_REPLY_PER_UTTERANCE', defaultValue: true);

/// Item B — a remark that only mentions a photo/the camera ("I like the
/// photo.") is not scored as an open_camera request by the fuzzy layer or
/// acted on from the Gemini intent check. `--dart-define=FUZZY_REMARK_VETO=false`.
const bool kFuzzyRemarkVeto = bool.fromEnvironment('FUZZY_REMARK_VETO', defaultValue: true);

/// Item C — "loop off" and its ASR spellings close the session
/// (`local_close_command.dart`). `--dart-define=LOOP_OFF_CLOSE=false`.
const bool kLoopOffClose = bool.fromEnvironment('LOOP_OFF_CLOSE', defaultValue: true);

String describeB182Flags() =>
    'B182 FLAGS: oneReplyPerUtterance=$kOneReplyPerUtterance fuzzyRemarkVeto=$kFuzzyRemarkVeto '
    'loopOffClose=$kLoopOffClose';
