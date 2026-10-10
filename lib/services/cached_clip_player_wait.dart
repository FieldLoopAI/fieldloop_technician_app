/// Build 177 Step 2 — a cached clip that was skipped only because the audio
/// player was "re-initialising" now waits briefly for it.
///
/// The race (b176, 8 of 9 "cached clip ... not used"): an utterance's first
/// transcript chunk runs the preemptive-mute interrupt, which marks the
/// player not ready SYNCHRONOUSLY and marks it ready again from a chained
/// Future — even when the native release/setup is skipped because the
/// player was idle ("PCM reinit SKIPPED — player confirmed idle"). The
/// reply for that same chunk (negation "Okay.", a job fact, "Sorry, I can't
/// make calls.") is requested in the same synchronous run, so its clip check
/// always saw "re-initialising", a few ms before the player was ready.
///
/// Only the re-initialising blocker waits. A camera native call or other
/// audio still playing still falls back at once, exactly as before — a clip
/// is never played over other audio.
library;

import 'dart:async';

/// Why a cached clip cannot play right now (checked in this order).
enum ClipPlayBlocker { playerReinitialising, cameraNativeCall, otherAudioPlaying }

/// The same three checks, in the same order, as build 176's `_playClipPcm`.
ClipPlayBlocker? clipPlayBlocker({
  required bool playerReady,
  required bool cameraNativeCallInProgress,
  required bool otherAudioPlaying,
}) {
  if (!playerReady) return ClipPlayBlocker.playerReinitialising;
  if (cameraNativeCallInProgress) return ClipPlayBlocker.cameraNativeCall;
  if (otherAudioPlaying) return ClipPlayBlocker.otherAudioPlaying;
  return null;
}

/// The log wording build 176 used in "cached clip … not used (…)".
String describeClipBlocker(ClipPlayBlocker blocker) => switch (blocker) {
  ClipPlayBlocker.playerReinitialising => 'audio player re-initialising',
  ClipPlayBlocker.cameraNativeCall => 'camera native call in progress',
  ClipPlayBlocker.otherAudioPlaying => 'other audio still playing',
};

/// True only when the ONE thing in the way is the player re-initialising
/// (and the wait is switched on). Any other blocker -> today's fallback.
bool clipShouldWaitForPlayer(ClipPlayBlocker? blocker, {required bool enabled}) =>
    enabled && blocker == ClipPlayBlocker.playerReinitialising;

/// Longest a clip waits for the player before Gemini speaks the line.
const Duration cachedClipPlayerMaxWait = Duration(milliseconds: 150);
const Duration cachedClipPlayerPoll = Duration(milliseconds: 10);

enum ClipWaitOutcome {
  /// Every blocker cleared inside the wait: play the clip.
  ready,

  /// Still blocked after [cachedClipPlayerMaxWait]: Gemini speaks it.
  timedOut,

  /// Something newer took over (another reply, a new utterance, the
  /// session closing): this clip is not played.
  superseded,
}

/// Polls [ready] (all blockers clear) every [poll] for at most [maxWait].
/// The first check is one microtask later, which is already enough for an
/// idle-player reinit whose readiness is set by a chained Future.
/// [superseded] is checked before [ready] each time.
Future<({ClipWaitOutcome outcome, int waitedMs})> waitForClipPlayer({
  required bool Function() ready,
  required bool Function() superseded,
  Duration maxWait = cachedClipPlayerMaxWait,
  Duration poll = cachedClipPlayerPoll,
}) async {
  final watch = Stopwatch()..start();
  await Future<void>.value();
  while (true) {
    if (superseded()) return (outcome: ClipWaitOutcome.superseded, waitedMs: watch.elapsedMilliseconds);
    if (ready()) return (outcome: ClipWaitOutcome.ready, waitedMs: watch.elapsedMilliseconds);
    if (watch.elapsed >= maxWait) return (outcome: ClipWaitOutcome.timedOut, waitedMs: watch.elapsedMilliseconds);
    final left = maxWait - watch.elapsed;
    await Future<void>.delayed(left < poll ? left : poll);
  }
}
