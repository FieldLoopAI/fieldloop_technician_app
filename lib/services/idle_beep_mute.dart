/// Build 179 item A — silences the Google speech recognizer's own start/end
/// beep while the IDLE wake-word listener runs between Gemini sessions.
///
/// b178 evidence (logcat, Oct 12 14:57:01-14:57:12): the recognizer ends its
/// wake-word session on its own every ~10 s (`error_no_match` — the device
/// caps the 18 s pauseFor), the app restarts it, and every start and end
/// plays `edwj: Playing beep` with `usage=USAGE_NOTIFICATION_EVENT` — the
/// soft "bell" every ~10 s after a session closes.
///
/// The native side (`MainActivity.kt`: `muteRecognizerBeep` /
/// `restoreRecognizerBeep`) mutes ONLY `STREAM_NOTIFICATION`, saves the
/// original volume/mute state (in SharedPreferences, so a killed app is
/// restored at its next start) and restores exactly that. This class only
/// decides WHEN, and never lets a platform failure escape: the first
/// failure logs `IDLE BEEP MUTE UNAVAILABLE` once and turns the feature off
/// for the rest of the process (no retry loop).
///
/// No wake-word timing changes: the restart interval and when listening
/// restarts are untouched — this only mutes and unmutes around them.
library;

/// `--dart-define=IDLE_BEEP_MUTE=false` turns item A off.
const bool kIdleBeepMute = bool.fromEnvironment('IDLE_BEEP_MUTE', defaultValue: true);

/// Calls one native method and returns its result map (or throws).
typedef IdleBeepInvoker = Future<Object?> Function(String method);

class IdleBeepMute {
  IdleBeepMute({required this.invoke, required this.log, this.enabled = kIdleBeepMute});

  final IdleBeepInvoker invoke;
  final void Function(String line) log;
  final bool enabled;

  bool _muted = false;
  bool _unavailable = false;

  /// True between a mute this class asked for and its restore.
  bool get isMuted => _muted;

  /// True once the platform refused (or failed) — nothing more is tried.
  bool get isUnavailable => _unavailable;

  /// The mute decision, pure so it can be unit tested: only while the idle
  /// wake-word listener is running, no Gemini session owns the mic, and the
  /// app is in the foreground.
  static bool shouldMute({
    required bool enabled,
    required bool unavailable,
    required bool idleListenerActive,
    required bool geminiSessionActive,
    required bool appForeground,
  }) =>
      enabled && !unavailable && idleListenerActive && !geminiSessionActive && appForeground;

  /// Called right before the idle wake-word listener (re)starts. A no-op
  /// when already muted, so the ~10 s restarts don't re-save the volume.
  Future<void> muteForIdleListener({
    required bool idleListenerActive,
    required bool geminiSessionActive,
    required bool appForeground,
  }) async {
    if (_muted) return;
    if (!shouldMute(
      enabled: enabled,
      unavailable: _unavailable,
      idleListenerActive: idleListenerActive,
      geminiSessionActive: geminiSessionActive,
      appForeground: appForeground,
    )) {
      return;
    }
    // Set before the call so a restore issued while it is in flight still
    // goes out (platform messages are delivered in order).
    _muted = true;
    var ok = false;
    try {
      final result = _asMap(await invoke('muteRecognizerBeep'));
      final status = result['status'];
      if (status == 'muted' || status == 'already_muted') {
        ok = true;
        log('IDLE BEEP MUTE: muted prev=${result['prev']}');
      } else if (status == 'already_silent') {
        // Notification volume is already 0/muted — nothing to save or
        // restore; leave the user's setting exactly as it is.
        _muted = false;
        ok = true;
        log('IDLE BEEP MUTE: not muted — notification stream already silent (prev=${result['prev']})');
      } else {
        _markUnavailable('${result['reason'] ?? status ?? 'no result'}');
      }
    } catch (e) {
      _markUnavailable('$e');
    } finally {
      if (!ok && _muted) {
        // Anything that went wrong after the native side may have muted:
        // put the stream back the way it was.
        await _restoreQuietly('mute_failed');
      }
    }
  }

  /// Restores the notification stream if this class muted it. Called
  /// before a Gemini session/greeting, on wake word, on app pause/detach,
  /// on exitJobScope, voice mute, logout and dispose.
  Future<void> restore(String reason) async {
    if (!enabled || !_muted) return;
    await _restoreQuietly(reason);
  }

  /// App start: the stream may have been left muted by a process that was
  /// killed mid-mute. The native side keeps the saved value in prefs and
  /// only acts when it finds one.
  Future<void> restoreLeftoverAtStart() async {
    if (!enabled) return;
    try {
      final result = _asMap(await invoke('restoreRecognizerBeep'));
      if (result['status'] == 'restored') {
        log('IDLE BEEP MUTE: restored vol=${result['vol']} reason=app_start_leftover');
      }
    } catch (e) {
      _markUnavailable('$e');
    }
  }

  Future<void> _restoreQuietly(String reason) async {
    _muted = false;
    try {
      final result = _asMap(await invoke('restoreRecognizerBeep'));
      if (result['status'] == 'restored') {
        log('IDLE BEEP MUTE: restored vol=${result['vol']} reason=$reason');
      }
    } catch (e) {
      _markUnavailable('$e');
    }
  }

  void _markUnavailable(String reason) {
    if (_unavailable) return;
    _unavailable = true;
    log('IDLE BEEP MUTE UNAVAILABLE: $reason');
  }

  static Map<Object?, Object?> _asMap(Object? value) => value is Map ? value : const {};
}
