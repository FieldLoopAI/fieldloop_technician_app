/// Build 180 switches, logged on their own `B180 FLAGS:` line at app start
/// and at every session open — the BUILD and B179 FLAGS lines are left
/// exactly as before.
library;

import 'close_line_playback.dart';
import 'late_finalize.dart';
import 'photo_decline.dart';
import 'scripted_reply_clips.dart';
import 'wait_hold_intent.dart';

String describeB180Flags() =>
    'B180 FLAGS: scriptedReplyClips=$kScriptedReplyClips lateFinalizeMs=$kLateFinalizeMs '
    'waitHoldIntent=$kWaitHoldIntent closeLineFullPlayback=$kCloseLineFullPlayback '
    'widerDeclineB180=$kWiderDeclineB180';
