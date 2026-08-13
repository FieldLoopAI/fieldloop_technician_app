import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'deepgram_command_capture.dart';
import 'voice_command_registry_provider.dart';

enum VoicePhase { listening, processing }

enum _ListenStage { idle, active, freeCapture }

/// Every legitimate reason [GlobalVoiceService._scheduleWakeWordRestart]
/// can be called for — a closed enum (not a free-form String) so every
/// call site is forced at COMPILE time to declare one; there is no code
/// path left that can reach a restart without a cause landing in the log.
/// Added after a self-sustaining restart loop turned out to be an extra,
/// structurally unlabeled call into that method from `_onStatus` (see the
/// `isAwaitedStopConfirmation` guard there, which is the actual fix) —
/// this enum plus the `reason=` logging in `_startListening` means any
/// future case like it is immediately visible in the log as a restart
/// whose cause doesn't match what was actually happening, instead of
/// being indistinguishable from a normal one.
enum _RestartCause {
  /// The wake-word-only session ended (native pauseFor/listenFor floor,
  /// or a clean 'done'/'notListening' status) without ever hearing the
  /// wake word — normal, expected, happens on essentially every cycle.
  sessionEndedNoWakeWord,

  /// A recoverable recognizer error (see `_recoverableErrors`) fired
  /// while no command was in flight.
  recoverableError,

  /// A full wake-word -> command -> dispatch cycle just finished (with
  /// or without a captured command) and the loop needs to go around
  /// again.
  commandCycleComplete,

  /// `_speech.listen()` itself threw (e.g. `ListenFailedException`
  /// wrapping `error_busy`) before a session even started.
  listenCallThrew,
}

/// A wake-word variant found in a transcript — [start]/[end] are character
/// offsets into the (lowercased) text it was found in, so the caller can
/// slice off everything before/after it.
class _WakeWordMatch {
  const _WakeWordMatch(this.variant, this.start, this.end);
  final String variant;
  final int start;
  final int end;
}

class GlobalVoiceState {
  const GlobalVoiceState({
    this.phase = VoicePhase.listening,
    this.transcript = '',
    this.available = true,
    this.muted = false,
  });

  final VoicePhase phase;
  final String transcript;

  /// Whether the on-device speech recognizer reported itself usable.
  /// Distinct from OS microphone permission (see `cameraMicProvider`) — a
  /// technician can have granted the mic permission and still have no
  /// recognizer available on their device.
  final bool available;

  final bool muted;

  GlobalVoiceState copyWith({
    VoicePhase? phase,
    String? transcript,
    bool? available,
    bool? muted,
  }) {
    return GlobalVoiceState(
      phase: phase ?? this.phase,
      transcript: transcript ?? this.transcript,
      available: available ?? this.available,
      muted: muted ?? this.muted,
    );
  }
}

/// The ONE `SpeechToText` and ONE `FlutterTts` instance for the entire app.
///
/// Created once, above the navigation/router level (`RootShell` — see
/// `VoiceCommandRegistrarMixin` usage sites — starts it the moment mic
/// permission is confirmed granted, right after login) and kept alive for
/// the whole authenticated session. It does NOT stop or restart when
/// navigating between screens — only [stopForLogout] tears it down.
///
/// Screens never touch the recognizer directly. They only add/remove
/// entries in [voiceCommandRegistryProvider] as they become active/inactive
/// (see `VoiceCommandRegistrarMixin`); this service just runs the
/// continuous wake-word loop and, on a captured command, asks the registry
/// "does anything match this?" — completely decoupled from any specific
/// screen or job.
///
/// Each cycle is a SINGLE `listen()` session covering the wake word: partial
/// results stream in continuously and the wake word is located in the
/// running transcript. Detecting the wake word itself always stays
/// on-device (free, always-on "sentry") — but the moment it's heard, this
/// on-device session is stopped and command CAPTURE hands off to
/// Deepgram's streaming API instead (see [_tryDeepgramCommandCapture] /
/// `DeepgramCommandCapture`) for lower latency and better accuracy on the
/// actual command phrase. Only if the Deepgram leg fails for any reason
/// does capture fall back to on-device recognition instead, for that one
/// command attempt — a fresh `listen()` session (see
/// [_fallBackToOnDeviceCapture]/[_reopenListenForCommand]), since the
/// original session was already stopped to free the mic for the Deepgram
/// attempt. Either way, the resulting text reaches
/// [_dispatchCommand] identically. See [_startListening] and
/// [_onSessionResult] for the wake-word half, [_tryDeepgramCommandCapture]
/// for the command-capture half.
final globalVoiceServiceProvider =
    StateNotifierProvider<GlobalVoiceService, GlobalVoiceState>(
      (ref) => GlobalVoiceService(ref),
    );

class GlobalVoiceService extends StateNotifier<GlobalVoiceState> {
  GlobalVoiceService(this._ref) : super(const GlobalVoiceState());

  final Ref _ref;

  SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  /// Near-miss variants Android's generic on-device recognizer has been
  /// observed producing for the invented brand wake word "FieldLoop" (real
  /// device logs: "hey facebook", "filled loop", "field look", "field
  /// rope", "fillup" — it biases toward common trained words/phrases over
  /// an unfamiliar one). Matching is a plain case-insensitive substring
  /// check against the running transcript (see [_matchWakeWord]), so
  /// "allowing minor extra words around them" falls out for free — no
  /// other code needs to change to add a variant, just extend this set as
  /// new mishearings show up in future logs.
  static const Set<String> _wakeWordVariants = {
    'field loop',
    'fieldloop',
    'facebook',
    'filled loop',
    'field look',
    'field rope',
    'fillup',
    'fill up',
    'feel loop',
    'field lube',
  };

  /// Finds the earliest-occurring known wake-word variant in [lowerText]
  /// (already lowercased by the caller). If more than one variant starts
  /// at the same position, prefers the longest one — matters if a shorter
  /// variant happens to be a prefix of a longer one, so the split point
  /// doesn't clip into what should be command text.
  _WakeWordMatch? _matchWakeWord(String lowerText) {
    _WakeWordMatch? best;
    for (final variant in _wakeWordVariants) {
      final start = lowerText.indexOf(variant);
      if (start == -1) continue;
      final candidate = _WakeWordMatch(variant, start, start + variant.length);
      if (best == null ||
          candidate.start < best.start ||
          (candidate.start == best.start && candidate.end > best.end)) {
        best = candidate;
      }
    }
    return best;
  }

  /// Default silence threshold applied to on-device command capture — the
  /// native recognizer's own `pauseFor`, passed via `SpeechListenOptions`
  /// whenever a session is (re)started for command capture (see
  /// [_reopenListenForCommand]). This is the FIX 5 tuning knob: short
  /// enough to finalize the command promptly after the technician
  /// stops talking, long enough not to cut off a brief mid-phrase pause
  /// (e.g. "job... complete") or a troubleshooting question. Starting point
  /// picked conservatively at 2s (down from the previous 5s command-stage
  /// pauseFor) — tune down further only after real-device latency logs (see
  /// FIX 4) confirm it isn't clipping speech. This is a per-COMMAND-SET
  /// default: individual short, single-word commands (e.g. "confirm",
  /// "retake") override it via [VoiceCommand.pauseWindow] — see
  /// [_matchedShortWindowCommand].
  static const Duration _commandPauseFor = Duration(seconds: 2);

  /// FIX 2 (wake-word bug) — default for how long to wait, from the app's
  /// own clock, after the last new bit of speech before treating the
  /// command as finished. This is what actually decides "command is done,"
  /// NOT the native recognizer's own end-of-session signal (`result.
  /// finalResult`, or a 'done'/'notListening' status) — Android can end its
  /// own session as little as 1-3 seconds after the wake word, per
  /// `speech_to_text`'s own docs, well before the technician finishes
  /// speaking. When that happens before this timer fires,
  /// [_reopenListenForCommand] silently re-opens the mic and capture
  /// continues; only when nothing new arrives for this whole window do we
  /// actually finalize. Like [_commandPauseFor], short single-word commands
  /// override this via [VoiceCommand.pauseWindow].
  static const Duration _commandSettleWindow = Duration(milliseconds: 1800);

  /// Native `pauseFor` for the BASELINE wake-word-listening session (as
  /// opposed to [_commandPauseFor] above, which governs the much shorter
  /// post-wake-word command-capture window) — see [_startListening]. Kept
  /// deliberately long: nobody has said anything yet in this state, so
  /// there's nothing to finalize on a pause, and normal silence (the
  /// technician thinking, walking, working) must not end the session on
  /// its own. Real-device logs showed the recognizer's own status going
  /// notListening/done every 1-2s even with a much shorter pauseFor,
  /// forcing constant restart cycling — this session should only end when
  /// WE explicitly stop it (registry-driven restart, a recoverable error,
  /// or the liveness check), never from ordinary quiet.
  static const Duration _wakeWordPauseFor = Duration(seconds: 18);

  /// Native `listenFor` ceiling for the same baseline session — a safety
  /// cap for platforms/OEMs that enforce their own maximum single-session
  /// duration, not the primary mechanism keeping the session open (that's
  /// [_wakeWordPauseFor]); the loop already restarts proactively (registry
  /// change, error, liveness check) well before this would ever matter.
  static const Duration _wakeWordListenFor = Duration(seconds: 58);

  bool _initialized = false;

  /// Whether a job is currently open (Job Detail is mounted, anywhere
  /// underneath whatever's pushed on top of it — see
  /// `JobDetailScreen.initState`/`dispose`, which are the only callers of
  /// [enterJobScope]/[exitJobScope]). The wake-word loop only actually
  /// listens while this is true — recognizer initialization (see
  /// [initialize]) happens independently/earlier, so there's no first-job
  /// delay, but Home/History/Profile never trigger the mic.
  bool _jobScopeActive = false;
  bool _wakeDetected = false;
  bool _commandHandled = false;
  String _pendingCommandText = '';

  /// Command text banked from native sessions that already ended this
  /// cycle (see [_reopenListenForCommand]) — the currently-open session's
  /// transcript starts fresh each time, so this is what keeps earlier
  /// words from being lost/overwritten when the mic reopens mid-command.
  String _bankedCommandText = '';
  Timer? _commandSettleTimer;

  /// The in-flight Deepgram capture attempt for the command currently being
  /// spoken, if any (see [_tryDeepgramCommandCapture]) — tracked so
  /// [exitJobScope]/[setMuted]/[stopForLogout]/[dispose] can cut it short
  /// instead of leaving an orphaned WebSocket + mic stream running after
  /// the technician has left the job, muted, or logged out.
  DeepgramCommandCapture? _activeDeepgramCapture;
  DateTime? _wakeWordDetectedAt;
  _ListenStage _stage = _ListenStage.idle;
  Completer<String>? _freeCaptureCompleter;

  // --- Session lifecycle tracking (stale-session fix) --------------------
  //
  // Minted fresh every time _ensureStoppedThenListen actually calls
  // _speech.listen() — i.e. once per genuinely NEW native session,
  // whether that's the wake-word loop starting (_startListening),
  // reopening mid-command (_reopenListenForCommand), or a free-text
  // capture (captureFreeText). Included in every VOICE debugPrint from
  // that point on via [_voiceLog], so a log line saying "listening" can
  // be checked against whether it's actually talking about the CURRENT
  // session or a stale reference to one that's already been superseded.
  int _sessionId = 0;

  /// How many onResult callbacks (partial or final) have landed for the
  /// CURRENT [_sessionId] — see [_armLivenessCheck]. Reset to 0 every time
  /// [_sessionId] is bumped.
  int _resultCallbackCount = 0;

  /// Wall-clock time of the most recent evidence of life for the CURRENT
  /// [_sessionId] — either an onResult callback (recognized speech) OR an
  /// onSoundLevelChange callback (raw mic amplitude, fires continuously
  /// regardless of whether anything was recognized). Reset to null every
  /// time [_sessionId] is bumped; updated by both [_onSessionResult]
  /// (indirectly, via [_resultCallbackCount]) and [_onSoundLevel]. See
  /// [_armLivenessCheck] — a session is only declared stale when NEITHER
  /// kind of callback has landed since it started, which is what silence
  /// (result callbacks only) used to be mistaken for.
  DateTime? _lastLivenessSignalAt;

  /// Throttle for the "still alive" debugPrint in [_onSoundLevel] — sound
  /// level callbacks can fire many times per second, so logging every one
  /// would flood the log; this logs at most once per
  /// [_soundLevelLogInterval] instead, purely to give test logs visible
  /// proof that silence is being tracked as liveness, not just assumed.
  DateTime? _lastSoundLevelLogAt;
  static const Duration _soundLevelLogInterval = Duration(seconds: 2);

  /// Session id [_ensureStoppedThenListen] believes is genuinely still
  /// live on the native side right now — set the moment `_speech.listen()`
  /// returns successfully, cleared ONLY by a real onStatus('done'/
  /// 'notListening') callback (see [_confirmSessionStopped]) or by a forced
  /// stale-session reinit ([_recoverFromStaleSession]). Deliberately never
  /// inferred from `_speech.isListening` — that getter is itself a
  /// Dart-side flag the plugin sets locally and is exactly what let a new
  /// `listen()` attach to a native session that hadn't actually finished
  /// tearing down; this field is the fix, gated on the recognizer's own
  /// callback instead.
  int? _liveSessionId;

  /// True whenever a native session has been confirmed (or forced) to have
  /// ended and the next `listen()` still owes it a post-teardown settle
  /// delay (see [_settleDelay]). Set in [_confirmSessionStopped] (a real
  /// onStatus callback landed) and consumed — then cleared — the next time
  /// [_ensureStoppedThenListen] runs. Cleared without consuming on a
  /// stale-session reinit, since a freshly recreated `SpeechToText`
  /// instance has nothing to settle from.
  bool _pendingSettle = false;

  /// Resolved by a genuine onStatus('done'/'notListening') callback for
  /// whatever session [_ensureStoppedThenListen] just called `stop()` on
  /// (see [_confirmSessionStopped]). This — not `_speech.isListening` — is
  /// what "confirmed the previous session actually stopped" now means.
  Completer<void>? _stopConfirmation;

  /// Mandatory quiet period after a genuinely confirmed session end, before
  /// the next `listen()` call — gives the native side a little extra room
  /// to finish releasing the session even after it has told us it's done.
  static const Duration _settleDelay = Duration(milliseconds: 500);

  /// Bounded safety net for [_stopConfirmation] — NOT the normal path.
  /// Real sessions always report done/notListening; this only fires if one
  /// genuinely never does (e.g. it's already the stale/dead session this
  /// whole mechanism exists to catch), so a confirmation wait can't hang
  /// the loop forever. Anything logged against this path is, by
  /// definition, degraded — the liveness check ([_armLivenessCheck]) is
  /// what's supposed to catch that session and force a reinit before this
  /// timeout would ever matter in practice.
  static const Duration _stopConfirmationTimeout = Duration(seconds: 2);

  /// Guards against overlapping stale-session recoveries (see
  /// [_recoverFromStaleSession]).
  bool _reinitializing = false;

  void _voiceLog(String message) =>
      debugPrint('VOICE [session=$_sessionId]: $message');

  /// Called from [_onStatus] whenever the recognizer reports 'done' or
  /// 'notListening' — the one and only genuine signal that a native
  /// session has actually ended. Clears [_liveSessionId] (nothing is
  /// live anymore), flags [_pendingSettle] so the next `listen()` still
  /// waits out [_settleDelay], and resolves whichever
  /// [_ensureStoppedThenListen] call (if any) is currently blocked waiting
  /// for exactly this.
  void _confirmSessionStopped(String status) {
    final sessionId = _sessionId;
    _liveSessionId = null;
    _pendingSettle = true;
    final completer = _stopConfirmation;
    if (completer != null && !completer.isCompleted) {
      _voiceLog(
        'genuine onStatus($status) confirmation received for session=$sessionId — real teardown confirmed',
      );
      completer.complete();
    }
  }

  /// A few seconds after a native session claims to have started
  /// listening, checks whether the recognizer has actually delivered ANY
  /// onResult callback (even an empty/partial one — this does not require
  /// the wake word to have been heard, just some sign of life from the
  /// platform channel). If not, the recognizer's own status/`isListening`
  /// state is lying — it says "listening" while the underlying native
  /// session is actually dead — and this proactively forces a full
  /// recognizer reinit ([_recoverFromStaleSession]) rather than waiting
  /// passively.
  ///
  /// NOTE for whoever reads these logs: Android's on-device recognizer only
  /// fires onResult when it detects actual speech — it never fires one
  /// during pure silence. That made the old result-only check indistinguishable
  /// from a genuinely dead session for the first several seconds of EVERY
  /// wake-word cycle, since nobody has said anything yet. onSoundLevelChange
  /// (see [_onSoundLevel]) is the fix: it fires continuously off raw mic
  /// amplitude regardless of whether anything was recognized, so it's true
  /// liveness rather than recognition liveness. A session is now only
  /// declared stale when NEITHER callback has landed for the whole window —
  /// what's diagnostic in these logs is a STALE warning that immediately
  /// follows a screen transition where the technician DID say something
  /// afterward and it went unheard — correlate against the registry-swap
  /// timestamps ([VoiceCommandRegistry]) and [_sessionId] in the
  /// surrounding log lines.
  static const Duration _livenessCheckDelay = Duration(seconds: 8);

  void _armLivenessCheck(int sessionId) {
    Timer(_livenessCheckDelay, () {
      if (!mounted) return;
      // A newer session has since started (or this one's already been
      // superseded/torn down) — this stale check no longer means anything.
      if (_sessionId != sessionId) return;
      if (_lastLivenessSignalAt == null) {
        debugPrint(
          'VOICE LIVENESS WARNING [session=$sessionId]: no recognizer OR sound-level callbacks '
          'received ${_livenessCheckDelay.inMilliseconds}ms after claimed listening start — '
          'treating as STALE and forcing a full recognizer reinit.',
        );
        unawaited(_recoverFromStaleSession(sessionId));
      }
    });
  }

  /// True liveness signal (FIX: liveness watchdog false positives) — fires
  /// continuously off raw mic amplitude whenever the recognizer is actually
  /// running, independent of whether any speech was recognized (see
  /// [_ensureStoppedThenListen], which wires this into every `listen()`
  /// call). Updates [_lastLivenessSignalAt] so [_armLivenessCheck] sees a
  /// perfectly healthy, silent session as alive rather than stale.
  void _onSoundLevel(double level) {
    _lastLivenessSignalAt = DateTime.now();
    final now = DateTime.now();
    final lastLog = _lastSoundLevelLogAt;
    if (lastLog == null || now.difference(lastLog) >= _soundLevelLogInterval) {
      _lastSoundLevelLogAt = now;
      _voiceLog(
        'sound-level callback (level=$level) reset the liveness timer — session genuinely alive',
      );
    }
  }

  /// Confirmed-stale recovery (FIX: stale-session race) — a session that
  /// claimed "listening" but delivered zero callbacks for
  /// [_livenessCheckDelay] is not coming back; simply stopping and
  /// re-listening on the SAME `SpeechToText` instance is exactly the
  /// stop()/listen() cycle that got it into this state in the first place.
  /// Instead this disposes the instance entirely and recreates it from
  /// scratch, then resumes the wake-word loop once the fresh instance is
  /// initialized (only if still job-scoped, unmuted, and available).
  Future<void> _recoverFromStaleSession(int sessionId) async {
    if (!mounted || _sessionId != sessionId || _reinitializing) return;
    _reinitializing = true;
    try {
      _voiceLog(
        'stale session=$sessionId confirmed (zero callbacks) — disposing and recreating the recognizer',
      );
      _stage = _ListenStage.idle;
      _cancelCommandSettleTimer();
      _cancelRestartDebounce();
      _cancelActiveDeepgramCapture();
      // The dead session is presumed unrecoverable — do not wait on a
      // callback that may never arrive; a fresh instance needs no settle.
      _liveSessionId = null;
      _pendingSettle = false;
      _stopConfirmation = null;
      await _withSpeechLock('reinit (stale session=$sessionId)', () async {
        try {
          _voiceLog(
            'disposing stale SpeechToText instance (session=$sessionId)',
          );
          await _speech.cancel();
          _speech = SpeechToText();
          _voiceLog(
            're-initializing a fresh SpeechToText instance after stale session=$sessionId',
          );
          final available = await _speech.initialize(
            onStatus: _onStatus,
            onError: _onError,
          );
          _voiceLog(
            'reinit complete (was session=$sessionId), available=$available',
          );
          if (mounted) state = state.copyWith(available: available);
        } catch (e, stackTrace) {
          debugPrint(
            'VOICE ERROR (stale-session reinit) [was session=$sessionId]: $e\n$stackTrace',
          );
          if (mounted) state = state.copyWith(available: false);
        }
      });
      if (!mounted) return;
      if (state.available && _jobScopeActive && !state.muted) {
        _voiceLog(
          'resuming wake-word loop on the freshly reinitialized recognizer',
        );
        await _startListening(reason: 'livenessStaleReinit');
      }
    } finally {
      _reinitializing = false;
    }
  }
  // ------------------------------------------------------------------

  /// Initializes the recognizer so it's ready to go the moment a job is
  /// opened — does NOT start listening by itself (see [enterJobScope] for
  /// that). Safe to call more than once — only the first call does
  /// anything. Called exactly once, from `RootShell`, the moment
  /// microphone permission is confirmed granted (i.e. as soon as the
  /// technician is signed in, well before any job is open).
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      debugPrint('VOICE: initializing speech recognizer...');
      final available = await _speech.initialize(
        onStatus: _onStatus,
        onError: _onError,
      );
      debugPrint('VOICE: speech recognizer available=$available');
      if (!mounted) return;
      state = state.copyWith(available: available);
      // Covers the (unusual but possible) case where a job was already
      // opened before this async initialize() resolved.
      if (available && _jobScopeActive && !state.muted) {
        await _startListening(reason: 'initialize');
      }
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (initialize): $e\n$stackTrace');
      if (mounted) state = state.copyWith(available: false);
    }
  }

  /// Starts the wake-word loop — called once when a job is opened (see
  /// `JobDetailScreen.initState`). Voice is never active on Home/History/
  /// Profile or anywhere else outside a job: those screens simply never
  /// call this.
  Future<void> enterJobScope() async {
    debugPrint('VOICE: entering job scope (mic will start listening)');
    _jobScopeActive = true;
    if (!mounted || !state.available || state.muted) return;
    await _startListening(reason: 'enterJobScope');
  }

  /// Stops the wake-word loop — called once when the technician backs all
  /// the way out of a job (see `JobDetailScreen.dispose`). The recognizer
  /// itself, the mute preference, and the rest of the singleton's state are
  /// left alone; re-entering a job later (or logging into a new one) just
  /// resumes via [enterJobScope].
  void exitJobScope() {
    debugPrint('VOICE: exiting job scope (mic stops listening)');
    _jobScopeActive = false;
    _stage = _ListenStage.idle;
    _cancelCommandSettleTimer();
    _cancelRestartDebounce();
    _cancelActiveDeepgramCapture();
    unawaited(_lockedStop('exitJobScope'));
    _completeFreeCapture('');
  }

  /// Cuts short an in-flight Deepgram capture (see
  /// [_tryDeepgramCommandCapture]), if any — called from every place that
  /// otherwise stops the on-device recognizer mid-cycle, so a Deepgram
  /// WebSocket/mic stream never keeps running after the technician has left
  /// the job, muted, or logged out.
  void _cancelActiveDeepgramCapture() {
    final capture = _activeDeepgramCapture;
    _activeDeepgramCapture = null;
    capture?.cancel();
  }

  /// Full teardown — called only on logout. `_initialized`/`_jobScopeActive`
  /// are reset so a subsequent login can call [initialize]/[enterJobScope]
  /// again from scratch.
  Future<void> stopForLogout() async {
    debugPrint('VOICE: stopping for logout');
    _initialized = false;
    _jobScopeActive = false;
    _stage = _ListenStage.idle;
    _cancelCommandSettleTimer();
    _cancelRestartDebounce();
    _cancelActiveDeepgramCapture();
    await _lockedStop('stopForLogout');
    await _withSpeechLock('cancel (stopForLogout)', () => _speech.cancel());
    // A forced cancel() outside the normal stop->confirm->settle flow —
    // don't leave a future listen() waiting on a confirmation this cancel
    // may never deliver.
    _liveSessionId = null;
    _pendingSettle = false;
    _stopConfirmation = null;
    _completeFreeCapture('');
    if (mounted) state = const GlobalVoiceState();
  }

  Future<void> setMuted(bool muted) async {
    debugPrint('VOICE: ${muted ? "muting" : "unmuting"}');
    state = state.copyWith(muted: muted);
    if (muted) {
      _stage = _ListenStage.idle;
      _cancelCommandSettleTimer();
      _cancelRestartDebounce();
      _cancelActiveDeepgramCapture();
      await _lockedStop('setMuted');
    } else if (state.available && _jobScopeActive) {
      await _startListening(reason: 'unmuted');
    }
  }

  /// Serializes every `listen()`/`stop()`/`cancel()` call on [_speech].
  /// Checking `_speech.isListening` right before calling `stop()`/`listen()`
  /// (as [_ensureStoppedThenListen] already did) guards against calling
  /// `listen()` on a session that's obviously still active, but it does
  /// NOT stop two of these operations from firing concurrently in the
  /// first place — e.g. [_tryDeepgramCommandCapture] stopping the
  /// recognizer to free the mic for Deepgram, while the ordinary
  /// auto-restart-after-timeout loop ([_scheduleWakeWordRestart]) happens
  /// to fire a `listen()` around the same moment. Two such calls
  /// overlapping mid-flight (not just back-to-back) is exactly what
  /// produces `error_busy` on the native side. Every direct
  /// `_speech.listen()`/`.stop()`/`.cancel()` call in this class (except
  /// [dispose], which is synchronous and is the final, unconditional
  /// teardown) must go through [_withSpeechLock] instead of touching
  /// `_speech` directly, so at most one such operation is ever in flight —
  /// a second caller waits for the first to actually finish rather than
  /// firing concurrently.
  Future<void>? _speechOpLock;

  /// Safety net only — `_withSpeechLock`'s own try/finally already
  /// guarantees release on every normal return AND every thrown
  /// exception. The one thing a finally block cannot save you from is an
  /// `await` inside [operation] that never resolves at all (most likely a
  /// hung native platform-channel call — e.g. the process got destabilized
  /// by an unrelated native crash while `_speech.stop()`/`.listen()` was
  /// in flight, so the native side never calls back). If the lock is still
  /// held by the SAME acquisition after this long, it's force-cleared so
  /// voice can recover within a few seconds instead of staying dead for
  /// the rest of the session — see the loud warning this logs, which is
  /// meant to be investigated as a real bug, not silently relied upon.
  static const Duration _maxLockHoldDuration = Duration(seconds: 5);

  Future<T> _withSpeechLock<T>(
    String opName,
    Future<T> Function() operation,
  ) async {
    while (_speechOpLock != null) {
      _voiceLog(
        '"$opName" waiting — another speech start/stop operation is already in flight',
      );
      await _speechOpLock;
    }
    final completer = Completer<void>();
    final lockFuture = completer.future;
    _speechOpLock = lockFuture;
    debugPrint('VOICE LOCK: acquired by "$opName"');
    final watchdog = Timer(_maxLockHoldDuration, () {
      // Only force-clear if this exact acquisition is still the current
      // holder — if it already released normally and something else has
      // since acquired the lock, this fired too late to mean anything and
      // must not stomp on that newer, legitimate holder.
      if (!identical(_speechOpLock, lockFuture)) return;
      debugPrint(
        'VOICE LOCK: force-cleared after ${_maxLockHoldDuration.inMilliseconds}ms — '
        'held by "$opName" — this indicates a release bug (or a hung native call), investigate '
        'the acquire without a matching release',
      );
      _speechOpLock = null;
      if (!completer.isCompleted) completer.complete();
    });
    try {
      return await operation();
    } finally {
      watchdog.cancel();
      // Same guard as the watchdog: only clear the lock if it's still
      // ours to clear — the watchdog may have already force-cleared it
      // (and possibly let a newer acquisition through) before this
      // original, now long-overdue `operation()` finally resolved.
      if (identical(_speechOpLock, lockFuture)) _speechOpLock = null;
      if (!completer.isCompleted) completer.complete();
      debugPrint('VOICE LOCK: released by "$opName"');
    }
  }

  /// Stops [_speech] (if it's actually listening) under [_withSpeechLock].
  /// [reason] is purely for the debugPrint trail (which call site asked for
  /// this stop) — every non-listen stop() call in this class (mute,
  /// exiting job scope, logout, handing the mic to Deepgram) routes through
  /// here instead of calling `_speech.stop()` directly.
  Future<void> _lockedStop(String reason) {
    return _withSpeechLock('stop ($reason)', () async {
      if (_speech.isListening) {
        _voiceLog('stopping speech session ($reason)');
        await _speech.stop();
      } else {
        _voiceLog('stop ($reason) requested but nothing was listening');
      }
    });
  }

  /// The one place `listen()` is ever called from. Runs under
  /// [_withSpeechLock] (as does every stop() elsewhere in this class — see
  /// [_lockedStop]) so this can never overlap with another in-flight
  /// stop()/listen(), which is what used to produce `error_busy`. Also the
  /// one place a new [_sessionId] is minted — see the DIAGNOSTIC block
  /// above — right before the actual `_speech.listen()` call, so it covers
  /// every kind of session this method starts (wake-word loop, mid-command
  /// reopen, free-text capture) uniformly.
  Future<void> _ensureStoppedThenListen({
    required void Function(SpeechRecognitionResult) onResult,
    required SpeechListenOptions options,
  }) {
    return _withSpeechLock('listen', () async {
      final priorSessionId = _liveSessionId;
      if (priorSessionId != null) {
        // Never trust `_speech.isListening` alone — that's exactly the
        // Dart-side flag that let a new listen() attach to a native
        // session that hadn't actually finished dying. Ask it to stop,
        // then genuinely WAIT for its own onStatus('done'/'notListening')
        // callback before doing anything else.
        _voiceLog(
          'stopping session=$priorSessionId — waiting for its REAL onStatus confirmation (not assuming from our own flag)',
        );
        final completer = Completer<void>();
        _stopConfirmation = completer;
        await _speech.stop();
        await completer.future.timeout(
          _stopConfirmationTimeout,
          onTimeout: () {
            _voiceLog(
              'WARNING: no genuine stop confirmation for session=$priorSessionId within '
              '${_stopConfirmationTimeout.inMilliseconds}ms — proceeding anyway as a bounded safety '
              'fallback (this session is likely the stale one the liveness check will catch)',
            );
          },
        );
        if (identical(_stopConfirmation, completer)) _stopConfirmation = null;
        if (!mounted) return;
      } else {
        _voiceLog('no live session tracked — nothing to stop');
      }
      if (_pendingSettle) {
        _voiceLog(
          'settling ${_settleDelay.inMilliseconds}ms past the confirmed stop before starting a new session',
        );
        await Future.delayed(_settleDelay);
        _pendingSettle = false;
        if (!mounted) return;
      }
      _sessionId++;
      final sessionId = _sessionId;
      _resultCallbackCount = 0;
      _lastLivenessSignalAt = null;
      _lastSoundLevelLogAt = null;
      try {
        _voiceLog('calling _speech.listen() — this is the new current session');
        await _speech.listen(
          onResult: onResult,
          onSoundLevelChange: _onSoundLevel,
          listenOptions: options,
        );
        _liveSessionId = sessionId;
        _armLivenessCheck(sessionId);
      } catch (e, stackTrace) {
        // listen() awaits a platform channel call and throws
        // ListenFailedException (wrapping a native error_busy, among
        // others) if the recognizer refuses the session — must not go
        // unhandled, or `_stage` is left claiming a session is active when
        // none actually started, and the loop goes silent for good.
        debugPrint(
          'VOICE ERROR (listen) [session=$sessionId]: $e\n$stackTrace',
        );
        _stage = _ListenStage.idle;
        _liveSessionId = null;
        _scheduleWakeWordRestart(_RestartCause.listenCallThrew);
      }
    });
  }

  /// Statuses the on-device recognizer reports at the end of essentially
  /// every listen session — never a reason to stop the wake-word loop, only
  /// a reason to restart it (see [_scheduleWakeWordRestart]).
  static const _restartStatuses = {'done', 'notListening'};

  void _onStatus(String status) {
    _voiceLog('recognizer status=$status');
    // FIX (self-sustaining restart loop): captured BEFORE _confirmSessionStopped
    // touches anything below. Non-null here means some in-flight
    // _ensureStoppedThenListen call is actively blocked awaiting exactly
    // this stop's confirmation (see _stopConfirmation) — i.e. this status
    // event is the recognizer confirming an INTENTIONAL stop of the PRIOR
    // session, issued as prep for starting a brand new one. Critically,
    // _startListening already set _stage = active for that NEW session
    // before its listen() call even happens, so without this guard the
    // restart-decision block below would misread this as "the current
    // active session ended on its own" and fire ANOTHER
    // _scheduleWakeWordRestart() — which itself stops the session that
    // restart just started, producing the exact same confirmation again,
    // forever. The _ensureStoppedThenListen call that's already awaiting
    // this confirmation knows exactly what happens next (proceed to
    // listen()); nothing here needs to also react to it.
    final isAwaitedStopConfirmation =
        _restartStatuses.contains(status) && _stopConfirmation != null;
    // Genuine confirmation that a session actually ended — tracked
    // regardless of mounted/muted so [_liveSessionId]/[_pendingSettle]
    // stay accurate for whenever listening next resumes.
    if (_restartStatuses.contains(status)) _confirmSessionStopped(status);
    if (!mounted || state.muted) return;
    if (isAwaitedStopConfirmation) {
      _voiceLog(
        'status=$status confirms an intentionally-requested stop that another in-flight '
        'operation is already awaiting — suppressing the restart-decision below (this is NOT '
        'the current active session ending on its own)',
      );
      return;
    }
    // A session (or free-text capture) can end (silence timeout) without
    // ever producing a final result — still treat that as "didn't catch it"
    // rather than leaving the UI stuck on an empty transcript, or a
    // free-text capture awaiting forever. If the wake word was never even
    // heard this cycle, there's nothing to process — just restart quietly.
    if (_restartStatuses.contains(status) && !_commandHandled) {
      if (_stage == _ListenStage.active) {
        if (_wakeDetected) {
          // The native session ended on its own (Android's own floor, not
          // the technician actually finishing) — reopen and keep
          // capturing; [_commandSettleTimer] is the only thing allowed to
          // decide the command is actually done.
          unawaited(_reopenListenForCommand());
        } else {
          _scheduleWakeWordRestart(_RestartCause.sessionEndedNoWakeWord);
        }
        return;
      }
      if (_stage == _ListenStage.freeCapture) {
        _commandHandled = true;
        _completeFreeCapture('');
        return;
      }
    }
  }

  /// Recognizer errors that fire naturally at the end of nearly every
  /// wake-word listen session — the device found no speech, found speech
  /// that didn't parse, the native client hit a routine hiccup
  /// (`error_client` — a generic, frequent Android SpeechRecognizer error,
  /// not a fatal one), the recognizer was still busy finishing a previous
  /// session when a new one was requested (`error_busy` — see
  /// [_withSpeechLock], which now prevents most of these outright, but a
  /// stray one is still tolerated here rather than trusted to never
  /// happen), a transient connectivity blip on a device/OS combo that
  /// routes on-device recognition through a network call (`error_network`
  /// — same "normal and frequent, not fatal" shape as the others), or the
  /// OS momentarily reporting the requested locale unavailable
  /// (`error_language_unavailable` — observed as a transient hiccup, not a
  /// persistent device limitation; it clears on its own on retry). These
  /// must never stop the loop, no matter how many times in a row they
  /// happen — real-device logs showed each of these six reaching the
  /// permanent-disable branch below instead of restarting, one at a time
  /// across successive fixes, as each was missing from this set.
  static const _recoverableErrors = {
    'error_speech_timeout',
    'error_no_match',
    'error_client',
    'error_network',
    'error_busy',
    'error_language_unavailable',
  };

  void _onError(SpeechRecognitionError error) {
    debugPrint(
      'VOICE ERROR (recognizer) [session=$_sessionId]: ${error.errorMsg} permanent=${error.permanent}',
    );
    if (!mounted || state.muted) return;

    if (_recoverableErrors.contains(error.errorMsg)) {
      _voiceLog(
        'recoverable error ${error.errorMsg}, restarting listener (not disabling)',
      );
      if (_stage == _ListenStage.active && !_commandHandled) {
        if (_wakeDetected) {
          unawaited(_reopenListenForCommand());
        } else {
          _scheduleWakeWordRestart(_RestartCause.recoverableError);
        }
      } else if (_stage == _ListenStage.freeCapture && !_commandHandled) {
        _commandHandled = true;
        _completeFreeCapture('');
      }
      return;
    }

    // Anything else (permission revoked mid-session, a genuinely broken
    // recognizer, etc.) — stop retrying so we don't spam a broken engine.
    // Reserved for things like a denied permission or the recognizer
    // failing to even initialize — NOT for normal, frequent mid-session
    // recognition misses, which are all handled above instead.
    if (error.permanent) {
      _voiceLog(
        'permanent recognizer error (${error.errorMsg}), disabling voice input',
      );
      _stage = _ListenStage.idle;
      state = state.copyWith(available: false);
      _completeFreeCapture('');
    }
  }

  /// Pending debounce window for [_scheduleWakeWordRestart] — see that
  /// method's doc comment. Cancelled (and, where relevant, re-armed) at
  /// every other place a fresh listen/stop decision supersedes "restart
  /// later": [_startListening] (a session is starting right now, so any
  /// still-pending restart from an earlier cycle is moot) and every full
  /// teardown/mute point that already cancels [_commandSettleTimer]
  /// ([exitJobScope], [stopForLogout], [setMuted], [dispose]).
  Timer? _restartDebounceTimer;

  /// The most recent cause passed to [_scheduleWakeWordRestart] while a
  /// debounce window is pending — logged when the debounce actually fires
  /// so a RAPID SWAP collapse still shows which of the (possibly several)
  /// collapsed triggers is the one that's about to run.
  _RestartCause? _pendingRestartCause;

  void _cancelRestartDebounce() {
    _restartDebounceTimer?.cancel();
    _restartDebounceTimer = null;
    _pendingRestartCause = null;
  }

  /// FIX 2 — debounces the restart so a BURST of restart-triggering events
  /// close together collapses into exactly ONE actual restart once things
  /// settle, instead of each trigger independently scheduling its own
  /// delayed [_startListening] call. This is called from four different
  /// places that can each independently decide "nothing more to do this
  /// cycle, restart the wake-word loop" — [_onStatus], [_onError],
  /// [_onSessionResult] (no wake word heard before the session ended), and
  /// [_processCommandText] (a command just finished) — and real-device
  /// logs showed these firing close enough together (e.g. right as a
  /// voice-triggered command's handler navigates to another screen) to
  /// each schedule their own independent 400ms-delayed restart. Even
  /// though [_withSpeechLock] already serializes the resulting
  /// stop()/listen() calls so they can't run concurrently, back-to-back
  /// restarts are still wasted work — starting a session only to
  /// immediately restart it again — and are exactly the kind of
  /// close-together stop()/listen() pair most likely to produce
  /// `error_busy` on the native side despite the lock. A `Timer` that gets
  /// cancelled and re-armed on every call (rather than a plain
  /// `Future.delayed` per call, which can't be cancelled) is what makes
  /// this an actual debounce instead of N independent timers all still
  /// running.
  void _scheduleWakeWordRestart(_RestartCause cause) {
    if (!mounted || state.muted) return;
    _voiceLog('restart TRIGGERED — cause=${cause.name}');
    _stage = _ListenStage.idle;
    _cancelCommandSettleTimer();
    if (_restartDebounceTimer != null) {
      _voiceLog(
        'RAPID SWAP: another restart trigger (cause=${cause.name}) arrived within the debounce '
        'window — collapsing into the single pending restart (previously pending '
        'cause=${_pendingRestartCause?.name}; resetting the window instead of stacking a second '
        'stop/listen cycle)',
      );
    }
    _pendingRestartCause = cause;
    _restartDebounceTimer?.cancel();
    _restartDebounceTimer = Timer(const Duration(milliseconds: 400), () {
      _restartDebounceTimer = null;
      final firedCause = _pendingRestartCause;
      _pendingRestartCause = null;
      if (!mounted || state.muted || !state.available || !_jobScopeActive)
        return;
      _voiceLog(
        'debounce window elapsed — running the single collapsed restart now for '
        'cause=${firedCause?.name} (stop -> real confirmation -> settle -> listen)',
      );
      unawaited(
        _startListening(reason: 'scheduledRestart:${firedCause?.name}'),
      );
    });
  }

  /// Starts the listen() session that detects the wake word (FIX 1).
  /// Uses [_wakeWordPauseFor]/[_wakeWordListenFor] — long enough that
  /// ordinary silence never ends this session on its own, since nothing
  /// has been said yet and the wake word alone is all this session is
  /// for; the moment it's heard, this session is stopped and command
  /// capture hands off to Deepgram (or, on failure, a fresh on-device
  /// session with the much shorter [_commandPauseFor] — see
  /// [_tryDeepgramCommandCapture]).
  Future<void> _startListening({required String reason}) async {
    _voiceLog(
      '_startListening() called — reason=$reason (mounted=$mounted muted=${state.muted} '
      'available=${state.available} jobScopeActive=$_jobScopeActive)',
    );
    if (!mounted || state.muted || !state.available || !_jobScopeActive) {
      _voiceLog('_startListening() returning early — guard condition not met');
      return;
    }
    _voiceLog('listening (single session: wake word + command)...');
    _stage = _ListenStage.active;
    _wakeDetected = false;
    _wakeWordDetectedAt = null;
    _pendingCommandText = '';
    _bankedCommandText = '';
    _commandHandled = false;
    _cancelCommandSettleTimer();
    // A session is starting right now — any earlier "restart later" plan
    // still pending is moot.
    _cancelRestartDebounce();
    state = state.copyWith(transcript: '', phase: VoicePhase.listening);
    _voiceLog(
      'baseline wake-word listen() params: pauseFor=${_wakeWordPauseFor.inSeconds}s '
      'listenFor=${_wakeWordListenFor.inSeconds}s (session should stay open across normal '
      'silence and only end via explicit stop, not on its own)',
    );
    await _ensureStoppedThenListen(
      onResult: _onSessionResult,
      options: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        listenFor: _wakeWordListenFor,
        pauseFor: _wakeWordPauseFor,
      ),
    );
  }

  /// Single onResult handler covering both halves of the cycle. `result.
  /// recognizedWords` is the FULL transcript accumulated since the CURRENT
  /// native session started (not just what's new) — but that native
  /// session can end on its own well before the technician finishes
  /// speaking (see [_commandSettleWindow]), so once the wake word has been
  /// heard, a session ending is never treated as "command done" here —
  /// only [_armCommandSettleTimer]'s own timer decides that. A session
  /// ending early just banks what's been heard so far ([_bankedCommandText])
  /// and reopens the mic via [_reopenListenForCommand], invisibly to the
  /// technician.
  void _onSessionResult(SpeechRecognitionResult result) {
    // The speech_to_text plugin calls this listener directly (see
    // `_notifyResults` in speech_to_text.dart) with no try/catch of its own
    // — an uncaught exception here would surface (if at all) as an opaque
    // platform-channel error instead of one of our own debugPrints, and the
    // wake-word loop would silently die. Wrapping defensively so any
    // exception in this new code path is guaranteed to be visible.
    try {
      // DIAGNOSTIC — counts toward this session's liveness check (see
      // _armLivenessCheck); ANY callback counts, even an empty/partial one
      // with no words recognized yet, since the point is just proving the
      // native session is actually alive and delivering callbacks at all.
      _resultCallbackCount++;
      _lastLivenessSignalAt = DateTime.now();
      _voiceLog(
        '_onSessionResult called (#$_resultCallbackCount this session, wakeDetected=$_wakeDetected '
        'final=${result.finalResult} words="${result.recognizedWords}")',
      );
      if (!mounted || _commandHandled) return;
      final words = result.recognizedWords.toLowerCase();

      if (!_wakeDetected) {
        final matched = _matchWakeWord(words);
        if (matched == null) {
          if (result.finalResult) {
            // Session timed out (silence) without ever hearing the wake
            // word — nothing to process, just start the next cycle.
            _scheduleWakeWordRestart(_RestartCause.sessionEndedNoWakeWord);
          }
          return;
        }
        _wakeDetected = true;
        _wakeWordDetectedAt = DateTime.now();
        _voiceLog(
          "wake word matched via variant '${matched.variant}' in \"$words\"",
        );
        _bankedCommandText = '';
        // Kept even though Deepgram capture (below) starts its own,
        // separate transcript stream: if Deepgram fails and
        // _fallBackToOnDeviceCapture resumes on-device recognition, this is
        // exactly the "already heard so far" state _reopenListenForCommand
        // expects, same as before.
        _pendingCommandText = words.substring(matched.end).trim();
        _onWakeWordDetected(); // FIX 2: instant haptic + tone, fire-and-forget
        if (mounted) state = state.copyWith(transcript: _pendingCommandText);
        _logLatency('wake-word-detected');
        // Command CAPTURE (not detection — the wake word itself always
        // stays on-device) now switches to Deepgram; see
        // _tryDeepgramCommandCapture for the on-device continuation this
        // used to do inline here, which only still runs as its fallback.
        unawaited(_tryDeepgramCommandCapture());
        return;
      }

      final matched = _matchWakeWord(words);
      final liveRemainder = matched != null
          ? words.substring(matched.end).trim()
          : words.trim();
      _pendingCommandText = _joinCommandParts(
        _bankedCommandText,
        liveRemainder,
      );
      if (mounted) state = state.copyWith(transcript: _pendingCommandText);
      _armCommandSettleTimer();
      if (result.finalResult) {
        _bankedCommandText = _pendingCommandText;
        unawaited(_reopenListenForCommand());
      }
    } catch (e, stackTrace) {
      debugPrint(
        'VOICE ERROR (_onSessionResult) [session=$_sessionId]: $e\n$stackTrace',
      );
    }
  }

  String _joinCommandParts(String banked, String live) {
    if (banked.isEmpty) return live;
    if (live.isEmpty) return banked;
    return '$banked $live';
  }

  /// FIX 2 — (re)starts the [_commandSettleWindow] countdown; called on
  /// every new bit of speech heard after the wake word (including the wake
  /// word itself landing). Only fires [_finishCommandCapture] if nothing
  /// new arrives for the whole window — i.e. this is a rolling debounce,
  /// not a one-shot timer from the wake word alone.
  void _armCommandSettleTimer() {
    _commandSettleTimer?.cancel();
    final window =
        _matchedShortWindowCommand()?.pauseWindow ?? _commandSettleWindow;
    _commandSettleTimer = Timer(window, () {
      _voiceLog(
        'command settle window (${window.inMilliseconds}ms) elapsed with no new speech, '
        'finalizing "$_pendingCommandText"',
      );
      _finishCommandCapture(_pendingCommandText);
    });
  }

  /// Looks up the currently-registered command (if any) that both declares a
  /// [VoiceCommand.pauseWindow] override and already matches the
  /// in-progress [_pendingCommandText] — e.g. once the technician has said
  /// "confirm", this finds `confirm_photo` and its short window applies to
  /// both the app-level settle timer ([_armCommandSettleTimer]) and the
  /// recognizer's own `pauseFor` on the next session ([_reopenListenForCommand]).
  /// Returns null while nothing short-windowed
  /// matches yet, so those callers fall back to the longer, generic default
  /// — this is what lets a single screen mix short commands ("confirm") with
  /// longer ones ("job complete") safely: only text that actually matches a
  /// short command's own `matches` predicate can shorten the window.
  VoiceCommand? _matchedShortWindowCommand() {
    final lower = _pendingCommandText.toLowerCase();
    final registry = _ref.read(voiceCommandRegistryProvider);
    for (final command in registry.values) {
      if (command.pauseWindow != null && command.matches(lower)) return command;
    }
    return null;
  }

  void _cancelCommandSettleTimer() {
    _commandSettleTimer?.cancel();
    _commandSettleTimer = null;
  }

  /// FIX 2 — reopens the mic mid-command, after the native session ended
  /// on its own before [_commandSettleTimer] fired. Deliberately does NOT
  /// touch `_wakeDetected`/`_pendingCommandText`/`_bankedCommandText` (only
  /// [_startListening] resets those, for a genuinely new cycle) — from the
  /// technician's perspective this is invisible, the mic never audibly
  /// drops and they never need to repeat the wake word.
  Future<void> _reopenListenForCommand() async {
    if (!mounted || state.muted || !state.available || _commandHandled) return;
    final pauseFor =
        _matchedShortWindowCommand()?.pauseWindow ?? _commandPauseFor;
    _voiceLog(
      'native session ended before settle window elapsed — reopening mic '
      '(banked="$_pendingCommandText", pauseFor=${pauseFor.inMilliseconds}ms)',
    );
    await _ensureStoppedThenListen(
      onResult: _onSessionResult,
      options: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        listenFor: const Duration(minutes: 5),
        pauseFor: pauseFor,
      ),
    );
  }

  /// The moment "fieldloop" is first recognized — independent of how long
  /// the rest of the command takes to capture or process, the technician
  /// gets instant confirmation the system heard them. Not awaited: this
  /// must not add latency to command parsing.
  void _onWakeWordDetected() {
    debugPrint('VOICE: _onWakeWordDetected() firing haptic + tone cue');
    HapticFeedback.lightImpact().catchError((e, stackTrace) {
      debugPrint('VOICE ERROR (haptic feedback): $e\n$stackTrace');
    });
    SystemSound.play(SystemSoundType.click).catchError((e, stackTrace) {
      debugPrint('VOICE ERROR (system sound): $e\n$stackTrace');
    });
  }

  /// The moment the wake word is detected on-device, command CAPTURE (not
  /// detection — the wake word itself always stays on-device, free and
  /// always-on) switches to Deepgram's streaming API for lower-latency,
  /// higher-accuracy recognition of the command phrase that follows. Falls
  /// back to the exact on-device continuation the old flow used (see
  /// [_fallBackToOnDeviceCapture]) for this one command attempt if anything
  /// about the Deepgram leg fails, so the technician is never left with
  /// dead air.
  Future<void> _tryDeepgramCommandCapture() async {
    if (!mounted || _commandHandled || !_jobScopeActive) return;
    _voiceLog('wake word detected — switching to Deepgram for command capture');

    // speech_to_text and the raw mic stream `record` needs both want
    // exclusive access to the microphone — the on-device session must be
    // fully stopped (not just have its pauseFor tweaked, as the old
    // continue-on-device flow did) before the Deepgram leg ever touches the
    // mic, or both silently fight over it.
    _stage = _ListenStage.idle;
    _cancelCommandSettleTimer();
    await _lockedStop('tryDeepgramCommandCapture');
    if (!mounted || _commandHandled || !_jobScopeActive) return;

    final accessToken =
        Supabase.instance.client.auth.currentSession?.accessToken;
    if (accessToken == null) {
      _voiceLog(
        'no Supabase session — cannot request a Deepgram token, falling back to on-device',
      );
      await _fallBackToOnDeviceCapture();
      return;
    }

    final capture = DeepgramCommandCapture(
      wakeWordDetectedAt: _wakeWordDetectedAt ?? DateTime.now(),
      onPartialTranscript: (partial) {
        if (!mounted || _commandHandled) return;
        _pendingCommandText = _joinCommandParts(_bankedCommandText, partial);
        state = state.copyWith(transcript: _pendingCommandText);
      },
    );
    _activeDeepgramCapture = capture;
    final result = await capture.capture(supabaseAccessToken: accessToken);
    _activeDeepgramCapture = null;
    if (!mounted || _commandHandled || !_jobScopeActive) return;

    final transcript = result?.transcript.trim() ?? '';
    if (transcript.isEmpty) {
      _voiceLog(
        'Deepgram capture produced no usable transcript — falling back to on-device',
      );
      await _fallBackToOnDeviceCapture();
      return;
    }

    final finalText = _joinCommandParts(_bankedCommandText, transcript);
    _voiceLog('command routed via Deepgram: "$finalText"');
    // Passes into the EXISTING command-matching/routing logic exactly as
    // the on-device path does — Deepgram only ever replaces HOW the text
    // was captured, never what happens with it afterward.
    _finishCommandCapture(finalText);
  }

  /// Resumes on-device recognition for the SAME command attempt already in
  /// progress — used only when the Deepgram leg fails for any reason (see
  /// [_tryDeepgramCommandCapture]). Deliberately reuses
  /// [_reopenListenForCommand] rather than a fresh [_startListening] cycle:
  /// the wake word has already been detected and `_pendingCommandText`/
  /// `_bankedCommandText` already reflect whatever was heard so far —
  /// exactly the state [_reopenListenForCommand] expects when a session
  /// needs to resume mid-command, so nothing already captured is lost.
  ///
  /// BUG B3 fix: this used to call a (since-removed) helper here first,
  /// which called `_speech.changePauseFor(...)` — valid only while a
  /// native session is ALREADY listening (that's how the original
  /// wake-word branch used it, on the still-active session that had just
  /// heard the wake word). By the time this fallback runs, though,
  /// [_tryDeepgramCommandCapture] has already fully stopped `_speech` (to
  /// free the mic for `record`), so calling `changePauseFor` on it threw
  /// `ListenNotStartedException`. No reordering/await was actually needed —
  /// [_reopenListenForCommand] already starts the new session with the
  /// correct (possibly short-window) `pauseFor` passed directly via
  /// `SpeechListenOptions`, so the separate `changePauseFor` call was both
  /// redundant and, in this context, broken. Removed.
  Future<void> _fallBackToOnDeviceCapture() async {
    if (!mounted || _commandHandled || !_jobScopeActive) return;
    _voiceLog('resuming on-device recognition for this command');
    _armCommandSettleTimer();
    await _reopenListenForCommand();
  }

  void _finishCommandCapture(String text) {
    if (_commandHandled) return;
    _commandHandled = true;
    _cancelCommandSettleTimer();
    _logLatency('command-captured');
    unawaited(_processCommandText(text));
  }

  Future<void> _processCommandText(String text) async {
    _stage = _ListenStage.idle;
    if (text.isEmpty) {
      _voiceLog('no command captured after wake word');
      if (mounted)
        state = state.copyWith(transcript: "Sorry, I didn't catch that");
      // FIX 3: don't gate the next wake-word cycle on this TTS finishing.
      unawaited(speak("Sorry, I didn't catch that"));
      _scheduleWakeWordRestart(_RestartCause.commandCycleComplete);
      return;
    }

    _voiceLog('command captured: "$text"');
    if (mounted) state = state.copyWith(transcript: text);
    await _dispatchCommand(text);
    _scheduleWakeWordRestart(_RestartCause.commandCycleComplete);
  }

  /// Matches [text] against every currently-registered command (see
  /// `voiceCommandRegistryProvider`) and runs the first match — this is the
  /// generic engine's only notion of "commands"; it knows nothing about
  /// arrival, jobs, photos, or any other business logic, all of which lives
  /// in whichever screen registered the matching entry.
  Future<void> _dispatchCommand(String text) async {
    final registry = _ref.read(voiceCommandRegistryProvider);
    final lower = text.toLowerCase();
    VoiceCommand? matched;
    for (final command in registry.values) {
      if (command.matches(lower)) {
        matched = command;
        break;
      }
    }

    if (matched == null) {
      // DIAGNOSTIC — the exact set of registered command ids at the moment
      // of a failed match, so a "should have matched but didn't" report
      // can be checked against whether the expected screen's commands were
      // actually registered at this instant (correlate against
      // [VoiceCommandRegistry]'s rapid-swap warnings).
      _voiceLog(
        'no known command matched "$text" (registry at dispatch time: [${registry.keys.join(', ')}])',
      );
      if (mounted)
        state = state.copyWith(transcript: "Sorry, I didn't catch that");
      unawaited(speak("Sorry, I didn't catch that"));
      return;
    }

    _logLatency('command-matched');
    _voiceLog('matched command "${matched.id}", running handler');
    if (mounted) state = state.copyWith(phase: VoicePhase.processing);
    _logLatency('action-started');
    await matched.handler(text);
    _voiceLog('handler for "${matched.id}" finished');
    if (mounted) state = state.copyWith(phase: VoicePhase.listening);
  }

  /// FIX 4 — logs elapsed time since the wake word was first detected in
  /// this cycle (or since a tap-triggered command started, see
  /// [triggerTapCommand]). No-op if there's no reference point yet.
  /// Consistent format so it's easy to grep Logcat: "VOICE LATENCY:
  /// wake-to-`stage`: `n`ms".
  void _logLatency(String stage) {
    final detectedAt = _wakeWordDetectedAt;
    if (detectedAt == null) return;
    final elapsedMs = DateTime.now().difference(detectedAt).inMilliseconds;
    debugPrint('VOICE LATENCY: wake-to-$stage: ${elapsedMs}ms');
  }

  /// Speaks arbitrary text through the single shared TTS instance. Every
  /// spoken confirmation across the app funnels through here — command
  /// handlers registered by screens call this (via
  /// `ref.read(globalVoiceServiceProvider.notifier).speak(...)`), so there's
  /// exactly one place that logs "about to speak" and exactly one
  /// `FlutterTts` doing the speaking.
  ///
  /// FIX 3: handlers are expected to call this WITHOUT awaiting it whenever
  /// the confirmation doesn't gate anything else the handler still needs to
  /// do — the action (navigation, DB write) and the speech then run
  /// concurrently instead of the action's completion waiting on TTS
  /// playback. Errors are caught here (not left to the caller) precisely
  /// because callers are expected to fire-and-forget this.
  Future<void> speak(String text) async {
    _logLatency('spoken-confirmation-started');
    debugPrint('VOICE: speaking "$text"');
    try {
      await _tts.speak(text);
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (speak): $e\n$stackTrace');
    }
  }

  /// One-shot free-text capture — prompts nothing itself (the caller speaks
  /// its own prompt first), just listens once and returns whatever was
  /// said. Used by the "site condition" command handler.
  Future<String> captureFreeText({
    Duration listenFor = const Duration(seconds: 15),
    Duration pauseFor = const Duration(seconds: 4),
  }) async {
    if (!mounted) return '';
    debugPrint('VOICE: listening for free-text capture...');
    _stage = _ListenStage.freeCapture;
    _commandHandled = false;
    final completer = Completer<String>();
    _freeCaptureCompleter = completer;
    state = state.copyWith(transcript: '', phase: VoicePhase.listening);
    await _ensureStoppedThenListen(
      onResult: _onFreeCaptureResult,
      options: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        pauseFor: pauseFor,
        listenFor: listenFor,
      ),
    );
    final note = await completer.future;
    debugPrint('VOICE: free-text capture result: "$note"');
    return note;
  }

  void _onFreeCaptureResult(SpeechRecognitionResult result) {
    if (!result.finalResult || _commandHandled || !mounted) return;
    _commandHandled = true;
    _completeFreeCapture(result.recognizedWords.trim());
  }

  void _completeFreeCapture(String text) {
    _stage = _ListenStage.idle;
    final completer = _freeCaptureCompleter;
    _freeCaptureCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete(text);
  }

  /// Tap fallback for chips/buttons (e.g. Voice Assistant's quick actions)
  /// — skips the microphone entirely but runs the exact same
  /// [_dispatchCommand] the real recognizer uses, so tap and voice are
  /// never two implementations of the same behavior. [rawPhrase] may
  /// include the "FieldLoop, " wake-word prefix (as the quick-action chips
  /// do) — stripped before matching/dispatch so it never pollutes e.g. a
  /// troubleshoot question sent to the backend.
  Future<void> triggerTapCommand(String rawPhrase) async {
    debugPrint('VOICE: tap-triggered command ("$rawPhrase")');
    // Treat the tap itself as the reference point for latency logging, same
    // as a spoken wake word would be.
    _wakeWordDetectedAt = DateTime.now();
    if (mounted) state = state.copyWith(transcript: rawPhrase);
    await _dispatchCommand(_stripWakeWord(rawPhrase));
  }

  String _stripWakeWord(String text) {
    final match = _matchWakeWord(text.toLowerCase());
    if (match == null) return text;
    return text
        .substring(match.end)
        .replaceFirst(RegExp(r'^[,\s]+'), '')
        .trim();
  }

  @override
  void dispose() {
    debugPrint('VOICE: global service disposing (app shutdown)');
    _stage = _ListenStage.idle;
    _cancelCommandSettleTimer();
    _cancelRestartDebounce();
    _cancelActiveDeepgramCapture();
    // Deliberately NOT routed through _withSpeechLock: StateNotifier.dispose()
    // is synchronous (can't await a lock), and this is the final,
    // unconditional teardown — the whole service is going away, so there's
    // no later operation left for the lock to protect this from racing.
    _speech.cancel();
    _tts.stop();
    _completeFreeCapture('');
    super.dispose();
  }
}
