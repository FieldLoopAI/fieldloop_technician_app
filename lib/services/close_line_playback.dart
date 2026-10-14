/// Build 180 item D — the spoken close line is not cut off.
///
/// b179: two of five voice closes ended on the 2s cap while "Okay, closing
/// the session." was still playing (part 1 15:18:15-17, part 2
/// 15:26:29-31: first audio ~0.85s after the request, the line itself
/// ~1.9s), and one (part 2 15:26:16.915) tore down 17ms after playback
/// started: its only audio sat in the jitter prebuffer, so nothing was
/// "playing" yet and the line looked finished.
///
/// With [kCloseLineFullPlayback] the close waits until the line has
/// started, the server (or the clip) has delivered all of it, the
/// prebuffer is empty and nothing is still playing — hard cap
/// [closeLineFullPlaybackCap] — then calls `_stopTest(voice_close)` as before.
/// Off: build 179's rule and 2s cap ([localCloseReplyWaitCap]).
library;

import 'local_close_command.dart' show localCloseReplyWaitCap;

/// `--dart-define=CLOSE_LINE_FULL_PLAYBACK=false` turns item D off.
const bool kCloseLineFullPlayback = bool.fromEnvironment('CLOSE_LINE_FULL_PLAYBACK', defaultValue: true);

const Duration closeLineFullPlaybackCap = Duration(seconds: 4);

/// The hard cap on waiting for the close line.
Duration closeLineWaitCap({bool fullPlayback = kCloseLineFullPlayback}) =>
    fullPlayback ? closeLineFullPlaybackCap : localCloseReplyWaitCap;

/// Whether the close line has finished playing.
///  - [started]: playback began after the close was requested.
///  - [playing]: frames still queued in the player, or expected end ahead.
///  - [turnDelivered]: the server's turnComplete (or a clip's whole delivery)
///    for the line has arrived.
///  - [prebufferEmpty]: no audio waiting in the jitter buffer.
bool closeLineFinished({
  required bool started,
  required bool playing,
  required bool turnDelivered,
  required bool prebufferEmpty,
  bool fullPlayback = kCloseLineFullPlayback,
}) {
  if (!fullPlayback) return started && !playing;
  return started && turnDelivered && prebufferEmpty && !playing;
}
