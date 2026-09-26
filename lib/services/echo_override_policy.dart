/// Decides whether a transcript the echo backstop flagged (its text closely
/// matches something Gemini just said) should still be allowed through as a
/// real technician command.
///
/// Text similarity alone can't tell mic bleed from a technician who mirrors
/// the app's own wording back ("take it", "capture it") — technicians do
/// that. What CAN tell them apart is whether our own audio was still
/// playing when the technician started speaking: an echo can only be
/// picked up while the speaker is producing it.
///
/// The reference point is when the NATIVE PLAYER confirmed it had played
/// everything we fed it — not when the mic resumed. CONFIRMED in a real
/// trace: all six echo-flagged transcripts came right after the mic
/// watchdog force-resumed the mic on a time estimate while the player
/// still held audio (once with 7341 frames reported queued), 2.6-11.7s
/// before that audio had actually finished. "Time since the mic resumed"
/// would have let every one of them through, two of them firing
/// capture/retake on their own.
library;

/// Our audio's own trailing tail after the player reports "0 remaining":
/// that report means its queue is empty, not that the last buffer has left
/// the speaker.
const Duration echoTailMargin = Duration(milliseconds: 300);

enum EchoDecision {
  /// Not flagged as echo — nothing to decide.
  notEcho,

  /// Flagged as echo and treated as echo: discarded, as before.
  suppress,

  /// Flagged as echo, but a command matched AND the technician started
  /// speaking after our audio had provably finished playing — let the
  /// command fire.
  override,
}

EchoDecision decideEcho({
  required bool textLooksLikeEcho,
  required bool commandMatched,
  required DateTime? speechStartedAt,
  required DateTime? playbackConfirmedEndedAt,
  required DateTime? lastPlaybackStartedAt,
}) {
  if (!textLooksLikeEcho) return EchoDecision.notEcho;
  if (!commandMatched) return EchoDecision.suppress;
  if (speechStartedAt == null || playbackConfirmedEndedAt == null) return EchoDecision.suppress;
  // The confirmation must be for the most recent playback, not an older one.
  if (lastPlaybackStartedAt != null && !playbackConfirmedEndedAt.isAfter(lastPlaybackStartedAt)) {
    return EchoDecision.suppress;
  }
  return speechStartedAt.isAfter(playbackConfirmedEndedAt.add(echoTailMargin))
      ? EchoDecision.override
      : EchoDecision.suppress;
}
