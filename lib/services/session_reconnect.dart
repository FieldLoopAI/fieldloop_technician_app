/// Build 178 — Gemini Live session recovery: socket-dead detection,
/// auto-reconnect, network-drop handling and the no-transcript watchdog.
///
/// b177 evidence: the server closed the socket (closeCode=1011 "Internal
/// error encountered.") and the app kept logging `socket=open`, kept
/// streaming mic audio for ~90s and never reconnected.
///
/// Everything here is plain Dart with an injectable [ReconnectScheduler]
/// and clock, so the timing rules are unit tested without a device; the
/// screen (`gemini_live_test_screen.dart`) and `GlobalVoiceService` only
/// wire these to real sockets, timers and connectivity events.
///
/// A reconnect never re-enters a running session: the dead session is
/// ended through the existing `_stopTest(reason:)` path and a NEW ambient
/// session is started through the same path the wake word uses.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';

// --- Switches (all default ON; --dart-define=NAME=false to turn off) -------

/// Step 2: a server/network close of an ambient session starts a new one.
const bool kAutoReconnect = bool.fromEnvironment('AUTO_RECONNECT', defaultValue: true);

/// Step 3: connectivity_plus offline/online drives the same reconnect.
const bool kNetworkReconnect = bool.fromEnvironment('NETWORK_RECONNECT', defaultValue: true);

/// Step 4: 2 empty utterances and 0 transcripts this session -> restart.
const bool kNoTranscriptWatchdog = bool.fromEnvironment('NO_TRANSCRIPT_WATCHDOG', defaultValue: true);

/// Step 5: "Snap it." opens the camera (closed camera); negated -> "Okay.".
const bool kSnapItFix = bool.fromEnvironment('SNAP_IT_FIX', defaultValue: true);

/// Step 7 (1011 investigation): false omits `toolConfig` from setup.
/// Default = build 177 behaviour (sent, mode ANY).
const bool kGeminiToolConfigAny = bool.fromEnvironment('GEMINI_TOOLCONFIG_ANY', defaultValue: true);

/// Step 7 (1011 investigation): `contextWindowCompression.triggerTokens`.
/// Default = build 177 value.
const int kGeminiCompressionTriggerTokens = int.fromEnvironment('GEMINI_COMPRESSION_TRIGGER_TOKENS', defaultValue: 6000);

/// Step 6c — `SETUP:` line, read from the setup JSON exactly as sent (no
/// behaviour change; for investigating the 1011 closes).
String describeSetupFacts(String setupJson) {
  final setup = ((jsonDecode(setupJson) as Map<String, dynamic>)['setup'] as Map<String, dynamic>?) ?? const {};
  final parts = (setup['systemInstruction'] as Map<String, dynamic>?)?['parts'] as List<dynamic>? ?? const [];
  final instructionChars = parts.fold<int>(0, (n, p) => n + (((p as Map<String, dynamic>)['text'] as String?)?.length ?? 0));
  final tools = setup['tools'] as List<dynamic>? ?? const [];
  final declarations = tools.fold<int>(
    0,
    (n, t) => n + (((t as Map<String, dynamic>)['functionDeclarations'] as List<dynamic>?)?.length ?? 0),
  );
  final mode = (setup['toolConfig'] as Map<String, dynamic>?)?['functionCallingConfig']?['mode'] ?? 'ABSENT';
  final trigger = (setup['contextWindowCompression'] as Map<String, dynamic>?)?['triggerTokens'] ?? 'ABSENT';
  final vad = (setup['realtimeInputConfig'] as Map<String, dynamic>?)?['automaticActivityDetection'] as Map<String, dynamic>?;
  final vadText = vad == null || vad.isEmpty ? 'default' : vad.entries.map((e) => '${e.key}=${e.value}').join(',');
  return 'SETUP: systemInstructionChars=$instructionChars tools=$declarations toolConfigMode=$mode '
      'contextCompressionTrigger=$trigger vad=$vadText '
      'geminiToolConfigAny=$kGeminiToolConfigAny geminiCompressionTriggerTokens=$kGeminiCompressionTriggerTokens';
}

/// For the BUILD and SETUP lines.
String describeB178Flags() =>
    'autoReconnect=$kAutoReconnect networkReconnect=$kNetworkReconnect '
    'noTranscriptWatchdog=$kNoTranscriptWatchdog snapItFix=$kSnapItFix '
    'geminiToolConfigAny=$kGeminiToolConfigAny geminiCompressionTriggerTokens=$kGeminiCompressionTriggerTokens';

// --- Timing constants --------------------------------------------------------

/// Wait between a dead socket and ending the session for the first attempt.
const Duration reconnectFirstDelay = Duration(seconds: 2);

/// Delay before attempt 1, 2, 3 (attempt 1's delay is [reconnectFirstDelay],
/// spent in the dead session before it hands off).
const List<Duration> reconnectBackoff = [Duration(seconds: 2), Duration(seconds: 4), Duration(seconds: 8)];

/// A reconnect attempt that has not reached setupComplete by then failed.
const Duration reconnectSetupTimeout = Duration(seconds: 10);

/// A photo/camera flow in progress holds the reconnect: polled this often,
/// for at most [reconnectFlowWaitMax].
const Duration reconnectFlowPoll = Duration(milliseconds: 500);
const Duration reconnectFlowWaitMax = Duration(seconds: 30);

/// Process-wide: at most this many reconnect SEQUENCES (each up to 3
/// attempts) per [reconnectSequenceWindow] — a server that accepts setup
/// and then 1011s again every time can never loop forever.
const int reconnectMaxSequences = 3;
const Duration reconnectSequenceWindow = Duration(minutes: 2);

/// Hard cap on one whole sequence (all attempts and waits) — past this the
/// microphone always goes back to the wake-word loop.
const Duration reconnectSequenceDeadline = Duration(seconds: 60);

/// Step 3 timings.
const Duration networkOnlineDebounce = Duration(milliseconds: 500);
const Duration networkOnlineSettle = Duration(milliseconds: 2000);
const Duration networkSilenceLimit = Duration(seconds: 4);

/// Step 4: watchdog thresholds and its process-wide cap.
const int watchdogEmptyUtterances = 2;
const int watchdogMaxRestarts = 2;
const Duration watchdogWindow = Duration(seconds: 60);

/// Shown while reconnecting / after giving up.
const String reconnectingStatusText = 'Reconnecting...';
const String connectionLostText = 'Connection lost - say FieldLoop to retry';

// --- Scheduler -----------------------------------------------------------------

/// `Timer.new` in the app; a manual fake in tests.
typedef ReconnectScheduler = Timer Function(Duration delay, void Function() callback);

Timer _realTimer(Duration d, void Function() cb) => Timer(d, cb);

// --- Step 1: who closed the socket -------------------------------------------

enum SocketCloseInitiator { server, network, app }

/// [closedByApp]: the app itself was ending the session (stop, end_session,
/// inactivity, left job scope, a reconnect hand-off). [error]: the socket's
/// onError value; null for onDone.
SocketCloseInitiator classifySocketClose({required bool closedByApp, Object? error}) {
  if (closedByApp) return SocketCloseInitiator.app;
  if (error is SocketException || error is HandshakeException || error is WebSocketChannelException) {
    return SocketCloseInitiator.network;
  }
  return SocketCloseInitiator.server;
}

/// The one `SOCKET DEAD:` line.
String describeSocketDead({
  required int? closeCode,
  required String? closeReason,
  required SocketCloseInitiator initiatedBy,
  required int? sessionAgeMs,
  required int utterancesSinceSetup,
  required int transcriptsSinceSetup,
  required int? lastServerMessageAgoMs,
}) =>
    'SOCKET DEAD: code=${closeCode ?? 'none'} reason=${closeReason == null || closeReason.isEmpty ? 'none' : '"$closeReason"'} '
    'initiatedBy=${initiatedBy.name} sessionAgeMs=${sessionAgeMs ?? 'n/a'} '
    'utterancesSinceSetup=$utterancesSinceSetup transcriptsSinceSetup=$transcriptsSinceSetup '
    'lastServerMessageAgoMs=${lastServerMessageAgoMs ?? 'n/a'}';

/// Short reason for RECONNECT lines: the close code, else the initiator.
String reconnectReasonFor({required int? closeCode, required SocketCloseInitiator initiatedBy}) =>
    closeCode != null ? '$closeCode' : initiatedBy.name;

// --- Step 2 (dead session side): wait for the delay and an idle flow ---------

/// Runs in the DEAD session: waits [reconnectFirstDelay], then polls
/// [isReady] every [reconnectFlowPoll] for up to [reconnectFlowWaitMax];
/// calls [onReady] once, or [onGiveUp] once if it never got ready.
/// [cancel] stops both.
class ReconnectWaiter {
  ReconnectWaiter({
    required this.isReady,
    required this.onReady,
    required this.onGiveUp,
    ReconnectScheduler? scheduler,
    this.delay = reconnectFirstDelay,
    this.poll = reconnectFlowPoll,
    this.maxWait = reconnectFlowWaitMax,
  }) : _schedule = scheduler ?? _realTimer;

  final bool Function() isReady;
  final void Function() onReady;
  final void Function(Duration waited) onGiveUp;
  final ReconnectScheduler _schedule;
  final Duration delay;
  final Duration poll;
  final Duration maxWait;

  Timer? _timer;
  Duration _waited = Duration.zero;
  bool _done = false;

  bool get isDone => _done;

  void start() {
    _timer = _schedule(delay, _check);
  }

  void _check() {
    if (_done) return;
    if (isReady()) {
      _done = true;
      onReady();
      return;
    }
    if (_waited >= maxWait) {
      _done = true;
      onGiveUp(_waited);
      return;
    }
    _waited += poll;
    _timer = _schedule(poll, _check);
  }

  void cancel() {
    _done = true;
    _timer?.cancel();
    _timer = null;
  }
}

// --- Step 2 (GlobalVoiceService side): attempts, backoff, give-up ------------

enum ReconnectPhase { idle, waitingForOldSession, waitingBackoff, attempting, attemptFailed }

/// What [SessionReconnectCoordinator.onSessionEnded] decided.
enum ReconnectNext { nothing, startAttempt, scheduled, gaveUp }

/// Process-wide (one per `GlobalVoiceService`): only one reconnect sequence
/// at a time, 3 attempts at 2s/4s/8s, then give up. Holds no Flutter state;
/// the service starts the sessions and logs what this returns.
class SessionReconnectCoordinator {
  SessionReconnectCoordinator({
    ReconnectScheduler? scheduler,
    DateTime Function()? now,
    this.maxAttempts = 3,
  }) : _schedule = scheduler ?? _realTimer,
       _now = now ?? DateTime.now;

  final ReconnectScheduler _schedule;
  final DateTime Function() _now;
  final int maxAttempts;

  ReconnectPhase _phase = ReconnectPhase.idle;
  int _attempt = 0;
  String _reason = '';
  String? _jobId;
  DateTime? _socketDeadAt;
  DateTime? _sequenceStartedAt;
  Timer? _backoffTimer;
  final List<DateTime> _sequenceStarts = [];

  ReconnectPhase get phase => _phase;
  bool get inFlight => _phase != ReconnectPhase.idle;
  int get attempt => _attempt;
  String get reason => _reason;
  String? get jobId => _jobId;

  /// Delay used before the current attempt (for the RECONNECT result line).
  Duration get currentDelay => reconnectBackoff[(_attempt - 1).clamp(0, reconnectBackoff.length - 1)];

  /// Why [begin] refused, or null when it started a sequence.
  String? begin({required String jobId, required String reason, required DateTime socketDeadAt}) {
    if (inFlight) return 'another reconnect is already in flight (attempt $_attempt)';
    final now = _now();
    _sequenceStarts.removeWhere((t) => now.difference(t) > reconnectSequenceWindow);
    if (_sequenceStarts.length >= reconnectMaxSequences) {
      return '$reconnectMaxSequences reconnect sequences already in the last ${reconnectSequenceWindow.inSeconds}s';
    }
    _sequenceStarts.add(now);
    _phase = ReconnectPhase.waitingForOldSession;
    _attempt = 1;
    _reason = reason;
    _jobId = jobId;
    _socketDeadAt = socketDeadAt;
    _sequenceStartedAt = now;
    return null;
  }

  /// An attempt's session is being started now.
  void markAttemptStarted() {
    if (_phase == ReconnectPhase.idle) return;
    _phase = ReconnectPhase.attempting;
  }

  /// The attempt's new session reached setupComplete: the sequence is over.
  /// Returns `totalDowntimeMs` (socket dead -> now), or null when no
  /// attempt was running.
  int? onSetupComplete() {
    if (_phase != ReconnectPhase.attempting) return null;
    final downtime = _now().difference(_socketDeadAt ?? _now()).inMilliseconds;
    _reset();
    return downtime;
  }

  /// The attempt's session failed before setupComplete.
  void onAttemptFailed() {
    if (_phase == ReconnectPhase.attempting) _phase = ReconnectPhase.attemptFailed;
  }

  /// The session that held the microphone has ended (the dead one, or a
  /// failed attempt). [startAttempt] is called — now or after the backoff —
  /// with the attempt number to start.
  ReconnectNext onSessionEnded(void Function(int attempt) startAttempt) {
    switch (_phase) {
      case ReconnectPhase.idle:
      case ReconnectPhase.waitingBackoff:
        return ReconnectNext.nothing;
      case ReconnectPhase.waitingForOldSession:
        // Attempt 1's 2s delay was already spent in the dead session.
        _phase = ReconnectPhase.attempting;
        startAttempt(_attempt);
        return ReconnectNext.startAttempt;
      case ReconnectPhase.attempting:
      // Ended without reaching setupComplete and without a report: a failure.
      case ReconnectPhase.attemptFailed:
        if (_attempt >= maxAttempts || _pastDeadline()) {
          _reset();
          return ReconnectNext.gaveUp;
        }
        _attempt++;
        _phase = ReconnectPhase.waitingBackoff;
        _backoffTimer = _schedule(currentDelay, () {
          _backoffTimer = null;
          if (_phase != ReconnectPhase.waitingBackoff) return;
          _phase = ReconnectPhase.attempting;
          startAttempt(_attempt);
        });
        return ReconnectNext.scheduled;
    }
  }

  bool _pastDeadline() {
    final started = _sequenceStartedAt;
    return started != null && _now().difference(started) > reconnectSequenceDeadline;
  }

  /// User/app ended things (wake word, stop, left job, backgrounded).
  /// Returns true when a sequence was actually cancelled.
  bool cancel() {
    if (!inFlight) return false;
    _reset();
    return true;
  }

  void _reset() {
    _backoffTimer?.cancel();
    _backoffTimer = null;
    _phase = ReconnectPhase.idle;
    _attempt = 0;
    _socketDeadAt = null;
    _sequenceStartedAt = null;
  }
}

/// `RECONNECT: attempt=… reason=… delayMs=… result=… totalDowntimeMs=…`.
String describeReconnectResult({
  required int attempt,
  required String reason,
  required int delayMs,
  required bool ok,
  int? totalDowntimeMs,
}) =>
    'RECONNECT: attempt=$attempt reason=$reason delayMs=$delayMs result=${ok ? 'ok' : 'fail'}'
    '${totalDowntimeMs == null ? '' : ' totalDowntimeMs=$totalDowntimeMs'}';

// --- Step 4: no-transcript watchdog -------------------------------------------

/// True when the session should be restarted: [consecutiveEmptyUtterances]
/// utterances (mic speech edge, no transcript within the 3s timeout) in a
/// row, NO transcript at all since setup (a quiet voice that got even one
/// transcript is left alone), and nothing of ours playing / mic not paused.
bool watchdogShouldRestart({
  required int consecutiveEmptyUtterances,
  required int transcriptsSinceSetup,
  required bool ownAudioPlaying,
  required bool micPaused,
}) =>
    consecutiveEmptyUtterances >= watchdogEmptyUtterances &&
    transcriptsSinceSetup == 0 &&
    !ownAudioPlaying &&
    !micPaused;

/// Process-wide cap: at most [watchdogMaxRestarts] per [watchdogWindow].
class WatchdogRestartCap {
  WatchdogRestartCap({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final List<DateTime> _restarts = [];

  /// Records and returns true when one more restart is allowed now.
  bool tryTake() {
    final now = _now();
    _restarts.removeWhere((t) => now.difference(t) >= watchdogWindow);
    if (_restarts.length >= watchdogMaxRestarts) return false;
    _restarts.add(now);
    return true;
  }
}

// --- Step 3: network drop / return ---------------------------------------------

/// Turns connectivity events into "pause the mic", "resume the mic" and
/// "reconnect" — at most ONE reconnect per offline episode. Lives in the
/// session screen (only while an ambient session is active).
class NetworkReconnectMonitor {
  NetworkReconnectMonitor({
    required this.isSocketDead,
    required this.lastServerMessageAt,
    required this.onOffline,
    required this.onOnlineResume,
    required this.onReconnect,
    required this.log,
    ReconnectScheduler? scheduler,
    DateTime Function()? now,
  }) : _schedule = scheduler ?? _realTimer,
       _now = now ?? DateTime.now;

  final bool Function() isSocketDead;
  final DateTime? Function() lastServerMessageAt;
  final void Function() onOffline;
  final void Function() onOnlineResume;
  final void Function(String reason) onReconnect;
  final void Function(String line) log;
  final ReconnectScheduler _schedule;
  final DateTime Function() _now;

  bool _down = false;
  bool _reconnectRequested = false;
  DateTime? _onlineAt;
  Timer? _timer;

  bool get isDown => _down;

  void onConnectivity({required bool online}) {
    if (!online) {
      _timer?.cancel();
      _timer = null;
      // Dropped again while settling after an online: a new offline.
      final wasSettling = _onlineAt != null;
      _onlineAt = null;
      if (_down && !wasSettling) return;
      _down = true;
      log('NETWORK: state=offline');
      onOffline();
      return;
    }
    // Online while never down: nothing to do (also the first event after
    // subscribing).
    if (!_down || _onlineAt != null) return;
    _timer?.cancel();
    _timer = _schedule(networkOnlineDebounce, _onlineDebounced);
  }

  void _onlineDebounced() {
    _timer = null;
    _onlineAt = _now();
    log('NETWORK: state=online');
    _timer = _schedule(networkOnlineSettle, _evaluate);
  }

  void _evaluate() {
    _timer = null;
    final onlineAt = _onlineAt;
    if (onlineAt == null) return;
    if (isSocketDead()) {
      _requestReconnect('network_socket_dead');
      return;
    }
    final last = lastServerMessageAt();
    if (last != null && last.isAfter(onlineAt)) {
      _resume('socket alive (server message ${_now().difference(last).inMilliseconds}ms ago)');
      return;
    }
    final silentFor = _now().difference(onlineAt);
    if (silentFor > networkSilenceLimit) {
      _requestReconnect('network_no_server_message');
      return;
    }
    // Give the server the rest of its window to say something.
    _timer = _schedule(networkSilenceLimit - silentFor + const Duration(milliseconds: 1), _evaluate);
  }

  void _resume(String why) {
    _down = false;
    _onlineAt = null;
    log('NETWORK: resumed without reconnect — $why');
    onOnlineResume();
  }

  void _requestReconnect(String reason) {
    _down = false;
    _onlineAt = null;
    if (_reconnectRequested) return;
    _reconnectRequested = true;
    onReconnect(reason);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

// --- Step 6a: utterances that end with no TURN TIMING line ------------------

/// Why utterance [u] ended without a TURN TIMING line — see the call site
/// in `_startNewUtterance`. [hint] is set where the reason is known
/// directly (`excluded_app_turn`, `no_estimate`).
String turnTimingNoneReason({required String? hint, required bool replyAudioPlayed, required bool replyOwed}) {
  if (hint != null) return hint;
  if (replyAudioPlayed) return 'excluded_app_turn';
  return replyOwed ? 'superseded' : 'no_reply_audio';
}

String describeTurnTimingNone(int utterance, String reason) =>
    'TURN TIMING: none utterance=$utterance reason=$reason';
