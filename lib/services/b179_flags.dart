/// Build 179 switches, all default ON. Logged on their own `B179 FLAGS:`
/// line — the BUILD line's flag list is left exactly as build 178 wrote it.
library;

import 'idle_beep_mute.dart';
import 'local_close_command.dart';
import 'photo_decline.dart';
import 'wider_capture.dart';

String describeB179Flags() =>
    'B179 FLAGS: idleBeepMute=$kIdleBeepMute localCloseCommands=$kLocalCloseCommands '
    'widerCapturePhrases=$kWiderCapturePhrases widerCloseDeclinePhrases=$kWiderCloseDeclinePhrases';
