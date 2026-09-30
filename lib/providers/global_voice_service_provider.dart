import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../routing/app_navigator_key.dart';
import '../screens/gemini_live_test_screen.dart';
import '../services/gemini_token_cache.dart';
import 'currently_viewed_job_provider.dart';
import 'deepgram_command_capture.dart';
import 'permission_providers.dart';
import 'voice_command_registry_provider.dart';

/// [awaitingWakeWord] vs [listening] — CONFIRMED bug fix: both used to be
/// the single `listening` value, which meant `VoicePhaseIndicator`'s
/// enlarge-on-non-idle logic (and anything else keying off "is voice
/// active") couldn't tell the passive, always-on baseline loop (mic open,
/// waiting to hear "FieldLoop", no interaction happening yet) apart from
/// genuine active capture (the mic open AFTER the wake word, or during
/// dictation/confirmation). [awaitingWakeWord] is set only in
/// [GlobalVoiceService._startListening] (the baseline session's start);
/// every other listening call site — post-wake-word command capture,
/// [GlobalVoiceService.captureDictation], [GlobalVoiceService.
/// captureConfirmation], and the post-handler "still listening" case in
/// [GlobalVoiceService._dispatchCommand] — uses [listening], since those
/// only ever run once [GlobalVoiceService._wakeDetected] is already true.
enum VoicePhase { idle, awaitingWakeWord, listening, processing, speaking }

/// Resolved outcome of [GlobalVoiceService.captureConfirmation] — see that
/// method's doc comment for the full contract, in particular why
/// [unclear] is a distinct outcome from [redo] rather than folded into it.
enum ConfirmationOutcome { confirmed, redo, unclear }

enum _ListenStage { idle, active, dictation, confirmation }

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
    this.phase = VoicePhase.idle,
    this.transcript = '',
    this.available = true,
    this.muted = false,
    this.pendingConfirmationTranscript,
    this.screenTaskActive = false,
    this.sessionEpoch = 0,
  });

  final VoicePhase phase;
  final String transcript;

  /// Bumped by exactly one place — [GlobalVoiceService.pauseForExternalSession]
  /// on the genuine (not-already-paused) path — once per Gemini Live session
  /// actually starting. [VoiceInteractionOverlay] watches this alongside
  /// [phase]/[screenTaskActive] to tell "a brand new session just started"
  /// apart from an ordinary within-session phase change (e.g. the idle blip
  /// [GlobalVoiceService.speak] leaves between a confirmation prompt and the
  /// listening it starts next): the brief full-screen intro is allowed once
  /// per bump of this value, never again until it bumps again.
  final int sessionEpoch;

  /// True while an external session (currently: the ambient Gemini Live
  /// screen — see [GlobalVoiceService.setScreenTaskActive]) has navigated to
  /// real, visible screen content that a function call triggered (the live
  /// camera preview, a captured photo, ...) — as opposed to pure
  /// conversation with nothing to look at. [VoiceInteractionOverlay] watches
  /// this alongside [phase]: the full-screen voice animation must not sit on
  /// top of and hide that real content, so it shrinks to the small corner
  /// indicator for as long as this is true, exactly as if voice had gone
  /// idle, even though [phase] itself may still say listening/processing/
  /// speaking underneath. False the rest of the time — the full-screen
  /// experience is unaffected for every screen/session that never sets it.
  final bool screenTaskActive;

  /// Whether the on-device speech recognizer reported itself usable.
  /// Distinct from OS microphone permission (see `cameraMicProvider`) — a
  /// technician can have granted the mic permission and still have no
  /// recognizer available on their device.
  final bool available;

  final bool muted;

  /// FIX 2 (dictation confirm/redo) — non-null exactly while
  /// [GlobalVoiceService.captureConfirmation] is awaiting a spoken or
  /// tapped confirm/redo reply, holding the full transcript being
  /// confirmed. Screens watch this (see `DictationConfirmationBar`, wired
  /// globally via `MaterialApp.builder` in `app.dart` since
  /// `prepare_estimate`/`site_condition` can be triggered from several
  /// different screens) to show the on-screen Confirm/Redo tap fallback —
  /// the same "voice AND tap always do the same thing" principle as every
  /// other command in this app.
  final String? pendingConfirmationTranscript;

  GlobalVoiceState copyWith({
    VoicePhase? phase,
    String? transcript,
    bool? available,
    bool? muted,
    String? pendingConfirmationTranscript,
    bool clearPendingConfirmationTranscript = false,
    bool? screenTaskActive,
    int? sessionEpoch,
  }) {
    return GlobalVoiceState(
      phase: phase ?? this.phase,
      transcript: transcript ?? this.transcript,
      available: available ?? this.available,
      muted: muted ?? this.muted,
      pendingConfirmationTranscript: clearPendingConfirmationTranscript
          ? null
          : (pendingConfirmationTranscript ?? this.pendingConfirmationTranscript),
      screenTaskActive: screenTaskActive ?? this.screenTaskActive,
      sessionEpoch: sessionEpoch ?? this.sessionEpoch,
    );
  }
}

/// Speech rate applied to every `speak()` call app-wide (see
/// `_configureTts`), tuned for wake-word/prompt clarity.
const ttsSpeechRate = 0.45;

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

  /// FIX (Deepgram/on-device mic-contention bug) — hard kill switch for the
  /// entire Deepgram command-capture leg. CONFIRMED root cause of the
  /// "no words captured" fallback failures: [_deepgramAttemptTimeout]
  /// "abandoning" a slow Deepgram attempt never actually cancels the
  /// underlying token request, WebSocket connection, or `record` mic
  /// stream — they keep running in the background after being abandoned,
  /// so the freshly-opened on-device fallback session and the still-live
  /// Deepgram mic stream fight over the microphone at the same time. While
  /// this is `false`, the wake-word handler below skips
  /// [_tryDeepgramCommandCapture] entirely — no token request, no
  /// WebSocket, no AudioRecorder stream ever starts — and goes straight to
  /// [_fallBackToOnDeviceCapture], exactly as if Deepgram capture didn't
  /// exist in this build. All Deepgram code is left intact and unchanged;
  /// flip this back to `true` once [DeepgramCommandCapture] actually tears
  /// down its in-flight work on cancel/timeout instead of orphaning it.
  ///
  /// UNUSED as of the wake-word-triggers-Gemini change (see
  /// [_triggerGeminiSession]): the wake-word branch in [_onSessionResult]
  /// no longer calls [_tryDeepgramCommandCapture]/[_fallBackToOnDeviceCapture]
  /// at all — a Gemini Live session now starts immediately instead of
  /// capturing/matching a fixed-phrase command. Left in place (not
  /// deleted) rather than risk a deeper cleanup pass through this file's
  /// many cross-references for a helper that isn't reachable from anywhere
  /// else either.
  // ignore: unused_field
  static const bool _useDeepgramCapture = false;

  SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  /// One pre-fetched Gemini Live token, kept only while the wake word can
  /// actually be heard (see [_syncGeminiTokenPrefetch]) so the session the
  /// wake word starts doesn't wait on a cold token round trip.
  final GeminiTokenCache _geminiTokens = GeminiTokenCache();

  /// Set while the app is fully backgrounded — see [onAppLifecycleChanged].
  bool _appBackgrounded = false;

  /// Keeps a spare token exactly while voice is live on a job screen (in
  /// job scope, recognizer available, not muted, app in the foreground) and
  /// drops it from memory otherwise.
  void _syncGeminiTokenPrefetch() {
    if (_jobScopeActive && state.available && !state.muted && !_appBackgrounded) {
      _geminiTokens.activate();
    } else {
      _geminiTokens.deactivate();
    }
  }

  /// A token for a Gemini session starting right now — the pre-fetched
  /// spare when there is one, otherwise fetched on demand (the old path).
  Future<String> takeGeminiToken() => _geminiTokens.take();

  /// Called from `FieldLoopApp`'s lifecycle observer. Backgrounded: drop
  /// the spare and stop refreshing it (same release-on-pause the camera
  /// does). Foregrounded: fetch a new spare if voice is still live.
  ///
  /// Also the Gemini Live session's app-close/background handling. Closing
  /// (`detached`): the session is ended right away — its recorder, player
  /// and socket stopped explicitly (see `GeminiLiveTestScreen.endRequest`),
  /// never left to the engine disconnecting, which CONFIRMED does not stop
  /// the native flutter_sound recorder. Backgrounded (`paused`): a session is
  /// only kept while a job is still in scope — that is exactly what the
  /// microphone foreground service (VoiceSessionService) exists for;
  /// anything else is ended.
  void onAppLifecycleChanged(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.detached) {
      _endActiveGeminiSession('app closing (AppLifecycleState.detached)');
      return;
    }
    if (lifecycle == AppLifecycleState.paused && !_jobScopeActive) {
      _endActiveGeminiSession('app backgrounded outside job scope');
    }
    if (lifecycle == AppLifecycleState.paused) {
      _appBackgrounded = true;
    } else if (lifecycle == AppLifecycleState.resumed) {
      _appBackgrounded = false;
    } else {
      return;
    }
    _syncGeminiTokenPrefetch();
  }

  /// DIAGNOSTIC (Bluetooth-headset-mic-ignored investigation) — native
  /// (Android-only; see [_logAudioRoute]) channel backing
  /// [_logAudioRoute]'s `getAudioRouteInfo` call. Handler registered in
  /// `MainActivity.kt`. Read-only: queries current audio routing state,
  /// never changes it.
  static const MethodChannel _audioDiagnosticsChannel =
      MethodChannel('com.fieldloop.fielloop/audio_diagnostics');

  /// Near-miss variants Android's generic on-device recognizer has been
  /// observed producing for the invented brand wake word "FieldLoop" (real
  /// device logs: "hey facebook", "filled loop", "field look", "field
  /// rope", "fillup" — it biases toward common trained words/phrases over
  /// an unfamiliar one). Matching is a plain case-insensitive substring
  /// check against the running transcript (see [_matchWakeWord]), so
  /// "allowing minor extra words around them" falls out for free — no
  /// other code needs to change to add a variant, just extend this set as
  /// new mishearings show up in future logs.
  ///
  /// FIX (wake-word detection tolerance): the entries below
  /// 'field lupe' onward are not yet confirmed from device logs the way
  /// the ones above them are — they're added proactively, on the same
  /// "unfamiliar brand word gets mapped onto a common trained one"
  /// reasoning, to widen the net before another round of failed-attempt
  /// logs is needed to justify each one individually. A false-positive
  /// match here just costs one wasted listening cycle (the technician
  /// says something unrelated, the app briefly listens for a command that
  /// never matches, and the wake-word loop restarts); a missed detection
  /// costs a frustrating repeat-yourself delay, so this list is
  /// deliberately biased toward over-matching. 'fieldwork' is the
  /// riskiest addition on that front — unlike the others it's an ordinary
  /// English word a technician might say in passing without meaning to
  /// invoke the assistant at all — kept anyway per that same
  /// asymmetric-cost tradeoff, but the first one to prune back if false
  /// triggers from it show up in logs.
  static const Set<String> _wakeWordVariants = {
    // "Loop On" — a second, EQUALLY VALID wake phrase (not a mishearing
    // variant of "FieldLoop" like everything below it): now that the wake
    // word starts a Gemini Live session instead of the old fixed-phrase
    // command flow (see the wake-word-detected branch in
    // [_onSessionResult]), this is the shorter, natural-sounding trigger
    // for that. Matched via the exact same plain substring check as every
    // other variant here — no separate code path.
    'loop on',
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
    'field lupe',
    'yield loop',
    'yield lupe',
    'field group',
    'fieldwork',
    'field loot',
    'field pool',
    'field crew',
    'field blue',
    'shield loop',
    'field news',
  };

  /// INVESTIGATED (lowering the recognizer's confidence threshold for
  /// wake-word matching): not possible, and not needed. `speech_to_text`
  /// 7.4.0's `SpeechListenOptions` (see the platform interface package)
  /// exposes no input-side confidence/threshold knob at all — Android's
  /// `SpeechRecognizer` and iOS's `SFSpeechRecognizer` don't expose one to
  /// this plugin either, so there is nothing to tune down there. The only
  /// confidence value the plugin surfaces is `SpeechRecognitionResult.
  /// confidence` — a read-only score attached to the FINAL result, meant
  /// for an app to reject a low-confidence transcript. [_matchWakeWord]
  /// (below) never reads it: wake-word matching already runs on every
  /// PARTIAL result (`_onSessionResult`, before `result.finalResult` and
  /// before Android even populates a real confidence value), so this is
  /// already the most lenient policy available — accepting a match the
  /// instant any variant appears in the running transcript, without
  /// waiting for the recognizer to finalize or vouch for it. Widening
  /// [_wakeWordVariants] (above) is the only lever that actually exists
  /// for this.
  ///
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
  /// [_reopenListenForCommand]). This is a per-COMMAND-SET default:
  /// individual short, single-word commands (e.g. "confirm", "retake")
  /// override it via [VoiceCommand.pauseWindow] — see
  /// [_matchedShortWindowCommand] — and that override is unaffected by the
  /// fix below, since it only ever applies once real words are already
  /// banked in `_pendingCommandText`.
  ///
  /// FIX (Deepgram-fallback "no words captured" bug) — every normal
  /// command capture goes through Deepgram first (see
  /// [_tryDeepgramCommandCapture]); [_reopenListenForCommand] (and
  /// therefore this default) is ONLY ever reached today via
  /// [_fallBackToOnDeviceCapture], after the Deepgram leg has already
  /// failed. That makes this on-device session the technician's ONLY
  /// capture path for that command, exactly the same shape as the
  /// baseline wake-word session and dictation capture — both already hit
  /// and fixed this identical bug (see [_wakeWordPauseFor] and
  /// [_dictationNativePauseFor]'s doc comments for the full history). This
  /// was still left at a short 2s here, so the fallback inherited the
  /// exact same symptom: real-device logs showed it repeatedly reporting
  /// "no words captured" immediately after being triggered, because the
  /// native session kept ending (and getting torn down/reopened) before
  /// the technician had said anything at all. Raised to match
  /// [_wakeWordPauseFor]/[_dictationNativePauseFor] (18s) for the same
  /// reason: ordinary silence right after a prompt/tone — the technician
  /// registering that the mic is open before they speak — must not end
  /// the session on its own.
  static const Duration _commandPauseFor = Duration(seconds: 18);

  /// Native `listenFor` ceiling for the same on-device fallback session —
  /// was already a generous 5 minutes (hardcoded inline in
  /// [_reopenListenForCommand]; pulled out to a named constant here purely
  /// so it's visible/greppable next to [_commandPauseFor]), so no change
  /// needed here to fix the bug above — `pauseFor`, not `listenFor`, was
  /// what was ending sessions early. Deliberately NOT shrunk toward
  /// [_wakeWordListenFor] (58s) either, for the same reason
  /// [_dictationMaxDuration] wasn't: a fallback command capture should be
  /// able to run as long as the technician needs (a troubleshooting
  /// question can run well past a minute), and [_commandPauseFor]/
  /// [_commandSettleWindow] — not this ceiling — are what should end it.
  static const Duration _commandListenFor = Duration(minutes: 5);

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

  /// Native `pauseFor` for dictation-capture sessions (`prepare_estimate`,
  /// `site_condition`). FIX (dictation-capture bug): this used to be a
  /// short 2s value on the same reasoning as [_commandPauseFor] — but
  /// unlike ordinary command capture, dictation has no Deepgram leg to
  /// hand off to; this on-device session is the ENTIRE capture, running
  /// continuously for as long as the technician talks. A short pauseFor
  /// meant the native session ended roughly every 2s regardless of whether
  /// the technician was still mid-sentence, forcing a
  /// stop -> real-confirmation -> settle -> relisten cycle (see
  /// [_ensureStoppedThenListen]) that briefly closes the mic; real-device
  /// logs showed this producing dozens of consecutive sessions with
  /// banked="" and no speech ever captured, since a fresh session often
  /// didn't stay open long enough to receive even one onResult callback
  /// before being torn down again. Raised to match/exceed
  /// [_wakeWordPauseFor] (18s) for the same underlying reason that fixed
  /// the baseline listener: ordinary mid-sentence silence (a technician
  /// pausing to think about a price) must not end the native session on
  /// its own. The real "is the dictation finished" decision still belongs
  /// entirely to [_dictationSettleWindow], on the app's own clock — this
  /// value now mostly just needs to outlast any pause a technician would
  /// plausibly take, so [_reopenListenForDictation] is a rare backstop
  /// again instead of the routine path.
  static const Duration _dictationNativePauseFor = Duration(seconds: 18);

  /// How long to wait, on the app's own clock, after the last new bit of
  /// speech before treating a multi-sentence dictation as finished. Longer
  /// than [_commandSettleWindow] (1800ms) on purpose — dictation is prose,
  /// not a short command phrase, so an ordinary breath or mid-sentence
  /// pause while describing a job or pricing must not cut it off early.
  /// Picked at 3.5s: within the 3-4s window multi-sentence capture calls for.
  ///
  /// This is the DEFAULT [captureDictation] settle window, used by
  /// `prepare_estimate`/`site_condition` ([handleDictationCommand]) and
  /// `change_order` ([handleChangeOrderCommand]) — both genuinely need this
  /// much pause tolerance for multi-sentence pricing descriptions. See
  /// [askQuestionSettleWindow] for the shorter override used by
  /// `ask_question`, which doesn't.
  static const Duration _dictationSettleWindow = Duration(milliseconds: 3500);

  /// [captureDictation] settle-window override for
  /// [handleAskQuestionCommand]'s `ask_question` flow specifically — NOT
  /// used by the other dictation flows ([_dictationSettleWindow] above
  /// remains their default). A troubleshooting question is typically one
  /// short spoken sentence, not multi-sentence pricing prose, so it doesn't
  /// need [_dictationSettleWindow]'s full 3.5s pause tolerance; the extra
  /// wait just made the technician wait longer than necessary for the mic
  /// to close after asking. Reduced from 3500ms to 2000ms — a moderate,
  /// safe trim, not pushed all the way to [_commandSettleWindow]'s 1800ms —
  /// confirm with a few real, natural-pace questions (including ones with a
  /// mid-sentence thinking pause) that this doesn't cut anyone off before
  /// tightening further. Public (unlike the other settle-window constants
  /// here) so `job_voice_commands.dart`'s [handleAskQuestionCommand] can
  /// pass it into [captureDictation] as its `settleWindow` override.
  static const Duration askQuestionSettleWindow = Duration(milliseconds: 2000);

  /// Safety ceiling on a single dictation capture (native `listenFor`,
  /// resets on every reopen).
  ///
  /// FIX 1 (dictation-capture total-silence bug) — this was 5 minutes, on
  /// the reasoning that a single dictation session should be able to run
  /// uninterrupted for as long as the technician talks. Real-device logs
  /// disproved that: with `listenFor=5m`, dictation mode captured ZERO
  /// speech across 13 consecutive restart cycles over ~2.5 minutes, despite
  /// the technician talking continuously — while baseline wake-word
  /// listening, using the identical [_dictationNativePauseFor]-equivalent
  /// ([_wakeWordPauseFor]) but a `listenFor` of only 58s
  /// ([_wakeWordListenFor]), worked correctly in the same window. A 5-minute
  /// `listenFor` on this recognizer appears to be unstable/unsupported in
  /// practice, not merely "generous." Shrunk to 60s — matching baseline's
  /// proven-working scale — and it is now safe to shrink: [_dictationBankedText]
  /// is banked on every reopen (see [_reopenListenForDictation]), not only on
  /// a `finalResult`, so a dictation that genuinely runs past 60s just cycles
  /// through another native session and keeps accumulating instead of losing
  /// anything. [_dictationNativePauseFor]/[_dictationSettleWindow] remain what
  /// actually decides the dictation is finished — this is purely the ceiling,
  /// now sized to a duration this recognizer has actually been proven to
  /// sustain.
  static const Duration _dictationMaxDuration = Duration(seconds: 60);

  /// Extra pause [captureDictation] waits out AFTER its caller's TTS prompt
  /// has genuinely finished playing (see [_configureTts]) and BEFORE it
  /// opens the mic — covers residual speaker/mic echo tail, on top of (not
  /// instead of) the `awaitSpeakCompletion` fix. See [captureDictation]'s
  /// doc comment for the bug this closes.
  static const Duration _dictationPostPromptBuffer = Duration(milliseconds: 400);

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

  /// FIX 2 (dictation confirm/redo) — native `pauseFor` for
  /// [captureConfirmation]'s on-device sessions. This is a short expected
  /// reply ("confirm" / "redo" / "yes" / "no"), not a multi-sentence
  /// dictation, so it doesn't need [_dictationNativePauseFor]'s full 18s —
  /// but it's still an on-device-only capture with no Deepgram leg (same
  /// as dictation, unlike ordinary command capture), so it must stay well
  /// above a couple of seconds or it inherits the exact same
  /// empty-banked-session bug [_dictationNativePauseFor] above was raised
  /// to fix. 8s gives room for a technician to hesitate ("uh... confirm")
  /// without ending the session before they've answered.
  static const Duration _confirmationNativePauseFor = Duration(seconds: 8);

  /// App-clock silence-tolerance window for [captureConfirmation] — armed
  /// the MOMENT each attempt starts listening (see
  /// [_captureConfirmationAttempt]), not only after the first onResult
  /// callback, and re-armed on every new bit of speech after that (see
  /// [_onConfirmationResult]). That "armed immediately" detail matters:
  /// Android's on-device recognizer only fires onResult once it detects
  /// actual speech (documented on [_livenessCheckDelay]), so a technician
  /// who hasn't started responding YET produces zero callbacks — without
  /// arming this up front, this class had no bounded way to notice "true
  /// silence" at all and would just keep reopening the native session
  /// forever on [_confirmationNativePauseFor]'s floor.
  ///
  /// FIX (confirmation defaulting to redo on mere hesitation) — this was
  /// 1200ms, which is barely enough time for a technician to register that
  /// the readback finished before the app had already finalized on
  /// silence and started counting it as an "unclear" reply (see
  /// [captureConfirmation]'s retry loop) — in the field this surfaced as
  /// the whole dictation getting silently discarded (defaulted to redo)
  /// essentially the instant the readback stopped, well before the
  /// technician had a real chance to answer. Raised to 6s: a real,
  /// comfortable pause to start responding, not a hard total-window cap —
  /// [_confirmationMaxDuration] is the actual backstop for that.
  static const Duration _confirmationSettleWindow = Duration(seconds: 6);

  /// Safety ceiling on a single confirmation-capture attempt (native
  /// `listenFor`) — a technician should answer within a few seconds; this
  /// is purely a backstop against a runaway session, same role as
  /// [_dictationMaxDuration] plays for dictation.
  static const Duration _confirmationMaxDuration = Duration(seconds: 30);

  /// BUG FIX (retry-prompt/mic race) — same purpose, same duration, as
  /// [_dictationPostPromptBuffer], but for [_captureConfirmationAttempt]:
  /// confirmed in logs that a confirmation attempt's own re-prompt
  /// ("I didn't hear you — say confirm to save, or redo to try again.")
  /// was being captured by the very next listening attempt as if it were
  /// the technician's reply — the banked transcript was literally a
  /// fragment of that re-prompt's own text, which happens to contain the
  /// word "confirm," so it was then (correctly, given that input)
  /// interpreted as an explicit CONFIRM. `awaitSpeakCompletion` (see
  /// [_configureTts]) alone wasn't enough here any more than it was for
  /// dictation — there's still a residual speaker/mic echo tail after
  /// playback genuinely finishes. Applied inside
  /// [_captureConfirmationAttempt] itself (not just before the first
  /// attempt) so EVERY attempt gets this buffer, including retries within
  /// [captureConfirmation]'s loop — that retry path was the one
  /// specifically missing it before this fix.
  static const Duration _confirmationPostPromptBuffer = Duration(milliseconds: 400);

  bool _initialized = false;

  /// Whether a job is currently open (Job Detail is mounted, anywhere
  /// underneath whatever's pushed on top of it — see
  /// `JobDetailScreen.initState`/`dispose`, which are the only callers of
  /// [enterJobScope]/[exitJobScope]). The wake-word loop only actually
  /// listens while this is true — recognizer initialization (see
  /// [initialize]) happens independently/earlier, so there's no first-job
  /// delay, but Home/History/Profile never trigger the mic.
  bool _jobScopeActive = false;

  /// True while an external system (currently: a Gemini Live session — see
  /// [pauseForExternalSession]) has claimed the microphone and the
  /// wake-word loop must not run — checked everywhere [_jobScopeActive] is
  /// checked before actually starting/restarting a listen() session, so
  /// this is a genuine pause of the real recognizer session, not just a
  /// flag that gets ignored. Deliberately separate from [_jobScopeActive]
  /// itself (rather than reusing enterJobScope/exitJobScope's flag
  /// directly): pausing must NOT forget "was a job actually open" — a job
  /// that goes read-only or is exited entirely WHILE paused must stay
  /// silent on resume too, not have the mic forced back on unconditionally
  /// (see [resumeAfterExternalSession]).
  bool _externallyPaused = false;
  bool _wakeDetected = false;
  bool _commandHandled = false;
  String _pendingCommandText = '';

  /// True for the rest of the current command-capture cycle once
  /// [_fallBackToOnDeviceCapture] has run — purely diagnostic (see the
  /// debugPrint in [_processCommandText]) so a capture outcome in the log
  /// can be directly attributed to the on-device Deepgram-failure fallback
  /// path rather than the normal Deepgram-succeeded path. Reset on every
  /// fresh cycle in [_startListening].
  bool _viaOnDeviceFallback = false;

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

  /// Dictation-capture state (see [captureDictation]) — mirrors
  /// [_bankedCommandText]/[_pendingCommandText]'s banked-across-reopens
  /// shape, kept as its own separate pair rather than reused so a dictation
  /// in progress can never be corrupted by (or corrupt) an ordinary
  /// command capture, even though the two never actually run concurrently.
  String _dictationBankedText = '';
  String _dictationPendingText = '';
  Timer? _dictationSettleTimer;
  Completer<String>? _dictationCompleter;

  /// Settle window actually in effect for the CURRENT [captureDictation]
  /// call — set once at the top of [captureDictation] from its
  /// `settleWindow` argument (defaulting to [_dictationSettleWindow]) and
  /// read by [_armDictationSettleTimer] on every rearm, so a per-handler
  /// override (see [askQuestionSettleWindow]) is honored for the whole
  /// capture, not just its first pause.
  Duration _activeDictationSettleWindow = _dictationSettleWindow;

  /// FIX 2 (dictation confirm/redo) — confirmation-capture state, mirroring
  /// [_dictationBankedText]/[_dictationPendingText]'s shape for the exact
  /// same reason: its own separate fields so a confirm/redo reply can never
  /// be corrupted by (or corrupt) an in-progress dictation, even though the
  /// two never run concurrently — [captureConfirmation] only ever starts
  /// after [captureDictation] has already resolved.
  String _confirmationBankedText = '';
  String _confirmationPendingText = '';
  Timer? _confirmationSettleTimer;
  Completer<String>? _confirmationCompleter;

  // --- Session lifecycle tracking (stale-session fix) --------------------
  //
  // Minted fresh every time _ensureStoppedThenListen actually calls
  // _speech.listen() — i.e. once per genuinely NEW native session,
  // whether that's the wake-word loop starting (_startListening),
  // reopening mid-command (_reopenListenForCommand), or a dictation
  // capture (captureDictation). Included in every VOICE debugPrint from
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

  /// REVERTED (Deepgram-fallback timing regression) — this was a
  /// speculative fixed delay inserted here between stopping the on-device
  /// recognizer and starting a Deepgram attempt, added on an unvalidated
  /// hypothesis about a mic-hardware handoff race. It was never confirmed
  /// necessary by a real test, and — worse — it unconditionally added
  /// latency to EVERY wake-word cycle regardless of outcome, directly
  /// working against reliably capturing a short command spoken right
  /// after the wake word. Removed. See [_deepgramAttemptTimeout] below for
  /// the actual, confirmed cause of the fallback regression this was
  /// mistaken for.
  ///
  /// FIX (fallback-capture regression — "no words captured" on every
  /// attempt) — the actual cause: [_tryDeepgramCommandCapture] never had
  /// an overall bound on how long a Deepgram attempt is allowed to run
  /// before giving up and calling [_fallBackToOnDeviceCapture]. Before
  /// this session's auth fixes, Deepgram failed FAST — usually within a
  /// couple hundred ms (bad URL, then bad auth) — so the fallback started
  /// almost immediately after the wake word, well within the time a
  /// technician is still speaking a short command ("photos", "confirm").
  /// Now that auth actually works, Deepgram gets much further (a real
  /// token request + a real WebSocket handshake, neither of which has its
  /// own timeout) before it still ultimately doesn't produce a transcript
  /// — pushing the fallback's start several seconds later, by which point
  /// a short command is already over and there's nothing left for the
  /// fresh on-device session to hear. This is TIMING, not shared mutable
  /// state — [_fallBackToOnDeviceCapture]/[_reopenListenForCommand]
  /// themselves are unchanged and need no Deepgram-awareness; the fix is
  /// bounding how long [_tryDeepgramCommandCapture] waits before calling
  /// them. 4s is generous enough for Deepgram to genuinely succeed on a
  /// healthy connection, while keeping the fallback's worst-case start
  /// time short and predictable again.
  static const Duration _deepgramAttemptTimeout = Duration(seconds: 4);

  /// Bounded safety net for [_stopConfirmation] — NOT the normal path.
  /// Real sessions always report done/notListening; this only fires if one
  /// genuinely never does (e.g. it's already the stale/dead session this
  /// whole mechanism exists to catch), so a confirmation wait can't hang
  /// the loop forever. Anything logged against this path is, by
  /// definition, degraded — the liveness check ([_armLivenessCheck]) is
  /// what's supposed to catch that session and force a reinit before this
  /// timeout would ever matter in practice.
  static const Duration _stopConfirmationTimeout = Duration(seconds: 2);

  /// Bounded safety net for [speak]'s `await _tts.speak(text)` — NOT the
  /// normal path. Real playback always resolves via the platform's
  /// completion callback (`awaitSpeakCompletion(true)`, see
  /// [_configureTts]); this only fires if that callback genuinely never
  /// arrives.
  ///
  /// CONFIRMED bug (real device logs, `ask_question`'s `no_match`/decline
  /// path — `job_voice_commands.dart`'s `_handleTroubleshoot`): the
  /// completion callback occasionally never fires for the short decline
  /// utterance ("Sorry, that information is not available in the
  /// Knowledge Base."), leaving `await _tts.speak(text)` — and therefore
  /// every awaiter chained above it (`_handleTroubleshoot` ->
  /// `handleAskQuestionCommand` -> `_dispatchCommand` ->
  /// `_processCommandText`) — hanging forever. [_scheduleWakeWordRestart]
  /// was never actually missing from either branch: `_handleTroubleshoot`
  /// speaks a confident KB answer and a decline message through this
  /// exact same [speak] call, so this fixes both identically rather than
  /// special-casing one. Sized generously — well above any realistic
  /// single/multi-sentence troubleshooting answer even at this app's slow
  /// [ttsSpeechRate] — so genuine playback is never cut off, but low
  /// enough to recover well within the 60+s silence reported on-device.
  static const Duration _speakCompletionTimeout = Duration(seconds: 20);

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
          _syncGeminiTokenPrefetch();
        } catch (e, stackTrace) {
          debugPrint(
            'VOICE ERROR (stale-session reinit) [was session=$sessionId]: $e\n$stackTrace',
          );
          if (mounted) state = state.copyWith(available: false);
        }
      });
      if (!mounted) return;
      if (state.available && _jobScopeActive && !state.muted && !_externallyPaused) {
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
      // _speech.initialize() (speech_to_text) and _configureTts()
      // (flutter_tts) are separate plugins/platform channels with zero
      // data dependency on each other — run them concurrently instead of
      // stacking their platform-channel round trips end to end.
      final results = await Future.wait<dynamic>([
        _speech.initialize(onStatus: _onStatus, onError: _onError),
        _configureTts(),
      ]);
      final available = results[0] as bool;
      debugPrint('VOICE: speech recognizer available=$available');
      if (!mounted) return;
      state = state.copyWith(available: available);
      _syncGeminiTokenPrefetch();
      // Covers the (unusual but possible) case where a job was already
      // opened before this async initialize() resolved.
      if (available && _jobScopeActive && !state.muted && !_externallyPaused) {
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
    _syncGeminiTokenPrefetch();
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
    // CONFIRMED BUG (logcat): leaving the job only stopped the wake-word
    // recognizer — an open Gemini Live session kept streaming mic audio and
    // answering ("Are you there?" -> "Yes, I can hear you...") on Home.
    // Gemini is only ever reachable inside an active job: close it too.
    _endActiveGeminiSession('left job scope');
    _syncGeminiTokenPrefetch();
    _stage = _ListenStage.idle;
    _cancelCommandSettleTimer();
    _cancelRestartDebounce();
    _cancelActiveDeepgramCapture();
    unawaited(_lockedStop('exitJobScope'));
    unawaited(_stopBluetoothScoIfActive('exitJobScope'));
    _cancelDictationSettleTimer();
    _finishDictationCapture('');
    _cancelConfirmationSettleTimer();
    _finishConfirmationCapture('');
  }

  /// Genuinely pauses the wake-word loop for an external mic consumer (a
  /// Gemini Live session — see `GeminiLiveTestScreen._startTest`/
  /// `_teardown`) — the SAME real teardown [exitJobScope] does (stop the
  /// actual `_speech` session via [_lockedStop], cancel every pending
  /// timer/in-flight capture, release Bluetooth SCO), so the microphone is
  /// genuinely released before the other system claims it, not just
  /// ignored while still technically listening underneath. Idempotent —
  /// calling this while already paused is a no-op.
  ///
  /// Deliberately does NOT touch [_jobScopeActive] (unlike [exitJobScope]):
  /// this is a TEMPORARY suspension, not "the job closed" — see
  /// [resumeAfterExternalSession] for why that distinction is what keeps
  /// resume from ever incorrectly forcing the mic back on.
  Future<void> pauseForExternalSession(String reason) async {
    if (_externallyPaused) return;
    debugPrint('VOICE: pausing wake-word loop for external session ($reason) — mic will stop listening');
    _externallyPaused = true;
    // A genuinely new Gemini session is starting — see [GlobalVoiceState.
    // sessionEpoch]'s doc comment for why [VoiceInteractionOverlay] needs
    // this bump distinguished from an ordinary in-session phase change.
    if (mounted) state = state.copyWith(sessionEpoch: state.sessionEpoch + 1);
    _stage = _ListenStage.idle;
    _cancelCommandSettleTimer();
    _cancelRestartDebounce();
    _cancelActiveDeepgramCapture();
    await _lockedStop('pauseForExternalSession:$reason');
    await _stopBluetoothScoIfActive('pauseForExternalSession:$reason');
    _cancelDictationSettleTimer();
    _finishDictationCapture('');
    _cancelConfirmationSettleTimer();
    _finishConfirmationCapture('');
  }

  /// Resumes the wake-word loop after [pauseForExternalSession] — but ONLY
  /// if it should actually still be running: re-derives that from the
  /// CURRENT [_jobScopeActive]/`state.available`/`state.muted`, exactly the
  /// same condition [enterJobScope] itself checks, rather than
  /// unconditionally forcing `_startListening` again. This matters because
  /// the paused window is real wall-clock time during which the technician
  /// could have exited the job entirely, or the job could have gone
  /// read-only (e.g. `job_complete` dispatched THROUGH the very Gemini
  /// session this is resuming from) — either of those already called
  /// [exitJobScope] live while paused, and this must respect that rather
  /// than clobbering it back on. Idempotent — calling this while not
  /// paused is a no-op.
  Future<void> resumeAfterExternalSession(String reason) async {
    if (!_externallyPaused) return;
    _externallyPaused = false;
    debugPrint(
      'VOICE: resuming after external session ($reason) — '
      'jobScopeActive=$_jobScopeActive available=${state.available} muted=${state.muted}',
    );
    // Clears whatever phase the external session left behind (see
    // setExternalSessionPhase) BEFORE deciding whether to restart
    // listening — otherwise a session that ends while e.g. the job has
    // gone read-only (the early return just below) would leave
    // VoicePhaseIndicator stuck showing "speaking"/"listening" forever,
    // since nothing else would ever touch phase again for a screen that's
    // correctly gone silent. If listening DOES restart, _startListening's
    // own flow sets phase again almost immediately anyway.
    if (mounted) state = state.copyWith(phase: VoicePhase.idle, screenTaskActive: false);
    // The session just used the spare (tokens are single-use) — line up the
    // next one. No-op unless voice is still live on a job.
    _geminiTokens.prefetch();
    if (!mounted || !_jobScopeActive || !state.available || state.muted) {
      debugPrint('VOICE: resumeAfterExternalSession($reason) — not resuming listening, guard condition not met');
      return;
    }
    await _startListening(reason: 'resumeAfterExternalSession:$reason');
  }

  /// Lets an external session (currently: the ambient Gemini Live screen —
  /// see `GeminiLiveTestScreen`) drive [VoicePhaseIndicator] (and anything
  /// else watching `state.phase`) while it, not this recognizer, actually
  /// owns the microphone — reusing the exact same phase-driven visual
  /// language (`listening`/`processing`/`speaking`) rather than adding a
  /// new indicator widget or a new [VoicePhase] value. A no-op outside an
  /// active [pauseForExternalSession] window, so a stray/late call (e.g.
  /// racing [resumeAfterExternalSession]) can never leave a wrong phase
  /// stuck on screen after this recognizer has already resumed.
  void setExternalSessionPhase(VoicePhase phase) {
    if (!_externallyPaused || !mounted) return;
    state = state.copyWith(phase: phase);
  }

  /// Lets the same external session (the ambient Gemini Live screen) tell
  /// [VoiceInteractionOverlay] whether it has navigated to real, visible
  /// screen content that a function call triggered — see [GlobalVoiceState.
  /// screenTaskActive]'s doc comment for the full contract. Same
  /// active-external-session-only guard as [setExternalSessionPhase], for
  /// the same reason: a stray/late call from a session that has already
  /// resumed FieldLoop must not leave this flag stuck wrong.
  void setScreenTaskActive(bool active) {
    if (!_externallyPaused || !mounted) return;
    state = state.copyWith(screenTaskActive: active);
  }

  /// Fires the moment the wake word ("FieldLoop"/"Loop On") is heard —
  /// starts a Gemini Live session for whichever job is currently open
  /// (`currentlyViewedJobIdProvider`, kept correct underneath Photo
  /// Capture/Photo Preview/Estimate/Change Orders too, not just Job
  /// Detail — see that provider's own doc comment) instead of the old
  /// fixed-phrase command capture this used to kick off.
  ///
  /// [pauseForExternalSession] runs FIRST — same real mic release the
  /// manual/tap-triggered entry point already uses — so there's never a
  /// window where this recognizer and Gemini's own mic capture could both
  /// be open. Navigation happens via [rootNavigatorKey] rather than a
  /// BuildContext: this fires from inside a speech-plugin result callback,
  /// not a widget's build, so there's no context of its own to navigate
  /// with — same reasoning `rootNavigatorKey` already exists for (a tapped
  /// system notification, see that key's doc comment).
  ///
  /// `ambient: true` is what makes the screen auto-start immediately, hide
  /// its debug-only Start/Stop buttons and scrollback log, show the same
  /// [VoicePhaseIndicator] visual language instead (see
  /// [setExternalSessionPhase]), and remove itself the moment the session
  /// ends — the manual "Voice Assistant" tap-fallback button on Job Detail
  /// pushes the exact same screen WITHOUT `ambient`, keeping its existing
  /// manual/debug experience unchanged (a normal opaque `Navigator` route,
  /// pushed/popped the ordinary way).
  ///
  /// Inserted via a raw [OverlayEntry] into the root [Navigator]'s own
  /// [Overlay] — CHANGED TWICE now:
  ///  1. Originally `MaterialPageRoute`, fully opaque for the session's
  ///     entire duration.
  ///  2. Then a non-opaque `PageRouteBuilder` (`TransparentPageRoute`) —
  ///     CONFIRMED on a real device to still NOT let touches (scrolling,
  ///     button taps) reach the route underneath, regardless of `opaque:
  ///     false` or what the pushed screen's own content painted;
  ///     `Navigator`/`ModalRoute` apparently insulates the current route's
  ///     input from whatever's behind it regardless of that flag.
  ///  3. Now: a plain [OverlayEntry], inserted directly into the SAME
  ///     [Overlay] the root [Navigator] already uses, the exact mechanism
  ///     [VoiceInteractionOverlay]/`DictationConfirmationBar` already use
  ///     successfully at the `MaterialApp.builder` level — no `ModalRoute`
  ///     wrapping at all, so hit-testing is plain `Stack`-style cascading:
  ///     wherever [GeminiLiveTestScreen]'s own body doesn't paint anything
  ///     (see `_buildAmbientPureConversationUi`), a touch genuinely falls
  ///     through to whatever's underneath (Job Detail, or wherever the
  ///     technician was). [VoiceInteractionOverlay] still draws its
  ///     dramatic brief full-screen intro ON TOP of everything for the
  ///     first few seconds, since it's layered even further above (also at
  ///     the `MaterialApp.builder` level, so above this `OverlayEntry`
  ///     too) — independent of whichever mechanism holds this screen.
  ///
  /// Since there's no route to `push`/`await` the pop of, [sessionEnded]
  /// (a [Completer]) stands in for that: [GeminiLiveTestScreen.
  /// onAmbientSessionEnded] removes the entry AND completes it, together,
  /// exactly once per session — see that field's doc comment.
  /// The running ambient session's end signal (see
  /// `GeminiLiveTestScreen.endRequest`) — `null` when no session is up.
  ValueNotifier<String?>? _activeGeminiSessionEndRequest;

  /// Closes the ambient Gemini Live session on screen, if any — mic, socket
  /// and any pending transcript/reply all stop at once (see
  /// `GeminiLiveTestScreen._onEndRequest`).
  void _endActiveGeminiSession(String reason) {
    final endRequest = _activeGeminiSessionEndRequest;
    if (endRequest == null) return;
    _activeGeminiSessionEndRequest = null;
    debugPrint('VOICE: ending the active Gemini Live session ($reason)');
    endRequest.value = reason;
  }

  Future<void> _triggerGeminiSession() async {
    // Claimed BEFORE the recognizer is stopped below, not after: releasing
    // the mic takes real time, and there's no reason the token (usually
    // already pre-fetched — see [_geminiTokens]) should wait behind it. The
    // no-op error listener only keeps an early return below from leaving a
    // failed fetch unhandled; the session itself still awaits and reports
    // any error exactly as before.
    final tokenFuture = takeGeminiToken();
    unawaited(tokenFuture.then((_) {}, onError: (Object _) {}));

    await pauseForExternalSession('wake_word');

    // Gemini is reachable only inside an active job — the same scope the
    // wake-word loop itself runs in. Also catches the job being left while
    // the mic was being released just above.
    if (!_jobScopeActive) {
      debugPrint('VOICE: wake word heard but job scope is not active — not starting a Gemini session');
      await resumeAfterExternalSession('wake_word_out_of_scope');
      return;
    }

    final jobId = _ref.read(currentlyViewedJobIdProvider);
    if (jobId == null) {
      debugPrint('VOICE: wake word heard but no job is currently open — nothing to start a Gemini session for');
      await resumeAfterExternalSession('wake_word_no_job');
      return;
    }

    final navigatorState = rootNavigatorKey.currentState;
    if (navigatorState == null) {
      debugPrint('VOICE ERROR: rootNavigatorKey has no live NavigatorState — cannot start a Gemini session');
      await resumeAfterExternalSession('wake_word_no_navigator');
      return;
    }
    // NavigatorState.overlay — NOT Overlay.of(context) — is what actually
    // gets this Navigator's OWN internal Overlay from here: Overlay.of
    // searches UP from a given context for an ancestor Overlay, but
    // rootNavigatorKey.currentContext is the Navigator widget's OWN
    // context (built by ITS parent), not a context from inside its routed
    // pages — searching up from there would look at the Navigator's
    // ancestors (MaterialApp, ...), never its own internally-built Overlay,
    // which is a DESCENDANT of the Navigator, not an ancestor.
    final overlay = navigatorState.overlay;
    if (overlay == null) {
      debugPrint('VOICE ERROR: no root Overlay available — cannot start a Gemini session');
      await resumeAfterExternalSession('wake_word_no_overlay');
      return;
    }

    debugPrint('VOICE: wake word heard — starting ambient Gemini Live session for job $jobId');
    final sessionEnded = Completer<void>();
    final endRequest = ValueNotifier<String?>(null);
    _activeGeminiSessionEndRequest = endRequest;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => GeminiLiveTestScreen(
        jobId: jobId,
        ambient: true,
        tokenFuture: tokenFuture,
        endRequest: endRequest,
        onAmbientSessionEnded: () {
          entry.remove();
          if (!sessionEnded.isCompleted) sessionEnded.complete();
        },
      ),
    );
    overlay.insert(entry);
    await sessionEnded.future;
    if (identical(_activeGeminiSessionEndRequest, endRequest)) _activeGeminiSessionEndRequest = null;

    // Defensive backstop, not the primary resume path: GeminiLiveTestScreen
    // already calls resumeAfterExternalSession itself from _teardown()
    // (which dispose() always runs once the OverlayEntry above is removed)
    // — this is a harmless no-op by the time execution reaches here in the
    // normal case (see that method's own `if (!_externallyPaused) return`
    // idempotency guard), and only actually does something if some future
    // change ever let the entry go away without running _teardown() first.
    await resumeAfterExternalSession('wake_word_session_returned');
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
    _geminiTokens.deactivate();
    _stage = _ListenStage.idle;
    _cancelCommandSettleTimer();
    _cancelRestartDebounce();
    _cancelActiveDeepgramCapture();
    await _lockedStop('stopForLogout');
    await _stopBluetoothScoIfActive('stopForLogout');
    await _withSpeechLock('cancel (stopForLogout)', () => _speech.cancel());
    // A forced cancel() outside the normal stop->confirm->settle flow —
    // don't leave a future listen() waiting on a confirmation this cancel
    // may never deliver.
    _liveSessionId = null;
    _pendingSettle = false;
    _stopConfirmation = null;
    _cancelDictationSettleTimer();
    _finishDictationCapture('');
    _cancelConfirmationSettleTimer();
    _finishConfirmationCapture('');
    if (mounted) state = const GlobalVoiceState();
  }

  Future<void> setMuted(bool muted) async {
    debugPrint('VOICE: ${muted ? "muting" : "unmuting"}');
    state = state.copyWith(muted: muted);
    _syncGeminiTokenPrefetch();
    if (muted) {
      _stage = _ListenStage.idle;
      _cancelCommandSettleTimer();
      _cancelRestartDebounce();
      _cancelActiveDeepgramCapture();
      await _lockedStop('setMuted');
      await _stopBluetoothScoIfActive('setMuted');
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
        // FIX 1 — logs the mode this session is ACTUALLY starting in,
        // dumped from _stage itself (not inferred/assumed), for every
        // single session this method ever starts (wake-word loop, mid-
        // command reopen, dictation, confirmation) — directly verifiable
        // against the pauseFor/listenFor values the calling method logged
        // just before this, so a mismatch between "params logged as
        // baseline" and "mode actually applied" is caught immediately
        // instead of only showing up as misbehavior several seconds later.
        _voiceLog(
          'calling _speech.listen() — this is the new current session, mode=$_stage',
        );
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
      if (_stage == _ListenStage.dictation) {
        // Same Android quirk documented on _commandSettleWindow: the native
        // session can end well before the technician is actually done
        // dictating — only _dictationSettleTimer, on the app's own clock,
        // is allowed to decide the dictation is finished.
        unawaited(_reopenListenForDictation());
        return;
      }
      if (_stage == _ListenStage.confirmation) {
        // FIX 2 — same reasoning again, for the short confirm/redo reply:
        // only _confirmationSettleTimer decides the reply is finished.
        unawaited(_reopenListenForConfirmation());
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
      } else if (_stage == _ListenStage.dictation && !_commandHandled) {
        unawaited(_reopenListenForDictation());
      } else if (_stage == _ListenStage.confirmation && !_commandHandled) {
        unawaited(_reopenListenForConfirmation());
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
      _finishDictationCapture('');
      _finishConfirmationCapture('');
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
    if (_externallyPaused) {
      _voiceLog('restart SUPPRESSED — cause=${cause.name} (externally paused, e.g. a Gemini Live session)');
      return;
    }
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
      if (!mounted || state.muted || !state.available || !_jobScopeActive || _externallyPaused)
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

  /// DIAGNOSTIC (Bluetooth-headset-mic-ignored investigation) — reads
  /// current audio routing state via [_audioDiagnosticsChannel]
  /// (`MainActivity.kt`'s `getAudioRouteInfo`, Android only) and logs it.
  /// Does not change routing itself (see [_maybeRouteBluetoothSco] for the
  /// actual fix) and never throws — a failed/missing platform call (e.g.
  /// iOS, where no handler is registered) is itself logged rather than
  /// surfacing as an unhandled exception.
  ///
  /// `bluetooth_connected` can still come back `null` — logged as such,
  /// not coerced to `false` — if the native side hits a `SecurityException`
  /// querying `BluetoothAdapter` despite `BLUETOOTH_CONNECT` now being
  /// declared/requested (e.g. the technician denied it): that's a real
  /// "couldn't determine," not a confirmed "not connected." See
  /// `MainActivity.kt`'s `getAudioRouteInfo` doc comment for the full
  /// picture.
  Future<void> _logAudioRoute(String reason) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final result = await _audioDiagnosticsChannel.invokeMethod<Map<Object?, Object?>>(
        'getAudioRouteInfo',
      );
      debugPrint(
        'AUDIO ROUTE: bluetooth_connected=${result?['bluetoothConnected']} '
        'bluetooth_sco_active=${result?['bluetoothScoActive']} '
        'input_device=${result?['inputDevice']} (reason=$reason)',
      );
    } catch (e, stackTrace) {
      debugPrint('AUDIO ROUTE: failed to query audio route info (reason=$reason): $e\n$stackTrace');
    }
  }

  /// FIX (Bluetooth-headset-mic-ignored bug) — set once
  /// [_maybeRouteBluetoothSco] has actually requested (and, per its own
  /// await, settled — connected or given up) a Bluetooth SCO audio link
  /// for the CURRENT job-scope voice session. Guards against re-requesting
  /// SCO on every one of [_startListening]'s frequent internal restarts
  /// (wake-word timeout, `livenessStaleReinit`, `unmuted`, ...) — SCO,
  /// once up, should stay up for the whole session, not be torn down and
  /// re-established on every cycle (each request costs a real,
  /// user-visible delay — see [_maybeRouteBluetoothSco]'s doc comment).
  /// Reset to `false` by [_stopBluetoothScoIfActive], called from whichever
  /// teardown path (`exitJobScope`/`setMuted(true)`/`stopForLogout`) ends
  /// the session for real.
  bool _bluetoothScoActive = false;

  /// FIX (Bluetooth-headset-mic-ignored bug) — the actual routing fix,
  /// confirmed necessary via a real `SecurityException` in testing:
  /// Android does not automatically route mic input through a connected
  /// Bluetooth headset just because it's connected. An app must explicitly
  /// open a Bluetooth SCO (voice) audio link via
  /// `AudioManager.startBluetoothSco()`/`setBluetoothScoOn(true)` (see
  /// `MainActivity.kt`'s `startBluetoothScoAudio`) before the mic opens,
  /// or the platform falls back to the built-in mic regardless of what's
  /// connected — exactly the reported bug.
  ///
  /// Called from [_startListening], AWAITED before the native listen()
  /// session below opens the mic (unlike [_logAudioRoute], which is
  /// read-only telemetry and safe to fire-and-forget) — the whole point is
  /// for the headset mic to already be the active route by the time
  /// capture starts, not to race it. Only actually does anything once per
  /// job-scope session (see [_bluetoothScoActive]); every other call this
  /// session is a fast no-op.
  ///
  /// Requests `BLUETOOTH_CONNECT` at runtime — lazily, not as part of the
  /// upfront Permissions Setup flow — the first time this runs while a
  /// Bluetooth audio device is actually detected connected (checked via
  /// [_audioDiagnosticsChannel]'s `isBluetoothAudioDevicePresent`, which
  /// needs no Bluetooth permission itself: it reads the audio-framework
  /// device list, not `BluetoothAdapter`). [hasAskedBluetoothPermission]/
  /// [markBluetoothPermissionAsked] (`permission_providers.dart`) make
  /// that ask a genuine one-time thing — a technician who denies it isn't
  /// re-prompted on every subsequent job or listen() restart.
  Future<void> _maybeRouteBluetoothSco(String reason) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_bluetoothScoActive) return;
    try {
      final devicePresent =
          await _audioDiagnosticsChannel.invokeMethod<bool>('isBluetoothAudioDevicePresent') ?? false;
      if (!devicePresent) {
        _voiceLog('bluetooth SCO: no bluetooth audio device present, skipping (reason=$reason)');
        return;
      }
      var permissionStatus = _ref.read(bluetoothPermissionProvider).status;
      if (!permissionStatus.isGranted) {
        if (await hasAskedBluetoothPermission()) {
          _voiceLog(
            'bluetooth SCO: bluetooth device present but permission not granted '
            '(status=$permissionStatus) and already asked once before — not re-prompting '
            '(reason=$reason)',
          );
          return;
        }
        _voiceLog(
          'bluetooth SCO: bluetooth audio device present, requesting BLUETOOTH_CONNECT '
          '(reason=$reason)',
        );
        await _ref.read(bluetoothPermissionProvider.notifier).request();
        await markBluetoothPermissionAsked();
        permissionStatus = _ref.read(bluetoothPermissionProvider).status;
        if (!permissionStatus.isGranted) {
          _voiceLog(
            'bluetooth SCO: permission denied (status=$permissionStatus) — continuing on '
            'the built-in mic (reason=$reason)',
          );
          return;
        }
      }
      _voiceLog('bluetooth SCO: requesting SCO audio routing (reason=$reason)');
      final started = await _audioDiagnosticsChannel.invokeMethod<bool>('startBluetoothScoAudio') ?? false;
      _bluetoothScoActive = started;
      _voiceLog('bluetooth SCO: startBluetoothScoAudio() returned started=$started (reason=$reason)');
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (bluetooth SCO routing) reason=$reason: $e\n$stackTrace');
    }
  }

  /// Counterpart to [_maybeRouteBluetoothSco] — tears down the Bluetooth
  /// SCO link when the whole job-scope voice session actually ends
  /// (`exitJobScope`/`setMuted(true)`/`stopForLogout`), not on every
  /// individual [_startListening] restart within a session (see
  /// [_bluetoothScoActive]). A no-op if SCO was never actually started
  /// this session.
  Future<void> _stopBluetoothScoIfActive(String reason) async {
    if (!_bluetoothScoActive) return;
    _bluetoothScoActive = false;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final stopped = await _audioDiagnosticsChannel.invokeMethod<bool>('stopBluetoothScoAudio') ?? false;
      _voiceLog('bluetooth SCO: stopBluetoothScoAudio() returned stopped=$stopped (reason=$reason)');
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (bluetooth SCO teardown) reason=$reason: $e\n$stackTrace');
    }
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
      'available=${state.available} jobScopeActive=$_jobScopeActive externallyPaused=$_externallyPaused)',
    );
    if (!mounted || state.muted || !state.available || !_jobScopeActive || _externallyPaused) {
      _voiceLog('_startListening() returning early — guard condition not met');
      return;
    }
    _voiceLog('listening (single session: wake word + command)...');
    // FIX (Bluetooth-headset-mic-ignored bug) — route audio through a
    // connected Bluetooth headset's SCO link, if present, BEFORE the
    // native listen() session below opens the mic (awaited, on purpose —
    // see _maybeRouteBluetoothSco's doc comment for why this can't be
    // fire-and-forget the way the diagnostic log is).
    await _maybeRouteBluetoothSco(reason);
    // DIAGNOSTIC (Bluetooth-headset-mic-ignored investigation) — logged
    // right before the native listen() session actually opens the mic, and
    // AFTER the SCO routing above has had its chance to take effect, so
    // this reflects the route the mic is actually about to use. Awaited
    // (unlike a truly fire-and-forget log) since it's a single fast
    // platform-channel round trip on top of the routing wait already just
    // paid above — negligible added delay for a much more trustworthy log.
    await _logAudioRoute(reason);
    _stage = _ListenStage.active;
    _viaOnDeviceFallback = false;
    _wakeDetected = false;
    _wakeWordDetectedAt = null;
    _pendingCommandText = '';
    _bankedCommandText = '';
    _commandHandled = false;
    _cancelCommandSettleTimer();
    // FIX 1 (dictation-mode leak into the next wake-word session): moving
    // _stage to .active above is NOT enough on its own to guarantee the
    // next session behaves as wake-word mode. _onDictationResult /
    // _onConfirmationResult are bound as the onResult callback of whatever
    // native session dictation/confirmation capture last opened, and that
    // native session is not necessarily torn down yet at this exact point
    // — only _ensureStoppedThenListen below (which stops-and-confirms the
    // prior live session before this new one starts) guarantees that. In
    // the gap between _commandHandled being reset to false (just above)
    // and that stop being genuinely confirmed, a stray callback from the
    // OLD dictation/confirmation session could otherwise still pass those
    // handlers' _commandHandled guard and arm a phantom dictation/
    // confirmation settle timer — which, when it later fired, finalized
    // stray background audio as a bogus transcript (confirmed in logs:
    // "1955", clearly not real speech) AND clobbered this brand new
    // session's _stage/_commandHandled out from under it. Explicitly
    // cancelling both settle timers and resetting both text buffers here,
    // as part of this SAME restart sequence, closes that gap; the
    // _stage != _ListenStage.dictation / .confirmation guards added to
    // _onDictationResult / _onConfirmationResult are the other half of
    // this fix — belt and suspenders, since either alone would have
    // stopped the bug.
    _cancelDictationSettleTimer();
    _dictationBankedText = '';
    _dictationPendingText = '';
    _cancelConfirmationSettleTimer();
    _confirmationBankedText = '';
    _confirmationPendingText = '';
    // A session is starting right now — any earlier "restart later" plan
    // still pending is moot.
    _cancelRestartDebounce();
    Future(() {
      // Baseline session start — the mic is opening to wait for the wake
      // word, not to capture a command yet (see VoicePhase's doc comment).
      state = state.copyWith(transcript: '', phase: VoicePhase.awaitingWakeWord);
    });
    _voiceLog(
      'baseline wake-word listen() params: pauseFor=${_wakeWordPauseFor.inSeconds}s '
      'listenFor=${_wakeWordListenFor.inSeconds}s mode=$_stage (session should stay open '
      'across normal silence and only end via explicit stop, not on its own)',
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
      // FIX 1 — belt-and-suspenders companion to the same guard added to
      // _onDictationResult/_onConfirmationResult: this callback is bound to
      // whatever native session THIS function's owning listen() call
      // opened, and that session isn't guaranteed to be torn down the
      // instant a dictation/confirmation capture finishes on the app's own
      // clock. Without this, a stray straggling callback from an old
      // dictation/confirmation session could in principle be misrouted
      // here if a future refactor ever passed _onSessionResult somewhere
      // stage-mismatched; harmless today (this is the only call site that
      // ever binds this handler, and it always does so with _stage already
      // set to .active — see _startListening), but keeping every onResult
      // handler consistently self-checking its own stage is what makes
      // that invariant enforced by the code, not just by convention.
      if (_stage != _ListenStage.active) return;
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
        _pendingCommandText = words.substring(matched.end).trim();
        // Task B diagnostic: words the ON-DEVICE recognizer already heard
        // after the wake word, in the same breath. They become
        // `state.transcript` (what the Voice Assistant screen shows under
        // "Listening..."), but the Gemini session's own mic only opens after
        // this recognizer is stopped, so Gemini never hears them — if the
        // command was all in here, nothing downstream can act on it. Compare
        // with the session's first `VOICE PIPELINE [u=...] transcript_received`.
        debugPrint(
          _pendingCommandText.isEmpty
              ? 'VOICE PIPELINE [wake] wake_word: nothing heard after the wake word yet'
              : 'VOICE PIPELINE [wake] wake_word: on-device recognizer already heard "$_pendingCommandText" after the '
                    'wake word — shown on screen as the transcript, but NOT passed to the Gemini session',
        );
        _onWakeWordDetected(); // FIX 2: instant haptic + tone, fire-and-forget
        // The wake word itself was heard during `awaitingWakeWord` — this
        // is the edge into genuine active capture (see VoicePhase's doc
        // comment). `listening` from this very moment, in the same frame as
        // the haptic + tone above: the Gemini session that takes over the
        // mic (see [_triggerGeminiSession]) buffers the technician's audio
        // from right after this handoff and delivers it once connected, so
        // from their point of view they're being listened to already. This
        // used to be `processing` ("Thinking..."), which read as "not
        // listening yet" for the ~2-3s of session setup and then switched
        // visuals at setupComplete — the cold start this avoids.
        if (mounted) {
          state = state.copyWith(transcript: _pendingCommandText, phase: VoicePhase.listening);
        }
        _logLatency('wake-word-detected');
        // Starts a Gemini Live session instead of the old fixed-phrase
        // command capture (matching a registered VoiceCommand and running
        // its job_voice_commands.dart handler) this used to kick off here —
        // Gemini's own function-calling now handles the entire
        // conversation from this point on. See [_triggerGeminiSession]'s
        // doc comment for the full handoff.
        unawaited(_triggerGeminiSession());
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
    // FIX (Deepgram-fallback regression) — this is the single place that
    // (re)opens an on-device session bound to _onSessionResult for command
    // capture, called from two different places that can leave _stage in
    // two different states: _onSessionResult's own mid-command reopen
    // (where _stage is already .active, so this is a no-op) AND
    // _fallBackToOnDeviceCapture, reached after _tryDeepgramCommandCapture
    // deliberately set _stage = .idle to free the mic for Deepgram (see
    // that method) and never restored it. _onSessionResult now checks
    // _stage == .active before processing any result (see FIX 1, previous
    // round) — without this line, every result from a Deepgram-fallback
    // session was silently dropped, the command settle timer fired on
    // unchanged (still empty) text, and the technician got "no command
    // captured after wake word" despite speaking right after the wake
    // word. Setting it here, at the one place that actually starts this
    // kind of session, makes the invariant hold regardless of which caller
    // reopens it — the same reasoning already applied to _stage being set
    // at the top of captureDictation/_captureConfirmationAttempt for their
    // own modes.
    _stage = _ListenStage.active;
    final pauseFor =
        _matchedShortWindowCommand()?.pauseWindow ?? _commandPauseFor;
    _voiceLog(
      'native session ended before settle window elapsed — reopening mic '
      '(banked="$_pendingCommandText", pauseFor=${pauseFor.inMilliseconds}ms, '
      'listenFor=${_commandListenFor.inMinutes}m, mode=$_stage)',
    );
    await _ensureStoppedThenListen(
      onResult: _onSessionResult,
      options: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        listenFor: _commandListenFor,
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
  ///
  /// FIX (resilience) — the entire Deepgram-specific body below is wrapped
  /// in a try/catch that itself falls back to on-device. `DeepgramCommand
  /// Capture.capture()` already documents that it never throws (every
  /// internal failure — token request, WebSocket, mic stream, a malformed
  /// message — resolves to `null` instead, see that class), but this outer
  /// catch enforces that promise structurally rather than trusting it by
  /// convention: this method is invoked as `unawaited(...)` from
  /// _onSessionResult, so ANY uncaught exception here (a 500, a network
  /// timeout, a future change to DeepgramCommandCapture that adds a new
  /// throw path, anything) would otherwise surface only as an unhandled
  /// Future error — silently leaving the technician with no fallback and
  /// no response, indistinguishable from voice just going dead after the
  /// wake word. "Voice should never go fully silent after a wake word" is
  /// the requirement; this is what actually guarantees it regardless of
  /// what's happening on the Deepgram/AWS side.
  // ignore: unused_element — no longer called (see _useDeepgramCapture's doc comment); left in place.
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

    try {
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
      // FIX (fallback-capture regression) — bounded here, at the
      // orchestration level, NOT inside DeepgramCommandCapture itself (see
      // _deepgramAttemptTimeout's doc comment — that class's own internals
      // are deliberately untouched). On timeout, cancel() is the exact
      // same public shutdown path already used when the technician backs
      // out of a job mid-capture — nothing new added to that class, just
      // an existing, already-safe way to give up early.
      final result = await capture
          .capture(supabaseAccessToken: accessToken)
          .timeout(
            _deepgramAttemptTimeout,
            onTimeout: () {
              _voiceLog(
                'Deepgram capture exceeded ${_deepgramAttemptTimeout.inSeconds}s — abandoning it '
                'and falling back to on-device now',
              );
              capture.cancel();
              return null;
            },
          );
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
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (Deepgram capture, unexpected): $e\n$stackTrace');
      _activeDeepgramCapture = null;
      if (!mounted || _commandHandled || !_jobScopeActive) return;
      _voiceLog('unexpected error in the Deepgram capture path — falling back to on-device');
      await _fallBackToOnDeviceCapture();
    }
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
    // Traceable in the log the instant the Deepgram leg gives up, before
    // _reopenListenForCommand's own (async) listen() call even resolves —
    // if this line is missing from a future log, the fallback isn't being
    // reached at all; if it's present but nothing gets captured, the bug
    // is downstream (was: _stage left stale — see _reopenListenForCommand).
    debugPrint('VOICE: Deepgram capture failed — triggering ON-DEVICE FALLBACK capture now');
    _voiceLog('resuming on-device recognition for this command');
    _viaOnDeviceFallback = true;
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
    if (_viaOnDeviceFallback) {
      // Directly answers "did the on-device fallback actually capture
      // anything" from the log, without having to cross-reference this
      // against the earlier "triggering ON-DEVICE FALLBACK capture now"
      // line and _pendingCommandText by hand.
      debugPrint(
        'VOICE: on-device FALLBACK capture ${text.isEmpty ? "FAILED — no words captured" : 'SUCCEEDED — "$text"'}',
      );
    }
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
    // Only reset here if nothing else already moved the phase on: most
    // handlers call speak() before returning (sometimes unawaited — see
    // [speak]'s FIX 3 doc comment), and speak() sets VoicePhase.speaking
    // synchronously before its first `await`, so by the time we get here
    // phase is usually already `speaking` (still playing) or `idle` (already
    // finished) — either way it must NOT be stomped back to `listening`
    // while a spoken response is in flight or has already resolved. Only a
    // handler that never calls speak() at all (e.g. PhotoCaptureScreen's
    // `_capture`, which just navigates) leaves phase sitting at
    // `processing`, and that's the one case this needs to clean up.
    if (mounted && state.phase == VoicePhase.processing) {
      state = state.copyWith(phase: VoicePhase.listening);
    }
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

  /// Makes `_tts.speak()`'s returned Future resolve only once playback has
  /// ACTUALLY finished, instead of `flutter_tts`'s default of resolving as
  /// soon as the text is handed off to the platform TTS engine (i.e. the
  /// synthesis request was accepted, not that audio finished playing out
  /// the speaker). Called once from [initialize].
  ///
  /// BUG FIX (prompt/mic race): without this, `await speak(...)` in
  /// [speak] returned almost immediately while the prompt was still
  /// audible. `job_voice_commands.dart`'s `handleDictationCommand` relies
  /// on `await service.speak(prompt)` genuinely blocking until the prompt
  /// has finished playing before it calls [captureDictation] — without
  /// this configured, the mic started listening while "Go ahead, describe
  /// the work and price" was still playing through the speaker, and the
  /// recognizer picked up the tail of the device's OWN prompt audio as if
  /// it were the technician's answer (confirmed in logs: the captured
  /// transcript exactly matched the tail of the prompt text). See
  /// [captureDictation] for the additional post-completion safety buffer.
  Future<void> _configureTts() async {
    // awaitSpeakCompletion and setSpeechRate are independent platform calls —
    // fire them concurrently. (The technician-chosen TTS voice that used to be
    // applied here was removed along with Voice Settings: spoken output now
    // comes from the Gemini Live pipeline, so this legacy engine just uses the
    // device default voice.)
    final awaitCompletionFuture = () async {
      try {
        await _tts.awaitSpeakCompletion(true);
        debugPrint(
          'VOICE TTS: awaitSpeakCompletion(true) configured — speak() will now wait for real '
          'playback completion, not just hand-off to the platform TTS engine',
        );
      } catch (e, stackTrace) {
        debugPrint('VOICE ERROR (tts configure): $e\n$stackTrace');
      }
    }();

    // Pacing tuned for wake-word/prompt clarity — applies to every speak()
    // call from here on.
    final speechRateFuture = () async {
      try {
        await _tts.setSpeechRate(ttsSpeechRate);
      } catch (e, stackTrace) {
        debugPrint('VOICE ERROR (tts speech rate): $e\n$stackTrace');
      }
    }();

    await Future.wait<void>([awaitCompletionFuture, speechRateFuture]);
  }

  /// Marks a real network/database write as in progress with no mic open —
  /// the same `processing` phase [_dispatchCommand] sets before running a
  /// handler, and [_armDictationSettleTimer] re-sets once dictation capture
  /// ends. Exposed here for handlers in `job_voice_commands.dart` that need
  /// to re-assert it themselves: once a handler has already been through a
  /// [captureConfirmation] (which sets `listening` while the mic is open —
  /// see that method), phase is left at `listening` even after the mic
  /// closes, so a save call made right after (e.g. `insertJobDictation`,
  /// `createChangeOrder`, `markComplete`) would otherwise run with phase
  /// still reading `listening`. Call this right when such a write begins;
  /// it stays `processing` until the handler's own `speak()` call (e.g. "X
  /// saved") takes over.
  void markProcessing() {
    if (mounted) state = state.copyWith(phase: VoicePhase.processing);
  }

  /// FIX (Bluetooth-headset-TTS-ignored bug) — companion to
  /// [_maybeRouteBluetoothSco] (mic input): confirmed via real-device
  /// testing that Bluetooth SCO input works correctly (mic routes through
  /// the headset — `AUDIO ROUTE:` logs `bluetooth_sco_active=true`), but
  /// spoken TTS output was still coming out of the phone's own speaker.
  /// Root cause: Android only pulls audio explicitly tagged
  /// `AudioAttributes.USAGE_VOICE_COMMUNICATION` onto an active SCO link —
  /// ordinary media-style audio (what flutter_tts's engine uses by
  /// default) never follows it, and a mono voice headset like the
  /// BlueParrott has no A2DP sink to fall back onto either, so it was
  /// simply playing out the phone speaker instead. See
  /// `MainActivity.kt`'s `routeTtsAudioTo` doc comment for exactly how
  /// this reaches flutter_tts's engine (Android only) and why
  /// `setAudioAttributesForNavigation()` — flutter_tts's only built-in
  /// Android audio-attributes option — isn't sufficient here.
  ///
  /// Re-checks LIVE audio-route state on every call (reusing
  /// [_logAudioRoute]'s own `getAudioRouteInfo`), rather than trusting
  /// [_bluetoothScoActive], so a headset that disconnects mid-session is
  /// never mistakenly left routed onto the voice-communication audio
  /// path — see [_restoreTtsRouting], always called afterward in
  /// [speak]'s `finally`. Returns whether TTS was actually routed to
  /// Bluetooth SCO, so [speak] knows whether restoring is needed and what
  /// to log.
  Future<bool> _maybeRouteTtsToBluetooth() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final routeInfo = await _audioDiagnosticsChannel.invokeMethod<Map<Object?, Object?>>(
        'getAudioRouteInfo',
      );
      final scoActive = routeInfo?['bluetoothScoActive'] == true;
      if (!scoActive) {
        debugPrint('TTS ROUTE: bluetooth SCO not active — using default (speaker) output');
        return false;
      }
      final routed = await _audioDiagnosticsChannel.invokeMethod<bool>('routeTtsAudioToBluetoothSco') ?? false;
      debugPrint(
        'TTS ROUTE: bluetooth SCO active — routeTtsAudioToBluetoothSco() returned routed=$routed',
      );
      return routed;
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (TTS bluetooth routing): $e\n$stackTrace');
      return false;
    }
  }

  /// Counterpart to [_maybeRouteTtsToBluetooth] — always called from
  /// [speak]'s `finally` when that returned `true`, so flutter_tts's
  /// engine never stays on the voice-communication audio path any longer
  /// than the one utterance that needed it.
  Future<void> _restoreTtsRouting() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final restored = await _audioDiagnosticsChannel.invokeMethod<bool>('restoreTtsAudioRouting') ?? false;
      debugPrint('TTS ROUTE: restoreTtsAudioRouting() returned restored=$restored');
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (TTS bluetooth routing restore): $e\n$stackTrace');
    }
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
  ///
  /// Callers that DO await this (e.g. `handleDictationCommand`'s prompt,
  /// right before [captureDictation]) can now rely on the returned Future
  /// only resolving once playback has genuinely finished — see
  /// [_configureTts].
  Future<void> speak(String text) async {
    _logLatency('spoken-confirmation-started');
    final startedAt = DateTime.now();
    debugPrint('VOICE TTS: playback starting: "$text"');
    // Set synchronously, before the first `await` below, so this lands even
    // when a caller fires this off with `unawaited(speak(...))` instead of
    // awaiting it (see FIX 3 above) — Dart runs an async function's body
    // synchronously up to its first `await`, so the phase flips to
    // `speaking` immediately on call, not on some later microtask.
    if (mounted) state = state.copyWith(phase: VoicePhase.speaking);
    // FIX (Bluetooth-headset-TTS-ignored bug) — route THIS utterance
    // through Bluetooth SCO if it's currently active, before speak()
    // below, and always restore afterward (see _maybeRouteTtsToBluetooth's
    // doc comment).
    final routedToBluetooth = await _maybeRouteTtsToBluetooth();
    try {
      // `awaitSpeakCompletion(true)` (see [_configureTts]) is what makes this
      // resolve only once playback has genuinely finished — relying on that
      // real completion signal here too, not a fixed delay, is what lets the
      // reset below reflect actual playback end. Bounded by
      // [_speakCompletionTimeout] as a safety net for the rare case that
      // signal never arrives (see that constant's doc comment) — without
      // it, a stuck callback here hangs every awaiter chained above this
      // call, including the wake-word loop's own restart.
      await _tts.speak(text).timeout(
        _speakCompletionTimeout,
        onTimeout: () {
          _voiceLog(
            'WARNING: no genuine TTS completion signal within '
            '${_speakCompletionTimeout.inSeconds}s for "$text" — proceeding anyway as a bounded '
            'safety fallback so the wake-word loop is not left stuck silently waiting on it',
          );
        },
      );
      final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
      debugPrint(
        'VOICE TTS: playback completion reported after ${elapsedMs}ms: "$text" '
        '(output_route=${routedToBluetooth ? "bluetooth_sco" : "default"})',
      );
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (speak): $e\n$stackTrace');
    } finally {
      if (routedToBluetooth) {
        await _restoreTtsRouting();
      }
    }
    // Back to the neutral resting state — whatever comes next (a wake-word
    // restart, captureDictation, captureConfirmation, ...) sets `listening`
    // or `processing` itself the moment a real capture session actually
    // starts, so there's no need to guess that here.
    if (mounted) state = state.copyWith(phase: VoicePhase.idle);
  }

  /// Continuous multi-sentence dictation capture — used behind
  /// `prepare_estimate` and `site_condition` (see `job_voice_commands.dart`)
  /// for capturing a whole spoken estimate description or site note
  /// verbatim, as opposed to a short command phrase.
  ///
  /// This reopens the mic across as many native sessions as it takes, the same way
  /// command capture does (see [_reopenListenForCommand]/
  /// [_onSessionResult]): Android can end a session on its own well before
  /// the technician is actually done talking, and only real silence — no
  /// new speech for [_activeDictationSettleWindow] ([_dictationSettleWindow]
  /// by default, 3.5s; shorter for `ask_question` — see [settleWindow]
  /// below), tracked on the app's own clock — is allowed to end the
  /// capture. The transcript returned is
  /// exactly what the recognizer produced, banked verbatim across reopens
  /// with no correction or reformatting (see [_joinCommandParts]) — callers
  /// must not alter it either, per the app's single-verbatim-capture rule.
  ///
  /// Callers are expected to have already spoken their own prompt and
  /// awaited it (see [speak]/[_configureTts]) — this then adds its own
  /// post-prompt safety buffer on top before opening the mic.
  ///
  /// [settleWindow] lets a specific caller override
  /// [_dictationSettleWindow] — currently only [handleAskQuestionCommand]
  /// does, passing [askQuestionSettleWindow]; every other caller omits it
  /// and gets the 3.5s default. [handlerTag] is purely for the debugPrint
  /// below identifying which flow's settle window is in effect.
  Future<String> captureDictation({Duration? settleWindow, String handlerTag = 'dictation'}) async {
    if (!mounted) return '';
    _activeDictationSettleWindow = settleWindow ?? _dictationSettleWindow;
    debugPrint(
      'VOICE: entering dictation-capture mode ("$handlerTag") — settle window = '
      '${_activeDictationSettleWindow.inMilliseconds}ms',
    );
    // CONFIRMED gap (real log evidence, ask_question flow) — this phase
    // flip used to happen AFTER the post-prompt buffer below, which left
    // `phase` sitting at whatever speak() reset it to (`idle`) for the
    // buffer's whole duration: a visible drop-out-and-back-in blip on the
    // full-screen overlay between the prompt finishing (`speaking`) and
    // the mic actually opening (`listening`). Setting `listening` here,
    // before the buffer, makes that transition direct — speaking straight
    // to listening, no idle gap — while the buffer itself is untouched
    // and still fully elapses before the mic opens (see BUG FIX below).
    state = state.copyWith(transcript: '', phase: VoicePhase.listening);
    // BUG FIX (prompt/mic race) — even with speak()'s Future now genuinely
    // waiting for TTS playback completion (see _configureTts), the device
    // speaker can still have a brief residual audio tail/echo bleeding
    // into the microphone right as playback ends. This buffer is on top
    // of, not instead of, that fix.
    debugPrint(
      'VOICE TTS: post-prompt safety buffer — waiting ${_dictationPostPromptBuffer.inMilliseconds}ms '
      'after prompt playback completion before opening the mic (covers speaker/mic echo tail)',
    );
    await Future.delayed(_dictationPostPromptBuffer);
    if (!mounted) return '';
    _stage = _ListenStage.dictation;
    _commandHandled = false;
    _dictationBankedText = '';
    _dictationPendingText = '';
    final completer = Completer<String>();
    _dictationCompleter = completer;
    debugPrint('VOICE: dictation capture started, listening now (buffer elapsed)...');
    debugPrint(
      'VOICE: dictation listen() params: pauseFor=${_dictationNativePauseFor.inSeconds}s '
      'listenFor=${_dictationMaxDuration.inSeconds}s (session should stay open across normal '
      'mid-sentence pauses; settle window ("$handlerTag")=${_activeDictationSettleWindow.inMilliseconds}ms '
      "on the app's own clock is what actually decides the dictation is finished)",
    );
    await _ensureStoppedThenListen(
      onResult: _onDictationResult,
      options: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        listenFor: _dictationMaxDuration,
        pauseFor: _dictationNativePauseFor,
      ),
    );
    final transcript = await completer.future;
    debugPrint('VOICE: dictation transcript finalized: "$transcript"');
    return transcript;
  }

  void _onDictationResult(SpeechRecognitionResult result) {
    // Same defensive wrapping as _onSessionResult — the plugin calls this
    // directly with no try/catch of its own.
    try {
      // FIX 3 (dictation diagnostics) — logs EVERY onResult callback this
      // handler ever receives during dictation mode, partial or final, even
      // an empty one, and BEFORE any of the early-return guards below can
      // discard it. Needed to tell apart, in the log, "genuinely zero audio
      // was ever recognized" (this line never appears at all) from "words
      // were recognized but then lost/overwritten before being saved" (this
      // line shows real words, but a later log line shows them discarded —
      // e.g. the stray-callback guard below, or a reopen that didn't bank
      // them). Without this, both looked identical: an empty final banked
      // transcript.
      debugPrint(
        'VOICE DICTATION: ${result.finalResult ? "final" : "partial"} result received: '
        "'${result.recognizedWords}'",
      );
      if (!mounted || _commandHandled) return;
      // FIX 1 (dictation-mode leak) — THE actual fix. This handler stays
      // bound to whatever native session captureDictation()/
      // _reopenListenForDictation() last opened until the plugin's next
      // listen() call replaces it — but that OLD session isn't guaranteed
      // to be torn down the instant _finishDictationCapture decides (on
      // the app's own clock) that the dictation is done. _startListening
      // resets _commandHandled to false early in its own restart sequence,
      // before the old session's stop is genuinely confirmed (see
      // _ensureStoppedThenListen) — in that gap, a stray callback from the
      // dying dictation session used to still pass the _commandHandled
      // check above and get processed as if it were live dictation input,
      // even though the app had already moved on to wake-word mode. Real
      // logs confirmed this: stray/background audio getting armed on
      // _dictationSettleTimer and finalized as a phantom transcript
      // ("1955") well into what should have been a clean baseline
      // wake-word session. Checking _stage here — the actual flag that
      // says which mode is currently active — closes that gap: a callback
      // arriving after the mode has moved on is simply ignored.
      if (_stage != _ListenStage.dictation) {
        _voiceLog(
          'stray dictation-session callback ignored — current mode is $_stage, not dictation '
          '(words="${result.recognizedWords}")',
        );
        return;
      }
      _dictationPendingText = _joinCommandParts(_dictationBankedText, result.recognizedWords.trim());
      if (mounted) state = state.copyWith(transcript: _dictationPendingText);
      _armDictationSettleTimer();
      // FIX 2 (dictation words lost on restart) — banking now happens
      // unconditionally inside _reopenListenForDictation itself (see its doc
      // comment), not only here on a finalResult, so it also covers the
      // native session ending WITHOUT ever producing one (_onStatus calling
      // _reopenListenForDictation directly). Still trigger the reopen here
      // on finalResult so a session that DOES finalize doesn't just sit idle
      // waiting for _onStatus.
      if (result.finalResult) {
        unawaited(_reopenListenForDictation());
      }
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (_onDictationResult) [session=$_sessionId]: $e\n$stackTrace');
    }
  }

  /// (Re)starts the [_activeDictationSettleWindow] countdown — called on
  /// every new bit of speech heard during dictation capture. Only fires
  /// [_finishDictationCapture] if nothing new arrives for the whole window,
  /// i.e. a rolling debounce, not a one-shot timer from the first word.
  /// Uses [_activeDictationSettleWindow] (set once per [captureDictation]
  /// call), NOT the [_dictationSettleWindow] default directly, so a
  /// per-handler override stays in effect across every rearm of the whole
  /// capture, not just its first pause.
  void _armDictationSettleTimer() {
    _dictationSettleTimer?.cancel();
    _dictationSettleTimer = Timer(_activeDictationSettleWindow, () {
      _voiceLog(
        'dictation settle window (${_activeDictationSettleWindow.inMilliseconds}ms) elapsed with no new '
        'speech, finalizing "$_dictationPendingText"',
      );
      // This is the genuine end of mic capture — the settle window (above)
      // is what actually decided the technician is done talking, not a
      // forced teardown/error path (see the other _finishDictationCapture
      // call sites, which pass '' and are already tearing the session down,
      // not about to make a backend call). From here the caller is about to
      // parse/send the transcript, so phase stays `processing` — matching
      // the _dispatchCommand/handler pattern — until speak() takes over.
      if (mounted) state = state.copyWith(phase: VoicePhase.processing);
      _finishDictationCapture(_dictationPendingText);
    });
  }

  void _cancelDictationSettleTimer() {
    _dictationSettleTimer?.cancel();
    _dictationSettleTimer = null;
  }

  /// Reopens the mic mid-dictation after the native session ended on its
  /// own before [_dictationSettleTimer] fired — invisible to the
  /// technician, same as [_reopenListenForCommand] for ordinary commands.
  ///
  /// FIX 2 (dictation words lost on restart) — this is the ONE place a
  /// dictation reopen actually happens (called both from [_onDictationResult]
  /// on a `finalResult` and directly from [_onStatus] when a native session
  /// ends WITHOUT ever producing one), so it's the right choke point to bank
  /// whatever is currently in [_dictationPendingText] — including words that
  /// only ever arrived as partial results — into [_dictationBankedText]
  /// before the old session's transcript is abandoned and a fresh one
  /// starts accumulating from empty again. Previously banking only happened
  /// on a `finalResult`; a session that ended on the native side (status
  /// done/notListening) without ever finalizing silently dropped every
  /// partial word it had captured the instant the next session's first
  /// partial result overwrote [_dictationPendingText] against the stale
  /// (unbanked) [_dictationBankedText] — the mechanism behind "13 restart
  /// cycles, banked stayed empty" even while the technician kept talking.
  Future<void> _reopenListenForDictation() async {
    if (!mounted ||
        state.muted ||
        !state.available ||
        _commandHandled ||
        _stage != _ListenStage.dictation) {
      return;
    }
    if (_dictationPendingText.isNotEmpty &&
        _dictationPendingText != _dictationBankedText) {
      _voiceLog(
        'banking dictation words before reopening (previously banked="$_dictationBankedText", '
        'now banking="$_dictationPendingText")',
      );
      _dictationBankedText = _dictationPendingText;
    }
    _voiceLog(
      'dictation native session ended before settle window elapsed — reopening mic '
      '(banked="$_dictationBankedText", pauseFor=${_dictationNativePauseFor.inSeconds}s '
      'listenFor=${_dictationMaxDuration.inSeconds}s)',
    );
    await _ensureStoppedThenListen(
      onResult: _onDictationResult,
      options: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        listenFor: _dictationMaxDuration,
        pauseFor: _dictationNativePauseFor,
      ),
    );
  }

  void _finishDictationCapture(String text) {
    if (_commandHandled) return;
    _commandHandled = true;
    _cancelDictationSettleTimer();
    _stage = _ListenStage.idle;
    final completer = _dictationCompleter;
    _dictationCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete(text.trim());
  }

  /// FIX 2 — words/phrases this app recognizes as an explicit "yes, save
  /// it" or "no, discard it" reply to a dictation readback (see
  /// [captureConfirmation]). Deliberately matched as whole words/phrases
  /// (not a plain substring check like [_matchWakeWord]) — a bare
  /// substring check on something as short as "no" risks matching inside
  /// an unrelated word the recognizer mishears, which would be exactly the
  /// kind of silent misfire this whole confirm/redo step exists to
  /// prevent.
  // "That's right" deliberately matched as a whole PHRASE (not split into
  // individual words — "that's"/"right" alone are too generic/risky to
  // treat as standalone confirm words) alongside the existing single-word
  // set.
  static const Set<String> _confirmPhrases = {'confirm', 'yes', 'correct', 'yep', 'yeah'};
  static const Set<String> _confirmMultiWordPhrases = {"that's right", 'thats right'};
  static const Set<String> _redoPhrases = {'redo', 'no', 'nope', 'wrong', 'cancel'};
  static const Set<String> _redoMultiWordPhrases = {'try again', 'do it again', 'start over'};

  /// Interprets a captured confirm/redo reply. Returns `true` only for an
  /// unambiguous affirmative match, `false` for an unambiguous negative
  /// match, `null` if the reply doesn't clearly match either — callers
  /// must treat `null` as "ask again" (see [captureConfirmation]), NEVER
  /// as an implicit yes or no. Every branch logs the exact keyword/phrase
  /// that decided the outcome (or that nothing matched at all), so a log
  /// reader never has to guess why an outcome was reached.
  bool? _matchConfirmationPhrase(String rawText) {
    final lower = rawText.trim().toLowerCase();
    if (lower.isEmpty) {
      debugPrint('VOICE: confirmation phrase match — no match found (empty/silent input)');
      return null;
    }
    for (final phrase in _confirmMultiWordPhrases) {
      if (lower.contains(phrase)) {
        debugPrint('VOICE: confirmation phrase match — matched CONFIRM phrase "$phrase"');
        return true;
      }
    }
    for (final phrase in _redoMultiWordPhrases) {
      if (lower.contains(phrase)) {
        debugPrint('VOICE: confirmation phrase match — matched REDO phrase "$phrase"');
        return false;
      }
    }
    final words = lower.split(RegExp(r'\s+'));
    for (final word in words) {
      if (_confirmPhrases.contains(word)) {
        debugPrint('VOICE: confirmation phrase match — matched CONFIRM keyword "$word"');
        return true;
      }
      if (_redoPhrases.contains(word)) {
        debugPrint('VOICE: confirmation phrase match — matched REDO keyword "$word"');
        return false;
      }
    }
    debugPrint('VOICE: confirmation phrase match — no match found in "$rawText"');
    return null;
  }

  /// FIX 2 (transcription-error safety net) — after a dictation transcript
  /// is captured, this reads it back (see `handleDictationCommand`, which
  /// speaks the full transcript + prompt before calling this) and waits
  /// for an explicit spoken "confirm"/"redo"-style reply, OR the matching
  /// on-screen tap (see [submitConfirmationTap] and
  /// `DictationConfirmationBar`) — whichever comes first. A real
  /// transcription error motivated this: "two hours labor at one hundred
  /// fifty dollars an hour" was captured as "to our labour at 10050 per
  /// hour" and would have been saved as-is with no chance to catch it.
  ///
  /// Returns [ConfirmationOutcome.confirmed] ONLY on an unambiguous
  /// affirmative match. [ConfirmationOutcome.redo] means the technician
  /// EXPLICITLY said/tapped a negative word — callers keep treating this
  /// however they already do (e.g. `handleChangeOrderCommand`/
  /// `handleDictationCommand` silently re-prompt from scratch;
  /// `_handleJobComplete` stops outright, since an explicit "cancel" there
  /// must never be treated as "try again"). [ConfirmationOutcome.unclear]
  /// means [_maxConfirmationAttempts] silent/unrecognized replies were
  /// exhausted WITHOUT a clear answer either way — this is deliberately a
  /// third, distinct outcome, not folded into `redo`: it is never the
  /// technician's real choice, so by the time this returns it has already
  /// spoken an explicit "let's try again from the start" — callers must
  /// restart their whole flow from the beginning on `unclear` (not just
  /// silently re-prompt the same confirm step), and must NEVER treat it as
  /// an implicit confirm.
  ///
  /// FIX (premature redo default) — this used to allow 3 attempts but with
  /// only a 1200ms silence tolerance per attempt (see
  /// [_confirmationSettleWindow]'s doc comment for the full bug), so all 3
  /// could burn through in a few seconds flat, discarding a perfectly good
  /// dictation before the technician had even started answering. Now: at
  /// most [_maxConfirmationAttempts] (2) attempts, each with a real ~6s
  /// silence tolerance, and only the SECOND unclear/silent attempt in a
  /// row resolves to [ConfirmationOutcome.unclear] — the first gets an
  /// explicit re-prompt instead.
  ///
  /// [transcriptForDisplay] is stored on [GlobalVoiceState.
  /// pendingConfirmationTranscript] purely for the on-screen tap fallback
  /// to show what's being confirmed — this method does not speak it
  /// itself (the caller already did, as part of its own prompt).
  static const int _maxConfirmationAttempts = 2;

  Future<ConfirmationOutcome> captureConfirmation({required String transcriptForDisplay}) async {
    // Not `.unclear` here: an unmounted service has nothing left to restart
    // — this is "give up entirely," the same as an explicit redo/cancel.
    if (!mounted) return ConfirmationOutcome.redo;
    state = state.copyWith(pendingConfirmationTranscript: transcriptForDisplay);
    try {
      for (var attempt = 1; attempt <= _maxConfirmationAttempts; attempt++) {
        // The mic is genuinely open and listening for "confirm"/"redo" here
        // — same as the original question/dictation capture — so this is
        // `listening`, not `processing`. `processing` is reserved for spans
        // with no mic open at all (a backend call, a handler doing work).
        if (mounted) state = state.copyWith(phase: VoicePhase.listening);
        final raw = await _captureConfirmationAttempt();
        final outcome = _matchConfirmationPhrase(raw);
        final heardNothing = raw.trim().isEmpty;
        debugPrint(
          'VOICE: confirmation attempt $attempt/$_maxConfirmationAttempts raw="$raw" outcome='
          '${outcome == null ? (heardNothing ? "SILENCE (no reply heard)" : "UNCLEAR SPEECH") : (outcome ? "CONFIRM" : "REDO")}',
        );
        if (outcome != null) {
          if (outcome) {
            debugPrint('VOICE: confirmation resolved CONFIRM — unambiguous affirmative match');
            return ConfirmationOutcome.confirmed;
          }
          debugPrint(
            'VOICE: confirmation resolved REDO — technician explicitly said/tapped redo/cancel '
            '(not a timeout default)',
          );
          return ConfirmationOutcome.redo;
        }
        if (attempt < _maxConfirmationAttempts && mounted) {
          final reprompt = heardNothing
              ? "I didn't hear you — say confirm to save, or redo to try again."
              : "Sorry, I didn't catch that — say confirm to save, or redo to try again.";
          await speak(reprompt);
        }
      }
      debugPrint(
        'VOICE: confirmation resolved UNCLEAR — exhausted $_maxConfirmationAttempts unclear/silent '
        'attempts, NOT a real user choice (never defaulting to confirm OR redo on ambiguous input — '
        'restarting the whole flow instead)',
      );
      if (mounted) {
        await speak("I still didn't catch that — let's try again from the start.");
      }
      return ConfirmationOutcome.unclear;
    } finally {
      if (mounted) {
        state = state.copyWith(clearPendingConfirmationTranscript: true);
      }
    }
  }

  Future<String> _captureConfirmationAttempt() async {
    if (!mounted) return '';
    // BUG FIX (retry-prompt/mic race) — see _confirmationPostPromptBuffer's
    // doc comment. This runs for every attempt, not just the first: the
    // caller's initial prompt (before ever calling captureConfirmation) and
    // this loop's own retry re-prompt (see captureConfirmation, right
    // before it loops back here) both finish with `await speak(...)`, so
    // this buffer belongs here, once, rather than duplicated at every call
    // site.
    debugPrint(
      'VOICE TTS: post-prompt safety buffer — waiting ${_confirmationPostPromptBuffer.inMilliseconds}ms '
      'after prompt playback completion before opening the mic (covers speaker/mic echo tail)',
    );
    await Future.delayed(_confirmationPostPromptBuffer);
    if (!mounted) return '';
    _stage = _ListenStage.confirmation;
    _commandHandled = false;
    _confirmationBankedText = '';
    _confirmationPendingText = '';
    final completer = Completer<String>();
    _confirmationCompleter = completer;
    debugPrint(
      'VOICE: confirmation listen() params: pauseFor=${_confirmationNativePauseFor.inSeconds}s '
      'listenFor=${_confirmationMaxDuration.inSeconds}s '
      'silenceTolerance=${_confirmationSettleWindow.inSeconds}s mode=$_stage',
    );
    await _ensureStoppedThenListen(
      onResult: _onConfirmationResult,
      options: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        listenFor: _confirmationMaxDuration,
        pauseFor: _confirmationNativePauseFor,
      ),
    );
    // FIX (premature redo default) — armed here too, not only inside
    // _onConfirmationResult: Android's on-device recognizer never fires
    // onResult during pure silence (see _confirmationSettleWindow's doc
    // comment), so a technician who hasn't started responding yet would
    // otherwise produce zero callbacks and this attempt would just keep
    // reopening on _confirmationNativePauseFor's floor forever, never
    // reaching the "unclear, try again" re-prompt at all. Starting the
    // timer the moment listening actually begins guarantees a bounded,
    // real silence-tolerance window regardless of whether any callback
    // ever lands; _onConfirmationResult re-arms (not re-starts) this same
    // timer the instant real speech does come in, so it never cuts off an
    // answer that's actually in progress.
    if (mounted && _stage == _ListenStage.confirmation) {
      _armConfirmationSettleTimer();
    }
    return completer.future;
  }

  void _onConfirmationResult(SpeechRecognitionResult result) {
    // Same defensive wrapping as _onSessionResult/_onDictationResult.
    try {
      if (!mounted || _commandHandled) return;
      // FIX 1's guard, applied here too — see _onDictationResult's doc
      // comment for the full reasoning. A stray callback from an old,
      // not-yet-torn-down confirmation session must never be processed
      // once the mode has moved on.
      if (_stage != _ListenStage.confirmation) {
        _voiceLog(
          'stray confirmation-session callback ignored — current mode is $_stage, not confirmation '
          '(words="${result.recognizedWords}")',
        );
        return;
      }
      _confirmationPendingText = _joinCommandParts(
        _confirmationBankedText,
        result.recognizedWords.trim(),
      );
      if (mounted) state = state.copyWith(transcript: _confirmationPendingText);
      _armConfirmationSettleTimer();
      if (result.finalResult) {
        _confirmationBankedText = _confirmationPendingText;
        unawaited(_reopenListenForConfirmation());
      }
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (_onConfirmationResult) [session=$_sessionId]: $e\n$stackTrace');
    }
  }

  void _armConfirmationSettleTimer() {
    _confirmationSettleTimer?.cancel();
    _confirmationSettleTimer = Timer(_confirmationSettleWindow, () {
      _voiceLog(
        'confirmation settle window (${_confirmationSettleWindow.inMilliseconds}ms) elapsed with no '
        'new speech, finalizing "$_confirmationPendingText"',
      );
      _finishConfirmationCapture(_confirmationPendingText);
    });
  }

  void _cancelConfirmationSettleTimer() {
    _confirmationSettleTimer?.cancel();
    _confirmationSettleTimer = null;
  }

  /// Reopens the mic mid-confirmation-reply after the native session ended
  /// on its own before [_confirmationSettleTimer] fired — same pattern as
  /// [_reopenListenForDictation].
  Future<void> _reopenListenForConfirmation() async {
    if (!mounted ||
        state.muted ||
        !state.available ||
        _commandHandled ||
        _stage != _ListenStage.confirmation) {
      return;
    }
    _voiceLog(
      'confirmation native session ended before settle window elapsed — reopening mic '
      '(banked="$_confirmationPendingText", pauseFor=${_confirmationNativePauseFor.inSeconds}s '
      'listenFor=${_confirmationMaxDuration.inSeconds}s)',
    );
    await _ensureStoppedThenListen(
      onResult: _onConfirmationResult,
      options: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        listenFor: _confirmationMaxDuration,
        pauseFor: _confirmationNativePauseFor,
      ),
    );
  }

  void _finishConfirmationCapture(String text) {
    if (_commandHandled) return;
    _commandHandled = true;
    _cancelConfirmationSettleTimer();
    _stage = _ListenStage.idle;
    final completer = _confirmationCompleter;
    _confirmationCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete(text.trim());
  }

  /// FIX 2 — on-screen tap fallback for the confirm/redo step (see
  /// `DictationConfirmationBar`), same fallback principle as every other
  /// voice command in this app: feeds the literal keyword through the
  /// exact same [_matchConfirmationPhrase] path a spoken reply would, so
  /// tap and voice are never two different implementations of "confirm."
  /// A no-op (logged, not silently ignored) if no confirmation capture is
  /// currently in progress — e.g. the technician tapped after it already
  /// resolved some other way.
  void submitConfirmationTap(bool confirmed) {
    if (_stage != _ListenStage.confirmation) {
      debugPrint(
        'VOICE: submitConfirmationTap($confirmed) ignored — no confirmation capture in '
        'progress (mode=$_stage)',
      );
      return;
    }
    debugPrint(
      'VOICE: confirmation resolved via TAP fallback -> ${confirmed ? "CONFIRM" : "REDO"}',
    );
    _finishConfirmationCapture(confirmed ? 'confirm' : 'redo');
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
    _geminiTokens.deactivate();
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
    unawaited(_stopBluetoothScoIfActive('dispose'));
    _cancelDictationSettleTimer();
    _finishDictationCapture('');
    _cancelConfirmationSettleTimer();
    _finishConfirmationCapture('');
    super.dispose();
  }
}
