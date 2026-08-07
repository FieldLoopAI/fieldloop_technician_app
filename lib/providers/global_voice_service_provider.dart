import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'voice_command_registry_provider.dart';

enum VoicePhase { listening, processing }

enum _ListenStage { idle, wakeWord, command, freeCapture }

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
final globalVoiceServiceProvider = StateNotifierProvider<GlobalVoiceService, GlobalVoiceState>(
  (ref) => GlobalVoiceService(ref),
);

class GlobalVoiceService extends StateNotifier<GlobalVoiceState> {
  GlobalVoiceService(this._ref) : super(const GlobalVoiceState());

  final Ref _ref;

  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  static final RegExp _wakeWordPattern = RegExp(r'\bfield\s?loop\b', caseSensitive: false);

  bool _started = false;
  bool _wakeHandled = false;
  bool _commandHandled = false;
  _ListenStage _stage = _ListenStage.idle;
  Completer<String>? _freeCaptureCompleter;

  /// Initializes the recognizer and, if it's available and the technician
  /// hasn't muted, starts the wake-word loop. Safe to call more than once —
  /// only the first call does anything. Called exactly once, from
  /// `RootShell`, the moment microphone permission is confirmed granted.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      debugPrint('VOICE: initializing speech recognizer...');
      final available = await _speech.initialize(onStatus: _onStatus, onError: _onError);
      debugPrint('VOICE: speech recognizer available=$available');
      if (!mounted) return;
      state = state.copyWith(available: available);
      if (available && !state.muted) await _startWakeWordListen();
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (initialize): $e\n$stackTrace');
      if (mounted) state = state.copyWith(available: false);
    }
  }

  /// Full teardown — called only on logout. `_started` is reset so a
  /// subsequent login can call [start] again from scratch.
  Future<void> stopForLogout() async {
    debugPrint('VOICE: stopping for logout');
    _started = false;
    _stage = _ListenStage.idle;
    if (_speech.isListening) {
      await _speech.stop();
    }
    await _speech.cancel();
    _completeFreeCapture('');
    if (mounted) state = const GlobalVoiceState();
  }

  Future<void> setMuted(bool muted) async {
    debugPrint('VOICE: ${muted ? "muting" : "unmuting"}');
    state = state.copyWith(muted: muted);
    if (muted) {
      _stage = _ListenStage.idle;
      if (_speech.isListening) await _speech.stop();
    } else if (state.available) {
      await _startWakeWordListen();
    }
  }

  /// The one place `listen()` is ever called from. Explicitly confirms any
  /// previous session has actually finished before starting a new one —
  /// calling `listen()` again while the native recognizer is still mid-
  /// operation from the last session is exactly what produces
  /// `error_busy`, which is why every listen call in this class routes
  /// through here rather than calling `_speech.listen(...)` directly.
  Future<void> _ensureStoppedThenListen({
    required void Function(SpeechRecognitionResult) onResult,
    required SpeechListenOptions options,
  }) async {
    if (_speech.isListening) {
      debugPrint('VOICE: confirming previous session stopped before restart');
      await _speech.stop();
    } else {
      debugPrint('VOICE: previous session already stopped, starting new listen()');
    }
    if (!mounted) return;
    try {
      await _speech.listen(onResult: onResult, listenOptions: options);
    } catch (e, stackTrace) {
      // listen() awaits a platform channel call and throws
      // ListenFailedException (wrapping a native error_busy, among others)
      // if the recognizer refuses the session — must not go unhandled, or
      // `_stage` is left claiming a session is active when none actually
      // started, and the loop goes silent for good.
      debugPrint('VOICE ERROR (listen): $e\n$stackTrace');
      _stage = _ListenStage.idle;
      unawaited(_scheduleWakeWordRestart());
    }
  }

  /// Statuses the on-device recognizer reports at the end of essentially
  /// every listen session — never a reason to stop the wake-word loop, only
  /// a reason to restart it (see [_scheduleWakeWordRestart]).
  static const _restartStatuses = {'done', 'notListening'};

  void _onStatus(String status) {
    debugPrint('VOICE: recognizer status=$status');
    if (!mounted || state.muted) return;
    // A command-listen (or free-text capture) session can end (silence
    // timeout) without ever producing a final result — still treat that as
    // "didn't catch it" rather than leaving the UI stuck on an empty
    // transcript, or a free-text capture awaiting forever.
    if (_restartStatuses.contains(status) && !_commandHandled) {
      if (_stage == _ListenStage.command) {
        _commandHandled = true;
        unawaited(_processCommandText(''));
        return;
      }
      if (_stage == _ListenStage.freeCapture) {
        _commandHandled = true;
        _completeFreeCapture('');
        return;
      }
    }
    if (_restartStatuses.contains(status) && _stage == _ListenStage.wakeWord) {
      unawaited(_scheduleWakeWordRestart());
    }
  }

  /// Recognizer errors that fire naturally at the end of nearly every
  /// wake-word listen session — the device found no speech, or found speech
  /// that didn't parse. These are the normal, expected shape of "sat there
  /// listening for a while and nobody said anything" and must never stop the
  /// loop, no matter how many times in a row they happen.
  static const _recoverableErrors = {'error_speech_timeout', 'error_no_match'};

  void _onError(SpeechRecognitionError error) {
    debugPrint('VOICE ERROR (recognizer): ${error.errorMsg} permanent=${error.permanent}');
    if (!mounted || state.muted) return;

    if (_recoverableErrors.contains(error.errorMsg)) {
      if (_stage == _ListenStage.command && !_commandHandled) {
        _commandHandled = true;
        unawaited(_processCommandText(''));
      } else if (_stage == _ListenStage.freeCapture && !_commandHandled) {
        _commandHandled = true;
        _completeFreeCapture('');
      } else if (_stage == _ListenStage.wakeWord) {
        unawaited(_scheduleWakeWordRestart());
      }
      return;
    }

    // Anything else (permission revoked mid-session, a genuinely broken
    // recognizer, etc.) — stop retrying so we don't spam a broken engine.
    if (error.permanent) {
      debugPrint('VOICE: permanent recognizer error, disabling voice input');
      _stage = _ListenStage.idle;
      state = state.copyWith(available: false);
      _completeFreeCapture('');
    }
  }

  /// Debounces the restart so a session that ends immediately (e.g. the
  /// native recognizer still tearing down the previous one) doesn't get
  /// restarted into a tight loop — combined with the isListening check in
  /// [_ensureStoppedThenListen], this is what keeps the loop from ever
  /// calling `listen()` while the previous session is still busy.
  Future<void> _scheduleWakeWordRestart() async {
    if (!mounted || state.muted) return;
    _stage = _ListenStage.idle;
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted || state.muted || !state.available) return;
    debugPrint('VOICE: restarting listener after timeout');
    await _startWakeWordListen();
  }

  Future<void> _startWakeWordListen() async {
    if (!mounted || state.muted || !state.available) return;
    debugPrint('VOICE: listening for wake word...');
    _stage = _ListenStage.wakeWord;
    _wakeHandled = false;
    state = state.copyWith(phase: VoicePhase.listening);
    await _ensureStoppedThenListen(
      onResult: _onWakeWordResult,
      options: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        // Generous ceiling — the loop restarts itself well before this via
        // onStatus/onError anyway, this just avoids the platform's own
        // (often much shorter) default cutting a session short.
        listenFor: Duration(minutes: 5),
        pauseFor: Duration(seconds: 10),
      ),
    );
  }

  void _onWakeWordResult(SpeechRecognitionResult result) {
    if (_wakeHandled || !mounted) return;
    final words = result.recognizedWords.toLowerCase();
    final match = _wakeWordPattern.firstMatch(words);
    if (match == null) return;
    _wakeHandled = true;
    debugPrint('VOICE: wake word detected in "$words"');
    final remainder = words.substring(match.end).trim();
    if (remainder.isNotEmpty) {
      unawaited(_processCommandText(remainder));
    } else {
      unawaited(_startCommandListen());
    }
  }

  Future<void> _startCommandListen() async {
    if (!mounted) return;
    debugPrint('VOICE: wake word acknowledged, listening for a command...');
    _stage = _ListenStage.command;
    _commandHandled = false;
    state = state.copyWith(transcript: '', phase: VoicePhase.listening);
    await _ensureStoppedThenListen(
      onResult: _onCommandResult,
      options: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        // Generous enough that a full troubleshooting question spoken
        // naturally isn't cut off mid-sentence.
        pauseFor: Duration(seconds: 5),
        listenFor: Duration(seconds: 25),
      ),
    );
  }

  void _onCommandResult(SpeechRecognitionResult result) {
    if (!result.finalResult || _commandHandled || !mounted) return;
    _commandHandled = true;
    unawaited(_processCommandText(result.recognizedWords.trim()));
  }

  Future<void> _processCommandText(String text) async {
    _stage = _ListenStage.idle;
    if (text.isEmpty) {
      debugPrint('VOICE: no command captured after wake word');
      if (mounted) state = state.copyWith(transcript: "Sorry, I didn't catch that");
      await speak("Sorry, I didn't catch that");
      await _scheduleWakeWordRestart();
      return;
    }

    debugPrint('VOICE: command captured: "$text"');
    if (mounted) state = state.copyWith(transcript: text);
    await _dispatchCommand(text);
    await _scheduleWakeWordRestart();
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
      debugPrint('VOICE: no known command matched "$text"');
      if (mounted) state = state.copyWith(transcript: "Sorry, I didn't catch that");
      await speak("Sorry, I didn't catch that");
      return;
    }

    debugPrint('VOICE: matched command "${matched.id}", running handler');
    if (mounted) state = state.copyWith(phase: VoicePhase.processing);
    await matched.handler(text);
    debugPrint('VOICE: handler for "${matched.id}" finished');
    if (mounted) state = state.copyWith(phase: VoicePhase.listening);
  }

  /// Speaks arbitrary text through the single shared TTS instance. Every
  /// spoken confirmation across the app funnels through here — command
  /// handlers registered by screens call this (via
  /// `ref.read(globalVoiceServiceProvider.notifier).speak(...)`), so there's
  /// exactly one place that logs "about to speak" and exactly one
  /// `FlutterTts` doing the speaking.
  Future<void> speak(String text) async {
    debugPrint('VOICE: speaking "$text"');
    await _tts.speak(text);
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
      options: SpeechListenOptions(partialResults: true, cancelOnError: false, pauseFor: pauseFor, listenFor: listenFor),
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
    if (mounted) state = state.copyWith(transcript: rawPhrase);
    await _dispatchCommand(_stripWakeWord(rawPhrase));
  }

  String _stripWakeWord(String text) {
    final match = _wakeWordPattern.firstMatch(text.toLowerCase());
    if (match == null) return text;
    return text.substring(match.end).replaceFirst(RegExp(r'^[,\s]+'), '').trim();
  }

  @override
  void dispose() {
    debugPrint('VOICE: global service disposing (app shutdown)');
    _stage = _ListenStage.idle;
    _speech.cancel();
    _tts.stop();
    _completeFreeCapture('');
    super.dispose();
  }
}
