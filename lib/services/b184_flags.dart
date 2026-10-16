/// Build 184 switches, all default ON. Logged on their own `B184 FLAGS:`
/// line at app start and at every session open — the B182 and B183 FLAGS
/// lines are left exactly as before. Each flag set to false gives exactly
/// the build 183 behavior for its change.
library;

import 'local_close_command.dart' show localCloseConfirmTimeout;

/// Change A — a remark ("I like the photo.", "That looks good") gets the
/// stored "Noted." at once: no Gemini intent check wait, no "Did you mean
/// take a photo?", no KB catch-all. See `remark_quick_reply.dart`.
/// `--dart-define=REMARK_QUICK_REPLY=false`.
const bool kRemarkQuickReply = bool.fromEnvironment('REMARK_QUICK_REPLY', defaultValue: true);

/// Change B — camera live: "Take another one" / "Take one" / "Click"
/// capture directly, like "Snap it". See `another_one_capture.dart`.
/// `--dart-define=ANOTHER_ONE_CAPTURE=false`.
const bool kAnotherOneCapture = bool.fromEnvironment('ANOTHER_ONE_CAPTURE', defaultValue: true);

/// Change C — camera live: "Yes, take another one" captures instead of
/// being kept as a C13 photo note. See `another_one_capture.dart`.
/// `--dart-define=YES_CAPTURE_ROUTING=false`.
const bool kYesCaptureRouting = bool.fromEnvironment('YES_CAPTURE_ROUTING', defaultValue: true);

/// Change D — the soft-close "Do you want me to close the session?" is
/// dropped after 5 s of no answer instead of 8 s.
/// `--dart-define=LOCAL_CLOSE_CONFIRM_5S=false`.
const bool kLocalCloseConfirm5s = bool.fromEnvironment('LOCAL_CLOSE_CONFIRM_5S', defaultValue: true);

/// Change D's timeout. The existing 8 s `localCloseConfirmTimeout` stays
/// as it is and is what the flag-off path uses.
const Duration localCloseConfirmTimeout5s = Duration(seconds: 5);

/// The soft-close confirm timeout this build uses.
Duration b184LocalCloseConfirmTimeout({bool enabled = kLocalCloseConfirm5s}) =>
    enabled ? localCloseConfirmTimeout5s : localCloseConfirmTimeout;

String describeB184Flags() =>
    'B184 FLAGS: remarkQuickReply=$kRemarkQuickReply anotherOneCapture=$kAnotherOneCapture '
    'yesCaptureRouting=$kYesCaptureRouting localCloseConfirm5s=$kLocalCloseConfirm5s';
