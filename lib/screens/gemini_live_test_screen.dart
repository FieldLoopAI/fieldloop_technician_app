import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show FrameTiming;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/env.dart';
import '../models/kept_photo_ref.dart';
import '../providers/global_voice_service_provider.dart';
import '../providers/job_photos_provider.dart';
import '../providers/offline_upload_queue_provider.dart';
import '../providers/safe_ref_disposal.dart';
import '../providers/voice_command_registry_provider.dart';
import '../routing/app_navigator_key.dart';
import '../routing/job_detail_route.dart';
import '../services/command_intent_matcher.dart';
import '../services/completion_claim_detector.dart';
import '../services/continuation_answer.dart';
import '../services/conversational_utterance.dart';
import '../services/echo_override_policy.dart';
import '../services/echo_sequence_matcher.dart';
import '../services/gemini_function_dispatcher.dart';
import '../services/navigation_destination.dart';
import '../services/pending_call_fillers.dart';
import '../services/photo_decision_classifier.dart';
import '../services/photo_note_classifier.dart';
import '../services/question_announcement.dart';
import '../services/transliterated_greeting.dart';
import '../services/voice_session_power.dart';
import '../services/trigger_phrase_matcher.dart';
import '../services/wake_greeting_clip.dart';
import '../theme/app_theme.dart';
import '../widgets/voice_phase_indicator.dart';
import 'voice_command_registrar_mixin.dart';

/// STANDALONE Day-1 connectivity proof for the Gemini Live API. Deliberately
/// self-contained — its own `FlutterSoundRecorder`/`WebSocketChannel`/
/// `FlutterPcmSound` stream, no shared state with `GlobalVoiceService` or any
/// other existing voice code, and reachable only via the temporary debug
/// entry point on [ProfileScreen]. Not wired into the real job flow.
///
/// Mic capture uses `flutter_sound` rather than `record` — swapped after
/// `record_android` hit an unresolved Kotlin compile error and was removed
/// from the project entirely (see pubspec.yaml). This only changes where
/// the raw PCM16 mic bytes come from; everything downstream (base64
/// encoding, the `realtimeInput` message shape, and the WebSocket itself)
/// is untouched.
///
/// Response playback uses `flutter_pcm_sound` (continuous raw PCM16
/// streaming) rather than `just_audio`'s `ConcatenatingAudioSource` —
/// swapped after the latter's per-chunk "track" boundaries produced an
/// audible gap at every response chunk (arriving every 10-90ms), heard as
/// stuttering/repeated-sounding speech. See `_onResponseAudioChunk` and the
/// `_outgoingAudioPaused`/`_maybeResumeOutgoingAudio` doc comments below.
///
/// The backend (`backend/functions/get-gemini-token`) mints a short-lived,
/// single-use ephemeral token via `authTokens.create()` — the raw, permanent
/// Gemini API key never leaves the Lambda. This screen connects using the
/// ephemeral-token WebSocket form (`BidiGenerateContentConstrained` +
/// `?access_token=`) — see [_geminiLiveUri].
///
/// Endpoint / message-format notes (verified against the current official
/// docs at https://ai.google.dev/api/live and
/// https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens as of
/// 2026-09-07 — see the two divergences from the original ticket flagged
/// below):
///
/// 1. WebSocket path: the ticket assumed `v1alpha` +
///    `GenerativeService.BidiGenerateContent?key=<token>`. Current docs put
///    the plain-key service on `v1beta`, but since our backend
///    (`backend/functions/get-gemini-token`) mints a short-lived *ephemeral*
///    auth token (via `POST v1alpha/authTokens`), not a raw API key, this
///    file uses the ephemeral-token method/path instead: `v1alpha` +
///    `GenerativeService.BidiGenerateContentConstrained?access_token=`; see
///    [_geminiLiveUri].
/// 2. Model id: the ticket said `gemini-2.5-flash-live-preview` (not 3.1).
///    That exact id does not appear in the current public models list
///    (which lists `gemini-3.1-flash-live-preview` and
///    `gemini-2.5-flash-native-audio-preview-12-2025` for the 2.5
///    generation), and in practice returned API key rejection errors,
///    root-caused to model deprecation via a 404 on the equivalent text
///    model. Switched to `gemini-3.1-flash-live-preview` on 2026-09-07 —
///    see the dated note on [_geminiModel] for why, and for the Day 2
///    function-calling caveat that comes with it.
class GeminiLiveTestScreen extends ConsumerStatefulWidget {
  const GeminiLiveTestScreen({
    super.key,
    this.jobId,
    this.ambient = false,
    this.onAmbientSessionEnded,
    this.tokenFuture,
    this.wakeDetectedAt,
    this.wakeGreeting,
    this.endRequest,
  });

  /// When the wake word that started this session was recognized — the
  /// reference point for the `VOICE LATENCY: wake-to-session-live` and
  /// `WAKE GREETING` log lines. Null for the manual entry points.
  final DateTime? wakeDetectedAt;

  /// The saved greeting clip [GlobalVoiceService._triggerGeminiSession]
  /// started playing the instant the wake word was heard (see
  /// `wake_greeting_clip.dart`). While it's in play, mic audio passes
  /// through [_GeminiLiveTestScreenState._greetingMicGate]. Null when no
  /// clip was started — the session then greets exactly as before.
  final WakeGreetingPlayback? wakeGreeting;

  /// Set (to a reason) by `GlobalVoiceService` when this session must end
  /// from OUTSIDE the conversation — the technician left the job (see
  /// `GlobalVoiceService.exitJobScope`). The session is closed on the spot:
  /// no further mic audio sent, no transcript processed, no reply spoken
  /// (see `_GeminiLiveTestScreenState._endForJobScopeExit`).
  final ValueListenable<String?>? endRequest;

  /// The Gemini token for this screen's FIRST session, already requested by
  /// the caller — [GlobalVoiceService._triggerGeminiSession] claims it the
  /// instant the wake word is heard (usually the pre-fetched spare), before
  /// the wake-word recognizer has even released the mic. Null (the manual
  /// entry points) or any later session: taken from the same cache at
  /// start time instead. Tokens are single-use, so this is never reused.
  final Future<String>? tokenFuture;

  /// When given, every dispatched function call gets its `job_id` argument
  /// forced to this value (see `_GeminiLiveTestScreenState._handleToolCall`)
  /// rather than trusting Gemini to have correctly said/inferred it —
  /// there's no reliable way to voice-dictate a UUID, and the app already
  /// knows exactly which job is open, so it's supplied directly instead of
  /// relying on the model.
  ///
  /// `null` preserves this screen's original STANDALONE Day-1/2
  /// connectivity-and-function-calling test behavior exactly — reachable
  /// only via the temporary debug entry point on [ProfileScreen], still
  /// with no job context and no `job_id` override.
  final String? jobId;

  /// True ONLY when pushed by [GlobalVoiceService._triggerGeminiSession]
  /// (the wake-word/"Loop On" trigger) — Gemini Live is now the app's
  /// single, permanent voice system, not a parallel beta mode, so THIS is
  /// the normal, everyday way this screen gets reached. `ambient` mode:
  /// auto-starts the session immediately (no manual Start tap), hides the
  /// debug-only Start/Stop buttons and raw scrollback log, and pops itself
  /// automatically the instant the session ends (Loop Off, "FieldLoop
  /// stop", or a timeout — see the `end_session` tool declaration and
  /// [_GeminiLiveTestScreenState._handleToolCall]) — so it reads as one
  /// continuous experience, not a separate app section.
  ///
  /// Inserted via a raw [OverlayEntry] (see `_triggerGeminiSession`'s doc
  /// comment) — NOT pushed as a `Navigator` route, even a non-opaque one.
  /// CONFIRMED on a real device: a `PageRouteBuilder(opaque: false)` route
  /// does NOT reliably let touches (scrolling, button taps) pass through to
  /// the route underneath, regardless of what its own content paints —
  /// `Navigator`/`ModalRoute` machinery apparently insulates the current
  /// route's input from whatever's behind it in ways an "opaque: false"
  /// flag alone doesn't undo. A plain [OverlayEntry], inserted directly
  /// into the root `Navigator`'s own [Overlay] the exact same way
  /// [VoiceInteractionOverlay]/`DictationConfirmationBar` already do at the
  /// `MaterialApp.builder` level, has no such wrapping — hit-testing is
  /// plain [Stack]-style cascading, so a region this screen's own body
  /// doesn't paint anything into genuinely falls through to whatever's
  /// underneath. This screen's own body (`_buildAmbientPureConversationUi`)
  /// stays almost entirely unpainted for as long as no function call has
  /// navigated to real screen content — so for ordinary listening/
  /// thinking/speaking, the technician sees and can interact with whatever
  /// real screen was open when the wake word was heard, with only a small
  /// corner [VoicePhaseIndicator] cluster on top of it. The moment a
  /// function call navigates somewhere real (the camera, `view_estimate`,
  /// ...), this screen (or the pushed destination) becomes fully opaque
  /// again for that step — see [_ScreenTask].
  ///
  /// `false` (the default) is used by the two remaining manual entry
  /// points — the standalone Profile debug screen and the "Voice
  /// Assistant" tap-fallback button on Job Detail — which both keep the
  /// original manual/debug UI (tap Start, watch the log, tap Stop), pushed
  /// as a normal opaque `Navigator` route exactly as before (a real route
  /// is exactly what's wanted there — those ARE meant to fully take over
  /// the screen); this is a genuinely different flag from [jobId] (the
  /// tap-fallback button also passes a `jobId`, but never `ambient`).
  final bool ambient;

  /// Called exactly once, when an `ambient: true` session ends (Loop Off,
  /// "FieldLoop stop", a timeout, or the corner cluster's own close
  /// button — see [_GeminiLiveTestScreenState._stopTest]) — removes the
  /// [OverlayEntry] this screen was inserted into (see
  /// `GlobalVoiceService._triggerGeminiSession`), which is what actually
  /// unmounts this widget (and therefore runs [_GeminiLiveTestScreenState.
  /// dispose]/`_teardown`) for the ambient case, replacing the
  /// `Navigator.pop()` this screen used back when it was pushed as a route.
  /// `null` for the two manual/debug entry points, which are still pushed
  /// as normal routes and pop normally via `Navigator.of(context).maybePop()`.
  final VoidCallback? onAmbientSessionEnded;

  @override
  ConsumerState<GeminiLiveTestScreen> createState() => _GeminiLiveTestScreenState();
}

enum _TestPhase { idle, requestingToken, connecting, connected, closed, error }

/// What real, function-call-triggered screen content (if any) the ambient
/// UI should show right now, in place of the pure-conversation voice
/// visual â€” see [_GeminiLiveTestScreenState._buildAmbientUi] and the
/// `screenTaskActive` updates in [_GeminiLiveTestScreenState._handleToolCall].
/// Currently only the camera flow drives this (the only tool group with a
/// real screen behind it â€” see `GeminiCameraSession`); a future screen-
/// visible tool group would add its own case here rather than overload
/// this one.
enum _ScreenTask {
  /// Nothing to show â€” pure conversation, full-screen voice UI is correct.
  none,

  /// `open_camera` (or `retake_photo`, which returns to the live view)
  /// succeeded â€” the live camera preview is the real content to show.
  cameraLive,

  /// `capture_photo` succeeded â€” the just-captured still is the real
  /// content to show, awaiting confirm/retake.
  cameraCaptured,

  /// P2: an `open_camera` has genuinely STARTED but the controller hasn't
  /// reported ready yet. Previously this whole window — measured at 9-30s
  /// on real hardware — was [none], i.e. the technician stared at the
  /// unchanged screen behind the ambient overlay with no indication
  /// anything was happening, then a camera appeared. That reads as broken
  /// regardless of the eventual frame rate (which measures a healthy
  /// ~50-57fps once live).
  ///
  /// Shows a real "opening the camera" surface, and is replaced by
  /// [cameraLive] the INSTANT a preview texture exists — see
  /// `GeminiCameraSession.onPreviewAvailable`, which fires before the
  /// dispatch even returns. Deliberately a SEPARATE state from
  /// [cameraLive] rather than an early flip to it: every capture guard in
  /// this file keys off [cameraLive] meaning "the camera is genuinely
  /// open", and the VIEW is what this unblocks early, never the ACTION.
  cameraOpening,

  /// A close has been requested (go_back out of the camera flow) and the
  /// native camera is still being released. Set the INSTANT the close is
  /// triggered — before the async release is awaited — and moved to [none]
  /// only once that release actually resolves. Without it the screen kept
  /// showing the live preview (still `cameraLive`) for the whole multi-
  /// second release and then cut abruptly to nothing, and backing out looked
  /// no different from a frozen camera. Has its own "Closing the camera…"
  /// surface, distinct from [cameraOpening]'s, so leaving never looks like
  /// opening. No camera action is allowed in this state: every capture
  /// guard keys off [cameraLive], and open_camera's guard requires [none].
  cameraClosing,
}

/// Who cancelled a slow camera open — decides what (if anything) is said
/// and where the screen goes. See `_updateScreenTaskForToolCall`'s
/// `cancelled` branch.
enum _CameraOpenCancelIntent { user, retry, goBack }

/// Caption escalation on the "Opening the camera…" surface — normal opens
/// finish well inside this.
const Duration _cameraOpenSlowCaptionAfter = Duration(seconds: 4);

const int _inputSampleRateHz = 16000;
const int _outputSampleRateHz = 24000;

/// Model updated 2026-09-07 after gemini-2.5-flash-live-preview was found to
/// return API key rejection errors, root-caused to model deprecation via a
/// 404 on the equivalent text model. NOTE: this is gemini-3.1, which the
/// original test plan flagged as having a function-calling freeze bug - safe
/// for Day 1 bare connectivity testing (no functions wired yet), but must be
/// re-evaluated before Day 2's function-calling work begins.
const String _geminiModel = 'gemini-3.1-flash-live-preview';

/// Server-side context sliding window (setup's `contextWindowCompression`):
/// once the session context reaches [_contextCompressionTriggerTokens], the
/// server drops the oldest turns back down to about
/// [_contextCompressionTargetTokens]; the system instruction and tools are
/// never trimmed. Production values since the earlier compression test —
/// tune here. Every turn's size against these is logged as `CONTEXT
/// REFRESH` (see `_GeminiLiveTestScreenState._logContextSize`).
const int _contextCompressionTriggerTokens = 6000;
const int _contextCompressionTargetTokens = 3000;

/// PART F item 1: the prebuilt Live voice to request via `speechConfig`
/// in the setup message (see `_startTest`) — swap this one constant to
/// try 'Kore'/'Leda' as alternates if 'Aoede' doesn't sound right on a
/// real listen test; every other prebuilt-voice plumbing stays the same.
const String _geminiVoiceName = 'Aoede';

const String _systemInstruction =
    "You are FieldLoop's hands-free voice assistant for ONE specific job - the job currently open on screen. "
    'You exist to help a field technician work entirely by voice while their hands are busy. You are not a '
    'general-purpose assistant - never offer generic help like brainstorming, writing, or answering unrelated '
    'questions. '
    'Your real capabilities, and ONLY these: answering questions about THIS job\'s details (customer, '
    'address, description, status) using get_job_details; answering questions about what\'s happened on this '
    'job (arrival time, photos taken, timeline) using get_job_timeline_answer; showing the most recent photo '
    'taken on this job using get_last_photo; answering trade/technical questions ONLY from the knowledge base '
    "using get_kb_answer - if it returns no match, say plainly you don't have that information, never guess "
    'or use general knowledge; navigating to screens the technician asks for - the estimate (view_estimate), '
    'change orders (view_change_orders), invoice (view_invoice), job history (view_job_history), or back to '
    'the main job screen (go_back); telling the technician which screen they\'re currently on if asked, using '
    'get_current_screen; taking photos - opening the camera (open_camera), capturing (capture_photo), and '
    'either uploading (confirm_photo_upload) or retaking (retake_photo) based on what the technician says '
    'after seeing the preview; and logging a quick site observation (site_condition). '
    'If asked what you can help with, describe THESE real capabilities specifically, in plain terms - never a '
    'generic answer about general assistance. If asked to do anything outside this list (drafting an '
    "estimate's actual pricing via voice, voiding something, generating an invoice, anything financial), "
    'explain that specific action needs the on-screen buttons, and offer to navigate there instead. '
    'CRITICAL: whenever the technician expresses intent to do something one of your available functions '
    'performs, you MUST actually call that function. Never just say you will do it, or describe doing it in '
    'words, without a real function call — a spoken acknowledgment ("sure, taking a photo now") is NOT a '
    'substitute for invoking the tool, and the action has NOT happened until the function is called. Only '
    "respond conversationally with no function call for genuine small talk or clarifying questions that don't "
    'map to any available function. '
    "For any question about THIS job's own details, use get_job_details or get_job_timeline_answer - NEVER "
    "use get_kb_answer for these, since that tool is only for general trade knowledge, not this specific "
    'job\'s data. When get_job_details returns, speak its "summary" field naturally in your own words - never '
    'read out a job id, database field name, or any other raw/technical value out loud. '
    'When get_kb_answer returns, speak its "answer" field exactly as returned, word for word — that answer is '
    'already vetted (including the "not in the knowledge base" decline, when it applies) and must never be '
    'paraphrased, shortened, second-guessed, or supplemented with anything from your own general knowledge. '
    'When a technician wants to take a photo, call open_camera, then ask if they\'re ready before calling '
    'capture_photo. After capturing, ask whether to upload or retake before calling confirm_photo_upload or '
    'retake_photo accordingly. Never skip the confirmation step. '
    // P0 TRUST FIX — see [photoCompletionClaimPhrases]'s doc comment for
    // the confirmed bug (two false "it's captured"/"both taken" claims in
    // one session with zero real captures). Stated as a vocabulary ban
    // rather than a behavioral request, because "only say it when it's
    // true" leaves the model to judge what's true from conversational
    // memory — which is exactly the faculty that produced the lie. The app
    // speaks every genuine completion itself, word for word, through a
    // constrained instruction issued only after the real function
    // returned success, so there is nothing for the free-text path to add.
    'ABSOLUTE RULE — NEVER CLAIM A PHOTO ACTION HAPPENED. You are forbidden from saying, in your own words, '
    'that a photo has been captured, taken, snapped, uploaded, saved, attached, kept, retaken, or discarded. '
    'Those words describe completed actions, and you are never the component that knows whether one '
    'completed. The app tells you, word for word, exactly what to say whenever a photo action genuinely '
    'succeeds; if you have not just been given such a script to read, then as far as you are concerned '
    'nothing has happened yet, no matter what the conversation seems to imply. Never say "it\'s captured", '
    '"both taken", "I\'ve uploaded it", "that\'s saved", or anything with the same meaning on your own '
    'initiative. If the technician asks whether a photo was taken or uploaded, do not answer from memory — '
    'say you\'ll check, and call get_job_timeline_answer or get_last_photo. Describing an action you are '
    'about to perform is fine ("opening the camera now"); describing one as already done is not. '
    // CHANGE 2 — CONFIRMED via logcat: every time a deterministic trigger
    // fires (open_camera, capture_photo, confirm_photo_upload, ...) Gemini
    // also free-generates its own reply to the same utterance ("I can't—",
    // "Great. Is there anything else I can help you with?"). The app's
    // mute/interrupt/hard-pause logic still catches it and stays in place
    // as the safety net; this only makes Gemini attempt it less often.
    'APP-HANDLED COMMANDS — STAY SILENT. The app itself recognizes and carries out these phrases the moment it '
    'hears them: opening the camera ("take a photo", "open the camera"), capturing ("take it", "ready", '
    '"capture it"), keeping or retaking a photo ("keep it", "save it", "retake", "try again"), answering the '
    'photo-note question (adding, confirming, or declining a note — "yes", "no", "skip", "save that", or the '
    'note\'s own words), navigation such as "go back", "take me back", or "go home", opening or showing a '
    'screen (the estimate, change orders, invoice, job history, job details, the last photo), and "which screen '
    'am I on". For any of these, do '
    'NOT produce a conversational answer of your own — no acknowledgment, no follow-up question, no "anything '
    'else?", no explanation of what you can or cannot do. You may still call the matching function, but say '
    'nothing. The app speaks the result itself and then tells you the outcome in a message afterward; only '
    'respond to what that message asks you to say. '
    // Wake-word greeting — the app speaks the session's one opening line
    // itself (see `_maybeSpeakSessionGreeting`); a greeting of Gemini's own
    // racing it is the double-greeting bug this codebase already had once.
    'NO GREETING OF YOUR OWN. When a session starts, the app itself speaks the one opening greeting. Never '
    'greet, introduce yourself, or announce that you are here or listening on your own initiative. At the '
    'start of a session, stay silent until the technician speaks or the app hands you an exact line to read. '
    'When the technician wants to log a quick observation or note about the site (not a priced estimate or '
    'change order), call site_condition. '
    'When the technician asks to see or review something (the estimate, change orders, the invoice, job '
    'history, or the last photo taken), call the matching view_ function or get_last_photo to actually show '
    'it - do not just describe it in words. '
    "When the technician wants to go back, return to the job, or asks for something like 'take me back' or "
    "'go home,' call go_back - never just describe going back without actually navigating. "
    'When the technician asks what screen they\'re on or where they currently are, call get_current_screen - '
    'never guess from conversational memory. '
    'If the technician says "stop", "loop off", "FieldLoop stop", or otherwise asks to end the '
    'session or be left alone, call end_session immediately — do not ask a follow-up question first.';

/// Short, forceful restatement of the core boundary rule — deliberately
/// kept SEPARATE from [_systemInstruction] itself (rather than just
/// appended to that const directly) so [_effectiveSystemInstruction] can
/// guarantee this is always the true LAST thing Gemini reads, even in
/// job-scoped mode where a "the job is already known" sentence also gets
/// appended — some models weight recently-stated instructions more heavily
/// in long system prompts, and stating this rule only once, near the top
/// of a long instruction, was not reliably enough: CONFIRMED via a real
/// session where Gemini gave a generic "I can help with a lot of things"
/// answer to "what kind of help do you provide" and claimed it "cannot
/// take photos at all" in response to "let's take the picture", despite
/// open_camera being a real, working function already declared as a tool.
const String _systemInstructionReminder =
    'REMINDER: you are ONLY a job-specific voice assistant with the exact capabilities listed above - if '
    'asked what you can help with, list those specific capabilities, never give a generic AI assistant '
    'answer. If asked to take a photo, always call open_camera - never claim you cannot take photos. '
    // P1 FIX: the line above only explicitly reinforced open_camera — a
    // technician report described Gemini instead hedging specifically on
    // the CAPTURE step ("I'm unable to capture photos" / "I can't actually
    // take the picture") right as the deterministic system was opening the
    // camera or capturing successfully in the background. capture_photo/
    // confirm_photo_upload/retake_photo are just as real and working as
    // open_camera — restated explicitly by name so this same hedging gap
    // can't recur for any of the other three camera-flow functions.
    'The same is true for every other step of that flow: capture_photo, confirm_photo_upload, and '
    'retake_photo are all real, working functions too - never claim you cannot capture, take, upload, or '
    'retake a photo, or that the technician should use their device\'s own camera app instead. If a photo '
    'action has already happened (you were told a function succeeded), acknowledge what actually happened - '
    'never contradict it by claiming the capability does not exist. '
    // PART 3 (client reliability fix — client reported Gemini giving
    // generic/made-up answers instead of either a real KB-vetted answer or
    // an honest decline): explicit, unambiguous restatement of the
    // get_kb_answer/get_job_timeline_answer boundary already stated earlier
    // in the system instruction, placed here (the true LAST text Gemini
    // reads — see this const's own doc comment above) for the same reason
    // the photo-capability line above already is.
    'You must NEVER answer a technician\'s question directly from your own knowledge. For any question about '
    'the job, procedures, materials, or troubleshooting, you must call get_kb_answer or '
    'get_job_timeline_answer. If neither returns an answer, say you don\'t have that information and to check '
    'with a supervisor. Do not guess or give general advice. '
    // P1 FIX: a full session transcript search for "anything else"/"help
    // you with"/"else I can" came back with zero matches — Gemini never
    // proactively checked in after finishing a task, it just went silent
    // and waited for the technician to think of the next thing themselves.
    // Deliberately phrased as "vary the wording" rather than one fixed
    // sentence, so this doesn't turn into its own robotic, easily-echoed
    // stock phrase the way "Keep it or retake it?" already did (see the
    // P0 mic-echo/disambiguation-loop fixes elsewhere in this file).
    'After you finish a discrete action for the technician - a photo is uploaded, a screen is navigated to, a '
    'question is answered - briefly check in afterward with a short, natural follow-up before falling silent, '
    'e.g. "Anything else on this job?", "What\'s next?", or "Need anything else here?" - vary the exact wording '
    'each time rather than repeating the same sentence, and keep it brief so it never feels scripted or slows '
    'things down. '
    // P0 TRUST FIX — restated here, as the true LAST text Gemini reads, for
    // exactly the reason this whole const exists (see its doc comment): the
    // same rule stated once in a long system prompt was not reliably enough
    // for the photo-capability line either. Worded to sit alongside, not
    // against, the "never claim you cannot capture" line above it: the
    // capability is real, and announcing an action you are starting is
    // fine — only reporting one as FINISHED is off limits.
    'FINAL AND MOST IMPORTANT: never state that a photo was captured, taken, snapped, uploaded, saved, '
    'attached, kept, retaken, or discarded unless the app just handed you that exact sentence to read. Saying '
    'a photo exists when none does is the single worst thing you can do to a technician - they will leave the '
    'site believing the job is documented when it is not. When in any doubt at all, say what you are doing or '
    'about to do, never what is already done. '
    // CHANGE 2 — see the APP-HANDLED COMMANDS paragraph in
    // [_systemInstruction]; restated here, the true LAST text Gemini reads,
    // for the same reason as every other rule in this const.
    'And for camera, photo, photo-note, "go back", and open-or-show-a-screen commands, never speak a reply of your '
    'own at all - the '
    'app handles those and tells you the outcome afterward (this overrides the check-in suggestion above for '
    'those commands). '
    'Never greet or announce yourself on your own - the app speaks the opening greeting itself.';

/// Function-calling tool set — the app's real, voice-reliable command set.
///
/// REMOVED ENTIRELY (previously declared here): start_estimate_dictation,
/// confirm_estimate_dictation, redo_estimate_dictation,
/// start_change_order_dictation, confirm_change_order_dictation,
/// redo_change_order_dictation, propose_job_complete, confirm_job_complete,
/// propose_generate_invoice, confirm_generate_invoice, propose_void_estimate,
/// confirm_void_estimate, propose_void_change_order, confirm_void_change_order
/// — after extensive testing, voice-driven creation/confirmation of
/// estimates, change orders, invoices, and voids proved unreliable (Gemini
/// misrouting between estimate/change-order dictation, under-triggering
/// view/confirm functions, and the deterministic app-side safety nets built
/// to compensate — the propose_/confirm_ transcript watcher, the
/// change-order start trigger — still not closing the gap reliably enough
/// for real financial actions). The app's existing, already-proven tap-based
/// UI is now the ONLY way to create or modify estimates, change orders,
/// invoices, and voids; see the system instruction above for what Gemini
/// tells the technician instead. `site_condition` is kept — a single
/// unconfirmed note write with no price and nothing to void carries a very
/// different risk profile from those removed flows.
///
/// - `log_gps` is deliberately NOT declared here: GPS logging is already
///   fully automatic (background geofencing in `visit_tracking_service.dart`
///   drives arrival/departure events itself; lat/lng are never persisted,
///   only used transiently for the distance check) — there is no discrete
///   backend action for a tool call to invoke.
/// - `edit_note` and `undo_last_action` are also NOT declared here: neither
///   has ANY existing backend implementation (no update path for dictation
///   transcripts; no rollback/undo mechanism anywhere in the app).
/// - Photo capture is FOUR separate functions — `open_camera` (NON_BLOCKING),
///   `capture_photo`, `confirm_photo_upload`, `retake_photo` — not one
///   atomic call, matching the app's real multi-step camera flow (open →
///   capture → preview → confirm/retake) and letting Gemini ask "ready?"
///   and "upload or retake?" as natural conversation instead of a hardcoded
///   prompt baked into the dispatcher. See `GeminiCameraSession` in
///   `lib/services/gemini_function_dispatcher.dart` for how the open
///   camera/captured file state is kept between these calls. None carry a
///   `note`/caption parameter — the upload-url Lambda
///   (`backend/functions/get-photo-upload-url`) only accepts
///   `jobId`/`fileName`; there is no note/caption field anywhere in the
///   photo pipeline (Lambda, `field_events` metadata, or `JobPhoto` model).
/// - `get_kb_answer` uses `question` (not `query`) and an optional `job_id`
///   — matching `backend/functions/ask-troubleshooting`'s real request body
///   and how every existing caller (`job_voice_commands.dart`) invokes it;
///   `job_id`, when given, trade-scopes the KB search instead of falling
///   back to a generic "general_contractor" search.
///
/// `view_estimate`/`view_change_orders`/`view_invoice`/`view_job_history`
/// are navigation-only, read-only — each just pushes the exact same existing
/// screen (`EstimateScreen`/`ChangeOrdersScreen`/`InvoiceScreen`/
/// `JobHistoryScreen`) the matching tap button on Job Detail already pushes,
/// and returns the job's real current data so Gemini can speak it. No new
/// screens, no new navigation logic, no writes. All four are `NON_BLOCKING`
/// since navigating doesn't need to pause the conversation the way a real
/// backend write does.
///
/// `get_job_details`/`get_job_timeline_answer` are read-only, real-data
/// lookups deliberately kept separate from `get_kb_answer`: the latter is
/// ONLY for general trade/how-to knowledge (see its own description below
/// and the system instruction), never for facts about the CURRENT job —
/// `get_job_details` reads the `jobs` table row directly (customer name,
/// address, description, status), `get_job_timeline_answer` reads the same
/// `job_history_feed` view `JobHistoryScreen` shows (see
/// `job_history_provider.dart`), so "when did we arrive"/"what have we done
/// so far" are answered from real logged events, never a guess.
///
/// `get_last_photo` is likewise navigation-only/read-only — pushes the
/// same `PhotoViewerScreen` every existing photo-thumbnail tap already
/// uses (see `_getLastPhoto` in `gemini_function_dispatcher.dart`), a real
/// visible preview rather than a spoken description.
///
/// `get_current_screen` is the one function here that does NOT go through
/// `dispatchGeminiFunctionCall`/`gemini_function_dispatcher.dart` at all —
/// it answers from this screen's own local UI state
/// (`_GeminiLiveTestScreenState._describeCurrentScreen`), same as
/// `end_session`.
///
/// NOTE: `_geminiModel` above is gemini-3.1-flash-live-preview, which its
/// own doc comment flags as having a known function-calling freeze bug —
/// this tool set is exactly the Day 2 function-calling work that comment
/// warned to re-evaluate the model choice before starting. Watch for it.
/// GEMINI INTENT CHECK's classification function — see
/// `_GeminiLiveTestScreenState._maybeStartGeminiIntentCheck`.
const String _geminiIntentCheckFunctionName = 'classify_camera_intent';

const List<Map<String, dynamic>> _geminiToolFunctionDeclarations = [
  {
    'name': 'open_camera',
    'description': 'Opens the camera to a live preview for the current job, ready to take a photo. Call this '
        'whenever the technician expresses ANY intent to take a photo — wanting to document something, '
        'capture an image, show what they\'re looking at, or asking to take/snap/get a picture — even if '
        'phrased indirectly. Does not capture anything yet — call capture_photo once the technician is ready.',
    'behavior': 'NON_BLOCKING',
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the job to open the camera for.'},
      },
      'required': ['job_id'],
    },
  },
  {
    'name': 'capture_photo',
    'description': 'Takes a photo using the already-open camera (call open_camera first) and shows it as a '
        'still preview. Call this as soon as the technician confirms they are ready — "go", "take it", '
        '"ready", "now", or similar. Does NOT upload it — the technician still needs to say whether to keep '
        'it (confirm_photo_upload) or retake it (retake_photo).',
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the job this photo belongs to.'},
      },
      'required': ['job_id'],
    },
  },
  {
    'name': 'confirm_photo_upload',
    'description': 'Keeps the photo that was just captured (call capture_photo first). The app then asks the '
        "technician about a note and uploads the photo to the job's photo record itself once that is answered "
        '— this call does not upload anything yet. Call this when the technician says to keep, save, upload, or '
        'confirm the photo — phrases like "keep it", "save it", "upload it", "that looks good", "use that one", '
        'or "yes, keep that" should ALWAYS trigger this function.',
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the job this photo belongs to.'},
      },
      'required': ['job_id'],
    },
  },
  {
    'name': 'retake_photo',
    'description': 'Discards the just-captured photo preview (call capture_photo first) and returns to the '
        'live camera view, ready for another capture_photo call. Call this when the technician wants to '
        'retake, redo, or discard the photo — phrases like "retake it", "try again", "take another one", '
        '"that doesn\'t look right", "redo that", or "no, retake" should ALWAYS trigger this function.',
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the job this photo belongs to.'},
      },
      'required': ['job_id'],
    },
  },
  {
    'name': 'site_condition',
    'description':
        "Logs a quick observational note about the job site into the job's history — a simple record, NOT a "
        'priced estimate or change order and NOT gated on any confirmation step. Call this whenever the '
        'technician wants to log a quick observation or note about the site — phrases like "note that...", '
        '"make a note", "log that...", "flag that...", or "for the record..." should trigger this, as long as '
        "it's an observation and not a priced estimate or change order.",
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the job this note belongs to.'},
        'note': {
          'type': 'STRING',
          'description':
              'Verbatim spoken text of the observation/note, unmodified — e.g. "water heater is rusted at the '
              'base, customer should be told". Never paraphrase or restructure it yourself.',
        },
      },
      'required': ['job_id', 'note'],
    },
  },
  {
    'name': 'get_job_details',
    'description':
        "Looks up THIS job's own real details — customer name, service address, problem description, and "
        'status — directly from the jobs table. Call this whenever the technician asks about the customer, '
        'the address, what the job/problem is, or the job status. Never guess or answer these from memory; '
        'never use get_kb_answer for these — that tool is only for general trade knowledge, not this '
        "specific job's data.",
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the job to look up.'},
      },
      'required': ['job_id'],
    },
  },
  {
    'name': 'get_job_timeline_answer',
    'description':
        "Looks up THIS job's real, actually-logged activity timeline (arrivals/departures, photos, "
        'dictations, estimate events, with real timestamps) to answer questions like "when did we arrive", '
        '"what have we done so far", or "when did I take that photo". Call this whenever the technician asks '
        "about what has happened on this job or when something happened. Never guess or answer these from "
        'your own conversational memory — always look up the real logged events. Never use get_kb_answer for '
        "these — that tool is only for general trade knowledge, not this specific job's history.",
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the job whose timeline to look up.'},
        'query_hint': {
          'type': 'STRING',
          'description':
              'A short phrase capturing what the technician actually asked, e.g. "when did we arrive" or '
              '"what has been done so far" — helps identify which logged event(s) answer the question.',
        },
      },
      'required': ['job_id', 'query_hint'],
    },
  },
  {
    'name': 'get_last_photo',
    'description':
        'Looks up the most recently uploaded photo for this job and shows it full-screen — a real, visible '
        'photo preview, not a spoken description. Call this whenever the technician wants to see, check, or '
        'review the last/most recent photo — phrases like "show me the last photo", "what did we last take a '
        'photo of", "what was the last picture", or "pull up the last photo" should ALWAYS trigger this '
        'function — do not just describe the photo in words.',
    'behavior': 'NON_BLOCKING',
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the job whose most recent photo to show.'},
      },
      'required': ['job_id'],
    },
  },
  {
    'name': 'get_kb_answer',
    'description':
        "Looks up a knowledge-base answer to a troubleshooting question, scoped to the job's trade category when "
        'job_id is given (falls back to a general-contractor scope otherwise). Call this whenever the '
        'technician asks a troubleshooting, how-to, or reference question about the job or equipment.',
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'question': {'type': 'STRING', 'description': 'The troubleshooting question to look up, verbatim.'},
        'job_id': {
          'type': 'STRING',
          'description':
              "Optional UUID of the current job — scopes the answer to the job's trade category (e.g. plumbing vs "
              'electrical) instead of a generic search.',
        },
      },
      'required': ['question'],
    },
  },
  {
    'name': 'view_estimate',
    'description': "Navigates to the job's full Estimate screen and returns the real estimate for this job — "
        'its actual id, status, total amount, and line items — if one exists. Call this whenever the '
        'technician wants to see, check, or review the estimate — phrases like "show me the estimate", '
        '"what\'s on the estimate", "let me see the estimate", "pull up the estimate", "check the estimate", '
        'or "review the estimate" should ALWAYS trigger this function — do not just describe it in words.',
    'behavior': 'NON_BLOCKING',
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the job whose estimate to view.'},
      },
      'required': ['job_id'],
    },
  },
  {
    'name': 'view_change_orders',
    'description': "Navigates to the job's Change Orders screen and returns the real list of change orders "
        'for this job, each with its actual id, description, amount, and status. Call this whenever the '
        'technician wants to see, check, or review the change orders — phrases like "show me the change '
        'orders", "what change orders are there", "let me see the change orders", "pull up the change '
        'orders", "check the change orders", or "review the change orders" should ALWAYS trigger this '
        'function — do not just describe them in words.',
    'behavior': 'NON_BLOCKING',
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the job whose change orders to view.'},
      },
      'required': ['job_id'],
    },
  },
  {
    'name': 'view_invoice',
    'description': "Navigates to the job's full Invoice screen. Call this whenever the technician wants to "
        'see, check, or review the invoice — phrases like "show me the invoice", "what\'s on the invoice", '
        '"let me see the invoice", "pull up the invoice", "check the invoice", or "review the invoice" '
        'should ALWAYS trigger this function — do not just describe it in words.',
    'behavior': 'NON_BLOCKING',
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the job whose invoice to view.'},
      },
      'required': ['job_id'],
    },
  },
  {
    'name': 'view_job_history',
    'description': "Navigates to the job's full History timeline screen. Call this whenever the technician "
        'wants to see, check, or review the job history — phrases like "show me the history", "what\'s '
        'happened so far", "let me see the timeline", "pull up the job history", "check the history", or '
        '"review the timeline" should ALWAYS trigger this function — do not just describe it in words.',
    'behavior': 'NON_BLOCKING',
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the job whose history to view.'},
      },
      'required': ['job_id'],
    },
  },
  {
    'name': 'go_back',
    'description':
        'Navigates back to the main Job Detail screen from wherever the technician currently is — the '
        'estimate, change orders, invoice, job history, OR mid-camera/photo-workflow (the camera is open, a '
        'photo was just captured, etc.) — a real, standard back-navigation (not a hardcoded route), so it '
        'correctly returns from whichever screen or task is actually active, closing out of an open camera '
        'flow if one is in progress. Call this whenever the technician wants to go back, return to the job, '
        'or asks for something like "take me back", "go home", or "back to job details" — including in the '
        'middle of taking a photo, before confirming or retaking it — never just describe going back without '
        'actually navigating. A no-op (does nothing harmful) if the technician is already at Job Detail.',
    'behavior': 'NON_BLOCKING',
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the current job.'},
      },
      'required': ['job_id'],
    },
  },
  {
    'name': 'get_current_screen',
    'description':
        'Tells the technician, in plain language, which screen the app is currently showing (the main job '
        'details screen, the Estimate screen, the Change Orders screen, the Invoice screen, the Job History '
        'screen, the photo viewer, or the camera). Call this whenever the technician asks where they are or '
        'what screen/page they\'re on — phrases like "where are we", "where am I", "what screen is this", or '
        '"which page are we on" should ALWAYS trigger this function — never guess from conversational memory, '
        'since navigation can happen without the technician saying anything (e.g. a deterministic app-side '
        'trigger).',
    'behavior': 'NON_BLOCKING',
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'job_id': {'type': 'STRING', 'description': 'UUID of the current job.'},
      },
      'required': ['job_id'],
    },
  },
  // GEMINI INTENT CHECK — see
  // [_GeminiLiveTestScreenState._maybeStartGeminiIntentCheck]. Local state only
  // (answered in [_GeminiLiveTestScreenState._handleToolCall], never
  // dispatched), and only ever called when the app explicitly asks.
  {
    'name': _geminiIntentCheckFunctionName,
    'description':
        'Classification step. ONLY call this when a message explicitly asks you to classify what the technician '
        'said — never on your own. Reports whether it means they want the camera opened, a photo taken right '
        'now, or neither.',
    'behavior': 'NON_BLOCKING',
    'parameters': {
      'type': 'OBJECT',
      'properties': {
        'intent': {
          'type': 'STRING',
          'enum': ['open_camera', 'capture_photo', 'none'],
          'description': 'open_camera, capture_photo, or none.',
        },
        'confidence': {'type': 'NUMBER', 'description': 'How sure you are, from 0.0 to 1.0.'},
      },
      'required': ['intent', 'confidence'],
    },
  },
  {
    'name': 'end_session',
    'description': 'Ends the current voice session — call this when the technician says "stop", "loop off", '
        '"FieldLoop stop", or otherwise asks to end the session or be left alone. Does not need confirmation '
        'first; ending the session is itself the safe, reversible action (saying the wake word again starts a '
        'new one).',
    'behavior': 'NON_BLOCKING',
    'parameters': {'type': 'OBJECT', 'properties': {}},
  },
];

/// Every top-level key `BidiGenerateContentServerMessage` can carry, per
/// https://ai.google.dev/api/live — `setupComplete`/`error`/`serverContent`
/// are already handled explicitly in [_GeminiLiveTestScreenState._onServerMessage];
/// the rest are logged by name there. Used only to tell a genuinely
/// unrecognized message shape apart from a known one that just isn't
/// specially handled yet.
const Set<String> _knownServerMessageKeys = {
  'setupComplete',
  'error',
  'serverContent',
  'usageMetadata',
  'toolCall',
  'toolCallCancellation',
  'goAway',
  'sessionResumptionUpdate',
};

/// Roughly calibrated int16 RMS threshold for "the mic is picking up
/// speech" vs. background noise/silence — good enough for a bare
/// connectivity proof's stop-timing, not a real VAD.
const double _speechRmsThreshold = 500;

/// How long the input has to stay below [_speechRmsThreshold] before we
/// consider the user to have stopped speaking (debounces brief gaps
/// between words so we don't restart the stopwatch mid-sentence).
const Duration _silenceDebounce = Duration(milliseconds: 500);

/// CONFIRMED bug: every deterministic trigger's buffer used to get wiped on
/// the SAME [_silenceDebounce] (500ms) edge used for the latency stopwatch
/// — any natural mid-sentence pause over 500ms (plausible for a 5+ word
/// phrase like "which page are we on") flipped [_GeminiLiveTestScreenState.
/// _isSpeaking] false then true again, and that speech-RESUMPTION edge
/// wiped every trigger's accumulated buffer before the full phrase had
/// finished accumulating — even though the phrase itself was correctly in
/// the trigger's own indicator-phrase list. This is a SEPARATE, longer
/// threshold used only to decide whether enough silence has passed to
/// treat the next word as a genuinely NEW utterance for buffer-reset
/// purposes — [_silenceDebounce]/[_isSpeaking] keep their existing 500ms
/// behavior for the latency stopwatch, untouched.
const Duration _utteranceBufferResetDebounce = Duration(seconds: 2);

/// HARD FALLBACK (CONFIRMED via flutter_run_log_new.txt: after one FREE-TEXT
/// AUDIO ONLY turn — Gemini answering "This photo is very blur." with spoken
/// text and no function call — the raw-amplitude silence->speech edge in
/// [_GeminiLiveTestScreenState._trackSpeechLevel] stopped firing "detected
/// user stopped speaking" for the rest of the session. [_GeminiLiveTestScreenState._isSpeaking]
/// stayed stuck `true` for 30+ seconds spanning two clearly separate real
/// utterances 30s apart, which then concatenated into one buffer instead of
/// resetting, and [_GeminiLiveTestScreenState._armPreemptiveDefaultMuteSafetyTimer]'s
/// retry-decline looped "still actively speaking" every 2s indefinitely —
/// waiting on an end-of-speech signal that never came again). Whatever the
/// exact cause, a single continuous speaking burst must never be able to
/// wedge the session for its remaining duration — see
/// [_GeminiLiveTestScreenState._speechStuckWatchdogTimer], which force-ends
/// a burst that has run continuously longer than this, independent of (and
/// as a backstop for) [_trackSpeechLevel]'s own per-chunk edge detection.
/// Generous relative to any real spoken command/sentence (well under 8s)
/// so it never cuts off genuine ongoing speech.
const Duration _speechMaxContinuousDuration = Duration(seconds: 8);

/// Under-triggered-function fix, same pattern already used to strengthen
/// site_condition: a strengthened tool description alone has not always
/// been enough to make Gemini reliably call a function on a clear,
/// unambiguous request. See
/// [_GeminiLiveTestScreenState._looksLikeViewEstimateRequest] for how these
/// are used: broad, not exact-phrase, whole-word/phrase matching against the
/// technician's own transcribed words, independent of whatever Gemini itself
/// decides to do.
const List<String> _viewEstimateIndicatorPhrases = [
  'show me the estimate',
  'show the estimate',
  'see the estimate',
  'view the estimate',
  'check the estimate',
  'review the estimate',
  'pull up the estimate',
  'whats on the estimate',
  'let me see the estimate',
  'look at the estimate',
];

/// Debounce for the deterministic view_estimate trigger — if Gemini already
/// called view_estimate more recently than this, the deterministic trigger
/// assumes Gemini is already handling it and stays out of the way. See
/// [_GeminiLiveTestScreenState._maybeTriggerViewEstimate].
const Duration _viewEstimateDebounce = Duration(seconds: 5);

/// CONFIRMED ghost-call bug: "Can you tell me about this job?" was
/// transcribed correctly but get_job_details was never called. Same
/// under-triggered-function pattern as [_viewEstimateIndicatorPhrases] — a
/// strengthened tool description alone was not enough, so this app-side
/// backstop watches the technician's own transcribed words directly. See
/// [_GeminiLiveTestScreenState._looksLikeGetJobDetailsRequest].
const List<String> _getJobDetailsIndicatorPhrases = [
  'tell me about this job',
  'tell me about the job',
  'about this job',
  'about the job',
  'whats this job',
  'whats the job',
  'job details',
  'details about this job',
  'details about the job',
  'whats the job about',
  // PART 3 gap found via a standalone match-logic check against "What's
  // this job about?": the letters-and-spaces-only normalization turns an
  // apostrophe into a SPACE, not nothing (same VERIFIED behavior already
  // documented on `_photoConfirmIndicatorPhrases`'s 'that s good' entry —
  // "What's" normalizes to "what s", not "whats"), so a real "what's..."
  // utterance transcribed with a literal apostrophe would miss every
  // 'whats ...' entry above and could otherwise fall through to the
  // broadened get_kb_answer catch-all instead of the correct, job-specific
  // answer. Both normalized forms are listed since it's unverified whether
  // Gemini's real transcription ever emits the apostrophe.
  'what s this job',
  'what s the job',
  'what s the job about',
  'what s this job about',
];

/// Debounce for the deterministic get_job_details trigger — same role as
/// [_viewEstimateDebounce], applied to get_job_details activity. See
/// [_GeminiLiveTestScreenState._maybeTriggerGetJobDetails].
const Duration _getJobDetailsDebounce = Duration(seconds: 5);

/// Debounce for the hand-rolled get_current_screen trigger — same role as
/// [_getJobDetailsDebounce].
const Duration _getCurrentScreenDebounce = Duration(seconds: 5);

/// CONFIRMED via a full real session: Gemini called ZERO functions natively
/// the entire time (toolCall received: 0 occurrences) — every navigation and
/// camera request was transcribed correctly but never acted on, except
/// get_job_details, which only worked because of its own deterministic
/// backstop above. [_TranscriptTrigger]/[_GeminiLiveTestScreenState.
/// _maybeTriggerDeterministic] extend that exact same backstop pattern to
/// every remaining function, sharing one implementation instead of
/// hand-rolling the same ~80-line accumulate/resolve/debounce/dispatch/
/// inform shape six more times (view_estimate/go_back/get_job_details above
/// predate this and are left exactly as proven-working rather than migrated
/// here).
///
/// `NEGATION PREFIX IGNORED` — a phrase matched although a "No,"/"Nope,"
/// sits right in front of it, because punctuation marks that word as a
/// reaction rather than a negation (see `clauseBoundariesBefore` in
/// `trigger_phrase_matcher.dart`).
void _logIgnoredNegationPrefix(String trigger, TriggerPhraseMatch match, String text) {
  final prefix = match.ignoredNegationPrefix;
  if (prefix == null) return;
  debugPrint(
    'NEGATION PREFIX IGNORED [$trigger]: leading "$prefix" is set off by punctuation — a reaction, not a negation '
    'of "${match.phrase}" — matched in "$text"',
  );
}

/// One instance per backstopped function, held in
/// [_GeminiLiveTestScreenState._deterministicTriggers] and reset each
/// silence->speech edge in [_GeminiLiveTestScreenState._trackSpeechLevel]
/// exactly like the hand-rolled buffers above.
class _TranscriptTrigger {
  _TranscriptTrigger(this.name, this.phrases, {this.extraMatcher});

  /// The Gemini function name this backstop fires, e.g. `view_invoice` —
  /// also used verbatim in every log line so CloudWatch/logcat output always
  /// says which trigger acted.
  final String name;
  final List<String> phrases;

  /// Optional secondary matcher, checked in ADDITION to [phrases] (never
  /// instead) — for a function whose real-world phrasing is too
  /// grammatically unpredictable for a fixed phrase list to reasonably
  /// enumerate (confirmed case: "when did we get arrived", genuinely mangled
  /// ASR output for get_job_timeline_answer's arrival-time question).
  ///
  /// P0 FIX (see [matches]): given the STEMMED, space-padded text — e.g.
  /// "let's take a photo" arrives as `' let s tak a photo '` — so word-form
  /// drift ("taking"/"takes"/"took") reaches these matchers too, not just
  /// the phrase list. Every matcher wired in below therefore stems its own
  /// literals with `stemTriggerPhrase` before comparing;
  /// [_looksLikeArrivalTimeQuestion] needs no change (its `' when '` is
  /// stem-stable and its `\barriv` prefix regex already covers every form).
  final bool Function(String stemmedPaddedText)? extraMatcher;

  String buffer = '';
  bool resolvedForCurrentUtterance = false;

  /// Timestamp of the most recent [name] call — Gemini-initiated (tracked
  /// generically in [_GeminiLiveTestScreenState._handleToolCall]) or this
  /// trigger's own deterministic firing (tracked in
  /// [_GeminiLiveTestScreenState._maybeTriggerDeterministic] itself, before
  /// the async dispatch call even starts).
  DateTime? lastActivityAt;

  void resetForNewUtterance() {
    buffer = '';
    resolvedForCurrentUtterance = false;
  }

  /// P0 FIX (CONFIRMED from a real session: the technician's capture
  /// attempt reached this matcher as "All right, taking the picture may."
  /// and matched NOTHING — no photo, and no "I didn't understand" either,
  /// for a long time afterwards). This used to be a literal, space-padded
  /// SUBSTRING check: `' take the picture '` simply is not a substring of
  /// `' all right taking the picture may '`, so a single verb-form drift
  /// silently dropped a real command on the floor. Real ASR output does
  /// that routinely — word-form drift, inserted filler, trailing noise.
  ///
  /// Now delegates to `trigger_phrase_matcher.dart`
  /// ([matchAnyTriggerPhrase]), which stems both sides, tolerates one
  /// inserted filler word, and tolerates a single-character garble in long
  /// content words — while deliberately keeping articles, negation, and
  /// scope words load-bearing, so every prior confirmed regression fix that
  /// depends on those distinctions still holds. See that library's doc
  /// comment and `test/trigger_phrase_matcher_test.dart` for the full
  /// both-directions contract.
  ///
  /// The match is logged with the phrase that fired and whether it needed
  /// the fuzzy path, so the next real run's log answers "did loosening the
  /// matcher actually change anything here" directly instead of by
  /// inference.
  bool matches(String text) {
    final phraseMatch = matchAnyTriggerPhrase(text, phrases);
    if (phraseMatch != null) {
      if (!phraseMatch.exact) {
        debugPrint('FUZZY TRIGGER MATCH [$name]: ${phraseMatch.describe()} matched in "$text"');
      }
      _logIgnoredNegationPrefix(name, phraseMatch, text);
      return true;
    }
    return extraMatcher?.call(stemmedPaddedTriggerText(text)) ?? false;
  }
}

enum _PhotoNotePhase { awaitingDescription, awaitingConfirmation }

/// Outcome of comparing a new turn against the interrupted-turn baseline —
/// see `_GeminiLiveTestScreenState._evaluateInterruptedTurnBaseline`.
enum _BaselineVerdict { noBaseline, needMoreWords, notDuplicate, duplicate }

/// State of the voice photo-description flow ("awaitingPhotoDescription") —
/// see the section of that name in [_GeminiLiveTestScreenState]. Carries
/// the kept photo's id ([keptId]) for its whole life: the photo is held,
/// NOT uploaded, until this flow's answer is known.
class _PhotoNoteFlow {
  _PhotoNoteFlow(this.keptId, this.jobId, this.enteredAt) : quietSince = enteredAt, stepStartedAt = enteredAt;

  /// See `GeminiCameraSession.keep`/`uploadKept`.
  final int keptId;
  final String jobId;
  final DateTime enteredAt;

  /// This photo's upload — `null` until the note question is answered (see
  /// `_startPhotoNoteUpload`), then the upload's result (`null` if it
  /// threw). Started at most once per flow.
  Future<Map<String, dynamic>?>? upload;

  String describePhoto() =>
      'kept photo #$keptId job_id=$jobId (${upload == null ? 'upload deferred until the note is answered' : 'upload started'})';
  _PhotoNotePhase phase = _PhotoNotePhase.awaitingDescription;

  /// The technician's words since the flow last acted on anything.
  String buffer = '';
  DateTime? lastHeardAt;

  /// Read back, awaiting "yes" — never saved until confirmed.
  String? candidate;
  int reasks = 0;
  bool prompted = false;
  bool saving = false;
  DateTime quietSince;

  /// Whether the current read-back already got its one "Save that note —
  /// yes or no?" re-prompt. Reset for each new read-back (a correction is
  /// a new candidate).
  bool confirmReprompted = false;

  /// Same, for the awaitingDescription ask ("Still there? Want to add a
  /// note, or should I skip it?"). Reset whenever the flow asks for a note
  /// again (redo / re-ask).
  bool descriptionReprompted = false;

  /// When the flow last spoke — the per-step hard ceiling runs from here.
  DateTime stepStartedAt;

  /// A real command broke out of the confirmation (see
  /// `_photoNoteBreakOutToRealCommand`) — [resumePending] until the one
  /// "back to the photo note" prompt is spoken; [resumedAfterCommand] so it
  /// only ever happens once.
  bool resumePending = false;
  bool resumedAfterCommand = false;

  /// The [_GeminiLiveTestScreenState._utteranceSeq] this flow last claimed.
  int? ownedUtteranceSeq;
}

/// Debounce shared by every [_TranscriptTrigger] — same 5s value already
/// proven for [_viewEstimateDebounce]/[_getJobDetailsDebounce].
const Duration _deterministicTriggerDebounce = Duration(seconds: 5);

/// PART G item 2 (CONFIRMED miss: "the job history screen" matched NONE of
/// [_viewJobHistoryIndicatorPhrases]'s fixed exact phrases — no fixed
/// phrase list can ever enumerate every real phrasing a technician uses).
/// General action-intent words shared by every navigation/camera trigger's
/// [_looksLikeNounPlusActionIntent] check below — kept broad deliberately,
/// since a false positive on any of these triggers only ever costs one
/// extra read-only navigation/camera call (same "safe to over-trigger"
/// philosophy already documented on every trigger in this file).
const List<String> _navigationActionIntentWords = [
  'show',
  'see',
  'view',
  'want',
  'need',
  'go',
  'open',
  'take me',
  'pull up',
  'switch to',
  'check',
  'review',
  'look at',
  'let me see',
  'give me',
  // CONFIRMED elsewhere in this file (e.g. `_getJobDetailsIndicatorPhrases`'s
  // "what s this job" entry): the letters-and-spaces-only normalization
  // turns an apostrophe into a SPACE, not nothing — "let's" becomes "let s"
  // (two separate words), never "lets", so that's the form that must
  // actually appear in this list for it to ever match.
  'let s',
];

/// [_navigationActionIntentWords] plus the extra verbs a camera/photo
/// request actually uses that a plain navigation request never does — "take
/// a photo" has no "show"/"view"/"go" in it at all. See
/// [_looksLikeNounPlusActionIntent]'s doc comment.
const List<String> _cameraActionIntentWords = [
  ..._navigationActionIntentWords,
  'take',
  'capture',
  'snap',
  'turn on',
  'start',
  'get a',
];

/// PART L item 1 (CONFIRMED via 4127d46d-flutter_run_log.txt: "Nice, very
/// good. I want to see a invoice." correctly fired view_invoice despite not
/// matching any fixed phrase, proving loose matching already worked for
/// SOME triggers — but view_change_orders and others were still fixed-
/// phrase-only, confirmed by their own "DETERMINISTIC NO MATCH" log lines).
/// Checked as an ADDITION to each trigger's existing fixed phrase list
/// (never a replacement — those stay exactly as proven-working): matches
/// when a topic noun from [nouns] appears ANYWHERE in the already
/// normalized/space-padded text AND either a general action-intent word
/// from [actionWords] is also present, OR the noun is itself directly
/// followed by a bare "screen"/"page" reference — naming a screen by name
/// ("the job history screen") is its own unambiguous navigation intent,
/// with no verb needed at all. Deliberately two SEPARATE keyword checks
/// (not one fixed multi-word phrase), so filler words ("ahhhh nice",
/// "can you") or reordering between the noun and the verb never break the
/// match. [excludeIfContains] is a last-word veto — e.g. `'last'` for the
/// camera/photo triggers, so "show me the LAST photo"
/// ([_getLastPhotoIndicatorPhrases]'s own phrasing) can never also fire
/// open_camera/capture_photo just because "photo" and "show" both appear.
/// [logLabel], when given, identifies the trigger in the match log line —
/// see that log line for exactly which noun/action-word pair fired, so this
/// is directly verifiable from the next run's log instead of inferred.
/// P0 FIX: [paddedText] is now the STEMMED padded text (see
/// [_TranscriptTrigger.extraMatcher]), so every literal this checks is run
/// through [stemTriggerPhrase] first — "taking a picture" reaches here as
/// `' tak a pictur '` and must still find noun="picture" + action="take".
/// The `excludeIfContains` veto gets the same treatment, so "the last
/// pictures" still vetoes on `last` exactly as before.
/// Statement-of-fact wording that turns a bare "`<noun>` screen" mention into
/// a remark about where the technician already is ("we're still on the
/// invoice screen", "no, this is the estimate page") rather than a request
/// to go there. Only consulted when NO request verb matched.
const List<String> _declarativeScreenMarkers = [
  'we are', 'we re', 'i am', 'i m', 'it is', 'it s', 'this is', 'that is', 'that s', 'they are', 'you are',
  'you re', 'still', 'already', 'no', 'not',
];

/// The most recent bare screen mention [_looksLikeNounPlusActionIntent]
/// rejected as declarative — lets the CLARIFY FALLBACK ask about that
/// specific screen instead of a plain "say that again". Top-level because
/// that matcher is.
({String trigger, String paddedText, DateTime at})? lastLooseNavRejection;

bool _looksLikeNounPlusActionIntent(
  String paddedText, {
  required List<String> nouns,
  required List<String> actionWords,
  List<String> excludeIfContains = const [],
  String? logLabel,
}) {
  for (final word in excludeIfContains) {
    if (paddedText.contains(' ${stemTriggerPhrase(word)} ')) return false;
  }
  String? matchedNoun;
  for (final noun in nouns) {
    if (paddedText.contains(' ${stemTriggerPhrase(noun)} ')) {
      matchedNoun = noun;
      break;
    }
  }
  if (matchedNoun == null) return false;
  final label = logLabel == null ? '' : ' [$logLabel]';
  for (final word in actionWords) {
    if (paddedText.contains(' ${stemTriggerPhrase(word)} ')) {
      debugPrint(
        'LOOSE NAV MATCH$label: noun="$matchedNoun" + action="$word" matched in "$paddedText"',
      );
      return true;
    }
  }
  // Stemmed too ("page" -> "pag", "pages" -> "pag") — a bare literal here
  // would silently stop matching now that [paddedText] arrives stemmed.
  if (paddedText.contains(' ${stemTriggerPhrase('screen')} ') ||
      paddedText.contains(' ${stemTriggerPhrase('page')} ')) {
    // 367d62af log: "No, we are still on invoice screen" — a correction,
    // not a request — navigated here on the bare screen reference alone.
    // Naming a screen with no request verb only counts when the sentence
    // isn't a statement about where they are; otherwise it's left to the
    // clarification fallback (see [lastLooseNavRejection]).
    final declarative = _declarativeScreenMarkers.firstWhere(
      (marker) => paddedText.contains(' ${stemTriggerPhrase(marker)} '),
      orElse: () => '',
    );
    if (declarative.isNotEmpty) {
      debugPrint(
        'LOOSE NAV REJECTED: trigger=${logLabel ?? '?'} reason=declarative_not_request text="${paddedText.trim()}" '
        '(noun="$matchedNoun" + screen/page reference, but "$declarative" and no request verb)',
      );
      if (logLabel != null) {
        lastLooseNavRejection = (trigger: logLabel, paddedText: paddedText, at: DateTime.now());
      }
      return false;
    }
    debugPrint(
      'LOOSE NAV MATCH$label: noun="$matchedNoun" + bare screen/page reference matched in "$paddedText"',
    );
    return true;
  }
  return false;
}

const List<String> _viewChangeOrdersIndicatorPhrases = [
  'show me the change orders',
  'show the change orders',
  'see the change orders',
  'view the change orders',
  'check the change orders',
  'review the change orders',
  'pull up the change orders',
  'let me see the change orders',
  'look at the change orders',
  'what change orders',
  'show change orders',
];

const List<String> _viewInvoiceIndicatorPhrases = [
  'show me the invoice',
  'show the invoice',
  'see the invoice',
  'view the invoice',
  'check the invoice',
  'review the invoice',
  'pull up the invoice',
  'whats on the invoice',
  'let me see the invoice',
  'look at the invoice',
];

const List<String> _viewJobHistoryIndicatorPhrases = [
  'show me the history',
  'show the history',
  'show job history',
  'show me the job history',
  'show the job history',
  'see the history',
  'see the job history',
  'view the history',
  'view the job history',
  'check the history',
  'check the job history',
  'review the history',
  'review the job history',
  'pull up the history',
  'pull up the job history',
  'let me see the history',
  'let me see the job history',
  'look at the history',
  'look at the job history',
  'what have we done',
  'whats happened so far',
];

const List<String> _openCameraIndicatorPhrases = [
  'take a photo',
  'take a picture',
  'take a pic',
  'lets take the image',
  'lets take a picture',
  'lets take a photo',
  'capture this',
  'snap a photo',
  'get a picture',
  'get a photo',
  // CONFIRMED gap: neither phrasing tested (verbatim "open the camera" +
  // "open camera") was in this list at all — the most literal, obvious
  // phrasing for a function actually named open_camera was simply missing.
  'open the camera',
  'open camera',
  'turn on the camera',
  'start the camera',
  // CONFIRMED gap (logcat 09-29 12:14, "take a shot" heard as "Tika shot"):
  // no "shot"/"snap"/"pic"/"photograph" phrasing at all, and none of the
  // common "bring the camera up" phrasings either. The shot/pic/snap/click
  // phrasings below are ALSO in [_capturePhotoIndicatorPhrases]: each
  // trigger's guard decides — with the camera closed they open it, with it
  // live capture_photo fires (a guard-failed open_camera match is a
  // non-event, see [_maybeTriggerDeterministic]).
  'lets get a shot',
  'get the camera up',
  'fire up the camera',
  'pull up the camera',
  'bring up the camera',
  'take a shot',
  'get a shot',
  'grab a shot',
  'snap a shot',
  'take a snap',
  'get a snap',
  'grab a pic',
  'get a pic',
  'snap a pic',
  'take a photograph',
  'click a picture',
  'click a photo',
];

/// FIX 2: `capture_photo`'s own deterministic backstop, same pattern as
/// [_openCameraIndicatorPhrases]. Deliberately short/imperative phrases —
/// this only fires while [_ScreenTask.cameraLive] is genuinely showing (see
/// the `guard:` on this trigger's `_maybeTriggerDeterministic` call), so
/// there's no risk of "ready"/"go ahead" misfiring during ordinary
/// conversation elsewhere in the session.
const List<String> _capturePhotoIndicatorPhrases = [
  'take it',
  'capture it',
  'snap it',
  // P0 FIX (CONFIRMED via flutter_run_log_new.txt, build #65): 'go ahead'
  // used to live here as a plain phrase too (alongside bare 'ready',
  // removed one round earlier for the identical reason) — both match as a
  // substring ANYWHERE, including inside Gemini's own coaching phrases
  // ("go ahead and take another one when you're ready", "The camera's
  // actually open now — go ahead when you're ready."). An echo of either
  // phrase slipping past the backstop would fire an unwanted
  // capture_photo directly. Both now live ONLY in the dedicated
  // standalone-utterance-only check in [_looksLikeCapturePhotoConfirmation]
  // — see that function's doc comment.
  // BUG 3 (real session evidence): broadened from the original five after
  // confirming the technician's actual phrasing wasn't fully covered.
  'take the photo',
  'take photo',
  'capture the photo',
  // CONFIRMED gap (real log evidence): a clean, uncontaminated buffer —
  // "Yes, take the picture." — didn't match because every phrase above was
  // "photo"-only. Technicians say "picture" just as often; open_camera's
  // own list already covers both words (see 'take a picture' etc. above),
  // capture_photo's didn't.
  'take the picture',
  'take picture',
  'capture the picture',
  'snap the picture',
  // "image" alongside photo/picture (CONFIRMED miss: "Yes, I am ready. Take
  // the image." with the camera live fell through to the fuzzy intent
  // layer, which resolved it to open_camera and got "the camera's already
  // open" instead of a photo). Same article rule as the photo/picture
  // entries: "the image" is this shot, "an image" stays open_camera's.
  'take the image',
  'take image',
  'capture the image',
  'snap the image',
  // CONFIRMED gap (logcat 09-29 12:14, "take a shot" heard as "Tika shot"):
  // shot/snap/pic/shoot/photograph/click phrasings. Unlike photo/picture,
  // the "a" forms of these ARE capture phrasings while the camera is live —
  // "take a shot" said at the live preview means "shoot now"; the article
  // rule (and [_looksLikeCapturePhotoConfirmation]'s veto) still keeps a
  // restated "take a photo"/"take a picture" from firing the shutter. Most
  // of these are also open_camera phrasings for when the camera is closed —
  // see the note in [_openCameraIndicatorPhrases].
  'take a shot',
  'take the shot',
  'get a shot',
  'get the shot',
  'grab a shot',
  'grab the shot',
  'snap a shot',
  'take a snap',
  'get a snap',
  'take a pic',
  'take the pic',
  'grab a pic',
  'get a pic',
  'snap a pic',
  'get the picture',
  'get the photo',
  'grab the picture',
  'grab the photo',
  'shoot it',
  'shoot this',
  'shoot that',
  'photograph it',
  'photograph this',
  'photograph that',
  'click a picture',
  'click the picture',
  'click a photo',
  'click the photo',
  'click it',
  // NOTE: 'confirm'/'keep it'/'upload it' ALSO appear in
  // [_photoConfirmIndicatorPhrases] (confirm_photo_upload's own trigger,
  // guarded on `_ScreenTask.cameraCaptured`) — not a copy-paste duplicate.
  // This trigger is guarded on `_ScreenTask.cameraLive` instead (see its
  // `_maybeTriggerDeterministic` call's `guard:`), so the two can never
  // both be armed at once; a technician saying any of these three while the
  // LIVE preview (not yet captured) is showing is read as "go ahead and
  // take it," matching real observed phrasing where these weren't reserved
  // exclusively for the post-capture decision.
  'confirm',
  'keep it',
  'upload it',
];

/// PART N item 1 (CONFIRMED accidental-capture regression via
/// 3ebd9995-flutter_run_log.txt: "Let's take a photo," said while the
/// camera was ALREADY open, correctly failed open_camera's own guard, then
/// matched capture_photo's OLD noun+action loose matcher — noun="photo" +
/// action="let s"/"take" — firing a real, unconfirmed shutter capture the
/// technician never asked for). Restricted to genuine shutter/confirm
/// words ONLY, with no noun requirement at all — every one of these is
/// unambiguous within capture_photo's own guarded context (only checked
/// while [_ScreenTask.cameraLive] is genuinely showing) — and an explicit,
/// visible veto for open_camera's own "take A photo"/"take A picture"
/// phrasing (the indefinite article — distinct from "take THE photo"/
/// "take photo" already in [_capturePhotoIndicatorPhrases] above, which
/// stay exactly as they are), so restating the ORIGINAL open-camera
/// request can never accidentally fire the shutter again, no matter how
/// this matcher evolves later.
bool _looksLikeCapturePhotoConfirmation(String paddedText) {
  const openCameraOnlyPhrases = [
    'take a photo',
    'take a picture',
    'let s take a photo',
    'let s take a picture',
  ];
  // P0 FIX: [paddedText] arrives STEMMED (see
  // [_TranscriptTrigger.extraMatcher]), so every literal here is stemmed
  // too. This makes the open_camera veto STRONGER, not weaker — "let's be
  // taking a photo" now vetoes exactly like "let's take a photo" already
  // did, instead of slipping past into a real, unconfirmed shutter.
  for (final phrase in openCameraOnlyPhrases) {
    if (paddedText.contains(' ${stemTriggerPhrase(phrase)} ')) return false;
  }
  // The same negation veto the phrase-list path applies (see
  // `trigger_phrase_matcher.dart`): "no, don't capture it" must never fire
  // a real shutter just because the word "capture" is in it.
  const shutterConfirmWords = ['capture', 'snap', 'take it', 'confirm', 'keep it'];
  for (final word in shutterConfirmWords) {
    if (!paddedText.contains(' ${stemTriggerPhrase(word)} ')) continue;
    if (triggerPhraseIsNegated(paddedText, word)) {
      debugPrint('LOOSE CAPTURE MATCH: shutter/confirm word "$word" found but NEGATED in "$paddedText" — not firing');
      continue;
    }
    debugPrint('LOOSE CAPTURE MATCH: shutter/confirm word "$word" matched in "$paddedText"');
    return true;
  }
  // P0 FIX (CONFIRMED via flutter_run_log_new.txt, builds #61 and #65):
  // bare "ready" and "go ahead" used to be plain shutterConfirmWords/phrase-
  // list entries, matching as a substring inside ANY sentence containing
  // them — including Gemini's own coaching phrases ("...when you're
  // ready", "go ahead and take another one...", "The camera's actually
  // open now — go ahead when you're ready.") and their mic-echoed,
  // ASR-drifted transcriptions. Both only count now when one of them is
  // (up to a couple of short filler words) essentially the WHOLE
  // utterance — a technician actually saying "ready"/"go ahead" — not a
  // word or two buried inside a much longer sentence. Checked against the
  // ORIGINAL (untrimmed-to-just-letters) word count so "I'm ready"/"yeah
  // go ahead" still count as short even though the apostrophe/comma add a
  // token.
  final words = paddedText.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.length <= 3) {
    if (words.contains('ready')) {
      debugPrint('LOOSE CAPTURE MATCH: standalone "ready" utterance ("$paddedText")');
      return true;
    }
    if (paddedText.contains(' go ahead ')) {
      debugPrint('LOOSE CAPTURE MATCH: standalone "go ahead" utterance ("$paddedText")');
      return true;
    }
  }
  return false;
}

/// Trade/how-to question cues — deliberately NOT a generic "any question"
/// detector (that would also fire on THIS-job questions that
/// get_job_details/get_job_timeline_answer own instead — see the system
/// instruction). A false positive here only costs an extra read-only
/// knowledge-base lookup.
const List<String> _getKbAnswerIndicatorPhrases = [
  'how do i',
  'how can i',
  'why is',
  'why does',
  'why would',
  'what causes',
  'whats wrong with',
  'what should i do about',
  'how to fix',
  'is it normal for',
  'whats the best way to',
];

/// PART F — see
/// [_GeminiLiveTestScreenState._maybeFallBackToKbAnswerCatchAll]'s doc
/// comment: a short, closed set of common conversational acknowledgments
/// excluded from that universal KB catch-all, so a bare "okay"/"thanks"
/// never triggers an unnecessary backend lookup and boundary decline.
const List<String> _nonInformationalFillerPhrases = [
  'okay',
  'ok',
  'yes',
  'yeah',
  'yep',
  'no',
  'nope',
  'sure',
  'thanks',
  'thank you',
  'great',
  'good',
  'got it',
  'sounds good',
  'alright',
  'all right',
  'cool',
  'nice',
];

/// PART F item 4 — the boundary statement Gemini speaks (via the same
/// constrained [_GeminiLiveTestScreenState._informGeminiToSpeakVerbatim]
/// instruction as every other canned response) when the KB catch-all
/// finds nothing: worded as a scope/boundary statement ("I can only help
/// with things related to this job") rather than the KB's own raw
/// "information not available" decline, since this path is specifically
/// for an utterance that never matched ANY known pattern at all — closer
/// to genuinely off-topic ("who is the president of India") than to a
/// real, on-topic trade question the KB just doesn't happen to cover.
///
/// Replaced (KB GATE change): the KB fallback now only runs on Job Detail,
/// and a true KB miss there — from the catch-all, the early phrase match,
/// or a Gemini-initiated call alike — says plainly that the knowledge base
/// has no answer, instead of the scope/boundary wording or the backend's
/// own raw decline. Found answers are unaffected.
const String _kbNoAnswerText = "I don't have an answer for that in the knowledge base.";

/// P0 TRUST FIX (CONFIRMED, twice in ONE real session): Gemini's free-text
/// response path narrated photo outcomes that never happened — "It's
/// captured." and, later, "Both taken. Anything else you need help with?"
/// in a session where `capture_photo` never once succeeded.
///
/// The primary fix is architectural and lives in [_systemInstruction] /
/// [_systemInstructionReminder]: completed-action vocabulary is reserved
/// for the deterministic constrained-instruction path
/// ([_GeminiLiveTestScreenState._informGeminiToSpeakVerbatim]), which only
/// ever runs after a real function actually returned success. The runtime
/// backstop behind that instruction is
/// [_GeminiLiveTestScreenState._auditGeminiCompletionClaim], which detects
/// claims via `completion_claim_detector.dart` — split out into its own
/// file, with its own regression tests, for the same reason
/// `photo_decision_classifier.dart` was.
///
/// How long after a genuine success a completed-action claim stays
/// licensed. Generous on purpose — the point is to catch claims with NO
/// corresponding success at all (the confirmed bug), not to police a
/// technician taking a while to answer a follow-up question after a real
/// capture.
const Duration _photoCompletionClaimWindow = Duration(seconds: 60);

/// Minimum spacing between spoken corrections, so a correction can never
/// feed itself into a loop if a future edit accidentally gives the
/// correction text claim vocabulary of its own.
const Duration _photoCompletionClaimCorrectionDebounce = Duration(seconds: 20);

/// Spoken through the SAME constrained verbatim path as every other canned
/// line. Deliberately contains NONE of the vocabulary in
/// [photoCompletionClaimPhrases] — it must be impossible for this
/// correction to trip the very audit that produced it — and deliberately
/// does not coach a phrase back at the technician, since Gemini's own
/// scripted phrases echoing off the speaker into the mic is a separate,
/// already-confirmed failure mode (see [_looksLikeGeminiEcho]).
const String _photoCompletionClaimCorrectionText =
    "Sorry, I misspoke — that hasn't actually happened yet. Tell me when you're ready and I'll do it.";

/// PART L item 1 (CONFIRMED via 4127d46d-flutter_run_log.txt: "I see you
/// good egg." — STT's mangled transcription of what was clearly meant to be
/// a change-orders request — has no usable keywords at all no matter how
/// loose the matching gets; that's a genuine speech-recognition failure,
/// not something pattern-matching can fix). Spoken ONLY by
/// [_GeminiLiveTestScreenState._maybeArmPreemptiveMuteSafetyTimeout]'s own
/// safety-net timeout — deliberately DIFFERENT from
/// [_kbNoAnswerText] (spoken when the KB catch-all genuinely
/// ran and had nothing to say, e.g. a real off-topic question like "who is
/// the president of India"): THIS case is "I couldn't even tell what you
/// said," not "I understood you and it's out of scope," so it invites a
/// retry with concrete examples instead of flatly declining. (The actual
/// wording now rotates through [_unrecognizedUtteranceReplies].)

/// ISSUE 2 (CONFIRMED via fbd877f0-flutter_run_log.txt: "एक फोटो" —
/// Devanagari script — appeared as a real `inputTranscription` chunk mid-
/// session despite the setup message's `inputAudioTranscription.
/// languageCodes: ['en-US']`). Confirmed against the current Live API
/// reference (`ai.google.dev/api/live`, `AudioTranscriptionConfig`):
/// `languageCodes` is documented as a HINT ("providing hints about the
/// languages present in the audio"), not a hard constraint — omitted or
/// not, the server can still auto-detect/switch script mid-session, and
/// there is no stricter locking parameter exposed by this API today. Every
/// trigger's own matcher in this file strips non-`[a-z ]` characters during
/// normalization (see [_TranscriptTrigger.matches] and every
/// `_looksLikeXRequest`), which means non-Latin-script text doesn't fail to
/// match so much as silently vanish into an empty/whitespace string first —
/// no matter how loose a future matcher gets, it can never recover from
/// that. Checked on every raw `inputTranscription` chunk, BEFORE any
/// normalization/trigger logic sees it, so this is caught explicitly
/// instead of silently discarded as an empty match.
///
/// A simple Unicode-range presence check, deliberately not a full
/// language/script classifier — ASCII English text can never contain any
/// of these codepoints, so a single hit is already unambiguous signal, per
/// this project's own logs having shown Hindi (Devanagari), Korean
/// (Hangul), and Japanese (Hiragana/Katakana/CJK) script at various points.
/// Cyrillic, Arabic, and Thai ranges are included defensively even though
/// not yet observed in a real log. Spanish is deliberately OUT of scope —
/// it uses the same Latin script as English (just different words), which
/// no Unicode range check can ever distinguish; that's a genuinely
/// different (language, not script) problem.
bool _looksLikeNonLatinScriptTranscription(String text) {
  for (final rune in text.runes) {
    if (_isNonLatinScriptRune(rune)) return true;
  }
  return false;
}

/// Common English function words — a chunk of 4+ words containing none of
/// these (6+ words) is very unlikely to be English speech (see
/// [_looksLikeNonEnglishLatinTranscription]).
const Set<String> _commonEnglishWords = {
  'the', 'a', 'an', 'and', 'or', 'to', 'of', 'in', 'on', 'for', 'is', 'it', 'i', 'you', 'we', 'me', 'my',
  'this', 'that', 'can', 'do', 'be', 'are', 'was', 'what', 'how', 'show', 'take', 'photo', 'picture', 'yes',
  'no', 'okay', 'with', 'at', 'have', 'let', 'go', 'see', 'want', 'need', 'hear', 'tell', 'about', 'job',
  'change', 'orders', 'order', 'estimate', 'invoice', 'history', 'last', 'camera', 'open', 'capture', 'ready',
  'confirm', 'back', 'please', 'now', 'who', 'why', 'when', 'where', 'which', 'here', 'there', 'not', 'so',
};

/// Widened drift check (build #38: "can you hear me" transcribed as Spanish
/// "¿Qué tal me veo?" — Latin script, so [_looksLikeNonLatinScriptTranscription]
/// can't see it). Two cheap signals: Spanish inverted punctuation or any
/// accented Latin letters (U+00C0–U+024F; English speech transcripts
/// essentially never contain them), or a 4+ word chunk with zero common
/// English words (6+ words, to keep partial command chunks safe).
/// Deliberately conservative — a false positive costs one
/// "didn't catch that" retry.
bool _looksLikeNonEnglishLatinTranscription(String text) {
  for (final rune in text.runes) {
    if (rune == 0xBF || rune == 0xA1) return true; // ¿ ¡
    if (rune >= 0xC0 && rune <= 0x24F && rune != 0xD7 && rune != 0xF7) return true;
  }
  final words = text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.length >= 6 && !words.any(_commonEnglishWords.contains)) return true;
  return false;
}

bool _isNonLatinScriptRune(int rune) {
  // Devanagari (Hindi, Marathi, etc.)
  if (rune >= 0x0900 && rune <= 0x097F) return true;
  // Hangul Jamo, Compatibility Jamo, and precomposed syllables (Korean)
  if (rune >= 0x1100 && rune <= 0x11FF) return true;
  if (rune >= 0x3130 && rune <= 0x318F) return true;
  if (rune >= 0xAC00 && rune <= 0xD7A3) return true;
  // Hiragana + Katakana (Japanese)
  if (rune >= 0x3040 && rune <= 0x30FF) return true;
  // CJK Unified Ideographs (Chinese/Japanese/Korean kanji/hanja)
  if (rune >= 0x4E00 && rune <= 0x9FFF) return true;
  // Cyrillic (Russian and others)
  if (rune >= 0x0400 && rune <= 0x04FF) return true;
  // Arabic
  if (rune >= 0x0600 && rune <= 0x06FF) return true;
  // Thai
  if (rune >= 0x0E00 && rune <= 0x0E7F) return true;
  return false;
}

/// The literal strings the KB backend (`ask-troubleshooting/index.js`'s
/// own "not available" decline) and its Dart caller's own missing-answer
/// fallback (`fetchTroubleshootingAnswer` in `job_voice_commands.dart`)
/// return when there's NO confident match. `dispatchGeminiFunctionCall`'s
/// `get_kb_answer` result only ever carries the answer TEXT, never the
/// backend's own `source` field, so comparing against these known
/// literals is the only way this file can tell "real KB answer" apart
/// from "no match" without changing that shared, multi-caller function.
/// FRAGILE, deliberately, not silently assumed robust: if either backend
/// string ever changes, this stops recognizing a no-match and speaks the
/// KB's own raw decline instead of [_kbNoAnswerText] — a
/// wording regression, not a crash.
const List<String> _kbNoMatchLiteralAnswers = [
  'Sorry, that information is not available in the Knowledge Base.',
  "Sorry, I couldn't find an answer.",
];

const List<String> _siteConditionIndicatorPhrases = [
  'note that',
  'make a note',
  'log that',
  'flag that',
  'for the record',
];

const List<String> _getLastPhotoIndicatorPhrases = [
  'show me the last photo',
  'show the last photo',
  'show me the last picture',
  'show the last picture',
  'what did we last take a photo of',
  'what was the last photo',
  'see the last photo',
  'see the last picture',
  'pull up the last photo',
];

/// get_current_screen is local UI state, not a `dispatchGeminiFunctionCall`
/// route (see [_GeminiLiveTestScreenState._handleToolCall]'s `end_session`-
/// style special case) — so unlike every phrase list above, this one is
/// consumed by a hand-rolled detector
/// ([_GeminiLiveTestScreenState._maybeTriggerGetCurrentScreen]), not the
/// shared [_TranscriptTrigger] engine.
const List<String> _getCurrentScreenIndicatorPhrases = [
  'where are we',
  'where am i',
  'what screen is this',
  'what screen am i on',
  'which screen are we on',
  'which page are we on',
  'what page is this',
  // CONFIRMED miss (flutter_run_log 97579c46): "Can you tell me which
  // screen we are" — declarative word order matched none of the above.
  'which screen we are on',
  'which screen we are',
  'what screen we are on',
  'what screen are we on',
  'which screen is this',
  'which page we are on',
];

/// PART A item 3 (client-confirmed regression: Gemini free-texted a generic
/// "I can help with a lot of things" answer to "What kind of help do you
/// provide?" instead of describing its real capabilities): meta/capability
/// question cues — same hand-rolled, bypass-Gemini-entirely pattern as
/// [_getCurrentScreenIndicatorPhrases]
/// ([_GeminiLiveTestScreenState._maybeTriggerMetaCapability]), not the
/// shared [_TranscriptTrigger] engine, because the answer here is a FIXED,
/// hardcoded description of real capabilities (see
/// [_metaCapabilityCannedResponse]) that must never depend on Gemini's own
/// judgment — this guarantees correctness regardless of whether the
/// `toolConfig`/`mode: ANY` setup-message field above is actually honored
/// by the server.
const List<String> _metaCapabilityIndicatorPhrases = [
  'what can you do',
  'what can you help me with',
  'what can you help with',
  'what kind of help',
  'what kind of help do you provide',
  'how can you help',
  'how can you help me',
  'what are you able to do',
  'what are your capabilities',
  'what do you do',
];

/// PART G item 2: a fixed exact-phrase list can't anticipate a garbled ASR
/// word in the middle of an otherwise-clear question shape (e.g. "help"
/// mis-transcribed as something else) — checked in ADDITION to
/// [_metaCapabilityIndicatorPhrases] (never a replacement), by
/// [_GeminiLiveTestScreenState._looksLikeMetaCapabilityRequest]. Matches the
/// general SHAPE "what kind of ___ do you provide/offer/help[ with]" with a
/// one-word wildcard in the middle — so "what kind of help do you provide"
/// still matches even if ASR renders the middle word as something else
/// entirely, as long as the surrounding shape survives.
final RegExp _metaCapabilityWildcardShape1 = RegExp(r'what kind of \w+ do you (provide|offer|help)');

/// See [_metaCapabilityWildcardShape1]'s doc comment — the same treatment
/// for "what can you help me with", with the middle verb (normally "help")
/// as the one-word wildcard instead.
final RegExp _metaCapabilityWildcardShape2 = RegExp(r'what can you \w+ (me )?with');

/// See [_metaCapabilityIndicatorPhrases]'s doc comment — the fixed text
/// spoken verbatim (never paraphrased, same "speak this word for word" rule
/// as [_GeminiLiveTestScreenState._finalizeUtteranceEndDeterministicTriggers]'s
/// get_kb_answer instruction) whenever that trigger fires. Names the SAME
/// real capabilities the system instruction itself lists — job details, job
/// timeline, the last photo, knowledge-base questions, on-screen
/// navigation, and taking a new photo — in plain, spoken-friendly terms.
const String _metaCapabilityCannedResponse =
    "I can answer questions about this job's details or timeline, show you the last photo taken, answer "
    'trade and troubleshooting questions from the knowledge base, take a new photo, and take you to the '
    "estimate, change orders, invoice, or job history — just tell me what you'd like.";

/// Debounce for the deterministic meta/capability trigger — same role as
/// [_getCurrentScreenDebounce].
const Duration _metaCapabilityDebounce = Duration(seconds: 5);

/// PART D (client-confirmed regression: plain greetings/check-ins like
/// "Can you hear me?"/"Hello" were being caught by the PART C preemptive
/// question-mute check — starting with "can "/containing "?" was enough —
/// producing a 20s dead-air wait followed by a nonsensical "check with
/// your supervisor" decline on every single greeting): small-talk/
/// presence-check cues, checked and consumed BEFORE
/// [_GeminiLiveTestScreenState._maybeMuteImmediatelyForSuspectedQuestion]
/// ever runs — see [_GeminiLiveTestScreenState._maybeTriggerAcknowledgePresence].
/// `'can you bear me'` is not a typo: CONFIRMED real ASR mis-transcription
/// of "hear" for this exact phrase in a live session log, so it's included
/// defensively the same way this file already handles other observed
/// mis-transcriptions (e.g. the apostrophe-normalization entries on
/// `_getJobDetailsIndicatorPhrases`).
const List<String> _acknowledgePresenceIndicatorPhrases = [
  'can you hear me',
  'can you bear me',
  'can you hear',
  'do you hear me',
  'did you hear me',
  'hear me',
  'are you there',
  'are you listening',
  'are you still there',
  'is anyone there',
  'anyone there',
  'you there',
  'you with me',
  'testing',
  'hello',
  'hi',
  'hey',
];

/// See [_acknowledgePresenceIndicatorPhrases]'s doc comment — spoken
/// verbatim (never paraphrased), same "speak this word for word" pattern
/// as [_metaCapabilityCannedResponse].
const List<String> _acknowledgePresenceResponses = [
  "Yes, I can hear you. What do you need on the job?",
  "I'm here, loud and clear. What can I do for you?",
  "Yep, I'm listening. What's next?",
  "I hear you. Want the estimate, the change orders, or a photo?",
];

int _presenceReplyCursor = 0;
int _retryReplyCursor = 0;

/// Rotates through the replies so repeated presence checks don't get the
/// identical sentence every time.
String _nextAcknowledgePresenceResponse() =>
    _acknowledgePresenceResponses[_presenceReplyCursor++ % _acknowledgePresenceResponses.length];

/// Natural-sounding replacement for a single fixed "didn't catch that" line —
/// used ONLY when nothing could be routed (garbled/drifted transcription).
/// Off-topic refusal ([_kbNoAnswerText]) is unchanged.
const List<String> _unrecognizedUtteranceReplies = [
  "I heard you say something, but I'm not sure what you need — want me to show the estimate, change orders, or take a photo?",
  "Sorry, that didn't come through clearly. Could you say it again? I can show the estimate, change orders, or take a photo.",
  "I missed that one. Try me again — for example, show the job history or take a photo.",
];

String _nextUnrecognizedUtteranceReply() =>
    _unrecognizedUtteranceReplies[_retryReplyCursor++ % _unrecognizedUtteranceReplies.length];

/// CONFIRMED gap: get_job_timeline_answer had NO deterministic backstop at
/// all before this — never built during the earlier "extend to every
/// function" pass, unlike its siblings. Literal phrase entries cover common
/// well-formed phrasings; [_looksLikeArrivalTimeQuestion] (used as this
/// trigger's `extraMatcher`) additionally catches grammatically mangled ASR
/// output like "when did we get arrived" that no fixed phrase list could
/// reasonably enumerate.
const List<String> _getJobTimelineAnswerIndicatorPhrases = [
  'when did we arrive',
  'when did we get here',
  'when did i arrive',
  'what time did we arrive',
  'when did we start',
  'what has been done',
  'what has happened on this job',
  'when did i take that photo',
];

/// See [_getJobTimelineAnswerIndicatorPhrases]'s doc comment — a looser,
/// word-stem check for "when...arrive[d]" in any grammatical form, since
/// real ASR output for this question is unpredictable ("when did we get
/// arrived" was the CONFIRMED-missed real phrase). Requires "when" so an
/// unrelated sentence that merely mentions arriving doesn't false-positive.
bool _looksLikeArrivalTimeQuestion(String normalizedPaddedText) {
  return normalizedPaddedText.contains(' when ') && RegExp(r'\barriv').hasMatch(normalizedPaddedText);
}

/// FIX 2: how long after any `view_*` function succeeds an UNPROMPTED
/// `go_back` call is held back — see
/// [_GeminiLiveTestScreenState._isGoBackInCooldown]. Guards against Gemini
/// navigating the technician straight back out of a screen it was just
/// asked to open, with no actual "go back" request from the technician in
/// between. Lifted immediately (regardless of this duration) the moment an
/// [_intentionalGoBackPhrases] match is heard — this is a cooldown on
/// UNPROMPTED go_back calls, never a delay on a genuinely requested one.
const Duration _goBackCooldownDuration = Duration(seconds: 3);

/// Debounce for the deterministic camera-flow go_back trigger (see
/// [_GeminiLiveTestScreenState._maybeDetectIntentionalGoBack]'s camera-flow
/// branch) — if Gemini (or a previous deterministic firing) already called
/// go_back more recently than this, the trigger assumes it's already being
/// handled and stays out of the way. Same role as [_viewEstimateDebounce],
/// applied to go_back activity instead of view_estimate activity.
const Duration _goBackTriggerDebounce = Duration(seconds: 5);

/// See [_goBackCooldownDuration]'s doc comment — matches the system
/// instruction's own go_back examples ("take me back"/"go home") plus a
/// couple of close variants. Checked the same whole-word/phrase way as
/// [_viewEstimateIndicatorPhrases] (see
/// [_GeminiLiveTestScreenState._looksLikeIntentionalGoBack]).
const List<String> _intentionalGoBackPhrases = [
  'go back',
  'take me back',
  'go home',
  'back to home',
  'back to the job',
  'back to job details',
  'return to the job',
];

/// Debounce for the deterministic photo-decision trigger — if Gemini
/// already called confirm_photo_upload or retake_photo more recently than
/// this, the trigger assumes it's already being handled and stays out of
/// the way. Same role as [_viewEstimateDebounce]/[_goBackTriggerDebounce].
const Duration _photoDecisionDebounce = Duration(seconds: 5);

/// Original Day 2 spec: an active session with no detected "turn"
/// (technician speech or a function call) for this long gets a spoken
/// warning — 10 seconds before [_inactivityTimeoutDelay] actually closes
/// the session. See [_GeminiLiveTestScreenState._resetInactivityTimer].
const Duration _inactivityWarningDelay = Duration(seconds: 50);

/// Original Day 2 spec: an active session with no detected "turn" for this
/// long closes automatically — the same clean [_stopTest] close as the
/// technician saying "Loop Off"/"FieldLoop stop". See
/// [_GeminiLiveTestScreenState._fireInactivityTimeout].
const Duration _inactivityTimeoutDelay = Duration(seconds: 60);

/// Fixed wording for the [_inactivityWarningDelay] spoken warning — sent to
/// Gemini as an instruction to say verbatim over its OWN Live conversation
/// turn (see [_GeminiLiveTestScreenState._fireInactivityWarning]), never
/// synthesized by a separate on-device TTS: a second voice pipeline talking
/// over the live Gemini session risks real mic-lock contention with the
/// active session.
const String _inactivityWarningText =
    "Still there? I'll close this session in a few seconds if I don't hear anything.";

/// FIX 2 (camera flow reliability): `open_camera` has been observed taking
/// anywhere from ~2.2s to 27-71s+ on a real device (see the reliability
/// audit TimelineTask spans in `GeminiCameraSession.open`,
/// `gemini_function_dispatcher.dart`) — camera HAL init time genuinely
/// varies and is not fully eliminated even after the overlap-rejection fix.
/// Rather than leaving the technician silently staring at a stuck screen,
/// [_GeminiLiveTestScreenState._dispatchWithOpenCameraSafeguards] speaks
/// [_openCameraAckText] at [_openCameraAckDelay] if it's still not done, so
/// it doesn't feel broken.
///
/// P0 FIX (CONFIRMED via flutter_run_log_new.txt, build #65): a SECOND
/// threshold used to exist here too — a 15s hard timeout that gave up
/// WAITING on the real dispatch (via `Future.timeout`) and told Gemini to
/// tell the technician the camera open had failed, while the real
/// `CameraController.initialize()` call kept running, unabortable, in the
/// background. Camera-open time is NOT reliably under 15s (this exact run
/// measured ~20.1s), so the timeout routinely fired while the real open was
/// still genuinely in progress — the technician heard "opening the camera
/// timed out — try again," then 5 seconds later heard "the camera's
/// actually open now," two directly contradictory messages about the same
/// action. Removed rather than fixed in place: the `camera` plugin's public
/// API has no way to actually cancel/abort an in-flight `initialize()` call
/// (Dart Futures aren't preemptible, and there's no cancellation token to
/// pass it), so the ONLY two honest options were "stop lying about having
/// timed out" (this) or "make the timeout genuinely stop the operation it
/// claims to have given up on" (not achievable without patching the
/// plugin) — a timeout that doesn't actually stop the thing it timed out is
/// worse than no timeout at all. `open_camera` now simply awaits the real
/// call, exactly like every other camera-flow function already does.
final Duration _openCameraAckDelay = pendingCallFillers['open_camera']!.delay;

/// See [_openCameraAckDelay]'s doc comment. Sent to Gemini as a
/// `clientContent` "say exactly this" instruction — same mechanism as
/// [_inactivityWarningText]/[_GeminiLiveTestScreenState._fireInactivityWarning],
/// not a separate on-device TTS call, for the same mic-lock-contention
/// reasoning given there.
final String _openCameraAckText = pendingCallFillers['open_camera']!.text;

class _GeminiLiveTestScreenState extends ConsumerState<GeminiLiveTestScreen> {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  bool _recorderOpen = false;
  StreamController<Uint8List>? _micStreamController;

  WebSocketChannel? _channel;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription? _wsSub;
  Timer? _silenceTimer;

  /// Original Day 2 spec — silence auto-timeout (see
  /// [_inactivityWarningDelay]/[_inactivityTimeoutDelay] for the current
  /// durations). Both started/reset
  /// together by [_resetInactivityTimer] the moment the session becomes
  /// active ([_startMicStreaming]) and on every detected turn (technician
  /// speech in [_trackSpeechLevel], a function call in [_onServerMessage]).
  /// Separate from [_silenceTimer] above, which only measures in-turn
  /// latency and has nothing to do with ending the session.
  Timer? _inactivityWarningTimer;
  Timer? _inactivityTimeoutTimer;

  /// Captured in [_startTest] (NOT read fresh in [_teardown]) — same
  /// capture-early-for-safe-dispose-use reasoning as `JobDetailScreen`'s
  /// `SafeRefDisposal` (`_voiceService` there): [_teardown] runs from
  /// [dispose], and by the time a fire-and-forget async call inside it
  /// resumes, this widget's Element can already be detached, making a
  /// fresh `ref.read()` unsafe. `null` until a session has actually paused
  /// FieldLoop (see [_startTest]).
  GlobalVoiceService? _pausedVoiceService;

  /// PART F (reverted PART E's flutter_tts switch per explicit instruction
  /// — Gemini's own voice, via [_speechConfig]'s prebuilt voice, is used
  /// for every spoken response again, including canned/boundary text; see
  /// [_informGeminiToSpeakVerbatim]). True once the server has signaled
  /// the current turn is done (either `turnComplete` or `interrupted`) —
  /// outgoing audio only resumes once this AND playback of everything
  /// already queued have both finished, so a still-playing tail of the
  /// response can't be picked up by the mic either.
  bool _turnComplete = true;

  /// Holds the open camera/captured-file state shared across the
  /// open_camera/capture_photo/confirm_photo_upload/retake_photo function
  /// group — see [GeminiCameraSession]'s own doc comment for why that
  /// state has to survive between separate Gemini function calls. One
  /// instance per session (this State object); disposed in [_teardown].
  final GeminiCameraSession _cameraSession = GeminiCameraSession();

  /// P2 — whether a camera-opening function (`open_camera`/`retake_photo`)
  /// has genuinely RETURNED SUCCESS, as opposed to merely having produced a
  /// preview texture. [_screenTask] reaching [_ScreenTask.cameraLive] now
  /// means "there is something to look at" and can happen many seconds
  /// earlier; this means "the camera is fully initialized and armed", which
  /// is what `capture_photo`'s guard actually requires. Set and cleared
  /// only in [_updateScreenTaskForToolCall], alongside [_screenTask] itself.
  bool _cameraOpenConfirmed = false;

  /// When the current "Opening the camera…" surface went up (reset on a
  /// retry) — drives the caption escalation and the Retry/Cancel offer in
  /// [_buildCameraTaskBody]. [_cameraOpeningTicker] just rebuilds once a
  /// second while that surface is showing, so the caption can change.
  DateTime? _cameraOpeningStartedAt;
  Timer? _cameraOpeningTicker;
  bool _cameraOpenIsRetry = false;

  /// See [_CameraOpenCancelIntent]; consumed when the cancelled dispatch
  /// returns.
  _CameraOpenCancelIntent? _cameraOpenCancelIntent;

  void _startCameraOpeningTicker() {
    _cameraOpeningStartedAt ??= DateTime.now();
    _cameraOpeningTicker?.cancel();
    _cameraOpeningTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _screenTask != _ScreenTask.cameraOpening) {
        timer.cancel();
        _cameraOpeningTicker = null;
        _cameraOpeningStartedAt = null;
        _cameraOpenIsRetry = false;
        return;
      }
      setState(() {});
    });
  }

  /// Retry/Cancel on a slow open — see [GeminiCameraSession.cancelPendingOpen]
  /// for why neither can abort the native call itself.
  void _onSlowCameraOpenAction({required bool retry}) {
    final intent = retry ? _CameraOpenCancelIntent.retry : _CameraOpenCancelIntent.user;
    if (!_cameraSession.cancelPendingOpen()) {
      _log_('CAMERA OPEN: ${intent.name} tapped but no open is pending any more — ignoring');
      return;
    }
    _cameraOpenCancelIntent = intent;
    _log_('CAMERA OPEN: technician tapped ${retry ? 'RETRY' : 'CANCEL'} on a slow open');
  }

  Future<void> _startCameraOpenRetry() async {
    final jobId = widget.jobId;
    if (!mounted || jobId == null) return;
    _log_('CAMERA OPEN: retrying — the new open queues behind the abandoned one and starts once the camera is free');
    await _executeDeterministic(
      _deterministicTriggers['open_camera']!,
      args: {'job_id': jobId},
      buildSpokenText: (result) => _defaultDeterministicSpokenText(
        name: 'open_camera',
        humanAction: 'take a photo',
        appAction: 'opened the camera for you',
        result: result,
      ),
    );
  }

  // ===========================================================================
  // P1 — camera-open latency, speculative prewarm
  // CONFIRMED, three rounds running: `native_open_still_pending` heartbeat
  // logging shows the ENTIRE open delay (5-30s across runs, 13.66s in the
  // most recent one) is 100% inside native CameraX's own
  // `controller.initialize()` — no Dart-side scheduling drift, nothing
  // reorderable within `open_camera`'s own call. Confirmed real-device
  // (SM A507FN, not an emulator — `flutter devices` lists a real model/
  // serial, never an `emulator-XXXX` id). With no further sub-step to
  // optimize, the only remaining lever is TIMING: start that same
  // expensive native call BEFORE the technician asks, so its cost overlaps
  // ordinary conversation/screen dwell time instead of blocking a real
  // request. See [_maybePrewarmCameraController].
  // ===========================================================================

  /// Whether the camera controller currently open (or opening) was started
  /// SPECULATIVELY by [_maybePrewarmCameraController], not by a genuine
  /// open_camera request yet. While true, [GeminiCameraSession
  /// .onOpenStarted]/`onPreviewAvailable`/`onOpenSettled` all suppress
  /// their usual ambient-UI transition (the technician hasn't asked for
  /// the camera — showing it would be actively confusing) while letting
  /// the REAL native work proceed normally in the background. Cleared the
  /// instant a GENUINE open_camera request is handled (see
  /// [_dispatchWithOpenCameraSafeguards]'s open_camera branch) — from that
  /// point on, every callback behaves exactly as it always has, and
  /// [GeminiCameraSession.open]'s own new "already initialized, reuse it"
  /// fast path means the technician gets the ALREADY-PAID controller
  /// immediately instead of waiting through a second real:with real cost.
  bool _cameraSpeculativelyPrewarming = false;

  /// Bounds how long a SPECULATIVE prewarm is allowed to hold the camera
  /// hardware open with nothing actually using it — cancelled the instant
  /// a real open_camera request arrives (see
  /// [_dispatchWithOpenCameraSafeguards]). If nobody ever asks for the
  /// camera this session, releases it automatically rather than holding it
  /// claimed (and drawing power, and potentially contending with some
  /// other app/screen that wants it) for the rest of a long conversation
  /// that never ends up needing a photo.
  Timer? _cameraPrewarmAutoReleaseTimer;

  /// How long a session waits after a successful speculative prewarm
  /// before releasing an unused camera. Generous — most conversations that
  /// WILL involve a photo reach that point well within this window; if
  /// not, releasing costs nothing worse than if prewarm had never
  /// happened (a later real request just re-opens from scratch, exactly
  /// as it always has).
  static const Duration _cameraPrewarmAutoReleaseDelay = Duration(seconds: 90);

  /// Starts the REAL native camera open — the actual expensive
  /// `controller.initialize()` call, not just the cheap device-enumeration
  /// [GeminiCameraSession.prewarm] already does — speculatively, the
  /// instant the voice session becomes active, rather than waiting for the
  /// technician to ask. Unconditional (not gated on any "camera intent
  /// detected" heuristic): this app's whole purpose is job-photo
  /// documentation, so the large majority of sessions plausibly involve at
  /// least one photo, and a speculative open that turns out unused is
  /// bounded and cheap (see [_cameraPrewarmAutoReleaseDelay]) — a
  /// narrower heuristic trying to guess intent from a partial transcript
  /// would only add its own false-negative risk (deciding NOT to prewarm
  /// a session that, moments later, genuinely does ask for a photo) for a
  /// benefit this bounded-cost approach already gets more reliably.
  ///
  /// Silent by design — see [_cameraSpeculativelyPrewarming]'s doc
  /// comment: nothing about this should be visible to the technician
  /// unless/until they actually ask for the camera.
  /// Measurement only — when the speculative controller.initialize() began
  /// and settled, so every wake-greeting barge-in decision can say whether
  /// the camera was initializing at that moment (see
  /// [_cameraPrewarmStateAt]).
  DateTime? _cameraPrewarmStartedAt;
  DateTime? _cameraPrewarmSettledAt;

  String _cameraPrewarmStateAt(DateTime at) {
    final started = _cameraPrewarmStartedAt;
    if (started == null || at.isBefore(started)) return 'camera prewarm not started';
    final settled = _cameraPrewarmSettledAt;
    if (settled == null || at.isBefore(settled)) {
      return 'camera prewarm INITIALIZING (${at.difference(started).inMilliseconds}ms in)';
    }
    return 'camera prewarm settled ${at.difference(settled).inMilliseconds}ms earlier';
  }

  void _maybePrewarmCameraController() {
    final jobId = widget.jobId;
    if (jobId == null) return; // Standalone mode has no job to attach a photo to.
    _cameraSpeculativelyPrewarming = true;
    _cameraPrewarmStartedAt = DateTime.now();
    _log_('CAMERA PREWARM: starting the real controller.initialize() speculatively at session start (job $jobId) — silent until a real request arrives.');
    unawaited(
      _cameraSession.open(ref, jobId).then((_) {
        _cameraPrewarmSettledAt = DateTime.now();
        if (!mounted || !_cameraSpeculativelyPrewarming) return;
        _log_(
          'CAMERA PREWARM: complete and sitting ready, unused — will auto-release in '
          '${_cameraPrewarmAutoReleaseDelay.inSeconds}s unless a real open_camera request arrives first.',
        );
        _cameraPrewarmAutoReleaseTimer?.cancel();
        _cameraPrewarmAutoReleaseTimer = Timer(_cameraPrewarmAutoReleaseDelay, () {
          _cameraPrewarmAutoReleaseTimer = null;
          if (!mounted || !_cameraSpeculativelyPrewarming) return;
          _log_('CAMERA PREWARM: never used this session — releasing the speculatively-opened camera now.');
          _cameraSpeculativelyPrewarming = false;
          unawaited(_cameraSession.dispose());
        });
      }, onError: (Object e) {
        // Already logged in detail by GeminiCameraSession's own open()
        // path and by [GeminiCameraSession.onOpenSettled] above — a failed
        // prewarm is harmless, a real request later just opens normally.
        _cameraPrewarmSettledAt = DateTime.now();
        _log_('CAMERA PREWARM: failed ($e) — harmless, a real open_camera request will simply open it itself.');
      }),
    );
  }

  /// Tracks how many view_estimate/view_change_orders/view_invoice/
  /// view_job_history screens are currently pushed on top of this ambient
  /// screen, so `go_back` can pop exactly one of THOSE instead of
  /// accidentally popping this ambient session itself — see
  /// [GeminiNavigationSession]'s own doc comment. One instance per session,
  /// same lifecycle as [_cameraSession]. `late final`, not initialized
  /// inline — its `onActiveChanged` callback needs `this` (to call
  /// `setState`), so it's constructed in [initState] instead.
  late final GeminiNavigationSession _navigationSession;

  /// Deterministic app-side START trigger for view_estimate — a strengthened
  /// tool description alone has not always been enough to make Gemini
  /// reliably call a function on a clear, unambiguous request (the same
  /// reason site_condition's description was strengthened). See
  /// [_viewEstimateIndicatorPhrases]'s doc comment. Accumulates across
  /// chunks of the SAME technician utterance, reset on the silence->speech
  /// edge in [_trackSpeechLevel].
  String _viewEstimateDetectionBuffer = '';

  /// Guards [_maybeTriggerViewEstimate] from re-evaluating the SAME
  /// utterance on every subsequent transcript chunk once it's already been
  /// resolved — reset alongside [_viewEstimateDetectionBuffer] on the next
  /// speech edge.
  bool _viewEstimateDetectionResolvedForCurrentUtterance = false;

  /// Timestamp of the most recent view_estimate call — Gemini-initiated
  /// (tracked in [_handleToolCall]) or this app's own deterministic trigger
  /// (tracked in [_maybeTriggerViewEstimate] itself, before the async
  /// dispatch call even starts). [_maybeTriggerViewEstimate] only fires when
  /// this is `null` or older than [_viewEstimateDebounce].
  DateTime? _lastViewEstimateActivityAt;

  /// CONFIRMED ghost-call bug: same role as [_viewEstimateDetectionBuffer],
  /// applied to [_getJobDetailsIndicatorPhrases]. See
  /// [_maybeTriggerGetJobDetails].
  String _getJobDetailsDetectionBuffer = '';

  /// Same role as [_viewEstimateDetectionResolvedForCurrentUtterance],
  /// applied to the get_job_details detector.
  bool _getJobDetailsDetectionResolvedForCurrentUtterance = false;

  /// Timestamp of the most recent get_job_details call — Gemini-initiated
  /// (tracked in [_handleToolCall]) or this app's own deterministic trigger
  /// (tracked in [_maybeTriggerGetJobDetails] itself, before the async
  /// dispatch call even starts). [_maybeTriggerGetJobDetails] only fires when
  /// this is `null` or older than [_getJobDetailsDebounce].
  DateTime? _lastGetJobDetailsActivityAt;

  /// Same accumulate/resolve/debounce shape as [_getJobDetailsDetectionBuffer]/
  /// [_getJobDetailsDetectionResolvedForCurrentUtterance]/
  /// [_lastGetJobDetailsActivityAt], applied to the hand-rolled
  /// get_current_screen detector ([_maybeTriggerGetCurrentScreen]) — see
  /// [_getCurrentScreenIndicatorPhrases]'s doc comment for why this one
  /// isn't in [_deterministicTriggers].
  String _getCurrentScreenDetectionBuffer = '';
  bool _getCurrentScreenDetectionResolvedForCurrentUtterance = false;
  DateTime? _lastGetCurrentScreenActivityAt;

  /// The "go to Job Details" destination trigger — see
  /// [_maybeTriggerJobDetailsDestination]. The buffer deliberately survives
  /// a generic go_back firing earlier in the same utterance ("Take me back"
  /// | "to the job screen." in two chunks), so the destination can still be
  /// read once the rest arrives; it resets per utterance.
  String _jobDetailsDestinationBuffer = '';
  bool _jobDetailsDestinationResolvedForCurrentUtterance = false;

  /// At most one destination firing per utterance (reset only by a new
  /// utterance, never by a success's buffer clear).
  bool _jobDetailsDestinationFiredThisUtterance = false;

  /// Whether the generic go_back fired for the current utterance — the one
  /// commitment the destination trigger may still override.
  bool _goBackFiredThisUtterance = false;

  /// PART A item 3: same accumulate/resolve/debounce shape as
  /// [_getCurrentScreenDetectionBuffer]/
  /// [_getCurrentScreenDetectionResolvedForCurrentUtterance]/
  /// [_lastGetCurrentScreenActivityAt], applied to the hand-rolled
  /// meta/capability detector ([_maybeTriggerMetaCapability]) — see
  /// [_metaCapabilityIndicatorPhrases]'s doc comment for why this is
  /// hand-rolled rather than in [_deterministicTriggers].
  String _metaCapabilityDetectionBuffer = '';
  bool _metaCapabilityDetectionResolvedForCurrentUtterance = false;
  DateTime? _lastMetaCapabilityActivityAt;

  /// PART D item 1: same accumulate/resolve shape as
  /// [_metaCapabilityDetectionBuffer] — see
  /// [_GeminiLiveTestScreenState._maybeTriggerAcknowledgePresence].
  /// Deliberately NO debounce timer (unlike every other hand-rolled
  /// trigger): a technician saying "can you hear me" two or three times in
  /// a row is normal, expected conversation, and each one must get its own
  /// instant response — only [_acknowledgePresenceResolvedForCurrentUtterance]
  /// (per-utterance, not cross-utterance) guards against firing twice for
  /// the SAME utterance.
  String _acknowledgePresenceDetectionBuffer = '';
  bool _acknowledgePresenceResolvedForCurrentUtterance = false;

  /// PART F items 4-5 / PART I item 1: true from the instant
  /// [_muteImmediatelyOnFirstChunkOfUtterance] preemptively mutes Gemini's
  /// audio on this utterance's very first chunk, unconditionally, until
  /// EITHER a known trigger resolves it (any OTHER call
  /// to [_interruptGeminiForDeterministicTrigger] clears this
  /// automatically — see that method's graduation logic) or
  /// [_maybeFallBackToKbAnswerCatchAll] resolves it (a real KB answer, the
  /// boundary decline, or — for a bare filler acknowledgment — a silent
  /// clear with nothing spoken at all). While `true`,
  /// [_onResponseAudioChunk] drops every response chunk regardless of
  /// [_suppressResponseAudioForDeterministic] — a SEPARATE gate because it
  /// covers the window BEFORE any real answer/informing turn exists yet,
  /// which that flag's own 1.2s safety-unmute would wrongly cut short
  /// (a real get_kb_answer backend call has been observed taking up to
  /// ~13s).
  bool _preemptiveDefaultMuteActive = false;

  /// Last-resort net if NOTHING ever clears [_preemptiveDefaultMuteActive]
  /// — declines explicitly rather than leaving the session silently muted
  /// forever. 5s (not 20s): a prior round found a 20s version of this
  /// exact timer becoming the PRIMARY resolution path instead of a rare
  /// last resort whenever the normal end-of-utterance path stalled, which
  /// is 20 straight seconds of dead air on every affected turn — 5s kept
  /// even the worst case tolerable.
  ///
  /// PART L item 1 (CONFIRMED via 4127d46d-flutter_run_log.txt: "I see you
  /// good egg." — a genuinely unrecognizable STT mangling — sat through the
  /// full 5s before anything was said): shortened further to 2s so a truly
  /// garbled utterance gets a fast, inviting retry instead of a long dead
  /// pause. Safe to shorten now specifically because
  /// [_maybeFallBackToKbAnswerCatchAll] cancels this timer itself the
  /// instant it actually dispatches a real get_kb_answer call (a genuine
  /// resolution attempt, which can take up to ~13s) — so this 2s window
  /// only ever applies to the case NOTHING, not even the KB catch-all,
  /// found anything to do with the utterance at all. Speaks
  /// [_unrecognizedUtteranceRetryText], not [_kbNoAnswerText]
  /// — see that constant's doc comment for why the two cases need different
  /// wording.
  Timer? _preemptiveDefaultMuteSafetyTimer;
  static const Duration _preemptiveDefaultMuteSafetyDelay = Duration(seconds: 2);

  /// ISSUE 1(b) (CONFIRMED via fbd877f0-flutter_run_log.txt): once
  /// [_maybeFallBackToKbAnswerCatchAll] actually dispatches a real
  /// get_kb_answer call, [_preemptiveDefaultMuteSafetyTimer] defers
  /// indefinitely (see [_armPreemptiveDefaultMuteSafetyTimer]) rather than
  /// ever speaking the wrong "didn't catch that" line over a real answer
  /// still on its way — but that indefinite defer has no ceiling of its
  /// own to prove/bound it. This is that ceiling: a SEPARATE, purely
  /// diagnostic timer, longer than [_preemptiveDefaultMuteSafetyDelay] and
  /// the near-0ms routing decision in (a), armed the instant a real
  /// get_kb_answer dispatch starts. If it fires, the KB call is still
  /// genuinely pending — logged so that's visible, but deliberately NEVER
  /// speaks a fallback message itself (that would risk exactly the
  /// wrong-message bug this issue fixes); the real answer, whenever it
  /// arrives, is still what gets spoken.
  Timer? _kbAnswerWaitSafetyTimer;
  static const Duration _kbAnswerWaitSafetyDelay = Duration(seconds: 6);

  /// ISSUE 1(a) — timestamp of the most recent silence->speech-end edge
  /// that fired [_finalizeUtteranceEndDeterministicTriggers] (i.e. the
  /// instant this app considers the current utterance actually OVER).
  /// [_maybeFallBackToKbAnswerCatchAll] logs the elapsed time from here to
  /// its own routing decision, so the next real log can directly confirm
  /// that decision is near-instant — a LOCAL branch, not something that
  /// should ever take multiple seconds on its own (see that method's doc
  /// comment for the CONFIRMED regression this was added to disprove: the
  /// real delay was a longer utterance still being spoken past
  /// [_preemptiveDefaultMuteSafetyDelay]'s fixed window, not this decision
  /// itself being slow).
  DateTime? _utteranceEndDetectedAt;

  /// PART J item 1 (CONFIRMED regression via 44c910b3-flutter_run_log.txt:
  /// a single "can you hear me" utterance fired THREE DETERMINISTIC
  /// INTERRUPT calls back-to-back — preemptive_default_mute, then
  /// acknowledge_presence's own early call, then acknowledge_presence AGAIN
  /// via [_informGeminiToSpeakVerbatim] — queuing three separate PCM reinit
  /// generations. Per the existing "only the newest generation may mark
  /// ready" logic, generations 1 and 2 finishing were correctly ignored,
  /// but generation 3 didn't finish until AFTER the entire spoken response
  /// had already streamed in and been dropped chunk-by-chunk as "reinit
  /// still in flight" — 100% of the response audio was thrown away). True
  /// once a REAL PCM reinit (release()+setup()+generation bump) has
  /// actually been issued for the utterance currently in progress; every
  /// subsequent call to [_interruptGeminiForDeterministicTrigger] this same
  /// utterance is a cheap no-op for the reinit specifically — the other,
  /// inexpensive parts of that function (arming
  /// [_suppressResponseAudioForDeterministic], the preemptive-mute
  /// graduation logic) still run every time, since those are correct and
  /// necessary regardless of how many times this utterance's interrupt is
  /// invoked. Reset at the SAME place [_utteranceAlreadyResolvedByTrigger]
  /// resets — the genuinely-new-utterance edge in [_trackSpeechLevel] —
  /// not [_clearAllTriggerBuffersAfterSuccess]'s more frequent mid-
  /// utterance reset, for the same reason that flag isn't reset there
  /// either: a trailing chunk for an utterance already resolved must never
  /// trigger a SECOND real reinit for it.
  bool _pcmReinitIssuedForCurrentUtterance = false;

  /// PART J item 2 (see [_onResponseAudioChunk]'s `!_pcmReady` branch): a
  /// chunk that clears [_suppressResponseAudioForDeterministic]/
  /// [_preemptiveDefaultMuteActive] — i.e., genuinely belongs to the
  /// CURRENT, resolved turn — but arrives while [_pcmReady] is still false
  /// (the reinit that same resolution triggered hasn't finished yet) used
  /// to be dropped PERMANENTLY, indistinguishable from a truly stale/
  /// superseded chunk. Queued here instead, tagged with
  /// [_pendingPcmChunksGeneration] (the reinit generation in flight when it
  /// arrived); flushed in order the instant that SAME generation's reinit
  /// completes (see [_flushQueuedPcmChunksForGeneration]). A later, NEWER
  /// interrupt bumping [_pcmReinitGeneration] again before this queue is
  /// flushed makes every entry here stale — discarded the next time a chunk
  /// arrives and this generation no longer matches (see
  /// [_onResponseAudioChunk]), not kept around indefinitely.
  ///
  /// P0 FIX (CONFIRMED regression: a technician's "Can you hear me?"
  /// produced TWO server turns — Gemini's own free-text reply, then, after
  /// the deterministic acknowledge_presence trigger caught up and
  /// interrupted, the correct canned reply — both still sitting UNFLUSHED
  /// in this SAME list, generation-tagged but with no way to tell WHICH
  /// TURN a given entry belonged to. When [_auditGeminiDuplicateResponse]
  /// correctly identified the second turn as a near-duplicate of the
  /// first and tried to drop "the rest of this turn," there was no way to
  /// do that selectively — every entry here, from EITHER turn, looked
  /// identical. Net result: NOTHING played; the technician heard silence
  /// after a completely ordinary question). [turnId] closes that gap —
  /// see [_currentResponseTurnId]'s doc comment for how it's assigned, and
  /// [_auditGeminiDuplicateResponse] for how it's used to purge ONLY the
  /// specific turn being suppressed, never an earlier turn's still-queued,
  /// still-wanted audio.
  final List<({Uint8List bytes, String? mimeType, int turnId})> _pendingPcmChunksAwaitingReinit = [];
  int _pendingPcmChunksGeneration = 0;

  /// P0 FIX — see [_pendingPcmChunksAwaitingReinit]'s doc comment. A
  /// purely CLIENT-SIDE counter, distinct from [_pcmReinitGeneration]
  /// (which tracks native player teardown/rebuild cycles, a different
  /// axis): this tracks which CONVERSATIONAL TURN a chunk belongs to, so a
  /// later per-turn decision (right now, only [_auditGeminiDuplicateResponse]'s
  /// suppression) can target exactly the right entries in
  /// [_pendingPcmChunksAwaitingReinit] without touching any other turn's.
  ///
  /// Bumped in two places, both safe to double-bump (an extra, redundant
  /// bump only means an id is "used up" slightly early — it can never
  /// cause two DIFFERENT turns to incorrectly share one id, which is the
  /// only failure mode that would actually matter here):
  ///  1. [_interruptGeminiForDeterministicTrigger] — the moment the app
  ///     itself decides "whatever was in flight is now stale, something
  ///     new is coming" (covers both the unconditional preemptive mute on
  ///     every new utterance, and any specific trigger's own interrupt
  ///     immediately before it sends its instruction).
  ///  2. [_logAndResetTurnShape] — every genuine server turn boundary
  ///     (`turnComplete`/`interrupted`), so a turn Gemini starts on its
  ///     own (not preceded by an app-side interrupt — e.g. two genuinely
  ///     separate spontaneous replies) still gets its own id.
  int _currentResponseTurnId = 0;

  /// PART G item 1 (CONFIRMED regression via real log evidence:
  /// acknowledge_presence and meta_capability each matched correctly and
  /// spoke their canned response, then ~5s later the SEPARATE
  /// [_preemptiveDefaultMuteSafetyTimer] fired anyway and spoke the
  /// boundary decline right over top of the already-correct response — same
  /// failure for a navigation trigger whenever it matched late). Root
  /// cause: [_clearAllTriggerBuffersAfterSuccess] resets every trigger's own
  /// `resolvedForCurrentUtterance` flag back to `false` immediately after a
  /// SUCCESSFUL fire — by design, so a genuinely new request right after
  /// this one, with no silence gap, can still be detected (see that
  /// method's own doc comment). That reset also erased the ONLY signal
  /// [_muteImmediatelyOnFirstChunkOfUtterance]/[_maybeFallBackToKbAnswerCatchAll]
  /// had that THIS utterance was already handled, so a LATER transcript
  /// chunk belonging to the very same utterance (a trailing/corrected ASR
  /// chunk — common right after a short one) read as brand new and
  /// unclassified, re-armed a FRESH preemptive mute + its own fresh 5s
  /// safety timer, and that new timer had nothing left to supersede it.
  /// This flag is a separate, longer-lived signal that survives
  /// [_clearAllTriggerBuffersAfterSuccess]'s more frequent mid-utterance
  /// reset — set the instant ANY trigger resolves for real (see that
  /// method), cleared only at a genuinely NEW utterance (the silence->speech
  /// edge in [_trackSpeechLevel], the same place the per-trigger buffers
  /// reset there).
  bool _utteranceAlreadyResolvedByTrigger = false;

  /// CONFIRMED via a full real session: Gemini called zero functions
  /// natively, so every remaining function gets the same deterministic
  /// backstop already proven for get_job_details/view_estimate/go_back —
  /// see [_TranscriptTrigger]'s own doc comment. Keyed by Gemini function
  /// name so [_handleToolCall] can generically claim a trigger's debounce
  /// window for ANY of these names in one place instead of six separate
  /// hand-written blocks.
  final Map<String, _TranscriptTrigger> _deterministicTriggers = {
    // PART G item 2 — extraMatcher added to each of these five (CONFIRMED
    // miss: "the job history screen" matched none of
    // [_viewJobHistoryIndicatorPhrases]'s fixed exact phrases) — see
    // [_looksLikeNounPlusActionIntent]'s doc comment. The fixed phrase lists
    // stay exactly as they were, unchanged; this only ADDS coverage.
    'view_change_orders': _TranscriptTrigger(
      'view_change_orders',
      _viewChangeOrdersIndicatorPhrases,
      extraMatcher: (padded) => _looksLikeNounPlusActionIntent(
        padded,
        nouns: const ['change order', 'change orders'],
        actionWords: _navigationActionIntentWords,
        logLabel: 'view_change_orders',
      ),
    ),
    'view_invoice': _TranscriptTrigger(
      'view_invoice',
      _viewInvoiceIndicatorPhrases,
      extraMatcher: (padded) => _looksLikeNounPlusActionIntent(
        padded,
        nouns: const ['invoice'],
        actionWords: _navigationActionIntentWords,
        logLabel: 'view_invoice',
      ),
    ),
    'view_job_history': _TranscriptTrigger(
      'view_job_history',
      _viewJobHistoryIndicatorPhrases,
      extraMatcher: (padded) => _looksLikeNounPlusActionIntent(
        padded,
        nouns: const ['job history', 'history'],
        actionWords: _navigationActionIntentWords,
        logLabel: 'view_job_history',
      ),
    ),
    'open_camera': _TranscriptTrigger(
      'open_camera',
      _openCameraIndicatorPhrases,
      // excludeIfContains: 'last' so "show me the last photo"
      // (get_last_photo's own phrasing) can never also open the camera.
      extraMatcher: (padded) => _looksLikeNounPlusActionIntent(
        padded,
        nouns: const ['camera', 'photo', 'picture'],
        actionWords: _cameraActionIntentWords,
        excludeIfContains: const ['last'],
        logLabel: 'open_camera',
      ),
    ),
    // PART N item 1: no longer the noun+action loose matcher (see
    // [_looksLikeCapturePhotoConfirmation]'s doc comment for the accidental-
    // capture regression that caused) — restricted to genuine shutter/
    // confirm words instead, with an explicit veto against open_camera's
    // own "take a photo"/"take a picture" phrasing.
    'capture_photo': _TranscriptTrigger(
      'capture_photo',
      _capturePhotoIndicatorPhrases,
      extraMatcher: _looksLikeCapturePhotoConfirmation,
    ),
    // PART F item 4: no `extraMatcher`/`rawExtraMatcher` broadening anymore
    // — that WAS the "keyword-detect is this a question" gate the client
    // asked to retire (proven unreliable twice, with two different
    // phrasings). `_getKbAnswerIndicatorPhrases` stays as a fast, EARLY
    // path for clearly trade/how-to-shaped phrasing; everything else now
    // reaches get_kb_answer through [_maybeFallBackToKbAnswerCatchAll]'s
    // universal "nothing else matched" fallback instead, with no separate
    // question-shape gate at all.
    'get_kb_answer': _TranscriptTrigger('get_kb_answer', _getKbAnswerIndicatorPhrases),
    'site_condition': _TranscriptTrigger('site_condition', _siteConditionIndicatorPhrases),
    // PART L item 1: nouns require "last photo"/"last picture" as a
    // compound — deliberately NOT bare "photo"/"picture" (that's
    // open_camera/capture_photo's territory, which in turn exclude "last"
    // specifically so the two can never collide either way).
    'get_last_photo': _TranscriptTrigger(
      'get_last_photo',
      _getLastPhotoIndicatorPhrases,
      extraMatcher: (padded) => _looksLikeNounPlusActionIntent(
        padded,
        nouns: const ['last photo', 'last picture'],
        actionWords: _navigationActionIntentWords,
        logLabel: 'get_last_photo',
      ),
    ),
    'get_job_timeline_answer': _TranscriptTrigger(
      'get_job_timeline_answer',
      _getJobTimelineAnswerIndicatorPhrases,
      extraMatcher: _looksLikeArrivalTimeQuestion,
    ),
  };

  /// PART 3 (force job-specific/KB-vetted answers only): whether some
  /// OTHER, more specific deterministic trigger already resolved (matched
  /// and was handled one way or another — fired, debounced, or skipped for
  /// missing job_id; not necessarily a successful dispatch) for this same
  /// utterance. Used as [_looksLikeQuestionOpener]/
  /// [_looksLikeQuestionByPunctuation]'s guard at the get_kb_answer call
  /// site in [_finalizeUtteranceEndDeterministicTriggers], so the broad
  /// "any question" catch-all never steals a question a job-specific
  /// trigger already correctly owns (e.g. "what's the address" matching
  /// get_job_details instead of falling through to a knowledge-base lookup
  /// that can only ever answer "I don't have that information"). Safe to
  /// check at utterance-end: every trigger this reads runs per-chunk in
  /// [_onInputTranscription], which the silence->speech edge that fires
  /// [_finalizeUtteranceEndDeterministicTriggers] always follows, so any
  /// trigger that was going to resolve this utterance already has by the
  /// time this is read. site_condition and get_kb_answer itself are
  /// deliberately excluded — neither is a job-specific "question" trigger
  /// this catch-all could ever legitimately be stealing from.
  bool get _otherSpecificTriggerAlreadyResolvedThisUtterance =>
      _viewEstimateDetectionResolvedForCurrentUtterance ||
      _getJobDetailsDetectionResolvedForCurrentUtterance ||
      _getCurrentScreenDetectionResolvedForCurrentUtterance ||
      _metaCapabilityDetectionResolvedForCurrentUtterance ||
      // PART D: get_kb_answer's own broad opener-based matching (via
      // _accumulateDeterministicBuffer in _onInputTranscription) runs
      // unconditionally, independent of the acknowledge_presence
      // short-circuit above it — without this, "Can you hear me?" could
      // fire BOTH the canned greeting response AND a real (nonsensical)
      // KB lookup for the same utterance.
      _acknowledgePresenceResolvedForCurrentUtterance ||
      _jobDetailsDestinationResolvedForCurrentUtterance ||
      _goBackTriggerResolvedForCurrentUtterance ||
      _photoDecisionResolvedForCurrentUtterance ||
      (_deterministicTriggers['view_change_orders']?.resolvedForCurrentUtterance ?? false) ||
      (_deterministicTriggers['view_invoice']?.resolvedForCurrentUtterance ?? false) ||
      (_deterministicTriggers['view_job_history']?.resolvedForCurrentUtterance ?? false) ||
      (_deterministicTriggers['open_camera']?.resolvedForCurrentUtterance ?? false) ||
      (_deterministicTriggers['capture_photo']?.resolvedForCurrentUtterance ?? false) ||
      (_deterministicTriggers['get_last_photo']?.resolvedForCurrentUtterance ?? false) ||
      (_deterministicTriggers['get_job_timeline_answer']?.resolvedForCurrentUtterance ?? false);

  /// True from the instant ANY trigger commits to the current utterance
  /// (each sets its own resolved flag synchronously at match time) until
  /// the next genuinely new utterance — unlike
  /// [_utteranceAlreadyResolvedByTrigger] alone, which only turns true once
  /// a fired trigger's async dispatch succeeds. See the evaluation loop in
  /// [_onInputTranscription].
  /// A guard-failed match's clarification reply (e.g. "the camera's already
  /// open"), queued during this chunk's evaluation loop — see the guard
  /// branch in [_maybeTriggerDeterministic].
  void Function()? _pendingGuardFailedReply;

  /// Set once a queued guard-failed reply has actually been spoken this
  /// utterance. Deliberately NOT part of [_anyTriggerCommittedThisUtterance]:
  /// a later chunk of the same utterance ("…capture it") must still be able
  /// to fire a real trigger. It only stops the reply repeating and keeps
  /// the KB catch-all / safety-timeout from also answering.
  bool _guardFailedReplySpokenThisUtterance = false;

  bool get _anyTriggerCommittedThisUtterance =>
      _utteranceAlreadyResolvedByTrigger || _otherSpecificTriggerAlreadyResolvedThisUtterance;

  /// ISSUE 1 fix — see the toolCall-suppression call site in
  /// [_handleToolCall] for the CONFIRMED duplicate-dispatch bug this
  /// closes. Unlike [_otherSpecificTriggerAlreadyResolvedThisUtterance]
  /// (which answers "did ANY OTHER trigger already claim this utterance"),
  /// this answers "did THIS APP'S OWN trigger already fire THIS EXACT
  /// function name for the current utterance" — the specific check needed
  /// to recognize a genuine Gemini toolCall as redundant with (not merely
  /// unrelated to) this app's own deterministic firing.
  bool _alreadyResolvedByAppTriggerThisUtterance(String name) {
    switch (name) {
      case 'view_estimate':
        return _viewEstimateDetectionResolvedForCurrentUtterance;
      case 'get_job_details':
        return _getJobDetailsDetectionResolvedForCurrentUtterance;
      case 'go_back':
        // A Gemini go_back for "take me to Job Details" is redundant with the
        // destination trigger that already took them there.
        return _goBackTriggerResolvedForCurrentUtterance || _jobDetailsDestinationFiredThisUtterance;
      case 'confirm_photo_upload':
      case 'retake_photo':
        return _photoDecisionResolvedForCurrentUtterance;
      default:
        return _deterministicTriggers[name]?.resolvedForCurrentUtterance ?? false;
    }
  }

  /// FIX 2: timestamp of the most recent `view_*` function success — set in
  /// [_handleToolCall]. `null` means no cooldown is active (either no
  /// view_* has succeeded yet this session, or [_isGoBackInCooldown]'s
  /// window has nothing to compare against). See
  /// [_goBackCooldownDuration]'s doc comment for the full reasoning.
  DateTime? _lastViewFunctionSucceededAt;

  /// FIX 2: whether an [_intentionalGoBackPhrases] match has been heard
  /// (see [_maybeDetectIntentionalGoBack]) since [_lastViewFunctionSucceededAt]
  /// was last set. Reset to `false` every time a NEW `view_*` succeeds
  /// (a fresh cooldown window starts clean), set `true` the instant a
  /// genuine go-back request is heard — once true, [_isGoBackInCooldown]
  /// never blocks again until the NEXT `view_*` success resets it.
  bool _intentionalGoBackHeardSinceLastView = false;

  /// FIX 2: accumulates the current utterance's transcript for
  /// [_looksLikeIntentionalGoBack] — same per-utterance accumulate/reset
  /// pattern as [_viewEstimateDetectionBuffer], reset on the same
  /// silence->speech edge in [_trackSpeechLevel].
  String _goBackIntentDetectionBuffer = '';

  /// Guards [_maybeDetectIntentionalGoBack]'s CAMERA-FLOW deterministic
  /// trigger from re-firing on every subsequent transcript chunk of the
  /// SAME utterance once it's already resolved — reset alongside
  /// [_goBackIntentDetectionBuffer] on the next speech edge. Deliberately
  /// separate from [_intentionalGoBackHeardSinceLastView] — that flag lifts
  /// a view_*-specific cooldown, doesn't apply to the camera/photo
  /// workflow (open_camera/capture_photo/retake_photo/confirm_photo_upload
  /// never push a route for `go_back` to pop — see [_screenTask]'s doc
  /// comment — so there's no "unprompted go_back" risk to guard against
  /// there, only an under-triggered-function risk to guard FOR, the exact
  /// same "strengthened description/cooldown-lifting alone isn't reliably
  /// enough" gap already proven for start_change_order_dictation and
  /// view_estimate elsewhere in this file).
  bool _goBackTriggerResolvedForCurrentUtterance = false;

  /// Timestamp of the most recent go_back call — Gemini-initiated (tracked
  /// in [_handleToolCall]) or this app's own camera-flow deterministic
  /// trigger (tracked in [_maybeDetectIntentionalGoBack] itself, before the
  /// async dispatch call even starts). The camera-flow trigger only fires
  /// when this is `null` or older than [_goBackTriggerDebounce].
  DateTime? _lastGoBackActivityAt;

  /// Reliability audit (CHECK 4): accumulates the current utterance's
  /// transcript for [classifyPhotoDecision] — same per-utterance
  /// accumulate/reset pattern as
  /// [_viewEstimateDetectionBuffer], reset on the same silence->speech edge
  /// in [_trackSpeechLevel]. Only ever accumulated while [_screenTask] is
  /// [_ScreenTask.cameraCaptured] — see [_maybeDetectPhotoDecision].
  String _photoDecisionDetectionBuffer = '';

  /// Guards [_maybeDetectPhotoDecision] from re-firing on every subsequent
  /// transcript chunk of the SAME utterance once it's already resolved —
  /// reset alongside [_photoDecisionDetectionBuffer] on the next speech
  /// edge.
  bool _photoDecisionResolvedForCurrentUtterance = false;

  /// Timestamp of the most recent confirm_photo_upload OR retake_photo
  /// call — Gemini-initiated (tracked in [_handleToolCall]) or this app's
  /// own deterministic trigger (tracked in [_maybeDetectPhotoDecision]
  /// itself, before the async dispatch call even starts). Shared between
  /// both functions since only one of them can legitimately apply to a
  /// given captured photo — whichever ran most recently means "Gemini (or
  /// a previous firing) is already handling this photo's decision."
  DateTime? _lastPhotoDecisionActivityAt;

  /// P0 FIX (CONFIRMED via flutter_run_log_new.txt, build #61): the "ask
  /// for a clear repeat" resolution for [PhotoDecision.ambiguous] could
  /// loop indefinitely — Gemini's own repeated clarification prompt ("Keep
  /// it or retake it?") is short enough, and itself matches BOTH keep and
  /// retake evidence, to legitimately win the "a short command must always
  /// beat an echo guess" exemption in [_looksLikeGeminiEcho] (see that
  /// method's doc comment) — so the mic picking up Gemini's own re-prompt
  /// just re-triggers the SAME ambiguous result, forever, with no bounded
  /// exit. A real run looped ~50s across two full ambiguous cycles before
  /// the echo backstop happened to catch a LONGER echoed sentence and only
  /// then went quiet — never actually resolving the decision; the tester
  /// had to manually abort.
  ///
  /// Counts consecutive ambiguous hits for the SAME pending photo (reset to
  /// 0 the instant a real decision dispatches, or a fresh photo is
  /// captured — see both reset sites). At
  /// [_photoDecisionAmbiguousEscalationThreshold], the prompt switches to a
  /// stricter one AND matching switches to
  /// `classifyStrictBareWordPhotoDecision` — the next utterance must be
  /// JUST the bare word "keep"/"confirm" or JUST "retake" (nothing else) to
  /// resolve. This breaks the loop even without a perfect echo fix: an
  /// echoed FULL sentence (the strict prompt or the original question)
  /// always has extra words around "keep"/"retake", so it can never satisfy
  /// a bare-word-only check.
  int _photoDecisionAmbiguousStreak = 0;
  static const int _photoDecisionAmbiguousEscalationThreshold = 2;

  /// P0 FIX (CONFIRMED, a real session): the escalation above has no decay
  /// — once triggered, it stays in strict bare-word-only mode for the REST
  /// of this photo's decision window, with the only reset being a FRESH
  /// capture_photo. A real cascade (Gemini's own "Keep it or retake it?"
  /// confirmation echoing back uncaught, THEN this trigger's own
  /// clarification reprompt — [_photoDecisionAmbiguousPrompt] — ALSO
  /// echoing back, two ambiguous hits in rapid succession) reached the
  /// threshold, and everything the technician said for the rest of that
  /// decision — "This looks good.", "Keep this for rock." (STT garble of
  /// a bare "keep") — matched NOTHING, even though the NORMAL
  /// (non-escalated) classifier already covers both a plain "looks good"
  /// and a bare "keep" fine on their own. With the deterministic layer
  /// permanently locked out, the utterance fell through to Gemini's own
  /// free text, which then claimed "I've saved that photo" with no real
  /// upload behind it — the escalation meant to protect this decision
  /// ended up being the direct cause of the trust violation.
  ///
  /// [_lastPhotoDecisionAmbiguousAt] + this decay window is the fix: after
  /// this long with no NEW ambiguous hit, the streak resets and the next
  /// utterance gets the full, normal evidence-scoring classifier back. A
  /// genuine rapid-fire echo cascade still reaches the threshold and
  /// escalates well within this window (a real cascade closes in a couple
  /// of seconds, not many) — this only ever matters once that cascade has
  /// clearly stopped and the technician is speaking freely again.
  static const Duration _photoDecisionAmbiguousStreakDecay = Duration(seconds: 12);
  DateTime? _lastPhotoDecisionAmbiguousAt;

  /// See [_photoDecisionAmbiguousStreak]'s doc comment.
  String _photoDecisionAmbiguousPrompt() {
    if (_photoDecisionAmbiguousStreak >= _photoDecisionAmbiguousEscalationThreshold) {
      return "I keep hearing both. Please say ONLY the word 'keep', or ONLY the word 'retake' — nothing else.";
    }
    return "Sorry, I heard both keep and retake in that — which do you want: keep this photo, or retake it?";
  }

  /// See [_photoDecisionAmbiguousStreak]'s doc comment — active only once
  /// escalated. Deliberately whole-buffer, not substring: allows trivial
  /// filler ("um", "okay") around the bare word since a technician saying
  /// it under repeated pressure plausibly hedges slightly, but anything
  /// resembling a full sentence (in particular either question being
  /// echoed back) has far more non-filler words than this tolerates and
  /// correctly falls through to [PhotoDecision.none]. See
  /// `classifyStrictBareWordPhotoDecision` in `photo_decision_classifier.dart`
  /// (moved there, alongside [classifyPhotoDecision], for the same
  /// unit-testability reasons — see `test/photo_decision_classifier_test.dart`).

  /// BUG 5 FIX — see [_unrecognizedReplyForCurrentState]'s doc comment. True
  /// from the instant [_executeDeterministicPhotoDecision] starts dispatching
  /// confirm_photo_upload/retake_photo until it genuinely finishes (success
  /// OR failure — see that method's `finally`), which can take many seconds
  /// (compression + S3 upload). [_screenTask] alone can't gate this: it only
  /// leaves [_ScreenTask.cameraCaptured] on SUCCESS, not on dispatch start.
  bool _photoDecisionDispatchInFlight = false;

  /// UI only: true for the whole confirm_photo_upload dispatch (compress +
  /// upload), so the Review Photo surface can show an "Uploading…" overlay
  /// alongside the spoken pending-call filler — see [_buildCameraTaskBody].
  bool _photoUploadInFlight = false;

  /// Reset to `false` every time [_photoDecisionDispatchInFlight] becomes
  /// `true` — lets [_unrecognizedReplyForCurrentState] speak the "still
  /// working on that" acknowledgment at most once per dispatch instead of
  /// repeating it for every stray unresolved utterance during a long upload.
  bool _photoDecisionDispatchAcknowledgedUnresolved = false;

  /// Mirrors [GeminiNavigationSession.onActiveChanged] — see that field's
  /// doc comment for why this ambient screen must render NOTHING (see
  /// [_buildAmbientUi]) while a view_* screen is on top, rather than its
  /// usual pure-conversation/camera-task content.
  bool _viewScreenActive = false;

  /// get_current_screen: WHICH `view_*` screen is currently on top, e.g.
  /// `'view_estimate'` — `null` whenever [_viewScreenActive] is `false`.
  /// [GeminiNavigationSession]/[_viewScreenActive] only ever tracked a
  /// count/bool (enough for the go-back cooldown, which never needed to
  /// know WHICH screen), so this is the one genuinely new bit of state
  /// get_current_screen needed — set at the exact same three "a view_*
  /// succeeded" points that already set [_lastViewFunctionSucceededAt]
  /// ([_handleToolCall], [_executeDeterministic], and
  /// [_executeDeterministicViewEstimate]), and cleared in lockstep with
  /// [_viewScreenActive] itself (below in [initState]) rather than tracked
  /// separately.
  String? _currentViewScreenName;

  /// Drives [_buildAmbientUi]/[_buildCameraTaskBody] and, via
  /// [_updateScreenTaskForToolCall], `GlobalVoiceService.
  /// setScreenTaskActive` â€” see [_ScreenTask]'s doc comment. `none` outside
  /// of (and for the whole standalone/manual, non-ambient UI, which never
  /// reads this) an active camera flow.
  _ScreenTask _screenTask = _ScreenTask.none;

  /// Guards [_stopTest] from calling [GeminiLiveTestScreen.onAmbientSessionEnded]
  /// more than once for the same session (see that field's doc comment) —
  /// a second call would try to remove an already-removed [OverlayEntry],
  /// which throws.
  bool _ambientSessionEndedCalled = false;

  _TestPhase _phase = _TestPhase.idle;
  final List<String> _log = [];
  String? _errorMessage;

  bool _setupComplete = false;
  bool _isSpeaking = false;

  /// Timestamp of the most recent above-[_speechRmsThreshold] mic chunk —
  /// separate from [_isSpeaking] (which only tracks the 500ms-debounced
  /// speaking/silent state for the latency stopwatch). Used only to gate
  /// deterministic-trigger buffer resets against [_utteranceBufferResetDebounce]
  /// — see that constant's doc comment for the bug this fixes.
  DateTime? _lastSpeechActivityAt;
  DateTime? _speechStoppedAt;

  /// LATENCY metric only: end of the latest speech burst whose audio
  /// actually reached Gemini, and when the current utterance's first real
  /// transcript arrived. Both cleared at each new utterance and once a
  /// latency is logged. See the LATENCY computation in [_onResponseAudioChunk].
  DateTime? _latencySpeechEndAt;
  DateTime? _latencyTranscriptAt;

  /// See [_speechMaxContinuousDuration]'s doc comment. Set only on the
  /// false->true edge of [_isSpeaking] (mirrors [_lastSpeechActivityAt]'s own
  /// edge-only semantics), cleared to `null` whenever [_isSpeaking] goes back
  /// to false — by the natural silence timer in [_trackSpeechLevel] or by
  /// [_speechStuckWatchdogTimer] itself force-ending a wedged burst.
  DateTime? _speechBurstStartedAt;

  /// Ticks once a second for the whole lifetime of the mic stream (started in
  /// [_startMicStreaming], cancelled in [_teardown]) — see
  /// [_speechMaxContinuousDuration]'s doc comment for why this backstop
  /// exists independently of [_trackSpeechLevel]'s own edge detection.
  Timer? _speechStuckWatchdogTimer;
  Duration? _lastLatency;
  int _audioChunksSent = 0;
  int _responseChunksReceived = 0;

  /// BLOCKING TEST instrumentation only — set right after `capture_photo`'s
  /// toolResponse is sent (T2), so the very next inbound audio chunk from
  /// Gemini logs T3 and clears the flag.
  bool _blockingTestAwaitingT3 = false;

  /// True while the current model response is being received/played back —
  /// mic audio is still captured but NOT sent to Gemini during this window,
  /// so the phone's own speaker output (the response itself) can't be
  /// picked back up by the mic and misread by Gemini's server-side VAD as
  /// the user interrupting (which was cutting every response short; see
  /// `_maybeResumeOutgoingAudio`). PART F: restored to this original
  /// Gemini-audio-playback meaning (PART E's brief `_speakLocally`
  /// detour is reverted).
  bool _outgoingAudioPaused = false;

  /// PART K (CONFIRMED regression: open_camera's real hardware work is
  /// trivial per CameraX's own timers — "Opened CameraId-0 in 161ms",
  /// "Configured CaptureSessionState-1 in 461ms" — but `handler_entry` to
  /// `controller_initialized` measured 71.4s, with continuous unrelated
  /// audio-processing traffic — chunk drops, PCM reinit bookkeeping, echo-
  /// backstop checks, repeated 5s "nothing matched" timeout cycles — filling
  /// the gap. The platform channel call that actually opens the camera was
  /// stuck queued behind that traffic). PART N item 3 (CONFIRMED via
  /// 3ebd9995-flutter_run_log.txt: capture_photo's own native shutter call
  /// took 38s the same way, having never gotten this same protection —
  /// generalized/renamed from `_cameraOpenInProgress` accordingly). BUG 2
  /// FIX (CONFIRMED via flutter_run_log_new.txt, build #56): widened again
  /// to confirm_photo_upload — its own `compressWithFile` platform-channel
  /// call showed the identical symptom (8.3s for a sub-1MP JPEG that should
  /// compress in well under 200ms), and the same protection here also
  /// closes the window for a stray "new utterance" reset to fire mid-upload
  /// at all (see [_trackSpeechLevel]'s BUG 4 FIX doc comment). Set the
  /// instant open_camera's, capture_photo's, OR confirm_photo_upload's real
  /// native dispatch starts, BEFORE anything else that call does — see
  /// [_dispatchWithOpenCameraSafeguards] — and cleared once that call
  /// reports back (success, failure, or open_camera's own hard timeout
  /// giving up waiting; capture_photo has no such timeout of its own, so
  /// for it this only ever clears on genuine completion). While `true`:
  /// [_onMicChunk] does nothing at all (not even RMS tracking — reuses this
  /// exactly like [_outgoingAudioPaused] already gates mic SEND, just
  /// earlier/harder, skipping ALL per-chunk work, not only the network
  /// send), [_onResponseAudioChunk] drops incoming audio immediately
  /// instead of feeding the native player, and no new preemptive-mute
  /// safety timeout can arm (any already-pending one is cancelled the
  /// instant this becomes true). Nothing legitimate is lost by any of this:
  /// no NEW technician utterance can be usefully acted on while the camera
  /// hardware call is mid-flight anyway, and the relevant spoken
  /// acknowledgment is sent only once this flag clears again.
  bool _cameraNativeCallInProgress = false;

  /// P0 FIX (CONFIRMED on a real SM-A507FN: a 55.03s `takePicture()` call
  /// dropped 80+ response chunks — total silence for the whole call). While
  /// `true`, [_onResponseAudioChunk] lets audio through DESPITE
  /// [_cameraNativeCallInProgress], so the one filler line
  /// [_speakPendingCallFiller] asked for is actually heard. Every other gate
  /// ([_suppressResponseAudioForDeterministic] in particular, which the
  /// filler's own interrupt arms to cut off whatever stale turn was in
  /// flight) still applies. Previously the open_camera ack WAS sent, but
  /// its audio hit the hard-pause drop like everything else.
  ///
  /// Cleared on the `turnComplete`/`interrupted` that follows the filler's
  /// first audible chunk ([_fillerAudioStarted]), or when the native call
  /// itself finishes — whichever comes first.
  bool _fillerPassthroughActive = false;

  /// See [_fillerPassthroughActive]: distinguishes the stale turn's own
  /// `interrupted` ack (arrives BEFORE any filler audio) from the filler
  /// turn's `turnComplete`.
  bool _fillerAudioStarted = false;

  /// PART M (CONFIRMED via 204dd37f-flutter_run_log.txt: camera-open time
  /// improved 71.4s -> 30.8s after [_cameraNativeCallInProgress]'s audio hard-stop,
  /// but a NEW bottleneck dominated the remainder — [_teardown]'s recorder
  /// stop/close + wake-word `resumeAfterExternalSession` restart competing
  /// for the main thread with CameraX's still-in-flight configuration work,
  /// producing "Skipped N frames" jank and ~15s of added delay). Non-null
  /// for as long as the REAL underlying open_camera dispatch is genuinely
  /// still running in the background — set the instant it starts, cleared
  /// only once it actually resolves for real (success or failure),
  /// regardless of whether [_dispatchWithOpenCameraSafeguards]'s own 15s
  /// hard timeout already gave up WAITING on it (that's
  /// [_cameraNativeCallInProgress] — a separate, shorter-lived flag; audio
  /// processing resumes at the 15s mark either way, this field only tracks
  /// whether the CAMERA HARDWARE call itself is still in flight). [_teardown]
  /// awaits this — if non-null — before touching the recorder/wake-word
  /// pipeline specifically, so the two heavy native-audio operations can
  /// never contend for the main thread with CameraX's own native work at
  /// the same time.
  Future<void>? _cameraOpenRealCallInFlight;

  /// Set the instant [_cameraOpenRealCallInFlight]'s underlying real call
  /// actually resolves — 'real completion' or 'real failure' — purely for
  /// [_teardown]'s deferred-start log line to report which one it was.
  /// Deliberately NOT reset to `null` afterward: a stale value here is
  /// harmless (only ever read once, immediately after the wait it explains
  /// completes) and there's no "new utterance" style boundary to reset it
  /// at anyway — a fresh open_camera call simply overwrites it when IT
  /// resolves.
  String? _cameraOpenRealCallOutcome;

  /// True the instant [_teardown] starts running, for the FIRST time this
  /// PART C item 6: whether the CURRENT turn (since the last turnComplete/
  /// interrupted) has included a real `toolCall` message / any spoken
  /// audio or output transcription text — reset at every turn boundary by
  /// [_logAndResetTurnShape]. Exists so every turn's actual shape
  /// (function call vs. free-text speech vs. empty) is directly visible in
  /// the log, settling whether the setup message's `toolConfig.
  /// functionCallingConfig.mode: 'ANY'` is having any real effect, rather
  /// than left ambiguous.
  bool _currentTurnHadToolCall = false;
  bool _currentTurnHadAudioOrText = false;

  /// PART F: restored — last `remainingFrames` reported by
  /// [FlutterPcmSound]'s feed callback, the "has everything queued
  /// finished actually playing" half of [_maybeResumeOutgoingAudio]'s
  /// check, since `_turnComplete` alone only means the server stopped
  /// sending, not that playback caught up.
  int _pcmRemainingFrames = 0;

  @override
  void initState() {
    super.initState();
    final wakeGreeting = widget.wakeGreeting;
    if (wakeGreeting != null) unawaited(wakeGreeting.done.then(_onWakeGreetingDone));
    _navigationSession = GeminiNavigationSession(
      isCameraFlowActive: () => _screenTask != _ScreenTask.none,
      onActiveChanged: (active) {
        if (!mounted) return;
        setState(() {
          _viewScreenActive = active;
          // See [_currentViewScreenName]'s doc comment — cleared the moment
          // no view_* screen remains, so get_current_screen never reports a
          // stale name after the technician has already navigated back.
          if (!active) _currentViewScreenName = null;
        });
      },
    );
    // P2 (see [_ScreenTask.cameraOpening]) — the camera surface is driven
    // straight off the real controller lifecycle now, not off the dispatch
    // returning. `onOpenStarted` puts a real "opening" surface up
    // immediately; `onPreviewAvailable` swaps in the live preview the
    // instant a texture exists, which on a slow open is many seconds before
    // `open_camera`'s own success payload comes back through
    // [_updateScreenTaskForToolCall].
    _cameraSession.onOpenStarted = () {
      if (!mounted) return;
      // P1 FIX — see [_cameraSpeculativelyPrewarming]'s doc comment: a
      // speculative prewarm's own open must never show the "opening the
      // camera" surface — the technician hasn't asked for the camera yet.
      // The native work still proceeds normally in the background; only
      // the UI-visible transition is suppressed.
      if (_cameraSpeculativelyPrewarming) {
        _log_('screen task: open_camera prewarm STARTED silently (speculative — no UI change until a real request)');
        return;
      }
      if (_screenTask != _ScreenTask.none) return;
      _log_('screen task: open_camera STARTED -> ${_ScreenTask.cameraOpening} (showing the opening surface now, not after the controller reports ready)');
      setState(() => _screenTask = _ScreenTask.cameraOpening);
      _startCameraOpeningTicker();
      _pausedVoiceService?.setScreenTaskActive(true);
    };
    _cameraSession.onPreviewAvailable = () {
      if (!mounted) return;
      if (_cameraSpeculativelyPrewarming) {
        _log_('screen task: camera preview prewarmed and ready (speculative — no UI change until a real request)');
        return;
      }
      if (_screenTask != _ScreenTask.cameraOpening && _screenTask != _ScreenTask.none) return;
      _log_('screen task: camera preview texture available -> ${_ScreenTask.cameraLive} (view unblocked; capture stays gated on open_camera\'s own success)');
      setState(() => _screenTask = _ScreenTask.cameraLive);
      _pausedVoiceService?.setScreenTaskActive(true);
      final requestedAt = _openCameraDispatchedAt;
      _pipelineLog(
        'camera_preview_live',
        requestedAt == null
            ? 'preview live (no open_camera dispatch recorded)'
            : 'preview live ${DateTime.now().difference(requestedAt).inMilliseconds}ms after open_camera was '
                  'dispatched — see PHOTO TIMING [open_camera] queue_wait_done / controller_initialize_done for the split',
      );
      // Painted and interactive: the first frame after the switch to the
      // live preview has actually rendered.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || requestedAt == null) return;
        _pipelineLog(
          'camera_preview_painted',
          'first frame with the live preview rendered ${DateTime.now().difference(requestedAt).inMilliseconds}ms after '
              'open_camera was dispatched',
        );
      });
    };
    // The guaranteed counterpart to `onOpenStarted` — see
    // [GeminiCameraSession.onOpenSettled]. Without this, an open that throws
    // somewhere that returns before [_updateScreenTaskForToolCall] runs
    // (e.g. [_executeDeterministic]'s own catch block) would strand the
    // "opening the camera" surface for the rest of the session. A SUCCESS
    // needs nothing here: `onPreviewAvailable` has already moved the task on.
    _cameraSession.onOpenSettled = (error) {
      if (!mounted || error == null) return;
      _cameraOpenConfirmed = false;
      // A prewarm that fails is a non-event UI-wise (nothing was ever
      // shown) — just clear the flag so a LATER real request retries the
      // open itself, from a clean slate, rather than being stuck thinking
      // a (failed) prewarm already handled it.
      if (_cameraSpeculativelyPrewarming) {
        _log_('screen task: open_camera prewarm FAILED silently ($error) — a real request later will retry normally.');
        _cameraSpeculativelyPrewarming = false;
        return;
      }
      if (_screenTask != _ScreenTask.cameraOpening) return;
      _log_('screen task: open_camera FAILED before any preview existed ($error) -> ${_ScreenTask.none} — clearing the opening surface.');
      setState(() => _screenTask = _ScreenTask.none);
      _pausedVoiceService?.setScreenTaskActive(false);
    };
    WidgetsBinding.instance.addTimingsCallback(_onFrameTimings);
    widget.endRequest?.addListener(_onEndRequest);
    if (widget.ambient) {
      // Deferred to a post-frame callback — same reasoning as every other
      // "write provider state / start real work right as a screen first
      // mounts" callback in this app (see JobDetailScreen.initState):
      // doing this synchronously, mid-build, is unsafe.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // The job may already have been left before this first frame.
        if (widget.endRequest?.value != null) {
          _onEndRequest();
          return;
        }
        _log_('ambient mode: auto-starting session (reached via wake word/"Loop On")');
        unawaited(_startTest());
      });
    }
  }

  /// See [GeminiLiveTestScreen.endRequest]. Everything that could still
  /// reach Gemini or the speaker is cut off synchronously, right here —
  /// [_teardown] itself awaits the mic capture and camera before closing the
  /// socket, and nothing may be heard or answered in that window.
  bool _sessionClosing = false;

  void _onEndRequest() {
    final reason = widget.endRequest?.value;
    if (reason == null || _sessionClosing) return;
    // Synchronously: ONLY the flag every gate reads (mic send, server
    // messages, scripted replies). CONFIRMED via logcat: this is called from
    // `JobDetailScreen.dispose()` -> `exitJobScope()`, i.e. while the widget
    // tree is locked — the old `_log_` (a setState) here threw, so the flag
    // got set but `_stopTest` never ran: the socket, the OUTGOING AUDIO timer
    // and the overlay all stayed alive. The rest runs on the next event-loop
    // turn, outside any build/finalize phase.
    _sessionClosing = true;
    debugPrint('GEMINI LIVE TEST: SESSION END requested ($reason) — gates closed, disposing next');
    _releaseNativeAudioNow(reason);
    Future(() => _disposeForEndRequest(reason));
  }

  /// The native pieces — recorder, PCM player, socket — are told to stop
  /// right away, not after [_teardown]'s awaits: when the app is closing
  /// (`AppLifecycleState.detached`) the engine may be gone before those
  /// finish, and a native recorder nobody stopped keeps running orphaned
  /// (CONFIRMED via logcat: 500+ "FlutterJNI was detached ... Channel:
  /// xyz.canardoux.flutter_sound_recorder"). No setState anywhere in here —
  /// safe while the widget tree is locked. [_teardown] still runs afterwards
  /// and closes everything properly (every step there tolerates this having
  /// already happened).
  void _releaseNativeAudioNow(String reason) {
    _pcmReinitGeneration++;
    _pcmReady = false;
    _pcmRemainingFrames = 0;
    try {
      FlutterPcmSound.setFeedCallback(null);
      unawaited(FlutterPcmSound.release().catchError((Object e) {
        debugPrint('GEMINI LIVE TEST ERROR (pcm sound release on session end): $e');
      }));
    } catch (e) {
      debugPrint('GEMINI LIVE TEST ERROR (pcm sound release on session end): $e');
    }
    if (_recorderOpen) {
      unawaited(() async {
        try {
          if (_recorder.isRecording) {
            await _recorder.stopRecorder();
            debugPrint('GEMINI LIVE TEST: mic recorder stopped on session end ($reason)');
          }
        } catch (e) {
          debugPrint('GEMINI LIVE TEST ERROR (recorder stop on session end): $e');
        }
      }());
    }
    final channel = _channel;
    if (channel != null) {
      unawaited(channel.sink.close().catchError((Object e) {
        debugPrint('GEMINI LIVE TEST ERROR (WebSocket close on session end): $e');
      }));
    }
  }

  void _disposeForEndRequest(String reason) {
    // Already disposed in the meantime — dispose() ran the same teardown.
    if (!mounted) return;
    _log_('SESSION END: $reason — closing the Gemini Live session now (no more mic audio, transcripts or replies)');
    // Anything already queued for the speaker, not just new chunks.
    _discardPcmPrebuffer('session ending: $reason');
    unawaited(_stopTest(reason: reason));
  }

  @override
  void dispose() {
    widget.endRequest?.removeListener(_onEndRequest);
    WidgetsBinding.instance.removeTimingsCallback(_onFrameTimings);
    _teardown();
    super.dispose();
  }

  /// PREVIEW SMOOTHNESS SAMPLING (replaces the removed `preview_fps` logger,
  /// which used `startImageStream` — and thereby forced the camera plugin to
  /// marshal full YUV frames to Dart on the main thread, itself a cause of
  /// "Skipped N frames"). This measures the app's real Flutter frame
  /// timings via the engine's batched [FrameTiming] callback instead: zero
  /// per-frame native work. Only sampled while the live preview is showing
  /// ([_ScreenTask.cameraLive]); one summary line per ~1s window.
  int _fpsWindowFrames = 0;
  int _fpsWindowSlowFrames = 0;
  int _fpsWindowWorstMs = 0;
  DateTime? _fpsWindowStartedAt;

  void _onFrameTimings(List<FrameTiming> timings) {
    // P1: sampled during [_ScreenTask.cameraOpening] too, not just once the
    // preview is live. The open window is exactly where the "is the camera
    // slow, or are we starving the thread that would service it" question
    // lives (see `controller.initialize()`'s heartbeat in
    // `gemini_function_dispatcher.dart`) — and this is the UI-thread half
    // of that same measurement, from the other side of the platform channel.
    if (_screenTask != _ScreenTask.cameraLive && _screenTask != _ScreenTask.cameraOpening) {
      _fpsWindowStartedAt = null;
      return;
    }
    final now = DateTime.now();
    _fpsWindowStartedAt ??= now;
    for (final t in timings) {
      final totalMs = t.totalSpan.inMilliseconds;
      _fpsWindowFrames++;
      if (totalMs > 32) _fpsWindowSlowFrames++;
      if (totalMs > _fpsWindowWorstMs) _fpsWindowWorstMs = totalMs;
    }
    final windowMs = now.difference(_fpsWindowStartedAt!).inMilliseconds;
    if (windowMs < 1000) return;
    final fps = _fpsWindowFrames * 1000 / windowMs;
    debugPrint(
      'PHOTO TIMING [preview_fps]: at $now (screenTask=${_screenTask.name}) — $_fpsWindowFrames frames in '
      '${windowMs}ms (~${fps.toStringAsFixed(1)} fps), $_fpsWindowSlowFrames slow (>32ms), worst frame '
      '${_fpsWindowWorstMs}ms',
    );
    _fpsWindowFrames = 0;
    _fpsWindowSlowFrames = 0;
    _fpsWindowWorstMs = 0;
    _fpsWindowStartedAt = now;
  }

  /// Base [_systemInstruction] plus, only in job-scoped mode
  /// ([GeminiLiveTestScreen.jobId] non-null), one added sentence telling
  /// Gemini the job is already known — purely to stop it from uselessly
  /// asking the technician for a job id out loud; the real job_id used in
  /// every dispatched call is forced by [_handleToolCall] regardless of
  /// whether Gemini ever mentions one. In standalone mode (`jobId == null`)
  /// this is byte-identical to [_systemInstruction].
  String get _effectiveSystemInstruction {
    final jobId = widget.jobId;
    final base = jobId == null
        ? _systemInstruction
        : '$_systemInstruction The current job is already known to the app ($jobId) — never ask the '
              'technician for a job id.';
    // [_systemInstructionReminder] is appended LAST here (after the
    // job-scoped sentence above, not before it) so it's the true final text
    // Gemini reads in every mode — see that const's own doc comment for why
    // that ordering specifically matters.
    return '$base $_systemInstructionReminder';
  }

  void _log_(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final line = '[$ts] $message';
    debugPrint('GEMINI LIVE TEST: $line');
    if (!mounted) return;
    setState(() {
      _log.add(line);
      if (_log.length > 300) _log.removeAt(0);
    });
  }

  /// P1 FIX (CONFIRMED via flutter_run_log_new.txt, build #61): the ~5.36s
  /// gap between `platform_capture_call_start` (Dart calling
  /// `controller.takePicture()`) and native `takePictureInternal` actually
  /// starting — the true root cause of the "10.5s/16.8s takePicture()"
  /// finding, NOT native camera latency at all (every CXCP capture-pipeline
  /// step inside that window logs in single-digit milliseconds once it
  /// finally starts) — was every "inlineData received"/"GEMINI SAID"
  /// fragment STILL calling [_log_] (a full `setState` widget rebuild) on
  /// every single chunk, unconditionally, even while
  /// [_cameraNativeCallInProgress] is hard-pausing everything else for
  /// exactly this reason. This is the SAME class of bug ISSUE 3(c) already
  /// fixed for [_onResponseAudioChunk]'s own drop-branch logging (see that
  /// method's doc comment) — that fix just didn't cover these two
  /// unconditional call sites, which fire even MORE often (every chunk,
  /// not just every dropped one) and were still competing directly with
  /// the camera preview's own rendering and the platform channel's ability
  /// to promptly dispatch `takePicture()` to native code. Same
  /// timestamp-prefixed format as [_log_], purely logcat/debugPrint — no
  /// `setState`, so no on-screen debug-log-list entry (same tradeoff
  /// ISSUE 3(c) already made and this file already accepts).
  void _logNoState(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    debugPrint('GEMINI LIVE TEST: [$ts] $message');
  }

  Future<void> _startTest() async {
    if (_phase == _TestPhase.connecting || _phase == _TestPhase.connected) return;
    if (_sessionClosing) return;

    setState(() {
      _phase = _TestPhase.requestingToken;
      _errorMessage = null;
      _setupComplete = false;
      _isSpeaking = false;
      _speechStoppedAt = null;
      _lastLatency = null;
      _audioChunksSent = 0;
      _responseChunksReceived = 0;
      _outgoingAudioPaused = false;
      _turnComplete = true;
      _pcmRemainingFrames = 0;
    });
    _log_('Start Test tapped');

    // P1 — pay the camera's one-time device-enumeration cost NOW, in the
    // background, while the token fetch and WebSocket connect are already
    // in flight and nobody is waiting on a camera. CONFIRMED to be 2.4-9s of
    // real platform-channel work on this device, and previously paid inside
    // the very first open_camera of the process, on the critical path. See
    // `GeminiCameraSession.prewarm`.
    unawaited(GeminiCameraSession.prewarm(ref));
    // P1 — go further: speculatively pay the REAL, expensive
    // controller.initialize() cost too (confirmed, three rounds running,
    // to be 100% of the actual camera-open delay — see
    // [_maybePrewarmCameraController]'s own doc comment), not just cheap
    // enumeration, so it overlaps ordinary conversation time instead of
    // blocking the technician's actual request.
    _maybePrewarmCameraController();

    // FIX 3 (confirmed: ~5.6s of the ~7.4s wake-word-to-ready time was this
    // token fetch alone, sequenced AFTER the voice-service pause and mic
    // permission check below for no reason — none of the three depend on
    // each other's results). Kicked off HERE, immediately, in parallel with
    // those two, and only actually awaited once its result is needed, right
    // before building the WebSocket connection URI. The no-op `catchError`
    // listener just prevents a spurious "unhandled exception" zone error if
    // the token fetch fails while we're still awaiting the pause/permission
    // steps below (before the real `await tokenFuture` gets a chance to
    // observe it) — the real result/error is still fully handled there;
    // Futures support multiple independent listeners, so this doesn't
    // swallow anything the try/catch below needs to see.
    //
    // The token now usually comes from GlobalVoiceService's pre-fetched
    // spare (see GeminiTokenCache) — the wake-word path claims it before
    // this screen even mounts and hands it in as [widget.tokenFuture];
    // otherwise it's taken from the same cache here, which falls back to
    // fetching on demand exactly as this used to.
    final Future<String> tokenFuture;
    final widgetToken = widget.tokenFuture;
    if (widgetToken != null && !_widgetTokenConsumed) {
      _widgetTokenConsumed = true;
      tokenFuture = widgetToken;
    } else {
      tokenFuture = ref.read(globalVoiceServiceProvider.notifier).takeGeminiToken();
    }
    unawaited(tokenFuture.catchError((_) => ''));
    _log_('Gemini token requested (pre-fetched spare if available, else from $apiBaseUrl/voice/gemini-token)');

    // Genuinely pauses the existing FieldLoop wake-word loop (real mic
    // release, not just ignoring its output — see
    // GlobalVoiceService.pauseForExternalSession) for the ENTIRE lifetime
    // of this session, brackets token/connect included, so there's no
    // window where both systems could contend for the microphone. Matching
    // resume happens in _teardown(), which every exit path (Stop/End
    // Session, back navigation, an error here, dispose) already funnels
    // through — so FieldLoop reliably resumes no matter how this session
    // ends. Harmless no-op if no job is open (standalone debug use) since
    // the wake-word loop wouldn't be running anyway. Captured into a field
    // (not read fresh in _teardown()) — see _pausedVoiceService's doc
    // comment for why.
    _pausedVoiceService = ref.read(globalVoiceServiceProvider.notifier);
    await _pausedVoiceService!.pauseForExternalSession('gemini_live_session');
    // Left the job during the pause — teardown has already run (and resumed
    // the voice service); nothing more may start.
    if (_sessionClosing || _pausedVoiceService == null) return;
    // `listening`, continuing what the wake word already showed (see
    // GlobalVoiceService's wake-word branch) rather than dropping to
    // "Thinking..." for the length of session setup: from here the mic is
    // captured into [_preSetupAudio] and sent once the session is ready, so
    // the technician genuinely is being listened to. [_applyVoicePhase]
    // takes over at setupComplete.
    _pausedVoiceService!.setExternalSessionPhase(VoicePhase.listening);

    try {
      // flutter_sound does not request/check mic permission itself (per its
      // own docs) — that's explicitly the app's responsibility.
      final permissionStatus = await Permission.microphone.request();
      _log_('mic permission check: status=$permissionStatus');
      if (!permissionStatus.isGranted) {
        throw StateError('Microphone permission denied.');
      }
      // Left the job while the permission check was pending — never open
      // the mic.
      if (_sessionClosing) return;

      // Release-build background restrictions — see VoiceSessionService.kt.
      // Started here: the app is in the foreground and the mic is granted,
      // both of which Android requires for a microphone foreground service.
      // Best-effort and not awaited — never delays or blocks the session.
      unawaited(VoiceSessionPower.startForegroundSession());
      unawaited(VoiceSessionPower.powerState().then((state) => _log_('VOICE POWER: session start — $state')));

      // Start capturing NOW — the wake-word recognizer has released the mic
      // (pauseForExternalSession above) — instead of after the token, the
      // WebSocket handshake and setupComplete. Until setupComplete arrives
      // the audio goes into [_preSetupAudio] and is sent first, in order,
      // once the session can take it; see [_startMicCapture]. Not awaited:
      // opening the recorder runs alongside the token/handshake below.
      _micCaptureFuture = _startMicCapture();
      unawaited(_micCaptureFuture!.catchError((_) {}));

      final token = await tokenFuture;
      _log_('token received');

      if (!mounted) return;
      // Left the job while the token was on its way — never connect.
      if (_sessionClosing) {
        _log_('SESSION END: session closed before connecting — not opening the WebSocket');
        return;
      }
      setState(() => _phase = _TestPhase.connecting);

      // `connectionUri` (real, full token) is what actually opens the socket
      // below. `redactedDisplayUri` is a SEPARATE object built only for the
      // log line — it is never read again after that _log_ call, and never
      // feeds back into `connectionUri`. Keeping these as two distinct named
      // variables (rather than one inline expression) makes that separation
      // visible at a glance instead of relying on reading the whole
      // expression carefully.
      final connectionUri = _geminiLiveUri(token);
      final redactedDisplayUri = connectionUri.replace(queryParameters: {
        for (final e in connectionUri.queryParameters.entries)
          e.key: (e.key == 'access_token' || e.key == 'key') ? '<redacted>' : e.value,
      });
      _log_('opening WebSocket: $redactedDisplayUri');
      debugPrint(
        'BLOCKING TEST: connecting to ${connectionUri.scheme}://${connectionUri.host}${connectionUri.path} '
        '(model=$_geminiModel)',
      );
      final channel = IOWebSocketChannel.connect(connectionUri);
      _channel = channel;
      await channel.ready;
      _log_('WebSocket connected');
      // Left the job during the handshake: close this socket too (teardown
      // may already have run and missed it).
      if (_sessionClosing) {
        _log_('SESSION END: session closed during the WebSocket handshake — closing it');
        if (identical(_channel, channel)) _channel = null;
        unawaited(channel.sink.close().catchError((Object _) {}));
        return;
      }

      _wsSub = channel.stream.listen(_onServerMessage, onError: _onWsError, onDone: _onWsDone);

      // `responseModalities` lives under `generationConfig`, NOT as a sibling
      // of `model`/`systemInstruction` — confirmed against the official
      // BidiGenerateContentSetup reference schema (ai.google.dev/api/live),
      // the @google/genai SDK's own LiveClientSetup/GenerationConfig type
      // definitions, and the server's own rejection of the flat form
      // ("Unknown name 'responseModalities' at 'setup': Cannot find field").
      final setupMessage = jsonEncode({
        'setup': {
          'model': 'models/$_geminiModel',
          'generationConfig': {
            'responseModalities': ['AUDIO'],
            // FIX 1 (instruction-adherence lever #2, distinct from a prompt
            // reword): lower than whatever server-side default is otherwise
            // in effect. Lower temperature narrows sampling toward the
            // highest-probability continuation, which for an instruction-
            // heavy system prompt like this one's persona/boundary rules
            // means the model should deviate from what's explicitly stated
            // less often — tested here specifically against the two CONFIRMED
            // failures in `_systemInstructionReminder`'s doc comment ("what
            // kind of help do you provide" -> generic answer; "let's take
            // the picture" -> claimed it can't take photos).
            'temperature': 0.2,
            // PART F item 1: requests a specific prebuilt Live voice
            // instead of leaving the server's own default in effect.
            // CONFIRMED via a real device setup-message/setupComplete round
            // trip (2026-09-17 16:12:54-55 local test): the server accepts
            // this WITH `languageCode` included and returns `setupComplete`
            // — a prior pass here had AVOIDED
            // `generationConfig.speechConfig.languageCode` specifically,
            // reasoning from Google's docs that native audio output models
            // (which $_geminiModel is) "automatically choose the
            // appropriate language and don't support explicitly setting
            // the language code" for that field. That documented caveat
            // turned out not to mean outright setup rejection in practice
            // — the server either honors it or silently ignores it,
            // either way without erroring. Kept in (not just `voiceConfig`
            // alone) per that empirical result; if a FUTURE session's log
            // ever shows an `error` instead of `setupComplete` after a
            // model/API change, that's the signal to drop just this
            // `languageCode` sub-field again.
            'speechConfig': {
              'voiceConfig': {
                'prebuiltVoiceConfig': {'voiceName': _geminiVoiceName},
              },
              'languageCode': 'en-US',
            },
          },
          'systemInstruction': {
            'parts': [
              {'text': _effectiveSystemInstruction},
            ],
          },
          'tools': [
            {'functionDeclarations': _geminiToolFunctionDeclarations},
          ],
          // PART A (retested at the client's explicit request after a prior
          // pass concluded `toolConfig` was unsendable here — see below for
          // what that conclusion was and why this now sends it anyway):
          // `allowedFunctionNames` is built directly FROM
          // `_geminiToolFunctionDeclarations` (never retyped), so this list
          // can never drift out of sync with the real tool set above.
          //
          // PRIOR FINDING (kept for the record, not proven wrong, only
          // overridden): the `@google/genai` Node SDK's `LiveConnectConfig`
          // interface and the official BidiGenerateContentSetup reference
          // (ai.google.dev/api/live) both omit `toolConfig` from this
          // message's accepted field list, which is why it wasn't sent
          // before. Sending it anyway is a deliberate, monitored experiment,
          // not a reversal of that finding — if the server rejects this
          // setup message (an `error` message on `_onServerMessage`, or the
          // WebSocket closing before `setupComplete`), that IS the
          // documentation being right, and this block must come back out
          // (reverting to the app-side-only enforcement below) rather than
          // being left in place breaking every session. Checked via a real
          // device connection (see the "setup message sent" log line below,
          // which now reports whether `toolConfig` was included) before
          // this is trusted.
          'toolConfig': {
            'functionCallingConfig': {
              'mode': 'ANY',
              'allowedFunctionNames': [
                for (final tool in _geminiToolFunctionDeclarations) tool['name'] as String,
              ],
            },
          },
          // App-side enforcement kept regardless of whether `toolConfig`
          // above is honored/accepted by the server — the broadened
          // get_kb_answer question-shape detection in
          // [_looksLikeQuestionOpener]/[_looksLikeQuestionByPunctuation]
          // (which calls get_kb_answer directly the moment ANY question is
          // heard, without waiting for Gemini to decide to call it — the
          // same deterministic-backstop pattern this file already uses for
          // every other under-triggered function), the new meta/capability
          // canned-response trigger (see [_metaCapabilityIndicatorPhrases]),
          // and the reinforced "never answer from your own knowledge" line
          // in [_systemInstructionReminder] all still apply unconditionally.
          // Enables `serverContent.inputTranscription` alongside the
          // technician's audio — this is what feeds `_onInputTranscription`
          // (the view_estimate/go_back deterministic triggers). Purely
          // additive — nothing about the existing audio-in/audio-out flow
          // changes; this just adds one more kind of server message to the
          // stream.
          //
          // `languageCodes: ['en-US']` pins recognition of the technician's
          // OWN spoken words to US English from the very first audio chunk,
          // instead of the server auto-detecting language from (possibly
          // ambiguous) early audio — confirmed against the current
          // AudioTranscriptionConfig reference schema (ai.google.dev/api/
          // live): "languageCodes[] — Optional. BCP-47 language codes
          // providing hints about the languages present in the audio,"
          // omitting it (or `[]`) enables automatic language ID instead.
          // Deliberately NOT `generationConfig.speechConfig.languageCode`
          // (a different field, governing the model's own spoken RESPONSE
          // language for half-cascade models only) — $_geminiModel is a
          // NATIVE AUDIO model (per its DeepMind model card), and Google's
          // own docs are explicit that "native audio output models
          // automatically choose the appropriate language and don't support
          // explicitly setting the language code" for that field; setting it
          // risked the exact kind of outright setup-message rejection
          // already seen once before for a misplaced field (see this
          // method's `responseModalities` comment above). `languageCodes`
          // under `inputAudioTranscription`, by contrast, is documented
          // generically for `AudioTranscriptionConfig` with no such
          // native-audio-model carve-out.
          'inputAudioTranscription': {
            'languageCodes': ['en-US'],
            // ISSUE 2(a) mitigation (CONFIRMED via fbd877f0-flutter_run_log.txt
            // and a fresh check against the current Live API reference,
            // ai.google.dev/api/live, AudioTranscriptionConfig): `languageCodes`
            // is documented as a HINT ("providing hints about the languages
            // present in the audio"), not a hard constraint, and there is no
            // stricter locking parameter this API exposes — auto language/
            // script switching mid-session (confirmed: Hindi/Devanagari
            // appeared here despite `languageCodes: ['en-US']`) is a real,
            // documented constraint of this API today, not something fully
            // fixable app-side. `customVocabulary` IS a legitimate, documented
            // AudioTranscriptionConfig field ("phrases to bias the speech
            // recognition model toward recognizing specific terms") — biasing
            // toward this app's actual short command vocabulary makes the
            // ambiguous, easily-misheard SHORT utterances (a single word or
            // two, the exact shape most prone to drifting into another
            // script/language) more likely to resolve as the English command
            // they almost certainly were, without pretending to solve the
            // general problem. See [_looksLikeNonLatinScriptTranscription]'s
            // doc comment for the pragmatic app-side mitigation this pairs
            // with for whatever this can't catch.
            'customVocabulary': [
              'take a photo',
              'take a picture',
              'open the camera',
              'capture it',
              'snap it',
              'ready',
              'confirm',
              'keep it',
              'keep this photo',
              'upload it',
              'retake',
              'retake it',
              'retake this photo',
              'take another photo',
              'show me the estimate',
              'show me the invoice',
              'show me the change orders',
              'show me the job history',
              'show me the last photo',
              'go back',
            ],
          },
          // FIX 1: enables `serverContent.outputTranscription` — a
          // transcript of GEMINI'S OWN spoken audio, not the technician's.
          // Same top-level-of-`setup` placement as `inputAudioTranscription`
          // above (both are siblings on `LiveConnectConfig`/
          // `BidiGenerateContentSetup`, NOT nested under `generationConfig`
          // — `generationConfig` only holds `responseModalities` here, per
          // the `responseModalities` comment at the top of this message).
          // Was the single most important missing piece of visibility for
          // diagnosing the audio-echo investigation: without this, there was
          // no way to directly compare "what Gemini actually said" against
          // a suspicious `inputTranscription` line that reads like Gemini's
          // own words, to confirm or rule out mic bleed. See
          // `_onServerMessage`'s `outputTranscription` handling below.
          'outputAudioTranscription': {},
          // Caps how large the server-side session context is allowed to
          // grow over a long conversation. The Live API has no "keep the
          // last N turns" knob — this sliding window is the actual
          // supported mechanism, and it only speaks in tokens, not turns.
          // `systemInstruction` and `tools` above are unaffected by this —
          // they're part of setup, not the compressible conversation
          // history, so they survive every compression pass intact.
          //
          // Production values, confirmed working against real test data —
          // a temporary 3000/1500 test pass showed a clean spike-and-reset
          // pattern (stable ~5000-token baseline across 13 turns once
          // triggered), proving the mechanism fires and compresses
          // correctly. Raised here to give a normal conversation more room
          // before the first compression pass, while still keeping context
          // (and cost) genuinely bounded rather than climbing unbounded
          // like the pre-compression baseline did (Test 4: 5039-6499 over
          // 12 turns, uncompressed).
          'contextWindowCompression': {
            'triggerTokens': '$_contextCompressionTriggerTokens',
            'slidingWindow': {'targetTokens': '$_contextCompressionTargetTokens'},
          },
        },
      });
      // Logs the EXACT, FULL system instruction text this specific setup
      // message is about to embed at systemInstruction.parts[0].text —
      // requested after a CONFIRMED session where Gemini behaved as if it
      // had never received the rewritten persona/boundary instruction at
      // all (generic "I can help with a lot of things" answers, claiming it
      // couldn't take photos). The SOURCE — `_systemInstruction`/
      // `_effectiveSystemInstruction` and this one, only, setup-message
      // construction site — was traced and confirmed correct; this line
      // exists so every future session can verify what was ACTUALLY SENT
      // directly from the log, not by re-reading source and assuming the
      // running build matches it (a stale/not-yet-rebuilt install would
      // still show the OLD text here even though the source file is
      // correct — that distinction is exactly what this makes visible).
      debugPrint('GEMINI FULL SYSTEM INSTRUCTION BEING SENT:\n$_effectiveSystemInstruction');
      channel.sink.add(setupMessage);
      _log_(
        'setup message sent (model=$_geminiModel, generationConfig.responseModalities=[AUDIO], '
        'generationConfig.temperature=0.2, '
        'generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName=$_geminiVoiceName, '
        'generationConfig.speechConfig.languageCode=en-US, '
        'tools=${_geminiToolFunctionDeclarations.length} functionDeclarations, '
        // PART A item 2: makes it verifiable from every future log, without
        // re-asking, whether toolConfig was actually included in the sent
        // setup message (not just planned/described in a comment) and how
        // many allowedFunctionNames it carried — read straight off the same
        // map this method just built and sent, not a hardcoded claim.
        'toolConfig.functionCallingConfig.mode='
        '${(jsonDecode(setupMessage) as Map<String, dynamic>)['setup']['toolConfig']?['functionCallingConfig']?['mode'] ?? 'ABSENT'}, '
        'toolConfig.allowedFunctionNames.count='
        '${((jsonDecode(setupMessage) as Map<String, dynamic>)['setup']['toolConfig']?['functionCallingConfig']?['allowedFunctionNames'] as List?)?.length ?? 0}, '
        'inputAudioTranscription.languageCodes=[en-US], inputAudioTranscription.customVocabulary.count='
        '${((jsonDecode(setupMessage) as Map<String, dynamic>)['setup']['inputAudioTranscription']?['customVocabulary'] as List?)?.length ?? 0}, '
        'outputAudioTranscription=enabled, '
        'contextWindowCompression=trigger $_contextCompressionTriggerTokens/target $_contextCompressionTargetTokens tokens, '
        'systemInstruction.length=${_effectiveSystemInstruction.length} chars — see '
        '"GEMINI FULL SYSTEM INSTRUCTION BEING SENT" just above for the full text)',
      );

      // PART F: restored — continuous raw-PCM streaming for Gemini's
      // response audio (PART E's flutter_tts detour is reverted; Gemini's
      // own voice, via [_speechConfig], is used for every spoken response
      // again). The prior ConcatenatingAudioSource/just_audio approach
      // treated every incoming chunk (arriving every 10-90ms per the logs)
      // as its own audio "track", introducing a real playback gap at every
      // chunk boundary — audible as stuttering/repeated-sounding speech
      // starting within the first couple seconds of almost any response.
      // FlutterPcmSound feeds raw int16 samples into one continuous native
      // audio buffer instead, with no per-chunk source-switching. Fixed at
      // _outputSampleRateHz (24000hz), matching the confirmed real rate in
      // Gemini's own response mimeType metadata — see the per-chunk
      // rate-mismatch warning in _onResponseAudioChunk for a safety net if
      // that ever stops being true.
      if (_sessionClosing) return;
      await FlutterPcmSound.setup(sampleRate: _outputSampleRateHz, channelCount: 1);
      // Left the job while the player was being set up — release it again.
      if (_sessionClosing) {
        unawaited(FlutterPcmSound.release().catchError((Object _) {}));
        return;
      }
      // Drives the resume half of the mic-pause fix: reports how many
      // sample frames are still queued for playback, so
      // `_maybeResumeOutgoingAudio` can catch the moment playback of the
      // current response actually finishes (as opposed to just when the
      // server says the turn is done — see the fields' doc comments above).
      FlutterPcmSound.setFeedCallback(_onPcmFeedCallback);
      FlutterPcmSound.start();
      _pcmReady = true;

      if (!mounted) return;
      setState(() => _phase = _TestPhase.connected);
    } catch (e, stackTrace) {
      final message = _scrubCredentials(e);
      debugPrint('GEMINI LIVE TEST ERROR: $message\n$stackTrace');
      _log_('ERROR: $message');
      if (!mounted) return;
      setState(() {
        _phase = _TestPhase.error;
        _errorMessage = message;
      });
      await _teardown();
    }
  }

  /// `/voice/gemini-token` mints a short-lived, single-use ephemeral token
  /// (via the backend's `authTokens.create()` call — see
  /// `backend/functions/get-gemini-token`), so this connects using the
  /// ephemeral-token form: `BidiGenerateContentConstrained` with an
  /// `access_token=` query param, on `v1alpha` — per
  /// https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens. The raw
  /// Gemini API key never reaches this client.
  Uri _geminiLiveUri(String ephemeralToken) {
    return Uri(
      scheme: 'wss',
      host: 'generativelanguage.googleapis.com',
      path: '/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained',
      queryParameters: {'access_token': ephemeralToken},
    );
  }

  /// Whether [widget.tokenFuture] has been used — tokens are single-use, so
  /// only the first session this screen starts may use it.
  bool _widgetTokenConsumed = false;

  /// Mic audio captured before the session could accept it (the token,
  /// WebSocket handshake and `setupComplete` still in flight), sent first,
  /// in order, the moment it can — see [_startMicCapture]/[_flushPreSetupAudio].
  final ListQueue<Uint8List> _preSetupAudio = ListQueue<Uint8List>();
  int _preSetupAudioBytes = 0;
  int _preSetupAudioDroppedBytes = 0;

  /// True from the moment capture starts until [_flushPreSetupAudio] runs;
  /// while true, mic chunks go to [_preSetupAudio] instead of the socket.
  bool _bufferingPreSetupAudio = false;

  /// The in-flight/finished [_startMicCapture] for the current session.
  Future<void>? _micCaptureFuture;

  /// Bumped by [_teardown] so a capture still opening when the session ends
  /// stops instead of starting the recorder for a session that's gone.
  int _micCaptureGeneration = 0;

  /// Cap on [_preSetupAudio]: 8s of 16kHz mono pcm16 = 256KB. The measured
  /// worst case from wake word to `setupComplete` was ~6.2s (SM-X230 trace);
  /// 8s covers that plus the start of a command spoken straight after the
  /// wake word, without letting an unusually slow setup grow the buffer
  /// unbounded. Past the cap the OLDEST audio is dropped, so what's kept is
  /// always contiguous with the live audio that follows it — a gap in the
  /// middle of an utterance would hurt recognition more than a lost start.
  static const int _preSetupAudioMaxBytes = _inputSampleRateHz * 2 * 8;

  int _pcmBytesToMs(int bytes) => bytes * 1000 ~/ (_inputSampleRateHz * 2);

  /// Opens the recorder and starts capturing into [_preSetupAudio] — started
  /// by [_startTest] right after the mic permission check, in parallel with
  /// the token/handshake, rather than after `setupComplete`.
  Future<void> _startMicCapture() async {
    final generation = _micCaptureGeneration;
    _log_('opening flutter_sound recorder session...');
    await _recorder.openRecorder();
    _recorderOpen = true;
    // _teardown waits for this future before closing the recorder, so
    // bailing here leaves it to close the (opened, not started) recorder.
    if (generation != _micCaptureGeneration) return;

    _preSetupAudio.clear();
    _preSetupAudioBytes = 0;
    _preSetupAudioDroppedBytes = 0;
    _bufferingPreSetupAudio = true;

    final controller = StreamController<Uint8List>();
    _micStreamController = controller;
    _micSub = controller.stream.listen(
      _onRawMicChunk,
      onError: (Object e, StackTrace stackTrace) {
        debugPrint('GEMINI LIVE TEST ERROR (mic stream): $e\n$stackTrace');
        _log_('ERROR (mic stream): $e');
      },
    );

    // P0 FIX (CONFIRMED via flutter_run_log_new.txt, build #61): the mic
    // was opened with `AudioSource.defaultSource` (flutter_sound's own
    // default — never explicitly set here before), which on Android does
    // NOT guarantee acoustic echo cancellation. With Gemini's own TTS
    // playing through the phone's speaker while this mic is simultaneously
    // listening, its own voice leaking back in and getting transcribed as
    // if the technician said it is a real, reproducible failure mode (see
    // [_looksLikeGeminiEcho]'s app-side text-matching backstop) — a genuine
    // capture_photo fired from the mic picking up Gemini's own "...go ahead
    // and take another one when you're ready" tail. `voice_communication`
    // maps to Android's `MediaRecorder.AudioSource.VOICE_COMMUNICATION`,
    // documented to apply acoustic echo cancellation/automatic gain control
    // when available on the device — exactly this two-way voice scenario.
    // This suppresses the leak at the SOURCE, before it ever reaches
    // transcription, instead of relying solely on the app-side text-match
    // backstop to catch it after the fact.
    //
    // P0 AUDIO-ECHO investigation (a later round — the confirmed 3x-repeat
    // bug was STILL reproducing despite the above): checked whether this
    // app could go further and explicitly attach
    // `android.media.audiofx.AcousticEchoCanceler` to this recording
    // session, as an additional, more aggressive AEC layer on top of what
    // `voice_communication` already requests from the platform.
    // CONFIRMED NOT FEASIBLE without forking a third-party dependency:
    // `AcousticEchoCanceler.create(audioSessionId)` requires the specific
    // native `AudioRecord`'s session id, and neither flutter_sound's
    // public Dart API (`FlutterSoundRecorder` — checked its full public
    // surface) nor its Android implementation (checked
    // `flutter_sound-9.30.0`'s own Java sources) exposes one — the real
    // `AudioRecord` is created inside `flutter_sound_core`, a compiled AAR
    // pulled from JitPack, not source available in this repo/pub cache to
    // patch. `AudioSource.voice_communication` (below) already engages
    // Android's platform-level AEC pipeline automatically wherever the
    // device supports it — genuinely THE mechanism the report asks for,
    // just not layerable a second time from this app without that fork.
    // Given that, the achievable, highest-impact fix this round is on the
    // TIMING side instead — see [_resumeGraceDelay]'s doc comment for the
    // adaptive mic-resume fix, plus the duplicate-response safety net (see
    // [_auditGeminiDuplicateResponse]) as defense in depth.
    _log_('starting mic stream (pcm16, ${_inputSampleRateHz}hz, mono, audioSource=voice_communication)...');
    await _recorder.startRecorder(
      codec: Codec.pcm16,
      toStream: controller.sink,
      sampleRate: _inputSampleRateHz,
      numChannels: 1,
      audioSource: AudioSource.voice_communication,
    );
  }

  /// Runs on `setupComplete`: the session can take audio now. Sends
  /// everything captured so far, then switches to live streaming.
  Future<void> _startMicStreaming() async {
    final generation = _micCaptureGeneration;
    // Normally already capturing since before the token arrived; this only
    // starts it here for a session that somehow skipped [_startTest]'s call.
    await (_micCaptureFuture ??= _startMicCapture());
    if (generation != _micCaptureGeneration) return;

    // Before the flush, so the buffered pre-setup audio is counted too.
    _startOutgoingAudioSummary();
    _flushPreSetupAudio();

    // Module A measurement — one figure per wake word: from the wake word
    // to this session taking live mic audio. Same "VOICE LATENCY: wake-to-"
    // format as GlobalVoiceService._logLatency.
    final wakeAt = widget.wakeDetectedAt;
    if (wakeAt != null && !_wakeToSessionLiveLogged) {
      _wakeToSessionLiveLogged = true;
      debugPrint('VOICE LATENCY: wake-to-session-live: ${DateTime.now().difference(wakeAt).inMilliseconds}ms');
    }

    // See [_speechMaxContinuousDuration]'s doc comment — armed for the whole
    // mic-streaming lifetime, cancelled in [_teardown] alongside [_silenceTimer].
    _speechStuckWatchdogTimer?.cancel();
    _speechStuckWatchdogTimer = Timer.periodic(const Duration(seconds: 1), (_) => _checkSpeechStuckWatchdog());

    _syncVoicePhase();

    // Original Day 2 spec: the silence auto-timeout starts counting the
    // moment the session actually becomes active — i.e. right here, once the
    // mic is genuinely capturing and forwarding the technician's audio, not
    // back when the WebSocket merely connected or the setup message was
    // sent (neither of which means anyone can be heard yet).
    _resetInactivityTimer(reason: 'session became active');

    // After the flush above, so speech already captured is known about.
    _maybeSpeakSessionGreeting();
  }

  /// The ONE opening line of a wake-word session, spoken by the app itself
  /// through the same constrained verbatim path as every other scripted
  /// line ("Camera's open — ready when you are.") — never left to Gemini,
  /// whose own greeting racing an app-triggered one is the double-greeting
  /// bug this codebase already had once (see [_interruptedTurnBaseline]).
  /// The system instruction tells Gemini never to greet on its own.
  ///
  /// Normally no longer spoken here at all: [GeminiLiveTestScreen.
  /// wakeGreeting] already played Gemini's saved rendition of it the instant
  /// the wake word was heard. Gemini is only asked for it when no clip
  /// exists yet (or it failed to play), and that rendition is then saved as
  /// the clip — see [_captureGreetingChunk].
  static const String _sessionGreetingText = kWakeGreetingText;

  /// At most once per session: this screen (and so this flag) is created
  /// fresh for each wake-word session, and `setupComplete` — the only
  /// caller — arrives once per connection.
  bool _sessionGreetingHandled = false;

  /// See [_startMicStreaming] — logged once per session.
  bool _wakeToSessionLiveLogged = false;

  // --- First-transcript timing (measurement only) ----------------------
  //
  // 1b059096 log: the session's FIRST turn spent 5059ms between speech end
  // and its transcript, against ~0.7-3s for later turns. Whether that is
  // the pre-setup audio burst (everything said before setupComplete is sent
  // in one go — see [_flushPreSetupAudio]) or something else can't be told
  // from the existing lines; this one line per session can.
  DateTime? _setupCompleteAt;
  int? _preSetupAudioFlushedMs;
  bool _firstTranscriptTimingLogged = false;

  void _maybeLogFirstTranscriptTiming() {
    if (_firstTranscriptTimingLogged) return;
    _firstTranscriptTimingLogged = true;
    final now = DateTime.now();
    final setupAt = _setupCompleteAt;
    final wakeAt = widget.wakeDetectedAt;
    final speechEnd = _latencySpeechEndAt ?? _speechStoppedAt;
    _log_(
      'FIRST TRANSCRIPT TIMING: ${setupAt == null ? 'setupComplete not seen' : '${now.difference(setupAt).inMilliseconds}ms after setupComplete'}, '
      '${wakeAt == null ? '' : '${now.difference(wakeAt).inMilliseconds}ms after the wake word, '}'
      'pre-setup audio flushed at setupComplete: ${_preSetupAudioFlushedMs ?? 0}ms, '
      'speech end -> this transcript: ${speechEnd == null ? 'n/a (speech end not detected yet)' : '${now.difference(speechEnd).inMilliseconds}ms'}, '
      'wake greeting: ${widget.wakeGreeting?.outcome?.name ?? (widget.wakeGreeting == null ? 'none' : 'still playing')}',
    );
  }

  void _maybeSpeakSessionGreeting() {
    if (!widget.ambient || _sessionGreetingHandled) return;
    final clip = widget.wakeGreeting;
    if (clip != null) {
      if (clip.isActive && clip.startedAt == null) {
        // Still loading — [_onWakeGreetingDone] calls back here if it turns
        // out there's nothing to play.
        _log_('SESSION GREETING: wake-word session ready — waiting on the local greeting clip');
        return;
      }
      if (clip.replacesGeminiGreeting) {
        _sessionGreetingHandled = true;
        _log_(
          'SESSION GREETING: wake-word session ready — the greeting was already handled locally at the wake word '
          '(clip ${clip.outcome?.name ?? 'still playing'}) — not asking Gemini for it',
        );
        return;
      }
    }
    _sessionGreetingHandled = true;
    // "FieldLoop, take a photo" in one breath: the command is already
    // captured (and on its way to Gemini) — greeting over it would be a
    // second, competing opening line. Its own reply is the only one.
    if (_lastSpeechActivityAt != null) {
      _log_('SESSION GREETING: skipped — the technician was already speaking before the session was ready');
      return;
    }
    _log_('SESSION GREETING: wake-word session ready — speaking the opening line');
    _informGeminiToSpeakVerbatim(_sessionGreetingText, reason: 'session_greeting');
    if (_channel != null) {
      // Recorded so the next wake word can play it instantly.
      _greetingCapture = BytesBuilder(copy: false);
      _greetingCaptureTurnId = _currentResponseTurnId;
    }
  }

  /// Listens to [GeminiLiveTestScreen.wakeGreeting] — attached once in
  /// [_startTest]. With no clip to play (none saved yet, or the player
  /// failed) the session greets the old way, through Gemini, as soon as it
  /// is ready; if it already is, that happens now.
  void _onWakeGreetingDone(WakeGreetingOutcome outcome) {
    if (!mounted || _sessionClosing) return;
    if (outcome != WakeGreetingOutcome.unavailable && outcome != WakeGreetingOutcome.failed) return;
    if (_setupComplete) _maybeSpeakSessionGreeting();
  }

  // --- Saving Gemini's greeting as the local clip ----------------------

  /// Audio of the greeting turn as it actually played — non-null only while
  /// Gemini is speaking the greeting because no clip was saved yet.
  BytesBuilder? _greetingCapture;

  /// [_currentResponseTurnId] when the greeting was requested — any later
  /// interrupt bumps it, and the capture is abandoned.
  int? _greetingCaptureTurnId;

  /// Called with every response chunk right before it's queued for
  /// playback — every mute/drop gate has already passed, so this is exactly
  /// what the technician hears.
  void _captureGreetingChunk(Uint8List pcmBytes) {
    final capture = _greetingCapture;
    if (capture == null) return;
    if (_currentResponseTurnId != _greetingCaptureTurnId) {
      _abandonGreetingCapture('a newer response superseded it');
      return;
    }
    if (capture.isEmpty) {
      final wakeAt = widget.wakeDetectedAt;
      final spokenAt = DateTime.now();
      if (wakeAt != null) {
        debugPrint(
          'WAKE GREETING: detectedAt=${wakeGreetingTs(wakeAt)} spokenAt=${wakeGreetingTs(spokenAt)} '
          'elapsedMs=${spokenAt.difference(wakeAt).inMilliseconds} source=gemini (no saved clip yet — '
          'recording this one)',
        );
      }
    }
    capture.add(pcmBytes);
  }

  /// At `turnComplete`, before the turn's text is reset: saves the captured
  /// audio only if the turn's played transcript is exactly the greeting.
  void _finishGreetingCapture() {
    final capture = _greetingCapture;
    if (capture == null || capture.isEmpty) return;
    final transcript = _currentTurnAudiblyPlayedText;
    final pcm = capture.takeBytes();
    _greetingCapture = null;
    _greetingCaptureTurnId = null;
    if (!isCleanGreetingTranscript(transcript, greeting: _sessionGreetingText)) {
      _log_('WAKE GREETING: not saving this turn as the clip — it played "$transcript", not the exact greeting');
      return;
    }
    unawaited(wakeGreetingClips.save(_sessionGreetingText, pcm));
  }

  void _abandonGreetingCapture(String reason) {
    if (_greetingCapture == null) return;
    _greetingCapture = null;
    _greetingCaptureTurnId = null;
    _log_('WAKE GREETING: not saving the greeting as the clip ($reason)');
  }

  // --- Mic gate while the greeting clip is in play ---------------------

  /// See [WakeGreetingMicGate]. Created on the first mic chunk of a session
  /// started with a greeting clip; closed for good once the clip is over.
  WakeGreetingMicGate? _greetingMicGate;
  bool _greetingMicGateClosed = false;

  /// Returns true when the gate took [chunk] (it's then held, dropped as the
  /// clip's echo, or forwarded later in order); false once there's no
  /// greeting clip in play and chunks go straight on.
  bool _passThroughGreetingMicGate(Uint8List chunk) {
    final greeting = widget.wakeGreeting;
    if (greeting == null || _greetingMicGateClosed) return false;
    final gate = _greetingMicGate ??= WakeGreetingMicGate();
    final now = DateTime.now();
    final outcome = greeting.outcome;

    if (outcome != null && outcome != WakeGreetingOutcome.played) {
      // Never played (or stopped for something other than speech, which the
      // gate itself would have caught): everything held is the technician's.
      gate.resolveUnused();
      _closeGreetingMicGate('greeting clip ${outcome.name} — forwarding all held mic audio');
      _routeMicChunk(chunk);
      return true;
    }
    // A loud run still open when the clip ends is followed to its verdict:
    // someone who talked over the greeting is still talking after it, and
    // that is exactly what confirms them.
    if (outcome == WakeGreetingOutcome.played &&
        !gate.withinEchoTail(endedAt: greeting.endedAt!, at: now) &&
        !gate.runInProgress) {
      final held = gate.heldChunks;
      gate.resolvePlayed(startedAt: greeting.startedAt);
      _closeGreetingMicGate(
        'greeting clip finished — dropped its echo from $held held chunk(s) '
        '(mic during playback: peakRms=${gate.peakRms.toStringAsFixed(0)} avgRms=${gate.averageRms.toStringAsFixed(0)}, '
        'barge-in level ${gate.bargeInRms.toStringAsFixed(0)})',
      );
      _routeMicChunk(chunk);
      return true;
    }

    final clipAudible = greeting.clipAudibleAt(now);
    final action = gate.add(chunk, now, Duration(milliseconds: _pcmBytesToMs(chunk.length)), clipAudible: clipAudible);
    if (action == WakeGreetingMicAction.rejectedLoudRun) {
      final run = gate.lastRejectedRun!;
      final why = run.outsideEcho < gate.speechEvidence
          ? 'only ${run.outsideEcho.inMilliseconds}ms of it fell outside the clip\'s own echo window (needs '
                '${gate.speechEvidence.inMilliseconds}ms) — the clip\'s echo, not the technician'
          : 'too short (${run.loud.inMilliseconds}ms loud, needs ${gate.bargeInSustain.inMilliseconds}ms) — a transient';
      _log_(
        'BARGE-IN REQUIRES SUSTAINED SPEECH: ignored a loud run from ${wakeGreetingTs(run.startedAt)} '
        '(${run.loud.inMilliseconds}ms loud, peakRms=${run.peakRms.toStringAsFixed(0)}) — $why; greeting keeps playing '
        '(${_cameraPrewarmStateAt(run.startedAt)})',
      );
    }
    if (action == WakeGreetingMicAction.bargeIn) {
      final onset = gate.bargeInOnset;
      final interruptedMidClip = greeting.isActive;
      greeting.stop(WakeGreetingOutcome.interrupted, 'technician speaking');
      gate.resolveBargeIn(startedAt: greeting.startedAt);
      _log_(
        'WAKE GREETING INTERRUPT: technician still speaking (speech began ${onset == null ? '?' : wakeGreetingTs(onset)}, '
        'mic peakRms=${gate.peakRms.toStringAsFixed(0)}, sustained and outside the clip\'s echo window; '
        '${onset == null ? '' : _cameraPrewarmStateAt(onset)}) — '
        '${interruptedMidClip ? 'greeting clip stopped' : 'greeting had already finished'}, their speech goes on to the '
        'normal command pipeline',
      );
      if (interruptedMidClip) _armGreetingReplayCheck();
      _closeGreetingMicGate('barge-in');
    }
    return true;
  }

  // --- Greeting replay safety net --------------------------------------
  //
  // ec736a7a log: a barge-in that wasn't speech left an empty utterance
  // (final text=""), ~7s of "Thinking...", then Gemini's own unrequested
  // "Hello!". If a barge-in's utterance turns out to have no words, the
  // greeting is spoken again (through Gemini's voice — the mic is live by
  // then, and that path pauses it during playback) instead of leaving the
  // technician in dead air.

  /// Armed by a mid-clip barge-in; disarmed by the first real transcript.
  bool _greetingReplayArmed = false;
  Timer? _greetingReplayTimer;

  /// After the barge-in's utterance ends with no words, how long to still
  /// wait for a late transcript before replaying. The norm in ec736a7a was
  /// 1.3-1.8s from speech end to transcript.
  static const Duration _greetingReplayWait = Duration(milliseconds: 2500);

  void _armGreetingReplayCheck() {
    _greetingReplayArmed = true;
  }

  /// Any real (non-echo) transcript chunk: the barge-in was the technician.
  void _disarmGreetingReplay(String reason) {
    if (!_greetingReplayArmed) return;
    _greetingReplayArmed = false;
    _greetingReplayTimer?.cancel();
    _greetingReplayTimer = null;
    _log_('GREETING REPLAY: not needed — $reason');
  }

  /// At an utterance end: if the barge-in's utterance produced no words,
  /// start the short wait before replaying.
  void _maybeScheduleGreetingReplay(String finalText) {
    if (!_greetingReplayArmed || _greetingReplayTimer != null) return;
    if (finalText.trim().isNotEmpty) {
      _disarmGreetingReplay('the barge-in utterance had words ("$finalText")');
      return;
    }
    _greetingReplayTimer = Timer(_greetingReplayWait, () {
      _greetingReplayTimer = null;
      if (!_greetingReplayArmed || !mounted || _sessionClosing) return;
      _greetingReplayArmed = false;
      if (_anyTriggerCommittedThisUtterance || _guardFailedReplySpokenThisUtterance || _inFlightFunctionCalls > 0) {
        _log_('GREETING REPLAY: skipped — something already answered this utterance');
        return;
      }
      _log_(
        'GREETING REPLAY: the barge-in that stopped the greeting produced no words (empty transcript after '
        '${_greetingReplayWait.inMilliseconds}ms) — it was not the technician; speaking the greeting again',
      );
      _stopAwaitingLateTranscript('greeting replay (barge-in was not speech)');
      _sessionGreetingHandled = true;
      _informGeminiToSpeakVerbatim(_sessionGreetingText, reason: 'session_greeting_replay');
    });
  }

  /// Forwards whatever the gate released, oldest first, and lets every
  /// later chunk go straight through.
  void _closeGreetingMicGate(String reason) {
    final gate = _greetingMicGate;
    _greetingMicGateClosed = true;
    if (gate == null) return;
    final released = gate.takeReleased();
    final releasedMs = released.fold<int>(0, (ms, c) => ms + _pcmBytesToMs(c.length));
    _log_('WAKE GREETING: mic gate closed ($reason) — forwarding ${released.length} chunk(s) / ${releasedMs}ms');
    for (final chunk in released) {
      _routeMicChunk(chunk);
    }
  }

  /// Every recorder chunk lands here: held in [_preSetupAudio] until the
  /// session is ready, then passed straight to [_onMicChunk] — after the
  /// wake-greeting gate, while a greeting clip is in play.
  void _onRawMicChunk(Uint8List chunk) {
    if (_passThroughGreetingMicGate(chunk)) return;
    _routeMicChunk(chunk);
  }

  void _routeMicChunk(Uint8List chunk) {
    if (!_bufferingPreSetupAudio) {
      _onMicChunk(chunk);
      return;
    }
    _preSetupAudio.addLast(chunk);
    _preSetupAudioBytes += chunk.length;
    while (_preSetupAudioBytes > _preSetupAudioMaxBytes && _preSetupAudio.length > 1) {
      final dropped = _preSetupAudio.removeFirst();
      _preSetupAudioBytes -= dropped.length;
      _preSetupAudioDroppedBytes += dropped.length;
    }
  }

  /// Sends the buffered pre-setup audio through the normal [_onMicChunk]
  /// path (so speech-level tracking sees the start of the utterance too),
  /// oldest first, then switches to live. Fully synchronous: recorder
  /// chunks arrive as separate stream events, so none can be delivered in
  /// the middle of this — buffered audio always goes out before live audio,
  /// with nothing dropped or sent twice at the switch.
  void _flushPreSetupAudio() {
    final chunks = _preSetupAudio.length;
    final bytes = _preSetupAudioBytes;
    while (_preSetupAudio.isNotEmpty) {
      _onMicChunk(_preSetupAudio.removeFirst());
    }
    _preSetupAudioBytes = 0;
    _bufferingPreSetupAudio = false;
    _preSetupAudioFlushedMs ??= _pcmBytesToMs(bytes);
    _log_(
      'pre-setup mic audio sent: $chunks chunks / ${_pcmBytesToMs(bytes)}ms captured before the session was ready'
      '${_preSetupAudioDroppedBytes > 0 ? ' (oldest ${_pcmBytesToMs(_preSetupAudioDroppedBytes)}ms dropped over the 8s cap)' : ''}'
      ' — streaming live from here',
    );
  }

  void _onMicChunk(Uint8List chunk) {
    final channel = _channel;
    if (channel == null || _sessionClosing) return;

    // PART K — see [_cameraNativeCallInProgress]'s doc comment: hard-stop, not
    // just "don't send" — skips [_trackSpeechLevel]'s RMS work too, so this
    // is genuinely zero per-chunk processing while the camera is opening,
    // not merely a gated network send.
    if (_cameraNativeCallInProgress) return;

    _trackSpeechLevel(chunk);

    // See `_outgoingAudioPaused` doc comment: capture keeps running (this
    // method still gets called every chunk), only the send to Gemini stops,
    // so resuming needs no recorder/stream reinitialization.
    if (_outgoingAudioPaused) {
      // BUG 2 diagnostic (step 2): edge-triggered (not per-chunk — this
      // fires dozens of times/sec while paused, which would flood the log
      // for no benefit) log of the EXACT moment sending actually stops, at
      // the real gating point itself — not inferred from the
      // `_outgoingAudioPaused` flag flip logged elsewhere. If a future real
      // capture ever shows a "MIC SEND: sending" line with a timestamp
      // between a "PAUSED" and "RESUMED" pair, that's direct proof of a
      // timing gap at THIS exact boundary.
      if (!_micSendCurrentlyPaused) {
        _micSendCurrentlyPaused = true;
        debugPrint('MIC SEND [t=${DateTime.now().millisecondsSinceEpoch}]: STOPPED (outgoing audio paused) — no more realtimeInput sent to Gemini until resumed');
      }
      _outgoingHeldChunks++;
      _diagChunksHeld++;
      return;
    }
    if (_micSendCurrentlyPaused) {
      _micSendCurrentlyPaused = false;
      debugPrint('MIC SEND [t=${DateTime.now().millisecondsSinceEpoch}]: RESUMED — sending realtimeInput to Gemini again');
    }

    final message = jsonEncode({
      'realtimeInput': {
        'audio': {'data': base64Encode(chunk), 'mimeType': 'audio/pcm;rate=$_inputSampleRateHz'},
      },
    });
    channel.sink.add(message);
    _audioChunksSent++;
    _diagChunksSent++;
    _diagBytesSent += chunk.length;
    _diagRmsSum += _lastMicChunkRms;
    _diagLastChunkBytes = chunk.length;
    if (_audioChunksSent == 1) {
      _log_('first audio chunk sent (${chunk.length} bytes)');
    }
    // OUTGOING AUDIO summary — see [_logOutgoingAudioSummary].
    _outgoingSentChunks++;
    _outgoingSentBytes += chunk.length;
    _outgoingRmsSum += _lastMicChunkRms;
    if (_lastMicChunkRms > _outgoingRmsPeak) _outgoingRmsPeak = _lastMicChunkRms;
    if (_lastMicChunkRms < _outgoingAudioSilenceFloorRms) _outgoingSilentChunks++;
  }

  // ===========================================================================
  // OUTGOING AUDIO — release-build diagnostic safety net. CONFIRMED need
  // (flutter_run_log 2801f4bc, release APK only): Gemini returned no
  // transcript for several utterances in a row ("UNCLEAR INPUT: N in a row")
  // while the WebSocket stayed alive. Every ~2s this logs what the send path
  // ACTUALLY did — chunks/bytes sent as realtimeInput, how many of them were
  // near-silent, and how many were captured but held back (outgoing paused)
  // — so the next log proves whether real audio reached Gemini during any
  // "no transcript" stretch. One summary line per window, never per chunk.
  // Driven by a timer, not by chunks, so "the recorder delivered nothing at
  // all" shows up as a line too instead of as silence in the log.
  // ===========================================================================

  /// RMS of the most recent mic chunk, set by [_trackSpeechLevel].
  double _lastMicChunkRms = 0;

  /// Near-zero int16 RMS floor: below this a chunk is effectively digital
  /// silence (a muted/dead input), well under [_speechRmsThreshold]'s
  /// "someone is talking" level — room tone still clears it.
  static const double _outgoingAudioSilenceFloorRms = 30;
  static const Duration _outgoingAudioSummaryInterval = Duration(seconds: 2);

  Timer? _outgoingAudioSummaryTimer;
  DateTime? _outgoingWindowStartedAt;
  int _outgoingSentChunks = 0;
  int _outgoingSentBytes = 0;
  int _outgoingSilentChunks = 0;
  int _outgoingHeldChunks = 0;
  double _outgoingRmsSum = 0;
  double _outgoingRmsPeak = 0;

  void _startOutgoingAudioSummary() {
    _outgoingAudioSummaryTimer?.cancel();
    _resetOutgoingAudioWindow();
    _outgoingAudioSummaryTimer = Timer.periodic(_outgoingAudioSummaryInterval, (_) => _logOutgoingAudioSummary());
  }

  void _stopOutgoingAudioSummary() {
    if (_outgoingAudioSummaryTimer == null) return;
    _outgoingAudioSummaryTimer?.cancel();
    _outgoingAudioSummaryTimer = null;
    _logOutgoingAudioSummary(finalWindow: true);
  }

  void _resetOutgoingAudioWindow() {
    _outgoingWindowStartedAt = DateTime.now();
    _outgoingSentChunks = 0;
    _outgoingSentBytes = 0;
    _outgoingSilentChunks = 0;
    _outgoingHeldChunks = 0;
    _outgoingRmsSum = 0;
    _outgoingRmsPeak = 0;
  }

  void _logOutgoingAudioSummary({bool finalWindow = false}) {
    final startedAt = _outgoingWindowStartedAt;
    final windowMs = startedAt == null ? 0 : DateTime.now().difference(startedAt).inMilliseconds;
    final window = '${(windowMs / 1000).toStringAsFixed(1)}s${finalWindow ? ', final window' : ''}';
    final extras = [
      if (_outgoingHeldChunks > 0) '$_outgoingHeldChunks chunk(s) captured but NOT sent (outgoing paused)',
      if (_cameraNativeCallInProgress) 'camera hard-pause active (mic chunks not processed)',
      if (_channel == null) 'WebSocket closed',
    ];
    final String line;
    if (_outgoingSentChunks == 0) {
      line = _outgoingHeldChunks == 0 && !_cameraNativeCallInProgress
          ? 'OUTGOING AUDIO: last $window — NOTHING sent and NO mic chunks captured at all (recorder delivered no audio)'
          : 'OUTGOING AUDIO: last $window — sent 0 chunks; ${extras.join('; ')}';
    } else {
      final avgBytes = _outgoingSentBytes ~/ _outgoingSentChunks;
      final silentPct = (_outgoingSilentChunks * 100 / _outgoingSentChunks).round();
      final avgRms = _outgoingRmsSum / _outgoingSentChunks;
      line = 'OUTGOING AUDIO: last $window — sent $_outgoingSentChunks chunks '
          '($_outgoingSentBytes bytes, avg $avgBytes bytes/chunk, ~${_pcmBytesToMs(_outgoingSentBytes)}ms audio), '
          '$silentPct% silent (RMS < ${_outgoingAudioSilenceFloorRms.toStringAsFixed(0)}), '
          'RMS avg ${avgRms.toStringAsFixed(0)} / peak ${_outgoingRmsPeak.toStringAsFixed(0)}'
          '${extras.isEmpty ? '' : '; ${extras.join('; ')}'}; total sent this session: $_audioChunksSent';
    }
    _logNoState(line);
    _resetOutgoingAudioWindow();
  }

  /// BUG 2 diagnostic: tracks the edge for the [_onMicChunk] logging above —
  /// separate from [_outgoingAudioPaused] itself so the log lines fire
  /// exactly once per transition, at the real send-gating site.
  bool _micSendCurrentlyPaused = false;

  /// The DETERMINISTIC RESET for a genuinely new utterance — what it clears
  /// is exactly what [_trackSpeechLevel]'s silence->speech edge always
  /// cleared (moved here unchanged so a second, transcript-based detector —
  /// [_attributeTranscriptChunkToUtterance] — runs the SAME reset).
  /// [fromTranscript]: a real transcript chunk is already in hand, so the
  /// "waiting for the first transcript" hold is not armed.
  void _startNewUtterance(DateTime now, {required String cause, bool fromTranscript = false}) {
    _utteranceSeq++;
    _currentUtteranceStartedAt = now;
    _latencySpeechEndAt = null;
    _latencyTranscriptAt = null;
    _finalizedCurrentUtterance = false;
    _lateTranscriptFinalizeTimer?.cancel();
    _lateTranscriptFinalizeTimer = null;
    _stopAwaitingLateTranscript('new utterance started');
    _pipelineLog('utterance_start', cause);
    debugPrint(
      'DETERMINISTIC RESET: new utterance — clearing all trigger buffers/resolved flags '
      '(outgoingAudioPaused=$_outgoingAudioPaused${fromTranscript ? ', transcript-detected' : ''})',
    );
    _utteranceCommittedAt = null;
    _utteranceLastChunkAt = null;
    // Fresh utterance starting — new detection buffers so stale text
    // from an earlier, unrelated sentence can never combine with this
    // one to produce a false match.
    _goBackIntentDetectionBuffer = '';
    _goBackTriggerResolvedForCurrentUtterance = false;
    _viewEstimateDetectionBuffer = '';
    _viewEstimateDetectionResolvedForCurrentUtterance = false;
    _getJobDetailsDetectionBuffer = '';
    _getJobDetailsDetectionResolvedForCurrentUtterance = false;
    _getCurrentScreenDetectionBuffer = '';
    _getCurrentScreenDetectionResolvedForCurrentUtterance = false;
    _metaCapabilityDetectionBuffer = '';
    _metaCapabilityDetectionResolvedForCurrentUtterance = false;
    _acknowledgePresenceDetectionBuffer = '';
    _acknowledgePresenceResolvedForCurrentUtterance = false;
    _photoDecisionDetectionBuffer = '';
    _photoDecisionResolvedForCurrentUtterance = false;
    _jobDetailsDestinationBuffer = '';
    _jobDetailsDestinationResolvedForCurrentUtterance = false;
    _jobDetailsDestinationFiredThisUtterance = false;
    _goBackFiredThisUtterance = false;
    for (final trigger in _deterministicTriggers.values) {
      trigger.resetForNewUtterance();
    }
    // PART G item 1 — see [_utteranceAlreadyResolvedByTrigger]'s doc
    // comment: THIS is the only place that flag is allowed to clear —
    // a genuinely new utterance, not the more frequent mid-utterance
    // reset in [_clearAllTriggerBuffersAfterSuccess].
    _utteranceAlreadyResolvedByTrigger = false;
    _guardFailedReplySpokenThisUtterance = false;
    _pendingGuardFailedReply = null;
    // P0 FIX — see [_awaitingFirstTranscriptOfUtterance]. Only when mic
    // audio is actually reaching Gemini: while [_outgoingAudioPaused],
    // Gemini can't be answering this speech (and it's most likely our
    // own playback echoing back anyway).
    if (!_outgoingAudioPaused && !fromTranscript) _beginAwaitingFirstTranscript();
    // PART J item 1 — see [_pcmReinitIssuedForCurrentUtterance]'s doc
    // comment: same lifecycle as the flag just above — a genuinely new
    // utterance is allowed exactly one more real PCM reinit.
    _pcmReinitIssuedForCurrentUtterance = false;
    // BUG 4 FIX (CONFIRMED via flutter_run_log_new.txt, build #56):
    // queued PCM audio used to be discarded RIGHT HERE, on the same
    // raw-amplitude edge as the text-buffer reset above — but unlike
    // those buffers (genuinely safe to clear on any 2s-silence gap,
    // real speech or not), a queued PCM chunk can be a just-generated,
    // not-yet-played response to something the app ITSELF just did
    // (e.g. confirm_photo_upload's own "I've uploaded the photo"
    // confirmation, queued behind that action's own PCM reinit).
    // Discarding real, wanted audio on nothing but background mic noise
    // — no real transcript text required — silently ate that exact
    // confirmation once, 100% reproducibly. The discard now happens in
    // [_muteImmediatelyOnFirstChunkOfUtterance] instead, gated on a
    // genuinely new utterance's first REAL transcript chunk arriving,
    // not a bare amplitude blip. See that method's own doc comment.
  }

  // ===========================================================================
  // UTTERANCE ATTRIBUTION — CONFIRMED REGRESSION (logcat 09-28 17:32:03-
  // 17:33:01): after open_camera committed, "Capture the photo.", "Take the
  // photo." and "Go back." all arrived under the SAME, already-committed
  // utterance id and were never evaluated ("utterance was ALREADY committed
  // before this chunk"); the reset only came ~41s later. New-utterance
  // detection was purely acoustic ([_trackSpeechLevel]: a chunk over
  // [_speechRmsThreshold] after [_utteranceBufferResetDebounce] of nothing
  // over it), so a quieter mic level (headset, voice-communication AGC) or
  // anything keeping the level up between commands meant no edge, ever.
  // A transcript chunk is itself proof of speech, so it can now start the
  // new utterance too, whenever it clearly can't belong to the committed one.
  // ===========================================================================

  /// When the current utterance committed to a trigger (see
  /// [_clearAllTriggerBuffersAfterSuccess] and the evaluator loop in
  /// [_onInputTranscription]); `null` while it hasn't.
  DateTime? _utteranceCommittedAt;

  /// Arrival time of the last transcript chunk attributed to the current
  /// utterance.
  DateTime? _utteranceLastChunkAt;

  /// When the most recent model turn the technician actually HEARD ended
  /// (`turnComplete`/`interrupted` with audibly played text). A muted turn
  /// doesn't count: a deterministic trigger interrupts Gemini's own muted
  /// reply moments after committing, and a trailing chunk of that same
  /// command arriving after that interrupt must not be split off.
  DateTime? _lastModelTurnEndedAt;

  /// Called at every model turn boundary, before [_logAndResetTurnShape]
  /// clears the turn's text.
  void _noteAudibleModelTurnEnded() {
    if (_currentTurnAudiblyPlayedText.trim().isNotEmpty) _lastModelTurnEndedAt = DateTime.now();
  }

  /// A chunk arriving this long after both the commit and this utterance's
  /// previous chunk can't be one of its trailing chunks (those land within
  /// about a second of each other).
  static const Duration _committedUtteranceChunkGap = Duration(milliseconds: 2500);

  /// Called for every real transcript chunk (past the echo backstop),
  /// before any trigger sees it. If the current utterance has already
  /// committed AND either a model reply finished after that commit (and
  /// after this utterance's last chunk), or [_committedUtteranceChunkGap]
  /// has passed since both — this chunk is a new request, so the same
  /// [_startNewUtterance] reset runs first. A trailing chunk of the SAME
  /// utterance (arriving right after the commit, before any reply) stays
  /// attributed to it, exactly as before.
  void _attributeTranscriptChunkToUtterance(String textChunk) {
    final now = DateTime.now();
    final committedAt = _utteranceCommittedAt;
    final lastChunkAt = _utteranceLastChunkAt;
    String? newUtteranceBecause;
    if (_anyTriggerCommittedThisUtterance && committedAt != null) {
      final turnEnded = _lastModelTurnEndedAt;
      final sinceCommit = now.difference(committedAt);
      final sinceLastChunk = lastChunkAt == null ? null : now.difference(lastChunkAt);
      if (turnEnded != null && turnEnded.isAfter(committedAt) && (lastChunkAt == null || turnEnded.isAfter(lastChunkAt))) {
        newUtteranceBecause = 'a model reply ended ${now.difference(turnEnded).inMilliseconds}ms ago, after '
            'u=$_utteranceSeq committed ${sinceCommit.inMilliseconds}ms ago';
      } else if (sinceCommit >= _committedUtteranceChunkGap &&
          (sinceLastChunk == null || sinceLastChunk >= _committedUtteranceChunkGap)) {
        newUtteranceBecause = '${sinceLastChunk?.inMilliseconds ?? '-'}ms since u=$_utteranceSeq\'s last chunk and '
            '${sinceCommit.inMilliseconds}ms since it committed';
      }
    }
    final loudAt = _lastLoudMicChunkAt;
    final micState = 'mic: last chunk over RMS ${_speechRmsThreshold.toStringAsFixed(0)} '
        '${loudAt == null ? 'never' : '${now.difference(loudAt).inMilliseconds}ms ago'}, last RMS '
        '${_lastMicChunkRms.toStringAsFixed(0)}, isSpeaking=$_isSpeaking';
    if (newUtteranceBecause != null) {
      final previous = _utteranceSeq;
      _startNewUtterance(
        now,
        cause: 'transcript-detected — "$textChunk" arrived for committed u=$previous: $newUtteranceBecause '
            '(the mic-level edge never fired; $micState)',
        fromTranscript: true,
      );
      // The acoustic edge missed this speech, so don't let a late one split
      // it again mid-sentence…
      _lastSpeechActivityAt = now;
      // …and if the mic doesn't think anyone is talking, the end-of-
      // utterance routing won't come from the silence edge either — let the
      // existing late-transcript finalize path run it (see
      // [_onInputTranscription]'s `arrivedAfterUtteranceEnd`).
      if (!_isSpeaking) _finalizedCurrentUtterance = true;
    }
    _logNoState(
      'UTTERANCE ATTRIBUTION: chunk at $now attributed to u=$_utteranceSeq'
      '${newUtteranceBecause != null ? ' (NEW — split from the committed utterance)' : ''}, '
      '${lastChunkAt == null || newUtteranceBecause != null ? 'first chunk of this utterance' : '${now.difference(lastChunkAt).inMilliseconds}ms since its previous chunk'}, '
      '${committedAt == null || newUtteranceBecause != null ? 'not committed' : '${now.difference(committedAt).inMilliseconds}ms since it committed'}; '
      '$micState',
    );
    _utteranceLastChunkAt = now;
  }

  /// Rough int16 RMS over [chunk], used only to time "user stopped
  /// speaking" for the latency stopwatch — not sent anywhere, not used for
  /// turn-taking (Gemini does its own server-side VAD for that).
  void _trackSpeechLevel(Uint8List chunk) {
    if (chunk.length < 2) return;
    final samples = ByteData.sublistView(chunk);
    final sampleCount = chunk.length ~/ 2;
    double sumSquares = 0;
    for (var i = 0; i < sampleCount; i++) {
      final sample = samples.getInt16(i * 2, Endian.little);
      sumSquares += sample * sample;
    }
    final rms = sampleCount == 0 ? 0.0 : (sumSquares / sampleCount);
    final amplitude = rms <= 0 ? 0.0 : _sqrt(rms);
    // Read by the OUTGOING AUDIO summary in [_onMicChunk] — reuses this RMS
    // rather than computing it a second time per chunk.
    _lastMicChunkRms = amplitude;

    if (amplitude > _speechRmsThreshold) {
      final now = DateTime.now();
      // P0 AUDIO-ECHO FIX — see [_maybeResumeOutgoingAudio]'s doc comment
      // for the full mechanism this feeds. Recorded UNCONDITIONALLY here
      // (paused or not — this is the one place raw mic amplitude is
      // already computed for every chunk, echo-relevant or not) so the
      // outgoing-mic resume logic can ask "has the mic genuinely gone
      // quiet" using REAL signal from the mic itself, instead of trusting
      // a single fixed timer to have guessed the right wait every time.
      _lastLoudMicChunkAt = now;
      // Reset the inactivity timer only on the silence->speech EDGE (not
      // every chunk while already speaking, which would churn the timer
      // dozens of times a second and flood the log for no benefit), and
      // only while outgoing audio is actually being forwarded to Gemini
      // (`!_outgoingAudioPaused`). That second guard matters here
      // specifically: while a response plays back, the phone's own speaker
      // output can leak into the mic and register as "speech" even though
      // the technician hasn't said anything — without it, Gemini's OWN
      // voice (including the inactivity warning itself) could keep
      // resetting this timer and the close would never actually fire.
      if (!_isSpeaking && !_outgoingAudioPaused) {
        _resetInactivityTimer(reason: 'technician speech detected');
      }
      // CONFIRMED bug: this used to reset on the SAME [_isSpeaking] 500ms
      // edge as the block above — wiping every trigger's buffer on any
      // natural mid-sentence pause over 500ms (a real risk for phrases like
      // "which page are we on"), discarding a phrase that was already
      // correctly in a trigger's indicator-phrase list before it ever
      // finished accumulating. Decoupled from [_isSpeaking] via
      // [_lastSpeechActivityAt]/[_utteranceBufferResetDebounce] instead — see
      // that constant's doc comment.
      final lastActivity = _lastSpeechActivityAt;
      final isGenuinelyNewUtterance =
          lastActivity == null || now.difference(lastActivity) >= _utteranceBufferResetDebounce;
      // PART I item 2 (CONFIRMED unresolved bug: by the end of a session,
      // the deterministic buffers were matching against multiple previous
      // unrelated utterances concatenated together, including garbled ASR
      // noise). Root cause: this reset used to ALSO require
      // `!_outgoingAudioPaused` — added to stop a raw-amplitude false
      // "speech" edge from a response's own audio leaking into the mic —
      // but that guard gated the ENTIRE reset, not just the (separate,
      // still-guarded) inactivity-timer reset above. Any time the
      // technician's genuinely NEW utterance began while
      // `_outgoingAudioPaused` was still true (barge-in over a still-
      // playing response, or that flag simply stuck true — see the
      // now-removed "if this keeps printing true" diagnostic this replaces)
      // the reset was skipped ENTIRELY, forever, for that edge — and
      // `_lastSpeechActivityAt`/`_isSpeaking` were updated regardless
      // (unconditionally, below), so the debounce window kept advancing
      // while the stale buffers underneath it never actually emptied.
      // Safe to unconditionally reset here regardless of echo: this only
      // runs after [_utteranceBufferResetDebounce] (2s) of genuine
      // silence/pause, so whatever's in these buffers is ALREADY stale by
      // then whether this particular edge is real speech or an echo false
      // positive — there is no in-progress utterance's buffer content this
      // could wrongly discard.
      if (isGenuinelyNewUtterance) {
        _startNewUtterance(now, cause: 'mic heard speech after silence (outgoingAudioPaused=$_outgoingAudioPaused)');
      }
      // See [_speechMaxContinuousDuration]'s doc comment: edge-only, exactly
      // like [_lastSpeechActivityAt] below it — marks when THIS burst began,
      // not refreshed on every chunk while already speaking.
      if (!_isSpeaking) {
        _speechBurstStartedAt = now;
        _speechBurstReachedGemini = !_outgoingAudioPaused;
      }
      _lastSpeechActivityAt = now;
      _isSpeaking = true;
      _speechStoppedAt = null;
      // BUG FIX (confirmed via log evidence): must null this out, not just
      // cancel it — a `cancel()` alone leaves `_silenceTimer` pointing at a
      // dead Timer object, so the `??=` guard below permanently refuses to
      // schedule a new one for the rest of the session the moment a SECOND
      // speech burst interrupts a pending silence debounce (any natural
      // mid-utterance pause). That left `_isSpeaking` stuck `true` forever,
      // which silently starved every silence->speech reset in this method
      // (and the deterministic-trigger buffer resets below) for the rest of
      // the session after the first such interruption — matching the
      // observed "timer only ever reset once" symptom.
      _silenceTimer?.cancel();
      _silenceTimer = null;
    } else if (_isSpeaking) {
      _silenceTimer ??= Timer(_silenceDebounce, () {
        _silenceTimer = null;
        _markStoppedSpeaking(reason: 'detected user stopped speaking — latency stopwatch started');
      });
    }
  }

  /// The one place [_isSpeaking] transitions back to `false` — used by both
  /// the natural silence-timer edge above and [_speechStuckWatchdogTimer]'s
  /// hard fallback, so the two paths can never drift apart (same log shape,
  /// same [_speechStoppedAt]/[_speechBurstStartedAt] bookkeeping, same
  /// [_finalizeUtteranceEndDeterministicTriggers] call).
  void _markStoppedSpeaking({required String reason}) {
    _isSpeaking = false;
    _speechStoppedAt = DateTime.now();
    // LATENCY metric only — see [_latencySpeechEndAt]. Only speech Gemini
    // actually received can be what it is answering.
    if (_speechBurstReachedGemini) _latencySpeechEndAt = _speechStoppedAt;
    _speechBurstStartedAt = null;
    _log_(reason);
    _finalizeUtteranceEndDeterministicTriggers();
  }

  /// See [_speechMaxContinuousDuration]'s doc comment — the hard fallback
  /// itself. Ticked every second by [_speechStuckWatchdogTimer] for as long
  /// as the mic is streaming; a no-op unless a single continuous burst has
  /// genuinely overrun the ceiling, which never happens for real speech.
  void _checkSpeechStuckWatchdog() {
    if (!_isSpeaking) return;
    final burstStartedAt = _speechBurstStartedAt;
    if (burstStartedAt == null) return;
    final burstDuration = DateTime.now().difference(burstStartedAt);
    if (burstDuration < _speechMaxContinuousDuration) return;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _markStoppedSpeaking(
      reason: 'SPEECH WATCHDOG: forcing "stopped speaking" after a ${burstDuration.inMilliseconds}ms continuous '
          'burst — the normal silence->speech edge in _trackSpeechLevel never fired one on its own (see '
          '_speechMaxContinuousDuration\'s doc comment).',
    );
  }

  double _sqrt(double value) {
    if (value == 0) return 0;
    var x = value;
    var guess = value / 2;
    for (var i = 0; i < 20; i++) {
      guess = (guess + x / guess) / 2;
    }
    return guess;
  }

  /// (Re)starts both the warning ([_inactivityWarningDelay]) and close
  /// ([_inactivityTimeoutDelay]) inactivity timers from now. Called on every
  /// event that counts as genuine session activity — NOT just once at
  /// session start (CONFIRMED bug: it used to only ever reset on the
  /// silence->speech edge and the initial toolCall-received event, then
  /// silently stopped resetting for the rest of the session the first time
  /// a mid-utterance pause hit a [_trackSpeechLevel] bug — see the doc
  /// comment on the `_silenceTimer = null` line there):
  ///  - session becoming active ([_startMicStreaming])
  ///  - the technician starting to speak, the raw-amplitude silence->speech
  ///    edge ([_trackSpeechLevel])
  ///  - every transcribed chunk of the technician's real speech
  ///    ([_onInputTranscription])
  ///  - a toolCall message arriving, AND each function call within it
  ///    succeeding ([_onServerMessage]/[_handleToolCall])
  ///
  /// P0 FIX (CONFIRMED regression, REMOVED): response audio STARTING/
  /// FINISHING playback ([_onResponseAudioChunk]'s PAUSE /
  /// [_maybeResumeOutgoingAudio]'s RESUME) used to ALSO reset both timers
  /// here — "so a long Gemini response with little raw silence around it
  /// never starves the timer." That made the close timer effectively
  /// unreachable: [_fireInactivityWarning] speaks its OWN warning through
  /// this exact pause->resume cycle, so the warning re-armed its own full
  /// 50s/60s window every time it spoke — confirmed via a real session
  /// where it looped three times over ~75s and the session never closed.
  /// The genuine "a long real response/action must not look like silence"
  /// concern is still covered, without this self-defeating property, by
  /// [_inFlightFunctionCalls] suspending both timers for the DISPATCH
  /// portion of any real action, and by the genuine technician input that
  /// started the exchange having already reset the full window before
  /// Gemini ever began responding.
  ///
  /// Cancels any previously scheduled pair first so a reset always restarts
  /// the full window rather than layering timers on top of each other. The
  /// 50s warning/60s close should therefore only ever fire after genuinely
  /// continuous silence from the TECHNICIAN (Gemini's own speech no longer
  /// counts, and never should — see the removal above) for that full
  /// duration.
  void _resetInactivityTimer({required String reason}) {
    _inactivityWarningTimer?.cancel();
    _inactivityTimeoutTimer?.cancel();
    // FIX 1 (CRITICAL, confirmed via log evidence): the timer fired and
    // closed the session WHILE open_camera was still stuck loading (66+
    // seconds) — the camera opened into an already-dead connection. A
    // function call genuinely in flight must never count as silence, no
    // matter how long it takes; see [_inFlightFunctionCalls]'s doc comment.
    // Suspended here rather than at every individual reset call site so
    // this one guard covers all of them (technician speech, transcription
    // chunks, response pause/resume, toolCall received) — normal countdown
    // resumes, fresh, the instant [_endFunctionCallInFlight] brings the
    // count back to zero.
    if (_inFlightFunctionCalls > 0) {
      _log_(
        'inactivity timer reset SKIPPED ($reason) — $_inFlightFunctionCalls function call(s) still in flight, '
        'timer stays suspended until they finish',
      );
      return;
    }
    debugPrint('GEMINI LIVE INACTIVITY: timer (re)started ($reason)');
    _log_(
      'inactivity timer (re)started ($reason) — warning at '
      '${_inactivityWarningDelay.inSeconds}s, close at ${_inactivityTimeoutDelay.inSeconds}s',
    );
    _inactivityWarningTimer = Timer(_inactivityWarningDelay, _fireInactivityWarning);
    _inactivityTimeoutTimer = Timer(_inactivityTimeoutDelay, _fireInactivityTimeout);
  }

  /// FIX 1 (CRITICAL, confirmed via log evidence): counts how many
  /// `dispatchGeminiFunctionCall` invocations are currently in flight, from
  /// ANY dispatch call site in this file (a genuine Gemini-issued toolCall
  /// in [_handleToolCall], or any deterministic trigger's own dispatch).
  /// While this is > 0, [_resetInactivityTimer] refuses to (re)schedule
  /// either timer — a slow function call (open_camera has been observed
  /// taking 66+ seconds) must never be treated as silence. See
  /// [_beginFunctionCallInFlight]/[_endFunctionCallInFlight].
  int _inFlightFunctionCalls = 0;

  /// Marks one function call as started — call exactly once per
  /// `dispatchGeminiFunctionCall` invocation, paired with EXACTLY one
  /// [_endFunctionCallInFlight] call (success or failure) via `finally`.
  void _beginFunctionCallInFlight(String reason) {
    _inFlightFunctionCalls++;
    _log_('inactivity timer: function call STARTED ($reason) — $_inFlightFunctionCalls now in flight');
    _logCrossRef('FUNCTION CALL STARTED', reason);
    _inactivityWarningTimer?.cancel();
    _inactivityTimeoutTimer?.cancel();
    _syncVoicePhase();
  }

  /// Marks one function call as finished (success or failure) — the instant
  /// the count reaches zero, normal countdown resumes fresh via
  /// [_resetInactivityTimer], from THIS moment, not whenever the call
  /// happened to start.
  void _endFunctionCallInFlight(String reason) {
    _inFlightFunctionCalls = (_inFlightFunctionCalls - 1).clamp(0, 1 << 30);
    _log_('inactivity timer: function call FINISHED ($reason) — $_inFlightFunctionCalls still in flight');
    _logCrossRef('FUNCTION CALL FINISHED', reason);
    if (_inFlightFunctionCalls == 0) {
      _resetInactivityTimer(reason: 'last in-flight function call finished ($reason)');
    }
    _syncVoicePhase();
  }

  /// ISSUE 2 (HIGH PRIORITY, CONFIRMED via f5a8bd8b-flutter_run_log.txt): a
  /// get_kb_answer dispatch for an abandoned "who is the president of
  /// India?" question, started at 11:42:39.823, didn't resolve until
  /// 11:42:57.497 — by which point the technician had moved on and said
  /// "I want to take a photo," which resolved and started speaking "Camera's
  /// open..." at 11:42:57.592. The ancient KB answer arrived right in that
  /// window and interrupted the fresh camera confirmation mid-word. Every
  /// real dispatch (a deterministic trigger firing OR a genuine Gemini
  /// toolCall — see every call site that reads/writes this) is assigned the
  /// next value here, captured at the INSTANT it begins (before any await),
  /// so dispatches are ordered by when the technician's request actually
  /// started, not by when their (possibly much slower) backend call happens
  /// to finish.
  int _dispatchGenerationCounter = 0;

  /// The highest [_dispatchGenerationCounter] value among dispatches that
  /// have SUCCEEDED so far (result received with no `error`) — see
  /// [_recordDispatchSucceeded]. A dispatch whose own generation is LOWER
  /// than this by the time IT resolves started before, and is now stale
  /// relative to, a request the technician has since made and already had
  /// answered — see [_discardIfStaleDispatch].
  int _latestSucceededDispatchGeneration = 0;

  /// Which trigger/function name achieved [_latestSucceededDispatchGeneration]
  /// — purely for the "superseded by X" half of the
  /// "STALE TRIGGER RESOLUTION DISCARDED" log line.
  String? _latestSucceededDispatchTriggerName;

  /// When [_latestSucceededDispatchGeneration] was recorded — purely so a
  /// later stale resolution can log how many ms after being superseded it
  /// actually resolved, straight from real timestamps.
  DateTime? _latestSucceededDispatchAt;

  /// Call at the very start of every real dispatch (deterministic trigger
  /// firing, KB catch-all firing, or a genuine Gemini toolCall dispatching),
  /// before any `await` — captures this dispatch's place in the technician's
  /// real request order. See [_dispatchGenerationCounter]'s doc comment.
  int _beginNewDispatchGeneration() => ++_dispatchGenerationCounter;

  /// Call once a dispatch genuinely SUCCEEDS (result received, no `error`
  /// key), before speaking/interrupting for it — records that this is now
  /// the newest successfully-resolved request, so any OLDER, still-pending
  /// dispatch that resolves later can recognize itself as stale. A no-op if
  /// an even newer dispatch already succeeded first (never moves generation
  /// backward).
  void _recordDispatchSucceeded(int generation, String triggerName) {
    if (generation <= _latestSucceededDispatchGeneration) return;
    _latestSucceededDispatchGeneration = generation;
    _latestSucceededDispatchTriggerName = triggerName;
    _latestSucceededDispatchAt = DateTime.now();
  }

  /// Call right before a dispatch's resolution would interrupt/speak
  /// (`_informGeminiToSpeakVerbatim` or equivalent) — `true` means a NEWER
  /// dispatch has already succeeded since this one started, so this
  /// resolution is stale and must be discarded rather than interrupting or
  /// overwriting whatever the newer one is currently saying. Logs the exact
  /// "STALE TRIGGER RESOLUTION DISCARDED" line ISSUE 2 asks for either way
  /// this is used, so it's directly greppable in the next real log.
  bool _discardIfStaleDispatch({required int generation, required String triggerName}) {
    if (generation >= _latestSucceededDispatchGeneration) return false;
    final supersededBy = _latestSucceededDispatchTriggerName ?? 'a newer trigger';
    final supersededAt = _latestSucceededDispatchAt;
    final elapsedMs = supersededAt == null ? null : DateTime.now().difference(supersededAt).inMilliseconds;
    _log_(
      'STALE TRIGGER RESOLUTION DISCARDED: $triggerName resolved '
      '${elapsedMs == null ? '' : '${elapsedMs}ms '}after being superseded by $supersededBy — not interrupting '
      'current speech.',
    );
    debugPrint(
      'PHOTO TIMING [stale_trigger]: $triggerName (generation $generation) discarded — superseded by '
      '$supersededBy (generation $_latestSucceededDispatchGeneration)',
    );
    return true;
  }

  /// FIX 3: prints a `debugPrint` line in the EXACT SAME `[t=<epoch ms>]`
  /// format `voice_command_registry_provider.dart`'s `_logChange` already
  /// uses for its `VOICE REGISTRY .../*** RAPID SWAP ***` lines — `_log_`'s
  /// own timestamp format (`HH:mm:ss.SSS`, local wall-clock) isn't directly
  /// diffable against that epoch-ms format without manual conversion. Used
  /// at exactly the two events STEP 3 needs to cross-reference against a
  /// RAPID SWAP warning: a function call (e.g. open_camera) starting/
  /// finishing, and every "GEMINI SAID" output-transcription line — so
  /// whether a slow open_camera call genuinely overlaps a RAPID SWAP event
  /// can be read directly off two `[t=...]`-prefixed lines instead of
  /// converted/guessed.
  void _logCrossRef(String label, String detail) {
    debugPrint('CROSSREF [t=${DateTime.now().millisecondsSinceEpoch}]: $label — $detail');
  }

  /// Cancels both inactivity timers without rescheduling — called from
  /// [_teardown] so a session that's already ending (Loop Off, end_session,
  /// or the timeout itself) can't also fire the OTHER timer of the pair
  /// afterward against an already-closed WebSocket.
  void _cancelInactivityTimer() {
    _inactivityWarningTimer?.cancel();
    _inactivityWarningTimer = null;
    _inactivityTimeoutTimer?.cancel();
    _inactivityTimeoutTimer = null;
  }

  /// Fires at [_inactivityWarningDelay] into a silent session. Prompts
  /// Gemini to speak [_inactivityWarningText] verbatim over its own Live
  /// conversation turn — a `clientContent` turn instructing it to say that
  /// exact line, not a separate on-device TTS call (see
  /// [_inactivityWarningText]'s doc comment for why). Does NOT touch
  /// [_inactivityTimeoutTimer]: the close still fires on its original
  /// schedule unless a genuine turn resets both via [_resetInactivityTimer]
  /// in the meantime.
  void _fireInactivityWarning() {
    _inactivityWarningTimer = null;
    if (_channel == null) {
      _log_('inactivity warning: WebSocket already closed — skipping');
      return;
    }
    debugPrint('GEMINI LIVE INACTIVITY: warning fired (${_inactivityWarningDelay.inSeconds}s of silence)');
    _log_('inactivity warning: ${_inactivityWarningDelay.inSeconds}s of silence — asking Gemini to speak the warning');
    _informGeminiToSpeakVerbatim(_inactivityWarningText, reason: 'inactivity_warning');
    // Distinct, greppable line requested for the next real test — this fires
    // purely from [_inactivityWarningTimer]'s own wall-clock Timer, driven by
    // [_resetInactivityTimer] (see that method's doc comment): NOT gated on
    // [_isSpeaking] or any other transient per-utterance flag.
    debugPrint('INACTIVITY WARNING: spoken');
  }

  /// Fires at [_inactivityTimeoutDelay] into a silent session — no
  /// technician speech or function call reset the timer in between (see
  /// [_resetInactivityTimer]). Closes exactly the same way as the
  /// technician saying "Loop Off"/"FieldLoop stop": the same [_stopTest]
  /// call the end_session toolCall branch and the manual Stop button both
  /// use, so there's only ever one clean-close code path.
  void _fireInactivityTimeout() {
    _inactivityTimeoutTimer = null;
    debugPrint('GEMINI LIVE INACTIVITY: ${_inactivityTimeoutDelay.inSeconds}s silence timeout reached — closing session');
    _log_('inactivity timeout: ${_inactivityTimeoutDelay.inSeconds}s of silence — closing session (same as Loop Off)');
    // Distinct, greppable line requested for the next real test — same
    // wall-clock-only guarantee as [_fireInactivityWarning]'s own line above.
    debugPrint('INACTIVITY: auto-closing session');
    unawaited(_stopTest(reason: 'inactivity timeout'));
  }

  /// Speaks [text] while [name]'s native call still has all audio hard-
  /// paused — see [_fillerPassthroughActive] for how its audio gets past
  /// that pause, and `pending_call_fillers.dart` for the lines/thresholds.
  /// Sent with `isFiller: true` so it never replaces
  /// [_lastVerbatimScriptText]: the completion-claim audit's scripted-line
  /// exemption and the leak-retry must keep pointing at the last REAL
  /// scripted line, not a "still working" filler.
  void _speakPendingCallFiller(String name, String text) {
    if (!_cameraNativeCallInProgress) return;
    _fillerPassthroughActive = true;
    _fillerAudioStarted = false;
    debugPrint('PENDING CALL FILLER [$name]: speaking "$text" at ${DateTime.now()} — passthrough open');
    _informGeminiToSpeakVerbatim(text, reason: 'pending_call_filler[$name]', isFiller: true);
  }

  void _endFillerPassthrough(String reason) {
    if (!_fillerPassthroughActive) return;
    _fillerPassthroughActive = false;
    _fillerAudioStarted = false;
    debugPrint('PENDING CALL FILLER: passthrough closed ($reason) at ${DateTime.now()}');
  }

  /// FIX 2: every function EXCEPT `open_camera` dispatches exactly as
  /// before — this only adds the acknowledgment safeguard around
  /// `open_camera` itself, since that's the one call the reliability audit
  /// found can occasionally run far longer than the ~2-3s typical case. See
  /// [_openCameraAckDelay]'s doc comment for the threshold, and that same
  /// doc comment for why the hard-timeout this method used to ALSO race
  /// against was removed entirely (P0 FIX, build #65) rather than fixed in
  /// place — it produced two directly contradictory spoken messages about
  /// the same open_camera call.
  ///
  /// The real dispatch (`dispatchGeminiFunctionCall`) is started
  /// immediately and simply awaited — Dart's `Future`s aren't preemptible,
  /// and the underlying call is a real platform camera operation mid-
  /// flight, not something safe to abandon in place. At [_openCameraAckDelay],
  /// if it hasn't finished yet, [_speakPendingCallFiller] fires so the
  /// technician hears something instead of dead air; there is no second,
  /// later threshold that gives up on it.
  Future<Map<String, dynamic>> _dispatchWithOpenCameraSafeguards({
    required String name,
    required Map<String, dynamic> args,
  }) async {
    // DIAGNOSTIC (added after the "zero deterministic triggers fired"
    // regression report): entry/exit logging around the passthrough branch
    // specifically, so a future silent failure for a NON-open_camera name
    // is impossible to miss — if this method is entered but "passthrough
    // returning" never prints, the exception happened inside
    // `dispatchGeminiFunctionCall` itself, not in this wrapper.
    debugPrint('PHOTO TIMING [_dispatchWithOpenCameraSafeguards]: entered for name="$name" args=$args');
    if (name != 'open_camera') {
      debugPrint('PHOTO TIMING [_dispatchWithOpenCameraSafeguards]: "$name" != open_camera — calling real dispatchGeminiFunctionCall directly (no timers, no timeout)');
      // PART N item 3 (CONFIRMED via 3ebd9995-flutter_run_log.txt:
      // capture_photo's own native shutter call took 38s this run, having
      // never gotten the SAME audio hard-pause protection open_camera has
      // had for two rounds — see [_cameraNativeCallInProgress]'s doc
      // comment). No ack-timer/hard-timeout escalation here (that dance is
      // specific to open_camera's own observed multi-second variance) —
      // just the identical "stop all audio feed processing until the
      // native call resolves" protection, reusing the exact same
      // flag/mechanism rather than a second, uncoordinated one.
      //
      // BUG 2 FIX (CONFIRMED via flutter_run_log_new.txt, build #56):
      // confirm_photo_upload's OWN compress step showed the exact same
      // symptom — `compressPhotoForUpload`'s single `compressWithFile` call
      // (a platform-channel call into native Android, same category as
      // `takePicture()`) took 8311ms for a 328KB/1280x720 JPEG that decodes
      // and re-encodes in well under 200ms on its own, with zero GC pauses
      // or dropped frames logged during that window — the signature of the
      // SAME native-main-thread contention `capture_photo` already needed
      // this exact protection for, not genuine compression cost. Extending
      // it to confirm_photo_upload also closes BUG 4/5's window for free:
      // with mic RMS tracking AND incoming-audio processing both hard-
      // stopped for the whole compress+upload duration, no background noise
      // can trigger a stray "new utterance" reset or a confusing keep/retake
      // reprompt while the upload is genuinely in flight — the real spoken
      // "I've uploaded the photo" confirmation is only ever requested AFTER
      // this method (and therefore this hard-pause) has already returned.
      //
      // The compress + upload now runs AFTER the photo-note question, as
      // [uploadKeptPhotoFunctionName] (confirm_photo_upload itself only
      // marks the photo kept) — the protection and the "Still uploading,
      // one more second." filler moved with it, keyed under the same
      // confirm_photo_upload filler entry.
      final needsAudioHardPause = name == 'capture_photo' || name == uploadKeptPhotoFunctionName;
      final fillerKey = name == uploadKeptPhotoFunctionName ? 'confirm_photo_upload' : name;
      if (needsAudioHardPause) {
        _cameraNativeCallInProgress = true;
        _syncVoicePhase();
        _preemptiveDefaultMuteSafetyTimer?.cancel();
        _preemptiveDefaultMuteSafetyTimer = null;
        _log_(
          '$name: hard-pausing ALL audio feed processing until the native call reports back — see PART N item 3 '
          '/ BUG 2 FIX.',
        );
        debugPrint('PHOTO TIMING [$name]: audio_hard_pause_engaged at ${DateTime.now()}');
      }
      // P0 FIX — see [_fillerPassthroughActive]: a slow native call gets one
      // spoken filler instead of total silence for however long it takes.
      final filler = needsAudioHardPause ? pendingCallFillers[fillerKey] : null;
      final fillerTimer = filler == null
          ? null
          : Timer(filler.delay, () {
              debugPrint('PHOTO TIMING [$name]: filler threshold (${filler.delay.inMilliseconds}ms) reached — still pending');
              _speakPendingCallFiller(name, filler.text);
            });
      // One follow-up for a call that's still going much later — see
      // `pendingCallFollowUpFillers`. Same passthrough, same cancel point.
      final followUp = needsAudioHardPause ? pendingCallFollowUpFillers[fillerKey] : null;
      final followUpTimer = followUp == null
          ? null
          : Timer(followUp.delay, () {
              debugPrint('PHOTO TIMING [$name]: follow-up filler threshold (${followUp.delay.inSeconds}s) reached — still pending');
              _speakPendingCallFiller(name, followUp.text);
            });
      // get_kb_answer — same filler config, but no hard-pause to pass
      // through (the preemptive mute just yields to this scripted line, as
      // to any other), so it's spoken directly rather than via
      // [_speakPendingCallFiller]'s camera-only passthrough.
      final kbFiller = name == 'get_kb_answer' ? pendingCallFillers['get_kb_answer'] : null;
      if (name == 'get_kb_answer') _kbCallStartedAt = DateTime.now();
      final kbFillerTimer = kbFiller == null
          ? null
          : Timer(kbFiller.delay, () {
              debugPrint(
                'PENDING CALL FILLER [get_kb_answer]: speaking "${kbFiller.text}" at ${DateTime.now()} '
                '[${kbFiller.delay.inMilliseconds}ms threshold] — KB lookup still pending',
              );
              _informGeminiToSpeakVerbatim(kbFiller.text, reason: 'pending_call_filler[get_kb_answer]', isFiller: true);
            });
      try {
        final passthroughResult = await dispatchGeminiFunctionCall(
          ref: ref,
          cameraSession: _cameraSession,
          navigationSession: _navigationSession,
          name: name,
          args: args,
        );
        debugPrint('PHOTO TIMING [_dispatchWithOpenCameraSafeguards]: passthrough for "$name" returned: $passthroughResult');
        return passthroughResult;
      } finally {
        fillerTimer?.cancel();
        followUpTimer?.cancel();
        kbFillerTimer?.cancel();
        if (needsAudioHardPause) {
          _cameraNativeCallInProgress = false;
          _syncVoicePhase();
          _endFillerPassthrough('$name native call finished');
          debugPrint('PHOTO TIMING [$name]: audio_hard_pause_released at ${DateTime.now()}');
        }
      }
    }

    // ISSUE 2 item 2 instrumentation: the true entry point of the open_camera
    // handler, timestamped in the SAME "PHOTO TIMING [open_camera]: ... at
    // <DateTime>" convention as `audio_hard_pause_engaged` a few lines below
    // and `dispatching_native_open_call`/`controller_initialized` in
    // `gemini_function_dispatcher.dart` — so the next real log can compute,
    // directly from timestamps rather than inferred from code reading,
    // exactly how many milliseconds elapse between the handler being entered
    // and the audio hard-pause actually taking effect (should be ~0, since
    // nothing awaits between the two), and separately how long
    // `dispatching_native_open_call` sits queued after that before the
    // native side picks it up.
    debugPrint('PHOTO TIMING [open_camera]: handler_entry at ${DateTime.now()}');

    // P1 FIX — see [_cameraSpeculativelyPrewarming]'s doc comment: this is
    // a GENUINE open_camera request, so from this point on the camera
    // controller (whether it's already sitting prewarmed, still opening,
    // or not started at all yet) is no longer speculative — every
    // [onOpenStarted]/[onPreviewAvailable] callback from here onward must
    // actually update the ambient UI. Cleared BEFORE the dispatch below so
    // there's no window where a callback fired by THIS call could still be
    // wrongly suppressed as speculative.
    _cameraSpeculativelyPrewarming = false;
    _cameraPrewarmAutoReleaseTimer?.cancel();
    _cameraPrewarmAutoReleaseTimer = null;

    // PART K (CONFIRMED 71.4s regression — see [_cameraNativeCallInProgress]'s
    // doc comment): set BEFORE `dispatchGeminiFunctionCall` is even called,
    // so it's in effect before `permission_check_done` or anything else the
    // real camera-opening call does. Cancelling any pending preemptive-mute
    // safety timer here too — no new one can arm while this is true (no new
    // mic audio reaches Gemini to produce a new utterance), so any timer
    // already ticking down from moments before this trigger resolved is
    // pointless now and would only speak the boundary decline over a
    // response that's about to come from a totally different function.
    _cameraNativeCallInProgress = true;
    _syncVoicePhase();
    _preemptiveDefaultMuteSafetyTimer?.cancel();
    _preemptiveDefaultMuteSafetyTimer = null;
    _log_(
      'open_camera: hard-pausing ALL audio feed processing (mic send, PCM playback feed, preemptive-mute '
      'safety timeout) until the camera controller reports back — see PART K.',
    );
    // PART N item 2 — same "PHOTO TIMING [open_camera]: ..." + raw
    // DateTime.now() convention `gemini_function_dispatcher.dart` already
    // uses for its own timestamps, so this line is directly comparable
    // against THOSE (e.g. `dispatching_native_open_call`) across the two
    // files instead of only inferred from code reading — settles whether
    // the audio hard-pause is genuinely in effect BEFORE the native
    // open/bind camera call gets dispatched, or only after.
    debugPrint('PHOTO TIMING [open_camera]: audio_hard_pause_engaged at ${DateTime.now()}');

    final stopwatch = Stopwatch()..start();
    final realCall = dispatchGeminiFunctionCall(
      ref: ref,
      cameraSession: _cameraSession,
      navigationSession: _navigationSession,
      name: name,
      args: args,
    );

    // PART M — see [_cameraOpenRealCallInFlight]'s doc comment: tracked
    // independently of the `.timeout()`/late-completion handling below,
    // from the moment the real call starts until it genuinely finishes
    // (never throws — errors are swallowed here, since this Future's only
    // job is "has it finished yet", not carrying the actual result).
    // [_cameraOpenRealCallOutcome] records WHICH it was (real completion vs
    // real failure), so [_teardown]'s deferred-start log line can say which
    // one actually woke it up — see that field's doc comment.
    final trackedRealCall = realCall.then(
      (_) => _cameraOpenRealCallOutcome = 'real completion',
      onError: (Object _, StackTrace _) => _cameraOpenRealCallOutcome = 'real failure',
    );
    _cameraOpenRealCallInFlight = trackedRealCall;
    unawaited(
      trackedRealCall.then((_) {
        // Guard against a NEWER open_camera call's own tracked Future
        // having already replaced this one (e.g. a retry after this one
        // resolved) — never clear a field that isn't still ours.
        if (identical(_cameraOpenRealCallInFlight, trackedRealCall)) {
          _cameraOpenRealCallInFlight = null;
        }
      }),
    );

    final ackTimer = Timer(_openCameraAckDelay, () {
      debugPrint('PHOTO TIMING [open_camera]: ack threshold reached at ${stopwatch.elapsedMilliseconds}ms — still open, speaking acknowledgment');
      _log_(
        'open_camera: still opening after ${_openCameraAckDelay.inSeconds}s — speaking acknowledgment '
        '("$_openCameraAckText") so it doesn\'t feel stuck',
      );
      _speakPendingCallFiller('open_camera', _openCameraAckText);
    });

    // P0 FIX (build #65) — see [_dispatchWithOpenCameraSafeguards]'s own
    // doc comment: no `.timeout()` wrapper anymore. Simply awaits the real
    // call, exactly like every other camera-flow function already does —
    // however long it genuinely takes, the technician gets ONE true
    // outcome, never a "timed out" message contradicted moments later by
    // "actually open now" for the same action.
    try {
      return await realCall;
    } finally {
      // PART K — see [_cameraNativeCallInProgress]'s doc comment: resume
      // normal audio processing the instant the real call genuinely
      // finishes.
      _cameraNativeCallInProgress = false;
      _syncVoicePhase();
      _endFillerPassthrough('open_camera native call finished');
      ackTimer.cancel();
    }
  }

  void _onServerMessage(dynamic raw) {
    // See [_onEndRequest]: outside job scope nothing is processed.
    if (_sessionClosing) return;
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      _noteServerMessageForDiagnostics(decoded);

      if (decoded.containsKey('setupComplete')) {
        _setupComplete = true;
        _setupCompleteAt ??= DateTime.now();
        // Raw payload, not a fixed string — `setupComplete` is documented as
        // an otherwise-empty ack (BidiGenerateContentSetupComplete has no
        // fields), so an empty `{}` here is the EXPECTED confirmation the
        // server accepted `setup` as sent, contextWindowCompression
        // included; there's no per-field accept/reject echo to look for.
        // This is only useful as a NEGATIVE check: a malformed/rejected
        // field surfaces as a top-level `error` message instead (handled
        // just below), never as content inside `setupComplete` itself.
        _log_('setupComplete received from server — raw payload: ${decoded['setupComplete']} — starting mic stream now');
        unawaited(_startMicStreaming());
        return;
      }

      if (decoded.containsKey('error')) {
        _log_('ERROR from server: ${decoded['error']}');
        return;
      }

      // `usageMetadata` and `sessionResumptionUpdate` are documented,
      // routine messages the server sends alongside/after turns (token-usage
      // stats and a session-resumption handle respectively) — harmless, just
      // logged for visibility. `goAway`/`toolCall`/`toolCallCancellation` are
      // also documented shapes but worth flagging distinctly: `goAway` means
      // the server is about to close the connection, and `toolCall`/
      // `toolCallCancellation` are unexpected on Day 1 since no tools are
      // wired up yet.
      if (decoded.containsKey('usageMetadata')) {
        _log_('usageMetadata (informational, harmless — token usage for the turn): ${decoded['usageMetadata']}');
        final usageMetadata = decoded['usageMetadata'] as Map<String, dynamic>;
        debugPrint('TOKEN COUNT this turn: ${usageMetadata['totalTokenCount']}');
        final promptTokens = (usageMetadata['promptTokenCount'] as num?)?.toInt();
        if (promptTokens != null) _logContextSize(promptTokens);
      }
      if (decoded.containsKey('sessionResumptionUpdate')) {
        // P1 FIX — see [_logNoState]'s doc comment: fires roughly once a
        // second throughout an active session (far more often than the
        // "usageMetadata"/once-per-turn line just above), explicitly
        // labeled informational/harmless — a `setState` for this is pure
        // main-thread cost with no corresponding value.
        _logNoState('sessionResumptionUpdate (informational, harmless — session resumption handle): ${decoded['sessionResumptionUpdate']}');
      }
      if (decoded.containsKey('goAway')) {
        _log_('goAway received — server will close the connection soon: ${decoded['goAway']}');
      }
      if (decoded.containsKey('toolCall')) {
        _log_('toolCall received: ${decoded['toolCall']}');
        // PART C item 6: settles, per turn, whether toolConfig's mode:
        // ANY is having any real effect — see the TURN SHAPE log at
        // turnComplete/interrupted below.
        _currentTurnHadToolCall = true;
        // Original Day 2 spec: a function call is itself a detected "turn",
        // same as technician speech — reset before dispatching so a session
        // kept alive purely by function calls (no spoken audio at all)
        // still never times out while genuinely active.
        _resetInactivityTimer(reason: 'function call received');
        unawaited(_handleToolCall(decoded['toolCall'] as Map<String, dynamic>));
      }
      if (decoded.containsKey('toolCallCancellation')) {
        _log_('toolCallCancellation received: ${decoded['toolCallCancellation']}');
      }

      final serverContent = decoded['serverContent'] as Map<String, dynamic>?;
      if (serverContent == null) {
        if (!decoded.keys.any(_knownServerMessageKeys.contains)) {
          _log_('server message (truly unrecognized shape) — raw content: $text');
        }
        return;
      }

      // PART H item 1 (CONFIRMED leaked-fragment stutter, e.g. "To show you
      // the job history, I just need" playing before the real answer):
      // root cause found HERE. `inputTranscription` used to be read AFTER
      // the `modelTurn`/`parts` audio loop below — so a single server
      // message carrying BOTH a new inputTranscription update AND Gemini's
      // own organic audio for that same utterance got its audio FED to the
      // native player (via `_onResponseAudioChunk`) BEFORE
      // `_onInputTranscription` ever ran to decide whether this utterance
      // should be muted. Reordered so the transcription — and therefore
      // every deterministic trigger's match/interrupt decision — is always
      // resolved FIRST, for every message, so THIS message's own audio
      // parts (processed right after) are already gated by the up-to-date
      // mute state instead of racing it.
      final inputTranscription = serverContent['inputTranscription'] as Map<String, dynamic>?;
      final inputTranscriptionText = inputTranscription?['text'] as String?;
      if (inputTranscriptionText != null && inputTranscriptionText.isNotEmpty) {
        _onInputTranscription(inputTranscriptionText);
      }

      final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
      final parts = modelTurn?['parts'] as List<dynamic>?;
      if (parts != null) {
        for (final part in parts) {
          final inlineData = (part as Map<String, dynamic>)['inlineData'] as Map<String, dynamic>?;
          final data = inlineData?['data'] as String?;
          if (data != null && data.isNotEmpty) {
            final mimeType = inlineData?['mimeType'] as String?;
            // Log the real structure Gemini actually sent — every inlineData
            // field except the base64 `data` payload itself (reported by
            // length only; dumping tens of KB of base64 into the on-screen/
            // logcat log per chunk isn't readable and isn't what actually
            // answers "what rate is this"). mimeType is the field that
            // carries the real output sample rate, e.g.
            // "audio/pcm;rate=24000" — logged once per chunk so it can be
            // read directly off the device rather than assumed.
            final otherInlineDataFields = Map<String, dynamic>.from(inlineData ?? {})..remove('data');
            // P1 FIX — see [_logNoState]'s doc comment: this fires on
            // EVERY chunk, unconditionally, at normal cadence every
            // 10-100ms during active playback — a `setState` here is
            // exactly the main-thread contention that delayed
            // `takePicture()`'s own platform-channel dispatch by 5+
            // seconds in a real run.
            _logNoState(
              'inlineData received: mimeType=$mimeType, otherFields=$otherInlineDataFields, '
              'data length=${data.length} base64 chars',
            );
            if (_blockingTestAwaitingT3) {
              debugPrint('BLOCKING TEST T3 (next audio received): ${DateTime.now()}');
              _blockingTestAwaitingT3 = false;
            }
            _onResponseAudioChunk(base64Decode(data), mimeType: mimeType);
            _currentTurnHadAudioOrText = true;
          }
        }
      }

      // FIX 1: transcript of GEMINI'S OWN spoken audio —
      // `outputAudioTranscription: {}` in the setup message is what makes
      // the server send this. The single most important missing piece of
      // visibility for the audio-echo investigation: lets a suspicious
      // `inputTranscription` line be directly compared against what Gemini
      // actually said, instead of guessed at.
      final outputTranscription = serverContent['outputTranscription'] as Map<String, dynamic>?;
      final outputTranscriptionText = outputTranscription?['text'] as String?;
      if (outputTranscriptionText != null && outputTranscriptionText.isNotEmpty) {
        // P1 FIX — see [_logNoState]'s doc comment: fires on every
        // output-transcription fragment (frequently, during any spoken
        // response), same main-thread-contention reasoning as the
        // inlineData site above.
        _logNoState('GEMINI SAID: "$outputTranscriptionText"');
        _logCrossRef('GEMINI SAID', outputTranscriptionText);
        // Turn-identity gate — must run before the audits below so they see
        // whether this turn's audio is actually being played.
        _classifyTurnAgainstScript(outputTranscriptionText);
        _currentTurnHadAudioOrText = true;
        // P0 TRUST FIX — see [_auditGeminiCompletionClaim]. Placed here, on
        // the transcript of what Gemini ACTUALLY SAID, rather than anywhere
        // in the request path: the whole point is that the free-text path
        // can produce words no function call ever justified, so the only
        // reliable place to catch it is the output itself.
        _auditGeminiCompletionClaim(outputTranscriptionText);
        // After the audit above, which accumulates [_currentTurnGeminiText].
        _maybeResolveIntentCheckFromSpokenCall();
        // P0 FIX — see [_auditGeminiForLeakedInstructionWrapper]'s doc
        // comment. Placed right after the completion-claim audit, once
        // [_currentTurnGeminiText] has already been updated with this
        // fragment, and before the duplicate-response audit below — a
        // leaked wrapper should be caught and suppressed as early in the
        // turn as possible, before more of it plays.
        _auditGeminiForLeakedInstructionWrapper();
        // P0 AUDIO-ECHO FIX — see [_auditGeminiDuplicateResponse]'s doc
        // comment. Same placement reasoning as the completion-claim audit
        // immediately above: this has to watch what Gemini ACTUALLY SAYS,
        // since the whole failure mode is the model generating a fresh
        // turn that happens to restate a turn it already said seconds ago.
        _auditGeminiDuplicateResponse(outputTranscriptionText);
        // Second baseline source for the same safety net: a restart of a
        // turn that was INTERRUPTED earlier in this utterance.
        _maybeAuditAgainstInterruptedTurnBaseline();
        // BUG 2 backstop (step 3 of the echo-leak fix), REDESIGNED — see
        // [_currentTurnAudiblyPlayedText]'s doc comment for the P0
        // regression this replaces (an unbounded-in-practice, whole-session
        // accumulator that let a short real command sharing a couple of
        // common words with ANYTHING Gemini had EVER said get discarded as
        // echo). Accumulates ONLY the CURRENT turn's text now — a genuinely
        // bounded, per-turn pool, never a growing multi-turn blob.
        //
        // P1 FIX (CONFIRMED via flutter_run_log_new.txt, build #65,
        // unchanged by this redesign): text from a turn whose audio was
        // entirely dropped (e.g. [_cameraNativeCallInProgress]'s hard-pause)
        // was never actually audible, so it can never legitimately echo
        // back through the mic — still excluded here via the same three
        // gates [_onResponseAudioChunk] itself checks, in the same order.
        final thisAudioWouldBeDropped = _responseAudioCurrentlyDropped;
        if (!thisAudioWouldBeDropped) {
          _currentTurnAudiblyPlayedText = ('$_currentTurnAudiblyPlayedText $outputTranscriptionText').trim();
        }
      }

      if (serverContent['turnComplete'] == true) {
        _log_('model turn complete');
        _dropRestOfSpokenIntentCheckTurn = false;
        _noteAudibleModelTurnEnded();
        _turnComplete = true;
        _flushPcmPrebuffer('turnComplete');
        _maybeResumeOutgoingAudio();
        _clearDeterministicAudioSuppression('turnComplete received');
        _onTurnBoundaryWhileAwaitingScript(interrupted: false);
        _scriptedResponsePending = false;
        if (_fillerAudioStarted) _endFillerPassthrough('filler turn turnComplete');
        _finishGreetingCapture();
        _logAndResetTurnShape('turnComplete');
      }
      if (serverContent['interrupted'] == true) {
        _log_('model turn interrupted');
        _dropRestOfSpokenIntentCheckTurn = false;
        _noteAudibleModelTurnEnded();
        // Must run before [_logAndResetTurnShape] below clears this turn's
        // text — see [_recordInterruptedTurnBaseline].
        _recordInterruptedTurnBaseline();
        _turnComplete = true;
        _discardPcmPrebuffer('turn interrupted');
        _maybeResumeOutgoingAudio();
        _clearDeterministicAudioSuppression('interrupted received');
        _onTurnBoundaryWhileAwaitingScript(interrupted: true);
        if (_fillerAudioStarted) _endFillerPassthrough('filler turn interrupted');
        if (_greetingCapture?.isNotEmpty ?? false) _abandonGreetingCapture('the greeting turn was interrupted');
        _logAndResetTurnShape('interrupted');
      }
    } catch (e, stackTrace) {
      debugPrint('GEMINI LIVE TEST ERROR (message parse): $e\n$stackTrace');
      _log_('ERROR (message parse): $e');
    }
  }

  /// PART C item 6 — called at every turn boundary (`turnComplete` or
  /// `interrupted`). Logs whether the just-finished turn included a real
  /// `toolCall` message, spoken audio/text, both, or neither, then resets
  /// both flags for the next turn. This is the direct, per-turn answer to
  /// "did toolConfig's mode: ANY actually make Gemini call a function this
  /// turn, or did it free-text instead" — read straight from what the
  /// server actually sent, not inferred.
  void _logAndResetTurnShape(String boundary) {
    final shape = _currentTurnHadToolCall && _currentTurnHadAudioOrText
        ? 'toolCall AND audio/text (function call this turn, plus spoken output — e.g. an acknowledgment)'
        : _currentTurnHadToolCall
            ? 'toolCall ONLY (Gemini called a function, no free-text speech this turn)'
            : _currentTurnHadAudioOrText
                ? 'FREE-TEXT AUDIO ONLY — Gemini spoke without calling any function this turn'
                : 'empty (neither a toolCall nor any audio/text this turn)';
    _log_('TURN SHAPE ($boundary): toolCall=$_currentTurnHadToolCall audioOrText=$_currentTurnHadAudioOrText — $shape');
    // P0 AUDIO-ECHO FIX — see [_auditGeminiDuplicateResponse]'s doc
    // comment: record this now-finished turn's full text into the recent-
    // turn history BEFORE clearing [_currentTurnGeminiText] below, so it's
    // available to compare the NEXT turn against.
    //
    // P1 FIX: only the AUDIBLE part of the turn. Every deterministic trigger
    // produces two generations by design — Gemini's own free-text answer to
    // the raw audio (muted by the preemptive mute / hold / hard-pause) and
    // then our scripted "say exactly" line — and the two are often
    // near-identical, because Gemini imitates our earlier scripted wording.
    // Recording the MUTED first one made the real, scripted confirmation
    // look like a repeat, so it was the one suppressed. A genuinely audible
    // repeat is still caught, and a third repeat still compares against the
    // first (audible) one within the lookback window.
    _recordGeminiTurnForDuplicateDetection(_currentTurnAudiblyPlayedText);
    // P0 ECHO FALSE-POSITIVE FIX — see [_currentTurnAudiblyPlayedText]'s
    // doc comment. Snapshot this now-finished turn's AUDIBLY-PLAYED text
    // (and when it finished) as the ECHO comparison pool's second, trailing
    // entry, BEFORE clearing it for the next turn below — this is what lets
    // a leaked chunk arriving shortly after Gemini stops talking still be
    // recognized as echo, without keeping every earlier turn around too.
    _lastCompletedTurnAudiblyPlayedText = _currentTurnAudiblyPlayedText;
    _lastCompletedTurnFinishedAt = DateTime.now();
    if (_currentTurnAudiblyPlayedText.trim().isNotEmpty) {
      _recentAudibleTurns.add((text: _currentTurnAudiblyPlayedText, at: DateTime.now()));
      final cutoff = DateTime.now().subtract(_recentAudibleTurnsWindow);
      _recentAudibleTurns.removeWhere((t) => t.at.isBefore(cutoff));
      while (_recentAudibleTurns.length > _recentAudibleTurnsMax) {
        _recentAudibleTurns.removeAt(0);
      }
    }
    // P0 FIX — see [_currentResponseTurnId]'s doc comment: every genuine
    // turn boundary also bumps it, so a turn Gemini starts on its own
    // (spontaneously, with no preceding app-side interrupt) still gets a
    // fresh id for whatever comes NEXT — redundant with the interrupt-time
    // bump in the common (app-interrupted) case, which is fine; an extra
    // bump never causes two different turns to collide on one id, only
    // (harmlessly) uses ids up slightly faster.
    _currentResponseTurnId++;
    // The suppression this turn's own audit may have armed is scoped to
    // THIS turn only (see [_suppressResponseAudioForDuplicate]'s doc
    // comment) — cleared here at the same turn boundary that already
    // clears [_suppressResponseAudioForDeterministic] for the identical
    // reason: the turn it applied to is now genuinely over.
    _suppressResponseAudioForDuplicate = false;
    // Same reasoning as the duplicate-suppression clear immediately
    // above — see [_suppressResponseAudioForLeakedWrapper]'s doc comment.
    _suppressResponseAudioForLeakedWrapper = false;
    _currentTurnHadToolCall = false;
    _currentTurnHadAudioOrText = false;
    _currentTurnGeminiText = '';
    _currentTurnAudiblyPlayedText = '';
    _completionClaimAuditedThisTurn = false;
    _duplicateResponseAuditedThisTurn = false;
    _verbatimInstructionAuditedThisTurn = false;
  }

  // ===========================================================================
  // P0 TRUST FIX — "Gemini said it happened when it didn't"
  // See [photoCompletionClaimPhrases]'s doc comment for the confirmed bug.
  // ===========================================================================

  /// Wall-clock time each photo-flow function last genuinely SUCCEEDED —
  /// written in exactly one place ([_updateScreenTaskForToolCall]'s success
  /// branch), which both the deterministic trigger path
  /// ([_executeDeterministic]) and a genuine server-sent `toolCall`
  /// ([_handleToolCall]) already funnel through, so neither route can grow
  /// a success this audit doesn't know about.
  ///
  /// Deliberately NOT [_TranscriptTrigger.lastActivityAt], which records
  /// when a call was ATTEMPTED — an attempted-but-failed capture is exactly
  /// the case where a "captured" claim is a lie.
  final Map<String, DateTime> _photoActionLastSucceededAt = {};

  /// Gemini's own spoken text for the CURRENT turn only, accumulated across
  /// `outputTranscription` fragments and cleared at every turn boundary (see
  /// [_logAndResetTurnShape]). Audited as a whole rather than fragment by
  /// fragment so a claim split across a fragment boundary ("It's cap" +
  /// "tured.") can't slip through — and so a long turn is audited once, not
  /// once per fragment (that's [_completionClaimAuditedThisTurn]).
  ///
  /// Distinct from [_currentTurnAudiblyPlayedText] (used for echo
  /// detection): this one includes text whose audio was dropped/never
  /// played (a completion claim is a lie regardless of whether the
  /// technician actually heard it said), while that one deliberately
  /// excludes it (only AUDIBLE speech can ever leak back through the mic
  /// as echo).
  String _currentTurnGeminiText = '';

  bool _completionClaimAuditedThisTurn = false;

  // ===========================================================================
  // P0 ECHO FALSE-POSITIVE FIX
  // CONFIRMED (a real ~2.5 minute session): a technician's genuine "Take the
  // photo." was discarded by [_looksLikeGeminiEcho] because it "matched" a
  // 150+-word blob of EVERYTHING Gemini had said since the camera opened a
  // minute earlier — comparing "take"/"the"/"photo" against that whole
  // session's accumulated vocabulary found SOME nearby window where all
  // three happened to co-occur, unrelated to any actual recent utterance.
  // Result: capture_photo fired ZERO times in the whole session, and the
  // app looped through 7 different "let me know when you're ready"
  // rephrasings without ever hearing a real answer.
  //
  // The OLD [_recentGeminiOutputText] (a single string, nominally capped at
  // 600 characters but still routinely spanning MANY distinct turns of
  // conversation — 600 characters is ~100-120 words) is replaced entirely
  // by these two, each compared SEPARATELY (never concatenated together,
  // which would just recreate the same blob problem one level up):
  //  - [_currentTurnAudiblyPlayedText] — the turn Gemini is speaking RIGHT
  //    NOW, if any (the most likely real echo source: the mic picking up
  //    what's playing at this exact moment).
  //  - [_lastCompletedTurnAudiblyPlayedText] — the turn Gemini MOST
  //    RECENTLY finished speaking, but ONLY while [_lastCompletedTurnFinishedAt]
  //    is within [_echoComparisonTrailingWindowFor] — covering trailing
  //    acoustic decay after playback stops, not "anything said this
  //    session." Once that window passes, the turn drops out of the
  //    comparison pool entirely, exactly as requested.
  // ===========================================================================

  /// Gemini's own spoken text for the CURRENT turn, but — unlike
  /// [_currentTurnGeminiText] — ONLY text whose audio genuinely reached the
  /// speaker (excludes anything [_onResponseAudioChunk] would drop: see the
  /// `thisAudioWouldBeDropped` gate at this field's own accumulation site).
  /// Text that was never audibly played can never leak back through the mic
  /// as echo, so including it here would only ever widen the false-positive
  /// surface for no corresponding real risk. Cleared at every turn boundary
  /// in [_logAndResetTurnShape], which also snapshots it into
  /// [_lastCompletedTurnAudiblyPlayedText] first.
  String _currentTurnAudiblyPlayedText = '';

  /// The PREVIOUS turn's [_currentTurnAudiblyPlayedText], snapshotted at
  /// that turn's own boundary — see [_echoComparisonTrailingWindowFor] for how
  /// long it stays eligible for comparison.
  String _lastCompletedTurnAudiblyPlayedText = '';

  /// When [_lastCompletedTurnAudiblyPlayedText] was captured — i.e. when
  /// that turn genuinely finished. `null` only before the very first turn
  /// of a session has completed.
  DateTime? _lastCompletedTurnFinishedAt;

  /// Rolling history of Gemini's AUDIBLE completed/interrupted turns, newest
  /// last — at most [_recentAudibleTurnsMax] entries from the last
  /// [_recentAudibleTurnsWindow]. Used by [_looksLikeGeminiEcho] for
  /// whole-turn echoes of turns older than the one just finished; entries
  /// are always compared separately, never concatenated.
  final List<({String text, DateTime at})> _recentAudibleTurns = [];
  static const int _recentAudibleTurnsMax = 5;
  static const Duration _recentAudibleTurnsWindow = Duration(seconds: 90);

  /// An older turn only counts as echoed if the chunk has at least
  /// [_olderTurnEchoMinWords] words AND this fraction of that turn's word
  /// count — see [_looksLikeGeminiEcho]. Sized so one sentence of a
  /// two-sentence turn qualifies ("I'm here, loud and clear" = 6 of 13),
  /// but a short command inside one of our longer prompts doesn't ("show me
  /// the job history" = 5 of 17).
  static const double _olderTurnEchoMinCoverage = 0.4;
  static const int _olderTurnEchoMinWords = 5;

  /// Base floor for how long after a turn finishes its text stays eligible
  /// as an echo comparison target — see [_echoComparisonTrailingWindowFor],
  /// which SCALES this up for longer turns and is what callers actually
  /// use. Matches this fix's own original request ("the last 3-5 seconds
  /// of TTS playback"), sized for a SHORT turn — generous enough to cover
  /// the documented native-buffer/acoustic-decay lag this file's OTHER
  /// echo fixes already measure in the low hundreds of ms to low seconds
  /// (see [_resumeGraceDelay]/[_echoTailQuietRequirement]), without
  /// reaching back far enough to accidentally re-admit "anything said a
  /// while ago" — the exact failure this whole redesign exists to close.
  static const Duration _echoComparisonTrailingWindowFloor = Duration(seconds: 5);

  /// P1 FIX (recurring, CONFIRMED again in a later session): a flat 5s
  /// window missed Gemini's own "Got it. I've taken the photo. Keep it or
  /// retake it?" — an 11-word confirmation — leaking back, while other,
  /// mostly SHORTER echoed turns in the SAME session correctly were still
  /// caught. A longer spoken turn genuinely takes longer to physically
  /// finish playing, and however much STT/network latency stacks on top
  /// before its echo reaches this app as a transcript chunk scales with
  /// that too — a short "Is that correct?" and an 11-word confirmation
  /// don't share the same real-world echo-arrival deadline. Scales the
  /// window with the completed turn's own word count past a small free
  /// allowance, capped well short of turning back into "anything said a
  /// while ago" (the original whole-session-blob failure this whole
  /// redesign exists to close) — this can add at most a few extra
  /// seconds for a genuinely long turn, never minutes.
  static const int _echoComparisonFreeWordAllowance = 5;
  static const Duration _echoComparisonPerExtraWord = Duration(milliseconds: 400);
  static const Duration _echoComparisonTrailingWindowCap = Duration(seconds: 10);

  static Duration _echoComparisonTrailingWindowFor(String turnText) {
    final trimmed = turnText.trim();
    if (trimmed.isEmpty) return _echoComparisonTrailingWindowFloor;
    final wordCount = trimmed.split(RegExp(r'\s+')).length;
    final extraWords = (wordCount - _echoComparisonFreeWordAllowance).clamp(0, 1 << 30);
    final scaled = _echoComparisonTrailingWindowFloor + _echoComparisonPerExtraWord * extraWords;
    return scaled > _echoComparisonTrailingWindowCap ? _echoComparisonTrailingWindowCap : scaled;
  }

  DateTime? _lastCompletionClaimCorrectionAt;

  /// The most recent text handed to [_informGeminiToSpeakVerbatim] — used
  /// only to exempt a genuinely scripted line from this audit. The
  /// timestamp window below already covers the normal case (a real
  /// confirm_photo_upload success is what produced the script in the first
  /// place); this is defense in depth for a script spoken at the very edge
  /// of that window.
  String _lastVerbatimScriptText = '';

  void _recordPhotoActionSuccess(String name) {
    if (!photoCompletionClaimPhrases.containsKey(name)) return;
    _photoActionLastSucceededAt[name] = DateTime.now();
    _log_('COMPLETION CLAIM AUDIT: recorded a genuine "$name" success — completed-action phrasing for it is now licensed for ${_photoCompletionClaimWindow.inSeconds}s.');
  }

  bool _photoActionSucceededRecently(String name) {
    final at = _photoActionLastSucceededAt[name];
    if (at == null) return false;
    return DateTime.now().difference(at) <= _photoCompletionClaimWindow;
  }

  /// Called for every `outputTranscription` fragment. Accumulates the turn's
  /// spoken text and, the first time that text claims a photo action
  /// completed, checks whether a real success actually licenses it.
  ///
  /// A violation is logged on a single, deliberately greppable line
  /// (`COMPLETION CLAIM VIOLATION`) carrying both what Gemini said and when
  /// — if ever — the claimed function last succeeded, so verifying "Gemini
  /// never claimed a capture that didn't happen" in the next run is a grep,
  /// not a manual read of three thousand lines. It is then corrected out
  /// loud through the same constrained verbatim path every other canned
  /// response uses, because the technician has already HEARD the false
  /// claim by the time this runs — the audio for a transcription fragment
  /// is streamed alongside it, so silently logging would leave the
  /// technician believing a photo exists.
  void _auditGeminiCompletionClaim(String fragment) {
    _currentTurnGeminiText = '$_currentTurnGeminiText $fragment'.trim();
    if (_completionClaimAuditedThisTurn) return;

    final claimedFunction = completionClaimFunctionIn(_currentTurnGeminiText);
    if (claimedFunction == null) return;
    _completionClaimAuditedThisTurn = true;

    // open_camera is licensed by the camera genuinely being open right now
    // (not by the 60s window — a technician can sit in the live preview far
    // longer than that), and never before its real open has completed.
    if (claimedFunction == 'open_camera' && _cameraOpenConfirmed) {
      _log_('COMPLETION CLAIM AUDIT: "$_currentTurnGeminiText" claims "open_camera" completed — LICENSED (camera is genuinely open).');
      return;
    }

    if (_photoActionSucceededRecently(claimedFunction)) {
      _log_('COMPLETION CLAIM AUDIT: "$_currentTurnGeminiText" claims "$claimedFunction" completed — LICENSED (it genuinely succeeded ${DateTime.now().difference(_photoActionLastSucceededAt[claimedFunction]!).inSeconds}s ago).');
      return;
    }

    // A verbatim script we ourselves just told Gemini to read is, by
    // construction, not a free-text guess — see [_lastVerbatimScriptText].
    final normalizedSpoken = _normalizeForEchoCompare(_currentTurnGeminiText);
    if (normalizedSpoken.isNotEmpty && _normalizeForEchoCompare(_lastVerbatimScriptText).contains(normalizedSpoken)) {
      _log_('COMPLETION CLAIM AUDIT: "$_currentTurnGeminiText" matches the constrained script we just sent — not a free-text claim, allowing.');
      return;
    }

    final lastSuccess = _photoActionLastSucceededAt[claimedFunction];
    final when = lastSuccess == null
        ? 'NEVER succeeded this session'
        : 'last succeeded ${DateTime.now().difference(lastSuccess).inSeconds}s ago, outside the ${_photoCompletionClaimWindow.inSeconds}s window';
    _log_(
      'COMPLETION CLAIM VIOLATION: Gemini said "$_currentTurnGeminiText", which claims "$claimedFunction" '
      'completed — but "$claimedFunction" $when. This is the free-text path narrating an outcome the '
      'deterministic layer never produced; correcting out loud.',
    );

    // A claim whose audio was dropped (e.g. the open_camera hard-pause) was
    // never heard — and a correction sent now would be dropped by the same
    // gate, while still interrupting and replacing [_lastVerbatimScriptText].
    if (_responseAudioCurrentlyDropped) {
      _log_('COMPLETION CLAIM VIOLATION: the claim\'s audio was being dropped (never audible) — logged, no spoken correction.');
      return;
    }

    final lastCorrection = _lastCompletionClaimCorrectionAt;
    if (lastCorrection != null &&
        DateTime.now().difference(lastCorrection) < _photoCompletionClaimCorrectionDebounce) {
      _log_('COMPLETION CLAIM VIOLATION: correction suppressed — one was already spoken ${DateTime.now().difference(lastCorrection).inSeconds}s ago.');
      return;
    }
    _lastCompletionClaimCorrectionAt = DateTime.now();
    // open_camera still mid-flight: "that hasn't happened yet… I'll do it"
    // would wrongly suggest nothing is underway.
    final openInProgress = claimedFunction == 'open_camera' &&
        (_screenTask == _ScreenTask.cameraOpening || _cameraOpenRealCallInFlight != null);
    _informGeminiToSpeakVerbatim(
      openInProgress ? "Sorry — the camera's still opening, give it a moment." : _photoCompletionClaimCorrectionText,
      reason: 'completion_claim_violation',
    );
  }

  // ===========================================================================
  // P0 AUDIO-ECHO FIX — duplicate-response safety net
  // CONFIRMED: "Camera's open — ready when you are." spoken identically
  // three times, ~6-7s apart, each preceded by an ECHO BACKSTOP discard.
  // The text-level echo backstop above only stops the APP from treating a
  // leaked/echoed chunk as a technician command — by the time that runs,
  // the raw audio it was transcribed from has ALREADY been sent to Gemini
  // as realtimeInput (the mic-pause/adaptive-quiet-wait mechanism above is
  // the fix for THAT). This is the last line of defense on the OUTPUT
  // side: regardless of why the model ends up generating a fresh turn that
  // just restates one it already said moments ago (leaked self-audio,
  // ambiguous input, or anything else), the technician must never hear the
  // same confirmation two or three times in a row.
  // ===========================================================================

  /// Recent, DISCRETE turns Gemini has actually spoken, newest last — each
  /// compared as a WHOLE against the CURRENT turn's accumulating text in
  /// [_auditGeminiDuplicateResponse]. Deliberately NOT a single
  /// concatenated blob (the shape [_looksLikeGeminiEcho] used to use, and
  /// was moved OFF of for the identical reason — see that function's own
  /// doc comment): a blob is right for "does this SHORT chunk appear
  /// anywhere recently" but wrong for "is this whole NEW turn essentially
  /// the same SENTENCE as a specific earlier one" — checking that against
  /// a blob would either miss a duplicate split across a turn boundary
  /// inside it, or false-positive on two unrelated turns that happen to
  /// share common phrasing somewhere within a long combined history.
  final List<({String text, DateTime at})> _recentGeminiTurnHistory = [];

  /// How far back a prior turn can be and still count as a "recent" enough
  /// duplicate to suppress. Matches the confirmed evidence (three repeats,
  /// ~6-7s apart) with real margin either side — wide enough to catch a
  /// slightly slower repeat cycle, narrow enough that a technician asking
  /// for a genuine repeat ("what did you say?") minutes later is never
  /// affected (an explicitly-requested repeat is legitimate; nothing about
  /// this mechanism can distinguish that case from an unprompted one within
  /// the window, which is the accepted, documented trade-off here — same
  /// "safe to occasionally over-suppress a rare legitimate case in
  /// exchange for reliably killing a confirmed, worse failure mode"
  /// posture already used throughout this file's other backstops).
  static const Duration _duplicateResponseLookbackWindow = Duration(seconds: 12);

  /// Slightly stricter than [_echoFuzzyOverlapThreshold] (0.8) — this
  /// suppresses OUTPUT the technician would otherwise hear, a higher-cost
  /// mistake than discarding one suspect INPUT chunk, so it asks for a
  /// larger fraction of the words to genuinely overlap before acting.
  static const double _duplicateResponseOverlapThreshold = 0.85;

  bool _duplicateResponseAuditedThisTurn = false;

  /// Whether the CURRENT turn's remaining response audio should be dropped
  /// on arrival because it was just found to duplicate a recent prior turn
  /// — a narrower, single-turn-scoped cousin of
  /// [_suppressResponseAudioForDeterministic] (see [_onResponseAudioChunk]'s
  /// own dedicated drop-branch for this flag). Deliberately a SEPARATE flag
  /// rather than reusing that one: that flag's machinery
  /// ([_interruptGeminiForDeterministicTrigger]'s full native-player
  /// teardown/reinit, and diagnostics like "PROTECTED CONFIRMATION AUDIO
  /// DROPPED" that assume re-arming it mid-window means something went
  /// WRONG) is built for "something BETTER is about to replace this stale
  /// turn" — not this case, where nothing new is coming and the fix is
  /// simply "stop feeding the rest of what's already playing." Cleared at
  /// the next turn boundary in [_logAndResetTurnShape], the same place
  /// [_suppressResponseAudioForDeterministic] already gets cleared for the
  /// identical reason (the turn it applied to is over).
  bool _suppressResponseAudioForDuplicate = false;

  // ===========================================================================
  // P0 FIX — Gemini reading its own "say exactly this" wrapper out loud
  // CONFIRMED: 5 of 15 constrained-verbatim sends this session leaked —
  // Gemini spoke the literal instruction text ("Say exactly and only the
  // following, with no additions, no preamble, and no extra commentary:
  // '...'") instead of just the quoted content, then got interrupted and
  // fell back to "I didn't catch that." The Live API's client protocol has
  // no system/tool-role message this could be sent as instead (confirmed
  // elsewhere in this file: `setup`/`clientContent`/`realtimeInput`/
  // `toolResponse` are the entire client vocabulary, and
  // `systemInstruction` is a ONE-TIME field in the initial `setup`
  // message, not re-sendable per turn) — so this is the report's own
  // suggested stopgap: detect a leaked wrapper via the SAME
  // `outputTranscription` visibility [_auditGeminiCompletionClaim]/
  // [_auditGeminiDuplicateResponse] already use, silently suppress its
  // audio, and retry the same instruction, bounded so a model that keeps
  // leaking can never loop forever.
  // ===========================================================================

  /// See [_suppressResponseAudioForDuplicate]'s doc comment for the SAME
  /// "separate flag, not shared machinery" reasoning — this one stops
  /// [_onResponseAudioChunk] from playing the rest of a turn the instant
  /// [_auditGeminiForLeakedInstructionWrapper] recognizes it as a leaked
  /// wrapper, so the technician never hears "Say exactly and only the
  /// following..." play out in full. Cleared at the next turn boundary in
  /// [_logAndResetTurnShape], same as every other per-turn suppression
  /// flag in this file.
  bool _suppressResponseAudioForLeakedWrapper = false;

  bool _verbatimInstructionAuditedThisTurn = false;

  /// How many times the CURRENT pending scripted line has already been
  /// retried after a leaked wrapper — reset to 0 the moment
  /// [_informGeminiToSpeakVerbatim] is asked to speak a genuinely
  /// DIFFERENT line (see that method's own reset logic), so this budget is
  /// per-LINE, not a single session-wide allowance that could starve a
  /// later, unrelated scripted response.
  int _verbatimInstructionRetryCount = 0;

  /// Bounded so a model that keeps leaking the wrapper can never retry
  /// forever — after this many retries, the line is left unsaid (silence)
  /// rather than risking an infinite loop of the same leak repeating.
  /// Silence is the safer failure here: the technician not hearing a
  /// confirmation at all is a lesser problem than hearing broken
  /// instruction text play out and get interrupted every single time.
  static const int _maxVerbatimInstructionRetries = 2;

  /// Normalized (via [_normalizeForEchoCompare]) prefix of
  /// [_informGeminiToSpeakVerbatim]'s own wrapper text — checked as a
  /// substring near the start of what Gemini actually said, not an exact
  /// `startsWith`, so a model that prepends a small acknowledgment before
  /// leaking ("Okay, say exactly...") is still caught.
  static const String _verbatimInstructionLeakPrefix = 'say exactly';

  /// Called for every `outputTranscription` fragment, same accumulate-
  /// once-per-turn shape as [_auditGeminiCompletionClaim]/
  /// [_auditGeminiDuplicateResponse]. The moment [_currentTurnGeminiText]
  /// (already updated by [_auditGeminiCompletionClaim], called
  /// immediately before this at the same call site) contains
  /// [_verbatimInstructionLeakPrefix], this turn is a leaked wrapper, not
  /// a genuine response — suppress its audio and retry the pending line.
  void _auditGeminiForLeakedInstructionWrapper() {
    if (_verbatimInstructionAuditedThisTurn) return;
    final normalized = _normalizeForEchoCompare(_currentTurnGeminiText);
    if (normalized.length < _verbatimInstructionLeakPrefix.length) return;
    if (!normalized.contains(_verbatimInstructionLeakPrefix)) return;
    _verbatimInstructionAuditedThisTurn = true;

    _log_(
      'VERBATIM INSTRUCTION LEAK: Gemini spoke the wrapper instruction itself ("$_currentTurnGeminiText") '
      'instead of just the intended content — suppressing this turn\'s audio.',
    );
    _suppressResponseAudioForLeakedWrapper = true;

    // A leaked FILLER is just dropped: [_lastVerbatimScriptText] is the last
    // real scripted line, not the filler (see [_speakPendingCallFiller]), so
    // retrying here would re-speak an old, unrelated line mid-capture.
    if (_fillerPassthroughActive) {
      _log_('VERBATIM INSTRUCTION LEAK: leaked turn was a pending-call filler — dropped, not retried.');
      return;
    }

    final pendingText = _lastVerbatimScriptText;
    if (pendingText.isEmpty) {
      _log_('VERBATIM INSTRUCTION LEAK: no pending script text on record — leaving it suppressed, nothing to retry.');
      return;
    }
    if (_verbatimInstructionRetryCount >= _maxVerbatimInstructionRetries) {
      _log_(
        'VERBATIM INSTRUCTION LEAK: already retried $_verbatimInstructionRetryCount time(s) for this line — '
        'giving up to avoid a retry loop; the technician gets silence here rather than broken wrapper text.',
      );
      return;
    }
    _verbatimInstructionRetryCount++;
    _log_('VERBATIM INSTRUCTION LEAK: retrying the same line (attempt $_verbatimInstructionRetryCount of $_maxVerbatimInstructionRetries).');
    _informGeminiToSpeakVerbatim(pendingText, reason: 'verbatim_instruction_leak_retry');
  }

  /// Pushes [text] (this now-finished turn's full spoken text) into
  /// [_recentGeminiTurnHistory] for future turns to compare against, and
  /// trims anything outside [_duplicateResponseLookbackWindow] plus a hard
  /// count cap, so this can never grow unbounded over a long session. A
  /// no-op for text too short to be a meaningful comparison target (the
  /// same [_echoBackstopMinWords]/[_echoBackstopMinChars] gate
  /// [_looksLikeGeminiEcho] already uses) — a short generic reply like
  /// "Got it." repeating is normal conversational cadence, not evidence of
  /// anything wrong.
  void _recordGeminiTurnForDuplicateDetection(String text) {
    final normalized = _normalizeForEchoCompare(text);
    if (normalized.length >= _echoBackstopMinChars &&
        normalized.split(' ').where((w) => w.isNotEmpty).length >= _echoBackstopMinWords) {
      _recentGeminiTurnHistory.add((text: text, at: DateTime.now()));
    }
    final cutoff = DateTime.now().subtract(_duplicateResponseLookbackWindow);
    _recentGeminiTurnHistory.removeWhere((entry) => entry.at.isBefore(cutoff));
    const maxEntries = 6;
    if (_recentGeminiTurnHistory.length > maxEntries) {
      _recentGeminiTurnHistory.removeRange(0, _recentGeminiTurnHistory.length - maxEntries);
    }
  }

  /// Called for every `outputTranscription` fragment, same accumulate-
  /// once-per-turn shape as [_auditGeminiCompletionClaim]. The first time
  /// THIS turn's accumulating text crosses the same min-length gate
  /// [_recordGeminiTurnForDuplicateDetection] uses, compares it against
  /// every still-in-window entry in [_recentGeminiTurnHistory] using
  /// [_bestWordOverlapRatio] — the exact same word-overlap algorithm
  /// already proven for echo detection, applied here turn-to-turn instead
  /// of chunk-to-blob. A high enough overlap means this turn is, for all
  /// practical purposes, repeating something already said seconds ago:
  /// arms [_suppressResponseAudioForDuplicate] so no further audio for
  /// THIS turn plays, and logs a single greppable violation line.
  ///
  /// Deliberately fires on the FIRST qualifying fragment, not the whole
  /// turn: TTS audio and its transcription arrive interleaved and roughly
  /// in step, so catching this as early as possible in the turn is what
  /// actually limits how much of a repeat plays before suppression kicks
  /// in — some of it may already have been heard by the time enough text
  /// has accumulated to compare, which is an accepted trade-off (still far
  /// better than the full sentence playing three times over).
  void _auditGeminiDuplicateResponse(String fragment) {
    if (_duplicateResponseAuditedThisTurn) return;
    // Pending-call fillers legitimately repeat word-for-word (five captures
    // in a row each get "Just a second, still capturing.") — never a
    // duplicate to suppress. See [_speakPendingCallFiller].
    if (_fillerPassthroughActive) return;
    // [_currentTurnGeminiText] is guaranteed already updated with this same
    // [fragment] by the time this runs — [_auditGeminiCompletionClaim],
    // called immediately before this at the same call site, updates it as
    // its own first line.
    final soFar = _currentTurnGeminiText;
    final normalized = _normalizeForEchoCompare(soFar);
    if (normalized.length < _echoBackstopMinChars) return;
    final words = normalized.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.length < _echoBackstopMinWords) return;
    _duplicateResponseAuditedThisTurn = true;

    final cutoff = DateTime.now().subtract(_duplicateResponseLookbackWindow);
    for (final entry in _recentGeminiTurnHistory.reversed) {
      if (entry.at.isBefore(cutoff)) continue;
      final priorWords = _normalizeForEchoCompare(entry.text).split(' ').where((w) => w.isNotEmpty).toList();
      final overlap = _bestWordOverlapRatio(words, priorWords);
      if (overlap < _duplicateResponseOverlapThreshold) continue;
      final agoMs = DateTime.now().difference(entry.at).inMilliseconds;
      _log_(
        'DUPLICATE RESPONSE SUPPRESSED: current turn ("$soFar") overlaps ${(overlap * 100).toStringAsFixed(0)}% '
        'of a turn spoken ${agoMs}ms ago ("${entry.text}") — >= ${(_duplicateResponseOverlapThreshold * 100).toStringAsFixed(0)}% threshold. Dropping the '
        'remainder of this turn\'s audio so the technician does not hear the same confirmation again '
        '(P0 audio-echo safety net).',
      );
      _suppressResponseAudioForDuplicate = true;
      // P0 FIX (CONFIRMED regression: this used to be the ONLY effect of a
      // duplicate finding, and it silently ate the wrong audio — see
      // [_pendingPcmChunksAwaitingReinit]'s doc comment for the full "Can
      // you hear me?" evidence). [_suppressResponseAudioForDuplicate]
      // alone only stops FUTURE chunks arriving live over the websocket
      // for this turn — it says nothing about chunks that arrived EARLIER
      // and are already sitting in the reinit-pending queue, waiting to be
      // flushed later via [_flushQueuedPcmChunksForGeneration], which
      // re-feeds the WHOLE queue through [_onResponseAudioChunk]
      // regardless of which turn each entry belongs to. Purging THIS
      // turn's own already-queued entries right now — by [turnId], not by
      // clearing the queue wholesale — is what actually keeps this
      // targeted: an EARLIER turn's still-queued, still-wanted audio
      // (e.g. a genuinely first-heard reply that just hasn't been flushed
      // yet) is never touched, only ever this specific, just-confirmed
      // duplicate turn's own entries.
      final purged = _pendingPcmChunksAwaitingReinit.length;
      _pendingPcmChunksAwaitingReinit.removeWhere((c) => c.turnId == _currentResponseTurnId);
      final actuallyPurged = purged - _pendingPcmChunksAwaitingReinit.length;
      if (actuallyPurged > 0) {
        _log_(
          'DUPLICATE RESPONSE SUPPRESSED: also purged $actuallyPurged already-queued chunk(s) tagged turn '
          '$_currentResponseTurnId from the reinit-pending queue (${_pendingPcmChunksAwaitingReinit.length} '
          'chunk(s) from OTHER turns left untouched).',
        );
      }
      return;
    }
  }

  /// The [_currentResponseTurnId] the interrupted-turn baseline was last
  /// evaluated for — it's checked once per turn (see
  /// [_maybeAuditAgainstInterruptedTurnBaseline]).
  int? _interruptedBaselineAuditedTurnId;

  /// Runs [_auditAgainstInterruptedTurnBaseline] ONCE per turn, as soon as
  /// this turn has as many words as the interrupted partial — deliberately
  /// NOT behind [_auditGeminiDuplicateResponse]'s 3-word/12-char gate, so a
  /// restart of "Yes, I…" is cut at "Yes, I" rather than after "Yes, I can
  /// hear". Separate from (and never touching) the completed-turn check's
  /// own gate, flag and history.
  void _maybeAuditAgainstInterruptedTurnBaseline() {
    final baseline = _interruptedTurnBaseline;
    if (baseline == null || _fillerPassthroughActive || _suppressResponseAudioForDuplicate) return;
    if (_interruptedBaselineAuditedTurnId == _currentResponseTurnId) return;
    final soFar = _currentTurnGeminiText;
    final words = _normalizeForEchoCompare(soFar).split(' ').where((w) => w.isNotEmpty).toList();
    final baselineWordCount = _normalizeForEchoCompare(baseline.text).split(' ').where((w) => w.isNotEmpty).length;
    if (words.isEmpty || words.length < baselineWordCount) return;
    _interruptedBaselineAuditedTurnId = _currentResponseTurnId;
    _auditAgainstInterruptedTurnBaseline(words, soFar);
  }

  /// CONFIRMED via flutter_run_log 97579c46 (acknowledge_presence): a
  /// scripted line's first attempt was `interrupted` after only 1-2 words
  /// (then an empty `turnComplete`), and a completely fresh generation of
  /// the SAME line then played in full — the technician heard the greeting
  /// start twice. The completed-turn history above never caught it: the
  /// interrupted attempt's text DOES reach [_recordGeminiTurnForDuplicateDetection]
  /// via [_logAndResetTurnShape], but 1-2 words is below that function's
  /// [_echoBackstopMinWords]/[_echoBackstopMinChars] gate (kept as is — it
  /// correctly ignores short generic replies), so nothing was recorded.
  ///
  /// This baseline keeps whatever was AUDIBLY played of an interrupted turn
  /// (same audible-only rule as the completed-turn history's P1 fix: a
  /// muted attempt was never heard, so it can never be "heard twice"),
  /// with the scripted line in effect and the utterance it belonged to.
  ({String text, DateTime at, int utteranceSeq, String script})? _interruptedTurnBaseline;

  void _recordInterruptedTurnBaseline() {
    final audible = _currentTurnAudiblyPlayedText.trim();
    if (audible.isEmpty) return;
    // a7d30b48 log: only the tail "that?" of an interrupted readback was
    // audible, so the restart ("Got it — noted: …") scored 0% against it
    // and played in full. When the audible part is not how the turn opened,
    // compare against the turn's FULL transcript (muted head included) —
    // a restart opens like that. Turns heard from their start keep using
    // the audible partial exactly as before.
    final full = _currentTurnGeminiText.trim();
    List<String> wordsOf(String text) => _normalizeForEchoCompare(text).split(' ').where((w) => w.isNotEmpty).toList();
    final audibleWords = wordsOf(audible);
    final fullWords = wordsOf(full);
    final audibleIsOpening = fullWords.length < audibleWords.length ||
        List.generate(audibleWords.length, (i) => fullWords[i] == audibleWords[i]).every((same) => same);
    final partial = audibleIsOpening ? audible : full;
    if (!audibleIsOpening) {
      _log_(
        'DUPLICATE RESPONSE BASELINE: audible part "$audible" is a mid-turn tail — using the interrupted turn\'s full '
        'transcript as the baseline instead.',
      );
    }
    _interruptedTurnBaseline = (
      text: partial,
      at: DateTime.now(),
      utteranceSeq: _utteranceSeq,
      script: _lastVerbatimScriptText,
    );
    _log_(
      'DUPLICATE RESPONSE BASELINE: turn interrupted after audibly playing "$partial" — kept as an interrupted-turn '
      'baseline (utterance u=$_utteranceSeq, scripted line "$_lastVerbatimScriptText") so a fresh restart of the same '
      'line is caught as a duplicate.',
    );
  }

  /// When the speech behind the most recent real technician transcript
  /// STARTED (a chunk that got past the echo backstop, stamped with its
  /// utterance's start) — the "same utterance" test for
  /// [_auditAgainstInterruptedTurnBaseline]: a new turn with NO technician
  /// speech begun since an interrupted one can only be the model answering
  /// the same thing again.
  DateTime? _lastTechnicianTranscriptAt;

  /// See [_interruptedTurnBaseline]. CONFIRMED via flutter_run_log 43ae0942:
  /// the first version of this check never fired — "Yes, I" was recorded,
  /// then "Yes, I can hear you. What do you need on the job?" played in
  /// full. Two reasons, both fixed here:
  ///  - "Same utterance" was `_utteranceSeq` equality, but that counter
  ///    bumps on any mic-amplitude edge after 2s of quiet — the greeting's
  ///    own speaker bleed included. It's now "no genuine technician
  ///    transcript since the baseline" ([_lastTechnicianTranscriptAt]).
  ///  - It also demanded the scripted line be unchanged and word-for-word
  ///    prefix-equal. It now uses the SAME [_bestWordOverlapRatio] and
  ///    [_duplicateResponseOverlapThreshold] (85%) as the completed-turn
  ///    check — oriented baseline-into-current (what fraction of the
  ///    interrupted partial reappears at the START of this turn), because
  ///    the completed-turn orientation (current-into-prior) scores a
  ///    4-word turn against a 2-word partial as 0 by construction.
  /// A 1-word partial is too weak alone ("Yes…" opens many replies) and
  /// additionally needs this turn to be restarting the current scripted
  /// line. Every skip is logged so the next device log says why.
  void _auditAgainstInterruptedTurnBaseline(List<String> words, String soFar) {
    final result = _evaluateInterruptedTurnBaseline(words, soFar);
    if (result.verdict == _BaselineVerdict.duplicate) _suppressTurnAsInterruptedDuplicate(soFar, result.overlap);
  }

  /// Words of the interrupted partial compared when TURN IDENTITY is
  /// deciding whether to release a held scripted turn (see
  /// [_classifyTurnAgainstScript]). The comparison itself is unchanged —
  /// same [_bestWordOverlapRatio], same 85% threshold — it just runs on the
  /// partial's opening words, so the decision is ready after a few words of
  /// transcript instead of the whole partial (10 words in flutter_run_log
  /// 6038bc76, i.e. longer than TURN IDENTITY's own hold timeout).
  static const int _baselineHoldCompareWords = 4;

  /// Side-effect-free except for dropping a baseline that no longer
  /// applies (expired / new technician speech) — the "is this turn a
  /// restart of the interrupted one" decision, shared by the post-release
  /// audit ([_auditAgainstInterruptedTurnBaseline]) and the pre-release
  /// hold in [_classifyTurnAgainstScript]. [maxBaselineWords] limits how
  /// much of the partial is compared (see [_baselineHoldCompareWords]).
  ({_BaselineVerdict verdict, double overlap}) _evaluateInterruptedTurnBaseline(
    List<String> words,
    String soFar, {
    int? maxBaselineWords,
  }) {
    const none = (verdict: _BaselineVerdict.noBaseline, overlap: 0.0);
    final baseline = _interruptedTurnBaseline;
    if (baseline == null) return none;
    final age = DateTime.now().difference(baseline.at);
    if (age > _duplicateResponseLookbackWindow) {
      _log_('DUPLICATE RESPONSE BASELINE: not applied — recorded ${age.inMilliseconds}ms ago, outside the '
          '${_duplicateResponseLookbackWindow.inSeconds}s window; dropped.');
      _interruptedTurnBaseline = null;
      return none;
    }
    final heardAt = _lastTechnicianTranscriptAt;
    if (heardAt != null && heardAt.isAfter(baseline.at)) {
      _log_('DUPLICATE RESPONSE BASELINE: not applied — the technician spoke again after "${baseline.text}" was '
          'interrupted, so this turn answers new speech; dropped.');
      _interruptedTurnBaseline = null;
      return none;
    }
    List<String> wordsOf(String text) => _normalizeForEchoCompare(text).split(' ').where((w) => w.isNotEmpty).toList();
    var baselineWords = wordsOf(baseline.text);
    if (baselineWords.isEmpty) return none;
    if (maxBaselineWords != null && baselineWords.length > maxBaselineWords) {
      baselineWords = baselineWords.sublist(0, maxBaselineWords);
    }
    if (words.length < baselineWords.length) return (verdict: _BaselineVerdict.needMoreWords, overlap: 0.0);
    // The partial must reappear at the START of this turn (a restart), not
    // just anywhere in it — compare against this turn's leading window.
    final leadLen = baselineWords.length + 1 < words.length ? baselineWords.length + 1 : words.length;
    final overlap = _bestWordOverlapRatio(baselineWords, words.sublist(0, leadLen));
    if (overlap < _duplicateResponseOverlapThreshold) {
      _log_('DUPLICATE RESPONSE BASELINE: not applied — this turn ("$soFar") opens differently from the interrupted '
          '"${baseline.text}" (${(overlap * 100).toStringAsFixed(0)}% < '
          '${(_duplicateResponseOverlapThreshold * 100).toStringAsFixed(0)}%).');
      return (verdict: _BaselineVerdict.notDuplicate, overlap: overlap);
    }
    if (baselineWords.length < 2) {
      final scriptWords = wordsOf(_lastVerbatimScriptText);
      final restartsScript = scriptWords.length >= words.length &&
          List.generate(words.length, (i) => words[i] == scriptWords[i]).every((same) => same);
      if (!restartsScript) {
        _log_('DUPLICATE RESPONSE BASELINE: not applied — the interrupted partial "${baseline.text}" is a single word '
            'and this turn is not a restart of the current scripted line; too weak to suppress on.');
        return (verdict: _BaselineVerdict.notDuplicate, overlap: overlap);
      }
    }
    return (verdict: _BaselineVerdict.duplicate, overlap: overlap);
  }

  void _suppressTurnAsInterruptedDuplicate(String soFar, double overlap) {
    final baseline = _interruptedTurnBaseline;
    if (baseline == null) return;
    final age = DateTime.now().difference(baseline.at);
    _interruptedTurnBaseline = null;
    _interruptedBaselineAuditedTurnId = _currentResponseTurnId;
    _log_(
      'DUPLICATE RESPONSE SUPPRESSED: current turn ("$soFar") overlaps ${(overlap * 100).toStringAsFixed(0)}% of an '
      'INTERRUPTED turn spoken ${age.inMilliseconds}ms ago ("${baseline.text}", interrupted-turn baseline, no '
      'technician speech since) — >= ${(_duplicateResponseOverlapThreshold * 100).toStringAsFixed(0)}% threshold. '
      'Dropping the remainder of this turn\'s audio so the technician does not hear it start over '
      '(P0 audio-echo safety net).',
    );
    _suppressResponseAudioForDuplicate = true;
    // Same targeted purge as the completed-turn path above — only THIS
    // turn's already-queued chunks.
    final queuedBefore = _pendingPcmChunksAwaitingReinit.length;
    _pendingPcmChunksAwaitingReinit.removeWhere((c) => c.turnId == _currentResponseTurnId);
    final purged = queuedBefore - _pendingPcmChunksAwaitingReinit.length;
    if (purged > 0) {
      _log_(
        'DUPLICATE RESPONSE SUPPRESSED: also purged $purged already-queued chunk(s) tagged turn '
        '$_currentResponseTurnId from the reinit-pending queue (interrupted-turn baseline).',
      );
    }
  }

  /// Executes every `functionCalls` entry in a `toolCall` message via
  /// [dispatchGeminiFunctionCall] — the routing-only dispatcher in
  /// `lib/services/gemini_function_dispatcher.dart` — then sends Gemini a
  /// `toolResponse` for each one, matching each `functionResponse.id` back
  /// to the `functionCall.id` it answers (required so Gemini can tell which
  /// response belongs to which call when more than one arrives in the same
  /// `toolCall`). A call that throws is reported back as an error response
  /// rather than left hanging — Gemini would otherwise wait indefinitely on
  /// a BLOCKING call that never gets an answer.
  Future<void> _handleToolCall(Map<String, dynamic> toolCall) async {
    final functionCalls = (toolCall['functionCalls'] as List<dynamic>?) ?? const [];
    final functionResponses = <Map<String, dynamic>>[];
    // Set when Gemini calls `end_session` — deliberately NOT acted on until
    // AFTER the toolResponse below is sent (see the end of this method):
    // `_stopTest()` tears down `_channel` itself, so ending the session
    // before Gemini's function call gets acknowledged would mean sending
    // that acknowledgment over an already-closed socket.
    var shouldEndSession = false;

    for (final raw in functionCalls) {
      final call = raw as Map<String, dynamic>;
      final id = call['id'] as String?;
      final name = call['name'] as String?;
      var args = (call['args'] as Map<String, dynamic>?) ?? const <String, dynamic>{};

      if (name == null) {
        _log_('ERROR (toolCall): functionCall missing "name" — skipping: $call');
        continue;
      }

      // `end_session` is screen-lifecycle control (ending THIS session),
      // not "reuse an existing backend Lambda" — it deliberately does NOT
      // go through gemini_function_dispatcher.dart, which only ever routes
      // to existing backend/provider logic.
      if (name == 'end_session') {
        _log_('toolCall: "end_session" (id=$id) — ending this voice session');
        functionResponses.add({'id': id, 'name': name, 'response': {'status': 'ending'}});
        shouldEndSession = true;
        continue;
      }

      // `get_current_screen` is local UI state (see [_describeCurrentScreen]),
      // not "reuse an existing backend Lambda" — same reasoning as
      // `end_session` above, deliberately NOT routed through
      // gemini_function_dispatcher.dart.
      if (name == 'get_current_screen') {
        _lastGetCurrentScreenActivityAt = DateTime.now();
        final description = _describeCurrentScreen();
        _log_('toolCall: "get_current_screen" (id=$id) — GEMINI-INITIATED: $description');
        functionResponses.add({'id': id, 'name': name, 'response': {'screen_description': description}});
        _clearAllTriggerBuffersAfterSuccess('toolCall "get_current_screen" (id=$id)');
        _informGeminiToSpeakVerbatim(description, reason: 'toolCall get_current_screen (id=$id)');
        continue;
      }

      // Job-scoped mode only: force the REAL job_id already known to this
      // screen into every call, overriding whatever (if anything) Gemini
      // supplied — there's no reliable way to voice-dictate a UUID
      // correctly, so this app-level binding is what actually guarantees
      // correctness, not the model's own output. No-op in standalone mode
      // (widget.jobId == null) and harmless for the functions that ignore
      // job_id entirely (get_kb_answer treats it as optional).
      final jobId = widget.jobId;
      if (jobId != null) {
        final original = args['job_id'];
        if (original != jobId) {
          _log_('toolCall: "$name" (id=$id) job_id overridden to real job $jobId (Gemini supplied: $original)');
        }
        args = {...args, 'job_id': jobId};
      }

      // awaitingPhotoDescription — Gemini hears the same audio and may act
      // on a spoken photo note itself. While the flow owns this utterance
      // nothing Gemini calls for it runs; while the flow is merely waiting,
      // Gemini's own note/question tools are held back (the flow decides
      // what that speech is). Checked BEFORE the debounce claims below: a
      // held-back call must not stamp a trigger's `lastActivityAt`, or the
      // flow's own break-out replay of a real command (see
      // [_photoNoteBreakOutToRealCommand]) would be debounced as "Gemini
      // already handling this" and never actually run.
      if (_photoNote != null &&
          (_photoNoteOwnsCurrentUtterance || name == 'site_condition' || name == 'get_kb_answer')) {
        _log_('toolCall: "$name" (id=$id) SUPPRESSED — awaitingPhotoDescription owns this speech (photo note flow).');
        _photoNoteLog('state', 'suppressed Gemini toolCall "$name" — speech belongs to the photo-note flow');
        functionResponses.add({
          'id': id,
          'name': name,
          'response': {'status': 'already_handled', 'job_id': args['job_id']},
        });
        continue;
      }

      // KB GATE — Gemini deciding on its own to call get_kb_answer is held
      // to the same per-screen rule as the app's own KB routing: never
      // called off Job Detail. Nothing is spoken here; the app's own
      // end-of-utterance routing for this same speech asks for
      // clarification (see [_maybeFallBackToKbAnswerCatchAll]).
      if (name == 'get_kb_answer' && !_kbGateAllows('gemini_toolcall')) {
        _log_('toolCall: "get_kb_answer" (id=$id) SUPPRESSED — KB fallback is disabled on this screen.');
        functionResponses.add({
          'id': id,
          'name': name,
          'response': {'status': 'already_handled', 'job_id': args['job_id']},
        });
        continue;
      }

      // GEMINI INTENT CHECK — the classification this app asked for (see
      // [_maybeStartGeminiIntentCheck]); local state only, never dispatched.
      if (name == _geminiIntentCheckFunctionName) {
        final intent = args['intent'] as String?;
        final confidence = (args['confidence'] as num?)?.toDouble();
        _log_('toolCall: "$name" (id=$id) — intent=$intent confidence=$confidence');
        functionResponses.add({
          'id': id,
          'name': name,
          'response': {'status': 'ok', 'scheduling': 'SILENT'},
        });
        _resolveGeminiIntentCheck(
          checkId: args['check_id'] as String?,
          intent: intent,
          confidence: confidence,
          source: 'toolCall',
        );
        continue;
      }

      if (name == 'capture_photo') {
        debugPrint('BLOCKING TEST T1 (function triggered): ${DateTime.now()}');
      }

      // Claim the debounce window the instant Gemini itself genuinely
      // attempts view_estimate — success or failure both count as "Gemini
      // is handling this," so [_maybeTriggerViewEstimate] correctly stays
      // out of the way either way. Logged distinctly from the deterministic
      // trigger's own "GEMINI DETERMINISTIC TRIGGER" lines so logs can
      // always tell which path actually handled a given request.
      if (name == 'view_estimate') {
        _lastViewEstimateActivityAt = DateTime.now();
        _log_('toolCall: "$name" (id=$id) — GEMINI-INITIATED (Gemini called this itself, not the deterministic trigger)');
      }

      // Same claim-the-debounce-window reasoning, applied to the
      // get_job_details deterministic trigger (CONFIRMED ghost-call bug).
      if (name == 'get_job_details') {
        _lastGetJobDetailsActivityAt = DateTime.now();
        _log_('toolCall: "$name" (id=$id) — GEMINI-INITIATED (Gemini called this itself, not the deterministic trigger)');
      }

      // Same claim-the-debounce-window reasoning, applied generically to
      // every [_deterministicTriggers] function in one place — see
      // [_TranscriptTrigger]'s doc comment for why this is shared rather
      // than six more hand-written blocks like the ones above/below.
      final sharedTrigger = _deterministicTriggers[name];
      if (sharedTrigger != null) {
        sharedTrigger.lastActivityAt = DateTime.now();
        _log_('toolCall: "$name" (id=$id) — GEMINI-INITIATED (Gemini called this itself, not the deterministic trigger)');
      }

      // Same claim-the-debounce-window reasoning as the view_estimate block
      // above, applied to the camera-flow go_back deterministic trigger.
      if (name == 'go_back') {
        _lastGoBackActivityAt = DateTime.now();
        _log_('toolCall: "$name" (id=$id) — GEMINI-INITIATED (Gemini called this itself, not the deterministic trigger)');
      }

      // Same claim-the-debounce-window reasoning again, applied to the
      // photo-decision deterministic trigger (CHECK 4 reliability audit).
      if (name == 'confirm_photo_upload' || name == 'retake_photo') {
        _lastPhotoDecisionActivityAt = DateTime.now();
        _log_('toolCall: "$name" (id=$id) — GEMINI-INITIATED (Gemini called this itself, not the deterministic trigger)');
      }

      // ISSUE 1 fix (CONFIRMED via f5a8bd8b-flutter_run_log.txt:
      // "PHOTO TIMING [open_camera]: handler_entry" logged TWICE, ~3ms
      // apart, for the SAME open_camera request). Root cause: Gemini's own
      // genuine toolCall for `name` arrived here while this app's OWN
      // deterministic trigger had ALREADY fired `name` for this exact
      // utterance a moment earlier — the debounce claims just above stop
      // the deterministic trigger from firing AGAIN once a genuine toolCall
      // claims `lastActivityAt` first, but nothing stopped the REVERSE
      // ordering: a genuine toolCall arriving after this app's own trigger
      // already fired never checked that at all, and just dispatched a
      // SECOND real call. Two concurrent `CameraController.initialize()`
      // calls contending for the same camera hardware is a plausible real
      // cause of that log's 3.79s Dart-side gap before the native call
      // actually dispatched. Fixed symmetrically: if this app's own trigger
      // already resolved (fired) `name` for the CURRENT utterance, this
      // toolCall is redundant — never dispatch a second, concurrent real
      // call. Still acknowledged back to Gemini (the Live API expects a
      // functionResponse for every toolCall it sends), just without a
      // second real dispatch and without a second spoken confirmation (the
      // app's own trigger already handles speaking one).
      // P0 FIX — same one-trigger-per-utterance rule as the evaluation loop
      // in [_onInputTranscription], extended to Gemini's own toolCalls for
      // screen-changing functions: if the app already committed a
      // DIFFERENT trigger for this utterance (e.g. go_back), a Gemini
      // view_invoice for it must not push a second screen on top.
      final conflictsWithCommittedTrigger = (_isNavigatingScreenFunction(name) || name == 'go_back') &&
          _anyTriggerCommittedThisUtterance &&
          !_alreadyResolvedByAppTriggerThisUtterance(name);
      if (conflictsWithCommittedTrigger) {
        _log_(
          'toolCall: "$name" (id=$id) SUPPRESSED — this utterance was already committed to a different app '
          'trigger; one screen change per utterance.',
        );
        functionResponses.add({
          'id': id,
          'name': name,
          'response': {'status': 'already_handled', 'job_id': args['job_id']},
        });
        continue;
      }
      // awaitingPhotoDescription (see the held-back check above, before the
      // debounce claims): any other genuine Gemini command ends the flow.
      if (_photoNote != null) {
        // Not Gemini's own late duplicate of the keep/retake that STARTED
        // this flow, nor of a break-out command the app itself already ran
        // for this utterance (both handled by the duplicate check below).
        if (name != 'confirm_photo_upload' &&
            name != 'retake_photo' &&
            !_alreadyResolvedByAppTriggerThisUtterance(name)) {
          _exitPhotoNote('Gemini called "$name" — treated as a new command', outcome: 'interrupted_by_command');
        }
      }
      if (_alreadyResolvedByAppTriggerThisUtterance(name)) {
        _log_(
          'toolCall: "$name" (id=$id) SUPPRESSED — this app\'s own deterministic trigger already fired "$name" '
          'for this exact utterance a moment earlier; not dispatching a second, concurrent real call. '
          'Acknowledging Gemini\'s toolCall without a second spoken confirmation.',
        );
        debugPrint(
          'GEMINI TOOLCALL SUPPRESSED (duplicate): "$name" already fired by this app\'s own deterministic '
          'trigger for this utterance — skipping the second real dispatch.',
        );
        functionResponses.add({
          'id': id,
          'name': name,
          'response': {'status': 'already_handled', 'job_id': args['job_id']},
        });
        continue;
      }

      // ISSUE 2 — see [_dispatchGenerationCounter]'s doc comment: captured
      // BEFORE dispatch, same as the deterministic path in
      // [_executeDeterministic], so a genuine Gemini-initiated toolCall is
      // ordered against deterministic dispatches by when it actually began,
      // not by when it happens to finish.
      final myDispatchGeneration = _beginNewDispatchGeneration();
      Map<String, dynamic> responsePayload;
      // FIX 2: an UNPROMPTED go_back right after a view_* succeeded — no
      // actual "take me back" heard from the technician in between — is
      // held back entirely rather than dispatched. Checked BEFORE the
      // normal dispatch below, not after: a real navigation pop is hard to
      // usefully "undo" once it's happened, so this has to stop it from
      // ever occurring at all, not clean up afterward.
      if (name == 'go_back' && _isGoBackInCooldown()) {
        final elapsed = DateTime.now().difference(_lastViewFunctionSucceededAt!);
        _log_(
          'GO BACK COOLDOWN: blocked an unprompted go_back (id=$id) — only ${elapsed.inMilliseconds}ms since '
          'the last view_ succeeded (< ${_goBackCooldownDuration.inSeconds}s) and no intentional go-back '
          'phrase heard since. Not navigating.',
        );
        debugPrint(
          'GEMINI GO BACK COOLDOWN: blocked automatic go_back (${elapsed.inMilliseconds}ms after last view_ '
          'success, no intentional phrase heard)',
        );
        responsePayload = {'status': 'blocked_cooldown', 'job_id': args['job_id']};
      } else {
        try {
          _log_('toolCall: dispatching "$name" (id=$id) args=$args ...');
          _beginFunctionCallInFlight('toolCall "$name" (id=$id)');
          try {
            responsePayload = await _pipelineDispatch(
              name: name,
              source: 'gemini_toolCall',
              call: () => _dispatchWithOpenCameraSafeguards(name: name, args: args),
            );
          } finally {
            _endFunctionCallInFlight('toolCall "$name" (id=$id)');
          }
          _log_('toolCall: "$name" (id=$id) succeeded: $responsePayload');
          // FIX 2: a genuinely successful (non-error) function call resolves
          // whatever request led to it — clear every trigger buffer so
          // nothing from before this point can combine with new speech
          // after it.
          if (!responsePayload.containsKey('error')) {
            _clearAllTriggerBuffersAfterSuccess('toolCall "$name" (id=$id)');
            // ISSUE 2 — see [_recordDispatchSucceeded]'s doc comment.
            _recordDispatchSucceeded(myDispatchGeneration, name);
          }
          // BUG FIX: a successful function call is itself a genuine "turn" —
          // reset here too, not just when the toolCall message first arrived
          // (line above, before dispatch), so a slow-dispatching call still
          // counts as activity for as long as it's genuinely in flight.
          _resetInactivityTimer(reason: 'toolCall "$name" succeeded');
          // Only for a call that actually went through the cooldown gate
          // above (never for a `blocked_cooldown` response) — an
          // UNPROMPTED go_back being blocked must stay a true no-op,
          // including leaving any active camera flow exactly as it was.
          if (name == 'go_back') {
            responsePayload = await _maybeCloseCameraFlowForGoBack(
              responsePayload,
              jobId: (args['job_id'] as String?) ?? widget.jobId ?? '',
            );
          }
        } catch (e, stackTrace) {
          debugPrint('GEMINI LIVE TEST ERROR (toolCall "$name"): $e\n$stackTrace');
          _log_('toolCall: "$name" (id=$id) FAILED: $e');
          responsePayload = {'error': e.toString()};
        }
      }

      if (name == 'capture_photo') {
        debugPrint('BLOCKING TEST T2 (function returned): ${DateTime.now()}');
        _blockingTestAwaitingT3 = true;
      }

      _updateScreenTaskForToolCall(name, responsePayload);

      // FIX 2: arms the go_back cooldown the instant a view_* genuinely
      // succeeds — see `_goBackCooldownDuration`'s doc comment. Resets
      // `_intentionalGoBackHeardSinceLastView` to false so an intentional
      // phrase heard for a PREVIOUS view_ screen doesn't carry over and
      // incorrectly waive the cooldown for this new one.
      if (_isNavigatingScreenFunction(name) && _viewResultNavigated(responsePayload)) {
        _lastViewFunctionSucceededAt = DateTime.now();
        _intentionalGoBackHeardSinceLastView = false;
        _currentViewScreenName = name;
        _log_(
          'GO BACK COOLDOWN: "$name" succeeded — go_back cooldown armed for '
          '${_goBackCooldownDuration.inSeconds}s unless an intentional go-back phrase is heard first.',
        );
      }

      // PART F: rather than trust Gemini's own follow-up narration turn
      // to phrase this result correctly (or at all), this builds the
      // exact sentence locally and has Gemini speak it verbatim — same
      // builder either way, whether Gemini called the function itself or
      // the app's deterministic backstop did (see
      // [_buildSpokenTextForResult]).
      final spokenText = responsePayload['silent'] == true ? null : _buildSpokenTextForResult(name: name, result: responsePayload);
      // ISSUE 2 — see [_discardIfStaleDispatch]'s doc comment: same
      // staleness guard [_executeDeterministic] applies, so a genuine but
      // slow-to-resolve Gemini toolCall can't interrupt a newer request's
      // already-spoken confirmation either.
      if (spokenText != null && !_discardIfStaleDispatch(generation: myDispatchGeneration, triggerName: name)) {
        _informGeminiToSpeakVerbatim(spokenText, reason: 'toolCall "$name" (id=$id)');
      }

      functionResponses.add({'id': id, 'name': name, 'response': responsePayload});
    }

    if (functionResponses.isNotEmpty) {
      final channel = _channel;
      if (channel == null) {
        _log_('ERROR (toolCall): WebSocket already closed — cannot send toolResponse for $functionResponses');
      } else {
        final toolResponseMessage = jsonEncode({
          'toolResponse': {'functionResponses': functionResponses},
        });
        channel.sink.add(toolResponseMessage);
        _log_('toolResponse sent: $toolResponseMessage');
      }
    }

    if (shouldEndSession) {
      unawaited(_stopTest(reason: 'end_session requested'));
    }
  }

  /// Called for every `serverContent.inputTranscription` chunk — the
  /// technician's own words, transcribed server-side from the same audio
  /// Gemini itself is listening to (`inputAudioTranscription: {}` in the
  /// setup message is what turns this on). CONFIRMED via a full real
  /// session: Gemini called zero functions natively the entire time, so
  /// EVERY function in [_geminiToolFunctionDeclarations] now has a
  /// deterministic backstop fed from here — nothing in this app's function
  /// calling can depend solely on Gemini's own judgment to fire. Feeds:
  ///  1. [_maybeTriggerViewEstimate] — runs on EVERY chunk, unconditionally,
  ///     since a "show me the estimate" request can happen at any point in
  ///     the conversation, not just after some prior app action.
  ///  2. [_maybeTriggerGetJobDetails] (CONFIRMED ghost-call bug) — same
  ///     "runs on every chunk, unconditionally" shape as #1, watching for
  ///     "tell me about this job"-shaped requests.
  ///  3. [_maybeDetectIntentionalGoBack] — the `view_*` cooldown-lifting
  ///     check (see [_isGoBackInCooldown]) AND the deterministic go_back
  ///     trigger itself, which now fires in any context (not just an active
  ///     camera/photo task) the moment a genuine phrase is heard — see that
  ///     method's own doc comment for the CONFIRMED bug this generalization
  ///     fixes.
  ///  4. [_maybeDetectPhotoDecision] (CHECK 4 reliability audit) — armed
  ///     only while [_screenTask] is [_ScreenTask.cameraCaptured], firing
  ///     `confirm_photo_upload` or `retake_photo` directly the moment a
  ///     genuine "keep it"/"retake it"-shaped decision is heard.
  ///  5. [_maybeTriggerDeterministic], once per [_deterministicTriggers]
  ///     entry — the same "runs on every chunk, unconditionally" shape as
  ///     #1/#2, generalized via [_TranscriptTrigger] to cover
  ///     view_change_orders/view_invoice/view_job_history/open_camera/
  ///     get_kb_answer/site_condition/get_last_photo/get_job_timeline_answer
  ///     without hand-rolling eight more near-identical detectors.
  void _onInputTranscription(String textChunk) {
    _pipelineLog('transcript_received', '"$textChunk" ($_utteranceStateSummary)');
    _maybeLogFirstTranscriptTiming();
    // BUG 2 backstop (step 3): checked BEFORE the "inputTranscription
    // chunk:" log line and BEFORE any trigger sees this text at all — see
    // [_looksLikeGeminiEcho]'s doc comment for the thresholds and why they
    // exist. A flagged chunk that carries a command the technician started
    // saying only after our audio had provably finished playing is let
    // through instead — see [_decideEchoOverride].
    final echoDecision = _looksLikeGeminiEcho(textChunk) ? _decideEchoOverride(textChunk) : EchoDecision.notEcho;
    if (echoDecision == EchoDecision.suppress) {
      _pipelineLog('transcript_dropped', 'reason=echo (reads like Gemini\'s own recent speech) — no matcher sees it');
      // ECHO LOOP FIX (CONFIRMED in a real trace): the "speech" this
      // transcript belongs to was our own voice, so its transcript HAS
      // arrived — there is nothing left to wait for and nothing to answer.
      // Leaving the wait running made its 8s timeout say "I didn't catch
      // that", which echoed in turn ("Sorry, still not catching that",
      // four times in a row).
      _stopAwaitingLateTranscript('the transcript was an echo of our own speech — nothing to answer');
      _log_(
        'ECHO BACKSTOP: discarding inputTranscription chunk "$textChunk" — matches Gemini\'s own recent spoken '
        'output (current turn: "$_currentTurnAudiblyPlayedText"; last completed turn: '
        '"$_lastCompletedTurnAudiblyPlayedText"), treating as acoustic mic bleed, not technician speech — NOT '
        'passed to any trigger',
      );
      debugPrint('PHOTO TIMING [echo]: discarded likely-echo inputTranscription chunk: "$textChunk"');
      // P0 AUDIO-ECHO FIX — the real measurement this whole fix's sizing
      // depends on. This chunk is TEXT-LEVEL discarded (never reaches a
      // trigger), but the underlying raw audio it was transcribed FROM was
      // only ever a problem if it was sent to Gemini AT ALL — i.e. if it
      // arrived while outgoing mic audio was already resumed. Logging how
      // long after the most recent resume this happened turns "is the
      // grace/quiet window wide enough" into something a real run's log
      // answers directly, not something inferred from code reading. A
      // small gap here (a few hundred ms) is expected/harmless — some
      // in-flight network jitter between resume and a chunk that was
      // already borderline is normal; a LARGE gap (multiple seconds, like
      // the confirmed 6-7s repeats) is the actual signal this fix targets.
      final resumedAt = _lastOutgoingMicResumedAt;
      if (resumedAt != null) {
        final sinceResume = DateTime.now().difference(resumedAt);
        _log_(
          'ECHO TIMING: this echo-flagged chunk was transcribed ${sinceResume.inMilliseconds}ms after outgoing '
          'mic audio last resumed — ${sinceResume.inSeconds >= 1 ? "LARGE gap: real acoustic echo tail still audible well after resuming, the adaptive quiet-wait above should be catching this now" : "small gap: normal transcription-latency jitter"}',
        );
      }
      return;
    }
    // P0 FIX (CONFIRMED via a real session: "Show me the estimate. Try me
    // again. For example, show the job history or take a photo." — one
    // inputTranscription chunk containing the technician's REAL request
    // followed by this app's OWN spoken fallback prompt, both merged into
    // one STT segment). [_looksLikeGeminiEcho] above only ever discards a
    // chunk WHOLESALE, and correctly refuses to here — the chunk also
    // carries genuine technician speech that must not be lost. This
    // instead finds and strips just the CONTAMINATED TAIL — see
    // [_stripTrailingEchoContamination]'s own doc comment — so every
    // trigger below only ever sees the technician's own words. (Also
    // backstopped independently by the hard "stop after the first trigger
    // fires" rule in [_maybeTriggerDeterministic] and every hand-rolled
    // trigger function, so even an UN-stripped contamination case can
    // never fire more than one action — but stripping is what gives the
    // TECHNICIAN'S actual request the best chance of being the one that
    // wins, rather than whichever trigger happens to be checked first.)
    textChunk = _stripTrailingEchoContamination(textChunk);
    // Before anything reads this utterance's state — see
    // [_attributeTranscriptChunkToUtterance].
    if (textChunk.trim().isNotEmpty) _attributeTranscriptChunkToUtterance(textChunk);
    _log_('inputTranscription chunk: "$textChunk"');
    // Real technician words (past the echo backstop) — see
    // [_lastTechnicianTranscriptAt].
    // Stamped with when that speech STARTED, so a late trailing chunk of the
    // utterance that caused the interruption doesn't read as new speech.
    if (textChunk.trim().isNotEmpty) _lastTechnicianTranscriptAt = _currentUtteranceStartedAt ?? DateTime.now();
    // Real technician words arrived — any "Thinking..." wait ends, and if
    // they arrived after this utterance was already finalized, its
    // end-of-utterance routing re-runs on them (see
    // [_scheduleLateTranscriptFinalize]).
    _stopAwaitingLateTranscript('transcript arrived');
    _latencyTranscriptAt ??= DateTime.now(); // LATENCY metric only
    final arrivedAfterUtteranceEnd = _finalizedCurrentUtterance && !_isSpeaking;

    // PART I item 1 (CONFIRMED root cause of every remaining "half answer"/
    // late-reply complaint): mute UNCONDITIONALLY, before ANY trigger-
    // specific logic runs — including acknowledge_presence/meta_capability,
    // which used to be checked (and could match+interrupt) BEFORE the
    // preemptive mute ever got a chance to arm. If a short utterance like
    // "can you hear me" arrives as a single transcription chunk that
    // matches instantly, the OLD order meant nothing muted anything until
    // that trigger's OWN interrupt call ran a few lines later — and Gemini's
    // own organic audio (generated from raw input audio, independent of and
    // often faster than this app's own text-based matching) could already
    // be streaming from an earlier server message by then. Every trigger
    // still resolves exactly as fast internally afterward; it just never
    // gets a head start over this mute anymore. See
    // [_muteImmediatelyOnFirstChunkOfUtterance]'s own doc comment.
    _endAwaitingFirstTranscript('first transcript chunk arrived');
    _muteImmediatelyOnFirstChunkOfUtterance();

    // ISSUE 2 — see [_looksLikeNonLatinScriptTranscription]'s doc comment:
    // checked BEFORE any trigger sees this chunk. Genuinely non-Latin-script
    // text (Hindi/Korean/Japanese/Cyrillic/Arabic/Thai) strips to nothing
    // under every trigger's own `[^a-z ]` normalization — there is no
    // matching left to even attempt — so this alone still short-circuits
    // straight to the same "didn't catch that" fallback genuinely-
    // unmatchable STT output gets (see ISSUE 1(c)).
    if (_looksLikeNonLatinScriptTranscription(textChunk)) {
      // An English greeting rendered in another script ("हेलो हेलो") gets the
      // exact same reply "hello" gets, through the same trigger — and only
      // greetings do (see `transliterated_greeting.dart`); anything else in
      // a non-Latin script is still discarded below, unchanged.
      if (!_utteranceAlreadyResolvedByTrigger && looksLikeTransliteratedGreeting(textChunk)) {
        _pipelineLog('transcript_greeting', 'non-Latin-script greeting "$textChunk" — answering it like "hello"');
        _log_('NON-LATIN SCRIPT GREETING: "$textChunk" is a greeting — routing to acknowledge_presence');
        _maybeTriggerAcknowledgePresence('hello');
        return;
      }
      _pipelineLog('transcript_dropped', 'reason=non_latin_script — no matcher sees it');
      _log_('NON-LATIN SCRIPT TRANSCRIPTION DETECTED: skipping English trigger matching for "$textChunk"');
      if (!_utteranceAlreadyResolvedByTrigger) {
        _clearAllTriggerBuffersAfterSuccess('non-latin script transcription detected', endsUnclearInputStreak: false);
        _respondToUnclearInput(reason: 'non_latin_script_transcription');
      }
      return;
    }
    // CONFIRMED bug (flutter_run_log_new.txt, build #50): "Y es, ¿dispor? Me
    // looks good." — a single stray "¿" from garbled STT — used to hit the
    // SAME short-circuit as true non-Latin script above via
    // [_transcriptionDriftReason], and so never even reached
    // [_maybeDetectPhotoDecision] below, even though "looks good" is an
    // exact, unambiguous confirm phrase that survives normalization just
    // fine (only the "¿"/accented characters themselves strip to spaces,
    // not the English words around them — unlike true non-Latin script,
    // where normalization strips EVERYTHING). This heuristic
    // ([_looksLikeNonEnglishLatinTranscription]) is a suspicion, not proof
    // the buffer is unmatchable, so it no longer short-circuits anything —
    // left as a diagnostic log only. Every trigger below still gets its
    // normal chance; [_maybeArmPreemptiveMuteSafetyTimeout] at the end of
    // this method remains the real "nothing matched" fallback, reached only
    // if every one of them genuinely misses.
    if (_looksLikeNonEnglishLatinTranscription(textChunk)) {
      _log_('NON-ENGLISH TRANSCRIPTION SUSPECTED (not skipped — still trying every trigger below): "$textChunk"');
    }

    // BUG FIX: reset on every transcribed chunk of real technician speech,
    // not just the raw-amplitude silence->speech edge in [_trackSpeechLevel]
    // — a genuine transcription is unambiguous evidence the conversation is
    // active right now.
    _resetInactivityTimer(reason: 'technician transcription chunk received');

    // awaitingPhotoDescription — see [_routeTranscriptToPhotoNote]: while a
    // just-kept photo is waiting on an optional note, speech goes there
    // BEFORE any normal trigger; only an interrupting command comes back
    // out (as the whole utterance so far) to be matched normally below. A
    // flow that just timed out is reopened first if this is a late answer
    // to it (see [_maybeReopenPhotoNoteForLateAnswer]).
    _maybeReopenPhotoNoteForLateAnswer();
    if (_photoNote != null) {
      final routed = _routeTranscriptToPhotoNote(textChunk);
      if (routed == null) return;
      textChunk = routed;
    }

    // P0 FIX (CONFIRMED twice in real sessions: view_estimate +
    // view_job_history + open_camera off one utterance, then go_back +
    // view_invoice off another). ONE trigger per utterance, enforced HERE in
    // the shared evaluation loop rather than per trigger pair: the moment
    // any evaluator below commits (see [_anyTriggerCommittedThisUtterance]),
    // the rest are not evaluated against this utterance at all. The old
    // check inside [_maybeTriggerDeterministic] read only
    // [_utteranceAlreadyResolvedByTrigger], which isn't set until a fired
    // trigger's async dispatch SUCCEEDS — so for the whole navigation window
    // (and for every trigger evaluated later in the same chunk) a second
    // trigger could still fire.
    _pipelineLog('transcript_to_matchers', '"$textChunk"');
    if (textChunk.trim().isNotEmpty) _disarmGreetingReplay('a transcript arrived ("${textChunk.trim()}")');
    final evaluators = _buildTriggerEvaluators(textChunk);
    final committedBefore = _anyTriggerCommittedThisUtterance;
    for (final entry in evaluators.entries) {
      // The one exception to one-trigger-per-utterance: a generic go_back
      // fired on an earlier chunk ("Take me back") may still be overridden
      // by the destination the rest of the sentence names ("...to the job
      // screen") — see [_maybeTriggerJobDetailsDestination].
      final destinationOverride = entry.key == 'view_job_details' && _goBackFiredThisUtterance;
      if (_anyTriggerCommittedThisUtterance && !destinationOverride) {
        debugPrint('DETERMINISTIC SKIP: utterance already committed to a trigger — not evaluating the rest');
        break;
      }
      entry.value();
    }
    if (!committedBefore && _anyTriggerCommittedThisUtterance) _utteranceCommittedAt ??= DateTime.now();
    _pipelineLog(
      'matcher_result',
      committedBefore
          ? 'utterance was ALREADY committed before this chunk — no trigger evaluated ($_utteranceStateSummary)'
          : (_anyTriggerCommittedThisUtterance
                ? 'committed ($_utteranceStateSummary)'
                : 'no trigger matched this chunk yet${_pendingGuardFailedReply != null ? ' (a guard-failed clarification is queued)' : ''}'),
    );
    // See the guard-failed branch in [_maybeTriggerDeterministic]: a queued
    // clarification only speaks if nothing actually fired for this chunk.
    final guardFailedReply = _pendingGuardFailedReply;
    _pendingGuardFailedReply = null;
    if (guardFailedReply != null && !_anyTriggerCommittedThisUtterance) {
      _guardFailedReplySpokenThisUtterance = true;
      guardFailedReply();
    }
    // get_kb_answer works standalone too (job_id is optional for it), so
    // get_kb_answer/site_condition are NOT fired here, unlike every trigger
    // above — their matched phrases ("how do i"/"note that") are only a
    // PREFIX of what needs to be sent as `question`/`note`; firing the
    // instant the cue phrase itself matches would truncate the actual
    // argument to just those cue words. These two only accumulate their
    // buffer per chunk and are matched/fired from
    // [_finalizeUtteranceEndDeterministicTriggers] instead, once the
    // technician has actually finished the utterance — see that method's
    // own doc comment.
    _accumulateDeterministicBuffer(_deterministicTriggers['get_kb_answer']!, textChunk);
    _accumulateDeterministicBuffer(_deterministicTriggers['site_condition']!, textChunk);
    if (arrivedAfterUtteranceEnd) {
      _pipelineLog('late_transcript', 'arrived after utterance end — end-of-utterance routing will re-run on it');
      _scheduleLateTranscriptFinalize();
    }

    // PART F items 4-5 / PART I item 1: checked LAST, after every known-
    // command trigger above has already had its synchronous chance to
    // match THIS chunk — the actual mute already happened unconditionally
    // at the top of this method (see [_muteImmediatelyOnFirstChunkOfUtterance]);
    // this only arms the last-resort safety timeout if nothing resolved.
    _maybeArmPreemptiveMuteSafetyTimeout();
  }

  /// Every per-chunk trigger evaluator, keyed by the trigger/function name it
  /// fires, in the fixed priority order [_onInputTranscription] runs them in
  /// (the first to commit wins the utterance). Keyed so
  /// [_maybeResolveByIntent] can run exactly one named trigger — with all of
  /// its own guards, args and replies — once the fuzzy intent layer has
  /// picked it.
  Map<String, void Function()> _buildTriggerEvaluators(String textChunk) {
    return <String, void Function()>{
      // FIRST, ahead of go_back and get_job_details: an utterance that names
      // Job Details as its destination ("take me back to the job screen")
      // must never be absorbed by go_back's "take me back" (one screen back)
      // or get_job_details' "job details" (read the summary). See
      // `navigation_destination.dart`.
      'view_job_details': () => _maybeTriggerJobDetailsDestination(textChunk),
      // PART D items 1-2: checked FIRST — a plain greeting/presence-check
      // ("can you hear me", "hello") resolves instantly via its own canned
      // response, same as it always has.
      'acknowledge_presence': () => _maybeTriggerAcknowledgePresence(textChunk),
      'view_estimate': () => _maybeTriggerViewEstimate(textChunk),
      'get_job_details': () => _maybeTriggerGetJobDetails(textChunk),
      'go_back': () => _maybeDetectIntentionalGoBack(textChunk),
      'photo_decision': () => _maybeDetectPhotoDecision(textChunk),

      // CONFIRMED via a full real session: Gemini called zero functions
      // natively — every one of these gets the same deterministic backstop
      // proven above for get_job_details, via the shared [_TranscriptTrigger]
      // machinery (see its own doc comment).
      'view_change_orders': () => _maybeTriggerDeterministic(
        _deterministicTriggers['view_change_orders']!,
        textChunk,
        requireJobId: true,
        buildArgs: (_, jobId) => {'job_id': jobId},
        buildSpokenText: (result) => _defaultDeterministicSpokenText(
          name: 'view_change_orders',
          humanAction: 'see the change orders',
          appAction: 'navigated there and looked them up for you',
          result: result,
        ),
      ),
      'view_invoice': () => _maybeTriggerDeterministic(
        _deterministicTriggers['view_invoice']!,
        textChunk,
        requireJobId: true,
        buildArgs: (_, jobId) => {'job_id': jobId},
        buildSpokenText: (result) => _defaultDeterministicSpokenText(
          name: 'view_invoice',
          humanAction: 'see the invoice',
          appAction: 'navigated there and looked it up for you',
          result: result,
        ),
      ),
      'view_job_history': () => _maybeTriggerDeterministic(
        _deterministicTriggers['view_job_history']!,
        textChunk,
        requireJobId: true,
        buildArgs: (_, jobId) => {'job_id': jobId},
        buildSpokenText: (result) => _defaultDeterministicSpokenText(
          name: 'view_job_history',
          humanAction: 'see the job history',
          appAction: 'navigated there and looked it up for you',
          result: result,
        ),
      ),
      'get_job_timeline_answer': () => _maybeTriggerDeterministic(
        _deterministicTriggers['get_job_timeline_answer']!,
        textChunk,
        requireJobId: true,
        buildArgs: (transcript, jobId) => {'job_id': jobId, 'query_hint': transcript},
        buildSpokenText: (result) => _defaultDeterministicSpokenText(
          name: 'get_job_timeline_answer',
          humanAction: "ask about this job's timeline",
          appAction: 'looked up the real logged events for you',
          result: result,
        ),
      ),
      // Guarded to skip while a camera/photo flow is already active (open
      // again mid-flow would be a confusing no-op/duplicate-open at best).
      'open_camera': () => _maybeTriggerDeterministic(
        _deterministicTriggers['open_camera']!,
        textChunk,
        requireJobId: true,
        guard: () => _screenTask == _ScreenTask.none,
        buildArgs: (_, jobId) => {'job_id': jobId},
        buildSpokenText: (result) => _defaultDeterministicSpokenText(
          name: 'open_camera',
          humanAction: 'take a photo',
          appAction: 'opened the camera for you',
          result: result,
        ),
        // PART N item 1 — see [_maybeTriggerDeterministic]'s `onGuardFailed`
        // doc comment: restating "take a photo"/"let's take a photo" while
        // the camera is already open must get this explicit clarification,
        // not silence a different trigger could wrongly fill in behind.
        onGuardFailed: () {
          // While a captured photo awaits keep/retake, an open-camera-style
          // phrase ("Daughters or take a photo?" in the log) is a decision
          // attempt, not a request to shoot: if the photo-decision trigger
          // already resolved it this chunk, stay silent; otherwise re-ask the
          // pending question instead of the live-preview "say ready" line.
          if (_screenTask == _ScreenTask.cameraCaptured) {
            // An already-kept photo on screen during the note question —
            // nothing is waiting for keep/retake; the note flow owns replies.
            if (_keptPhotoPreviewFile != null) {
              _log_('OPEN_CAMERA GUARD: kept photo showing during the note question — no keep/retake re-ask');
              return;
            }
            if (_photoDecisionResolvedForCurrentUtterance) {
              _log_('OPEN_CAMERA GUARD: photo decision already handled this utterance — no reply');
              return;
            }
            _log_('OPEN_CAMERA REPEAT WHILE PHOTO PENDING: re-asking keep/retake, no action taken');
            _informGeminiToSpeakVerbatim(
              "You've got a photo waiting — do you want to keep it, or retake it?",
              reason: 'open_camera_guard_failed_photo_pending',
            );
            return;
          }
          // P0 FIX — never claim "already open" before the real open has
        // completed (see the open_camera entry in
        // `photoCompletionClaimPhrases`).
        if (_screenTask == _ScreenTask.cameraClosing) {
          _log_('OPEN_CAMERA WHILE CLOSING: acknowledging, no action taken — the camera is still being released.');
          _informGeminiToSpeakVerbatim(
            "The camera's just closing — give it a second, then ask again.",
            reason: 'open_camera_guard_failed_closing',
          );
          return;
        }
        if (_screenTask == _ScreenTask.cameraOpening || !_cameraOpenConfirmed) {
          _log_('OPEN_CAMERA REPEAT WHILE OPENING: acknowledging, no action taken — open still in progress.');
          _informGeminiToSpeakVerbatim(
            "The camera's still opening — give it a moment.",
            reason: 'open_camera_guard_failed_still_opening',
          );
          return;
        }
        // ISSUE 1 item 3: a distinct, greppable log line for exactly this
          // path — separate from the generic "DETERMINISTIC SKIP"/
          // "DETERMINISTIC INTERRUPT" lines [_maybeTriggerDeterministic]/
          // [_informGeminiToSpeakVerbatim] already print — so the next real
          // log makes it unambiguous that a repeated open-camera-style phrase
          // while already open was acknowledged and NOT allowed to fall
          // through to any other trigger (in particular capture_photo).
          _log_(
            'OPEN_CAMERA REPEAT WHILE OPEN: acknowledging, no action taken — camera is already open, telling the '
            'technician to say \'ready\' or \'capture it\' instead of silently falling through to another trigger.',
          );
          _informGeminiToSpeakVerbatim(
            "The camera's already open — say 'ready' or 'capture it' when you want the photo.",
            reason: 'open_camera_guard_failed_already_open',
          );
        },
      ),
      // FIX 2: capture_photo's own backstop, mirroring open_camera's exactly —
      // guarded to ONLY arm while the live camera preview is genuinely showing
      // ([_ScreenTask.cameraLive], set by a successful open_camera/retake_photo
      // — see [_updateScreenTaskForToolCall]), so "ready"/"go ahead" can never
      // misfire at any other point in the conversation.
      //
      // P2: [_screenTask] can now reach `cameraLive` EARLY, off the preview
      // texture rather than off `open_camera` returning success (see
      // [_ScreenTask.cameraOpening]) — which is the whole point, but would
      // have quietly widened this guard from "the camera is open" to "a
      // preview is showing". [_cameraOpenConfirmed] keeps the ACTION gated on
      // full initialization while the VIEW runs ahead of it.
      'capture_photo': () => _maybeTriggerDeterministic(
        _deterministicTriggers['capture_photo']!,
        textChunk,
        requireJobId: true,
        guard: () => _screenTask == _ScreenTask.cameraLive && _cameraOpenConfirmed,
        buildArgs: (_, jobId) => {'job_id': jobId},
        buildSpokenText: (result) => _defaultDeterministicSpokenText(
          name: 'capture_photo',
          humanAction: 'capture the photo',
          appAction: 'took the photo for you',
          result: result,
        ),
      ),
      'get_last_photo': () => _maybeTriggerDeterministic(
        _deterministicTriggers['get_last_photo']!,
        textChunk,
        requireJobId: true,
        buildArgs: (_, jobId) => {'job_id': jobId},
        buildSpokenText: (result) => _defaultDeterministicSpokenText(
          name: 'get_last_photo',
          humanAction: 'see the last photo',
          appAction: (result['found'] as bool? ?? false)
              ? 'opened it for you'
              : 'checked, but no photos have been taken on this job yet',
          result: result,
        ),
      ),
      // get_current_screen bypasses dispatchGeminiFunctionCall entirely (see
      // [_describeCurrentScreen]), so it gets its own small hand-rolled
      // detector rather than going through [_maybeTriggerDeterministic] —
      // same reasoning as get_job_details predating the shared engine.
      'get_current_screen': () => _maybeTriggerGetCurrentScreen(textChunk),
      // PART A item 3: meta/capability questions ("what can you do") answer
      // from a FIXED, hardcoded description, never dispatchGeminiFunctionCall
      // — same hand-rolled reasoning as get_current_screen just above, not the
      // shared [_TranscriptTrigger] engine (which sends the DISPATCHER's real
      // result to Gemini to speak, not a canned string).
      'meta_capability': () => _maybeTriggerMetaCapability(textChunk),
    };
  }

  /// Appends [textChunk] to [trigger]'s buffer without matching/firing —
  /// see the "NOT fired here" comment in [_onInputTranscription] for why
  /// get_kb_answer/site_condition need this instead of going straight
  /// through [_maybeTriggerDeterministic] like every other trigger.
  void _accumulateDeterministicBuffer(_TranscriptTrigger trigger, String textChunk) {
    if (trigger.resolvedForCurrentUtterance) return;
    trigger.buffer = '${trigger.buffer} $textChunk'.trim();
  }

  /// Called once the technician has actually stopped talking (the silence
  /// debounce in [_trackSpeechLevel] firing, same "utterance genuinely over"
  /// signal already used for the latency stopwatch) — matches/fires
  /// get_kb_answer/site_condition against their now-FINAL buffer. Passing
  /// `''` as the chunk into [_maybeTriggerDeterministic] here is
  /// deliberate: the buffer was already fully accumulated by
  /// [_accumulateDeterministicBuffer] on every chunk, so this only needs to
  /// run the match/debounce/dispatch step, not append anything further.
  void _finalizeUtteranceEndDeterministicTriggers() {
    // ISSUE 1(a) — see [_utteranceEndDetectedAt]'s doc comment.
    _utteranceEndDetectedAt = DateTime.now();
    _pipelineLog(
      'utterance_end',
      'final text="${_deterministicTriggers['get_kb_answer']!.buffer.trim()}" ($_utteranceStateSummary)',
    );
    _maybeScheduleGreetingReplay(_deterministicTriggers['get_kb_answer']!.buffer);
    // awaitingPhotoDescription owns this utterance: none of the routing
    // below (KB, site_condition, intent layer, catch-all — the last of which
    // would also silently lift the preemptive mute) applies to a photo note.
    if (_photoNote != null && _photoNoteOwnsCurrentUtterance) {
      _finalizedCurrentUtterance = true;
      _onPhotoNoteUtteranceEnd();
      return;
    }
    // QUESTION ANNOUNCEMENT — before the KB, the intent layer and the
    // camera-intent check: "I have a question" is never a KB query or a
    // camera command, so it neither waits on nor reaches any of them.
    final heardSoFar = _deterministicTriggers['get_kb_answer']!.buffer.trim();
    if (heardSoFar.isNotEmpty) _consumeQuestionAnnouncement();
    if (_maybeHandleQuestionAnnouncement(heardSoFar)) {
      _finalizedCurrentUtterance = true;
      return;
    }
    _maybeTriggerDeterministic(
      _deterministicTriggers['get_kb_answer']!,
      '',
      requireJobId: false,
      // See [_otherSpecificTriggerAlreadyResolvedThisUtterance]'s doc
      // comment — the broadened [_looksLikeQuestionOpener]/
      // [_looksLikeQuestionByPunctuation] matchers (PART 3) make this
      // trigger match almost any question, so it steps aside whenever a
      // more specific trigger already owns this utterance instead of
      // double-answering (or wrongly declining a job-specific question the
      // KB was never going to have).
      // KB GATE last, so it only logs once the phrase matched and nothing
      // else owns the utterance. Blocked here, the utterance carries on to
      // the intent layer and the catch-all below, which asks for
      // clarification instead.
      guard: () =>
          !_otherSpecificTriggerAlreadyResolvedThisUtterance &&
          !_guardFailedReplySpokenThisUtterance &&
          _kbGateAllows('early_match'),
      buildArgs: (transcript, jobId) => {
        'question': transcript,
        'job_id': ?jobId,
      },
      // PART F: Gemini speaks the already-vetted `answer` field verbatim,
      // via the same constrained [_informGeminiToSpeakVerbatim] instruction
      // as every other canned response — "never paraphrase" enforced by
      // that tight framing, not a looser "word for word" request.
      buildSpokenText: _buildKbAnswerSpokenText,
    );
    // `note` is the verbatim matched transcript, same "never paraphrase"
    // rule the tool declaration itself states for a genuine Gemini call.
    _maybeTriggerDeterministic(
      _deterministicTriggers['site_condition']!,
      '',
      requireJobId: true,
      buildArgs: (transcript, jobId) => {'job_id': jobId, 'note': transcript},
      buildSpokenText: (result) => _defaultDeterministicSpokenText(
        name: 'site_condition',
        humanAction: 'log a note about the site',
        appAction: 'saved the note for you',
        result: result,
      ),
    );
    // Task A: the keyword/similarity layer gets the utterance only if
    // nothing above claimed it. When it answers (fires, asks which, or gives
    // the options reply) it sets the same flags every other resolution does,
    // so the catch-all below sees them and stands down on its own.
    _maybeResolveByIntent();
    // PART F item 4: by this point every per-chunk AND end-of-utterance
    // trigger above has already had its synchronous chance to match, so
    // this sees the final, settled state of every trigger's
    // resolvedForCurrentUtterance flag.
    _maybeFallBackToKbAnswerCatchAll();

    // Nothing heard yet for speech Gemini did receive: its transcript is
    // most likely still on the way — show that instead of nothing.
    _finalizedCurrentUtterance = true;
    final heard = _deterministicTriggers['get_kb_answer']!.buffer.trim();
    if (heard.isEmpty &&
        _speechBurstReachedGemini &&
        !_anyTriggerCommittedThisUtterance &&
        !_guardFailedReplySpokenThisUtterance) {
      _startAwaitingLateTranscript();
    }
  }

  /// Set only while [_maybeResolveByIntent] runs its one chosen evaluator —
  /// lets that trigger past its phrase check (see [_maybeTriggerDeterministic]).
  String? _forcedIntentTrigger;

  /// Task B — numbers each utterance (bumped on the same "genuinely new
  /// utterance" edge that resets every trigger buffer, in
  /// [_trackSpeechLevel]) so every VOICE PIPELINE line for one spoken
  /// command can be pulled out of logcat with a single grep.
  int _utteranceSeq = 0;

  /// When the current open_camera was dispatched (voice match or Gemini
  /// toolCall) — the start of the end-to-end camera_preview_live timing.
  DateTime? _openCameraDispatchedAt;

  /// Whether the current speech burst's audio was actually being sent to
  /// Gemini when it started (outgoing mic not paused for playback) — only
  /// then can a transcript for it ever arrive, so only then is it worth
  /// waiting for one. CONFIRMED in a real trace: several "utterances" were
  /// bursts that began while outgoing audio was paused (the speaker's own
  /// echo), and never got a transcript.
  bool _speechBurstReachedGemini = false;

  /// True once [_finalizeUtteranceEndDeterministicTriggers] has run for the
  /// current utterance — reset on each genuinely new utterance. A transcript
  /// arriving while this is true (and the technician is silent) arrived
  /// LATE, after the end-of-utterance routing already ran on an empty
  /// buffer; see [_scheduleLateTranscriptFinalize].
  bool _finalizedCurrentUtterance = false;

  /// Speech ended, it reached Gemini, and no transcript has arrived yet.
  /// Gemini's input transcription routinely lands ~1-2s after the app's own
  /// silence detection, and CONFIRMED once 17.5s after (with live mic audio
  /// flowing the whole time — server-side, not app-side, latency). While
  /// true the UI shows "Thinking..." (see [_applyVoicePhase]).
  bool _awaitingLateTranscript = false;
  Timer? _lateTranscriptTimeout;
  Timer? _lateTranscriptFinalizeTimer;

  /// Longest the app shows "Thinking..." for a transcript that hasn't come,
  /// before asking the technician to try again. A transcript that still
  /// arrives after this is handled normally, not ignored.
  static const Duration _lateTranscriptMaxWait = Duration(seconds: 8);

  /// How long a late transcript must be quiet (no further chunks) before
  /// end-of-utterance routing re-runs on it.
  static const Duration _lateTranscriptSettle = Duration(milliseconds: 700);

  // --- Transcript-wait diagnostics (measurement only) -------------------
  //
  // acbd952c (tablet) log: three utterances got NO transcript for the full
  // 8s while healthy audio kept streaming and other utterances in the same
  // session transcribed in <20ms. The capture path is identical on every
  // device (pcm16 / 16kHz / mono / voice_communication, no per-device
  // branch), so the open question is what the SERVER did with that audio.
  // These lines answer it: a STALL check partway through and a full snapshot
  // at the timeout — what was sent, what the server sent back (any model
  // output? an `interrupted`? any message at all?), and the last
  // clientContent we sent, so a stall can be correlated with it.

  int _diagChunksSent = 0;
  int _diagChunksHeld = 0;
  int _diagBytesSent = 0;
  double _diagRmsSum = 0;
  int _diagLastChunkBytes = 0;
  DateTime? _diagLastServerMessageAt;
  DateTime? _diagLastModelOutputAt;
  DateTime? _diagLastServerInterruptedAt;
  DateTime? _diagLastTurnCompleteAt;
  DateTime? _diagLastInputTranscriptionAt;
  DateTime? _diagLastClientContentAt;
  String _diagLastClientContentKind = 'none';

  ({DateTime at, int sent, int held, int bytes, double rmsSum})? _transcriptWaitStart;
  Timer? _transcriptStallTimer;
  static const Duration _transcriptStallCheck = Duration(seconds: 4);

  void _noteServerMessageForDiagnostics(Map<String, dynamic> decoded) {
    final now = DateTime.now();
    _diagLastServerMessageAt = now;
    final content = decoded['serverContent'] as Map<String, dynamic>?;
    if (content == null) return;
    if (content['modelTurn'] != null || content['outputTranscription'] != null) _diagLastModelOutputAt = now;
    if (content['interrupted'] == true) _diagLastServerInterruptedAt = now;
    if (content['turnComplete'] == true) _diagLastTurnCompleteAt = now;
    if (content['inputTranscription'] != null) _diagLastInputTranscriptionAt = now;
  }

  void _noteClientContentSent(String kind) {
    _diagLastClientContentAt = DateTime.now();
    _diagLastClientContentKind = kind;
  }

  String _transcriptWaitDiagnostics() {
    final now = DateTime.now();
    final start = _transcriptWaitStart;
    String ago(DateTime? t) => t == null ? 'never' : '${now.difference(t).inMilliseconds}ms ago';
    String sinceWait(DateTime? t) =>
        t == null || start == null ? 'no' : (t.isAfter(start.at) ? 'YES (${now.difference(t).inMilliseconds}ms ago)' : 'no');
    final sent = start == null ? 0 : _diagChunksSent - start.sent;
    final held = start == null ? 0 : _diagChunksHeld - start.held;
    final bytes = start == null ? 0 : _diagBytesSent - start.bytes;
    final avgRms = sent == 0 || start == null ? 0 : (_diagRmsSum - start.rmsSum) / sent;
    return 'audio format: pcm16 ${_inputSampleRateHz}Hz mono, audioSource=voice_communication, sent as '
        'audio/pcm;rate=$_inputSampleRateHz, last chunk ${_diagLastChunkBytes}B (~${_pcmBytesToMs(_diagLastChunkBytes)}ms), '
        'no format conversion; since speech end: $sent chunk(s) / ${_pcmBytesToMs(bytes)}ms sent (avg RMS '
        '${avgRms.toStringAsFixed(0)}), $held held (outgoing paused), outgoingPausedNow=$_outgoingAudioPaused; '
        'server since speech end: model output=${sinceWait(_diagLastModelOutputAt)}, '
        'interrupted=${sinceWait(_diagLastServerInterruptedAt)}, turnComplete=${sinceWait(_diagLastTurnCompleteAt)}, '
        'any message ${ago(_diagLastServerMessageAt)}; last transcript ${ago(_diagLastInputTranscriptionAt)}; '
        'last clientContent we sent: $_diagLastClientContentKind ${ago(_diagLastClientContentAt)}; '
        'socket=${_channel == null ? 'closed' : 'open'}, device OS: ${Platform.operatingSystemVersion}';
  }

  void _startAwaitingLateTranscript() {
    if (_awaitingLateTranscript) return; // keep the first deadline for this utterance
    _awaitingLateTranscript = true;
    _transcriptWaitStart = (
      at: DateTime.now(),
      sent: _diagChunksSent,
      held: _diagChunksHeld,
      bytes: _diagBytesSent,
      rmsSum: _diagRmsSum,
    );
    _transcriptStallTimer?.cancel();
    _transcriptStallTimer = Timer(_transcriptStallCheck, () {
      _transcriptStallTimer = null;
      if (!_awaitingLateTranscript) return;
      _log_('TRANSCRIPT STALL: ${_transcriptStallCheck.inMilliseconds}ms with no transcript — ${_transcriptWaitDiagnostics()}');
    });
    _pipelineLog(
      'awaiting_transcript',
      'speech ended and reached Gemini, but no transcript yet — showing "Thinking..." for up to '
          '${_lateTranscriptMaxWait.inSeconds}s',
    );
    _syncVoicePhase();
    _lateTranscriptTimeout?.cancel();
    _lateTranscriptTimeout = Timer(_lateTranscriptMaxWait, () {
      if (!_awaitingLateTranscript) return;
      _log_(
        'TRANSCRIPT TIMEOUT DIAGNOSTICS: no transcript within ${_lateTranscriptMaxWait.inSeconds}s — '
        '${_transcriptWaitDiagnostics()}',
      );
      _stopAwaitingLateTranscript('no transcript within ${_lateTranscriptMaxWait.inSeconds}s');
      if (_anyTriggerCommittedThisUtterance || _guardFailedReplySpokenThisUtterance || _inFlightFunctionCalls > 0) {
        return;
      }
      _pipelineLog(
        'transcript_timeout',
        'asking the technician to try again — if the transcript still arrives later it is handled normally',
      );
      _respondToUnclearInput(reason: 'transcript_never_arrived');
    });
  }

  void _stopAwaitingLateTranscript(String reason) {
    _lateTranscriptTimeout?.cancel();
    _lateTranscriptTimeout = null;
    _transcriptStallTimer?.cancel();
    _transcriptStallTimer = null;
    if (!_awaitingLateTranscript) return;
    _awaitingLateTranscript = false;
    _pipelineLog('awaiting_transcript_done', reason);
    _syncVoicePhase();
  }

  /// A transcript that arrived after this utterance's end-of-utterance
  /// routing already ran (on an empty buffer): per-chunk commands have
  /// already had their chance on it, but the knowledge-base question,
  /// site-condition note and fuzzy-intent steps only run at utterance end,
  /// so without this a late question would never be routed at all. Re-runs
  /// that routing once the late transcript stops growing. Harmless if a
  /// per-chunk trigger already handled it — every step there checks the
  /// same "already resolved" flags and stands down.
  void _scheduleLateTranscriptFinalize() {
    _lateTranscriptFinalizeTimer?.cancel();
    _lateTranscriptFinalizeTimer = Timer(_lateTranscriptSettle, () {
      _lateTranscriptFinalizeTimer = null;
      if (!mounted || _isSpeaking) return; // still talking — the natural silence edge will finalize it
      _pipelineLog('late_transcript_finalize', 're-running end-of-utterance routing on the late transcript');
      _finalizeUtteranceEndDeterministicTriggers();
    });
  }

  /// Task B — one line per step of transcript -> matcher -> dispatch ->
  /// result -> UI/reply, in a fixed `VOICE PIPELINE [u=N] stage: detail`
  /// shape, so a "correct transcript, no action" reproduction shows exactly
  /// which step was the last to fire. debugPrint only (no setState), since
  /// several of these run per transcript chunk.
  int? _lastPromptTokenCount;
  int _contextMeasuredTurns = 0;
  DateTime? _contextFirstMeasuredAt;

  /// CONTEXT REFRESH (measurement only) — one line per `usageMetadata`:
  /// how big the session context Gemini re-reads each turn is, against the
  /// server-side sliding window ([_contextCompressionTriggerTokens]). A
  /// drop of a quarter or more from the previous turn is the server
  /// compressing (`action=server_compression`); otherwise `action=none`.
  /// Paired with the LATENCY BREAKDOWN lines, this shows from a long-session
  /// log whether latency actually tracks context size.
  void _logContextSize(int promptTokens) {
    final now = DateTime.now();
    _contextFirstMeasuredAt ??= now;
    _contextMeasuredTurns++;
    final previous = _lastPromptTokenCount;
    _lastPromptTokenCount = promptTokens;
    final compressed = previous != null && promptTokens < previous * 0.75;
    _logNoState(
      'CONTEXT REFRESH: promptTokenCount=$promptTokens threshold=$_contextCompressionTriggerTokens '
      'action=${compressed ? 'server_compression (was $previous)' : 'none'} turn=$_contextMeasuredTurns '
      'sessionMinutes=${(now.difference(_contextFirstMeasuredAt!).inSeconds / 60).toStringAsFixed(1)}',
    );
  }

  void _pipelineLog(String stage, String detail) => _logNoState('VOICE PIPELINE [u=$_utteranceSeq] $stage: $detail');

  /// Which triggers have claimed the current utterance (fired, debounced,
  /// or skipped after matching) — the state that decides whether anything
  /// else may still act on it.
  List<String> get _resolvedTriggerNamesThisUtterance => [
    if (_acknowledgePresenceResolvedForCurrentUtterance) 'acknowledge_presence',
    if (_viewEstimateDetectionResolvedForCurrentUtterance) 'view_estimate',
    if (_getJobDetailsDetectionResolvedForCurrentUtterance) 'get_job_details',
    if (_goBackTriggerResolvedForCurrentUtterance) 'go_back',
    if (_photoDecisionResolvedForCurrentUtterance) 'photo_decision',
    if (_getCurrentScreenDetectionResolvedForCurrentUtterance) 'get_current_screen',
    if (_metaCapabilityDetectionResolvedForCurrentUtterance) 'meta_capability',
    for (final trigger in _deterministicTriggers.values)
      if (trigger.resolvedForCurrentUtterance) trigger.name,
  ];

  String get _utteranceStateSummary =>
      'resolved=[${_resolvedTriggerNamesThisUtterance.join(', ')}] '
      'alreadyResolvedBySuccess=$_utteranceAlreadyResolvedByTrigger screenTask=${_screenTask.name} '
      'cameraOpenConfirmed=$_cameraOpenConfirmed inFlightCalls=$_inFlightFunctionCalls';

  /// The voice command registry at dispatch time. Gemini-session dispatch
  /// never reads it, but its "RAPID SWAP" warning is the suspected link, so
  /// its contents and the age of its last change are captured anyway, to
  /// confirm or rule that out from a real log.
  String _registrySnapshot() {
    final registry = ref.read(voiceCommandRegistryProvider);
    final lastChangeAt = ref.read(voiceCommandRegistryProvider.notifier).lastChangeAt;
    final sinceChange = lastChangeAt == null ? null : DateTime.now().difference(lastChangeAt).inMilliseconds;
    final swapNote = sinceChange != null && sinceChange < 2000 ? ' *** registry changed <2s ago ***' : '';
    return 'registry=[${registry.keys.join(', ')}] '
        'lastRegistryChange=${sinceChange == null ? 'never' : '${sinceChange}ms ago'}$swapNote';
  }

  /// Wraps each of the six dispatch call sites (unchanged calls, just
  /// bracketed) with dispatch_start / dispatch_result / dispatch_error and
  /// a ui_settled line on the next frame, so a command that was matched
  /// but never visibly acted on shows whether the handler ran, what it
  /// returned, and whether it threw.
  Future<Map<String, dynamic>> _pipelineDispatch({
    required String name,
    required String source,
    required Future<Map<String, dynamic>> Function() call,
  }) async {
    final startedAt = DateTime.now();
    if (name == 'open_camera') _openCameraDispatchedAt = startedAt;
    _pipelineLog('dispatch_start','function=$name source=$source mounted=$mounted $_utteranceStateSummary; ${_registrySnapshot()}');
    try {
      final result = await call();
      final ms = DateTime.now().difference(startedAt).inMilliseconds;
      _pipelineLog(
        'dispatch_result',
        'function=$name after ${ms}ms status=${result['status'] ?? '-'}'
            '${result.containsKey('error') ? ' ERROR=${result['error']}' : ''} keys=[${result.keys.join(', ')}]',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pipelineLog('ui_settled', 'function=$name mounted=$mounted screenTask=${_screenTask.name}');
      });
      return result;
    } catch (e) {
      final ms = DateTime.now().difference(startedAt).inMilliseconds;
      _pipelineLog('dispatch_error', 'function=$name after ${ms}ms threw ${_scrubCredentials(e)}');
      rethrow;
    }
  }

  /// Task A — runs `command_intent_matcher.dart` over a FINISHED utterance
  /// that no existing trigger matched (a paraphrase like "grab a shot of
  /// that", or a truncated transcript like "foto"), before it would fall
  /// through to the knowledge-base catch-all:
  ///  - confident: fires that one trigger through its own evaluator, so its
  ///    guard/debounce/dispatch/reply are exactly what a phrase match gets;
  ///  - ambiguous: asks "did you mean A, or B?" instead of guessing;
  ///  - weak: the existing "not sure what you need" options reply;
  ///  - none: does nothing — the catch-all handles it exactly as before.
  void _maybeResolveByIntent() {
    if (_anyTriggerCommittedThisUtterance || _guardFailedReplySpokenThisUtterance) return;
    final kbTrigger = _deterministicTriggers['get_kb_answer']!;
    if (kbTrigger.resolvedForCurrentUtterance || _deterministicTriggers['site_condition']!.resolvedForCurrentUtterance) {
      return;
    }
    final transcript = kbTrigger.buffer.trim();
    if (transcript.isEmpty) return;
    // Routing re-run for this same utterance (a late transcript) while its
    // Gemini intent check is still out — that check decides.
    if (_geminiIntentCheck != null && _geminiIntentCheck!.utteranceSeq == _utteranceSeq) return;
    // "Yes" to an earlier "Did you mean ...?" — see [_pendingReconfirm].
    if (_maybeAnswerPendingReconfirm(transcript)) return;
    // "Yes, take another one" to Gemini's own "want one more?" — see
    // `continuation_answer.dart`.
    if (_maybeAnswerPhotoOffer(transcript)) return;

    final decision = classifyCommandIntent(transcript);
    _log_(decision.describe(transcript));
    _pipelineLog('intent_layer', '${decision.kind.name}${decision.best == null ? '' : ' best=${decision.best!.trigger}'}');

    // Live camera only: a bare photo noun ("Tika shot" — ASR's "take a
    // shot") is FUZZY WEAK in general, but with the preview up and armed the
    // context makes it a shutter command — see [liveCameraShotNoun]. Never
    // applied in any other state (the camera not open, a photo awaiting
    // keep/retake, the note question), and never over a confident match to
    // something other than the camera.
    final otherConfidentTrigger = decision.kind == IntentDecisionKind.confident && decision.best!.trigger != 'open_camera';
    final liveNoun = _screenTask == _ScreenTask.cameraLive && _cameraOpenConfirmed && !otherConfidentTrigger
        ? liveCameraShotNoun(transcript)
        : null;
    if (liveNoun != null) {
      _log_(
        'FUZZY LIVE-CAMERA MATCH: "$liveNoun" in "$transcript" with the camera live and armed — firing capture_photo '
        '(${decision.kind.name} in the general matcher)',
      );
      _pipelineLog('intent_layer', 'live_camera_capture noun=$liveNoun');
      _forcedIntentTrigger = 'capture_photo';
      try {
        _buildTriggerEvaluators('')['capture_photo']!();
      } finally {
        _forcedIntentTrigger = null;
      }
      if (_anyTriggerCommittedThisUtterance) return;
      // Guard/debounce said no after all — the normal handling below
      // (including the context-aware "I didn't catch that" reply) applies.
    }

    // The utterance right after "I have a question" IS the question: no
    // camera-intent check or "not sure what you need" reply — straight on to
    // the catch-all's normal KB routing (KB GATE unchanged). A confident
    // command still wins above.
    if (_expectingQuestionThisUtterance &&
        (decision.kind == IntentDecisionKind.none || decision.kind == IntentDecisionKind.weak)) {
      _log_('QUESTION ANNOUNCEMENT: "$transcript" is the announced question — skipping the camera-intent check');
      _pipelineLog('question_announcement', 'follow-up routed to the KB flow');
      return;
    }

    // GEMINI INTENT CHECK — the matcher found nothing confident (NO MATCH
    // or FUZZY WEAK) where a photo action would make sense: ask Gemini
    // itself before treating this as unclear. Its result re-enters the
    // weak / catch-all handling below if it says "none".
    if ((decision.kind == IntentDecisionKind.none || decision.kind == IntentDecisionKind.weak) &&
        _maybeStartGeminiIntentCheck(transcript, decision)) {
      return;
    }

    switch (decision.kind) {
      case IntentDecisionKind.none:
        return;
      case IntentDecisionKind.confident:
        final name = decision.best!.trigger;
        _fireIntentTrigger(name, logLabel: 'FUZZY MATCH');
      case IntentDecisionKind.ambiguous:
        _guardFailedReplySpokenThisUtterance = true;
        _informGeminiToSpeakVerbatim(
          'Did you mean ${decision.best!.intent.label}, or ${decision.runnerUp!.intent.label}?',
          reason: 'intent_ambiguous',
        );
      case IntentDecisionKind.weak:
        _respondToWeakIntentMatch(transcript, decision);
    }
  }

  // ---------------------------------------------------------------------
  // CONTINUATION ANSWERS — a yes/no reply to the photo offer the technician
  // just heard (see `continuation_answer.dart`). Runs where the fuzzy layer
  // does: only for a finished utterance no phrase trigger matched.
  // ---------------------------------------------------------------------

  /// How recently the offer must have been heard for a bare "yes"/"no" to
  /// count as answering it.
  static const Duration _photoOfferAnswerWindow = Duration(seconds: 20);

  static const String _photoOfferDeclinedText = 'Okay — what would you like to do?';

  /// The last turn the technician actually HEARD (audible text only — a
  /// muted reply never counts) within [_photoOfferAnswerWindow], or null.
  ({String text, DateTime at})? _recentlyHeardModelTurn() {
    if (_recentAudibleTurns.isEmpty) return null;
    final last = _recentAudibleTurns.last;
    if (DateTime.now().difference(last.at) > _photoOfferAnswerWindow) return null;
    return last;
  }

  bool _maybeAnswerPhotoOffer(String transcript) {
    final heard = _recentlyHeardModelTurn();
    if (heard == null || !looksLikePhotoOfferQuestion(heard.text)) return false;
    final answer = classifyContinuationAnswer(transcript);
    if (answer == ContinuationAnswer.none) return false;

    if (answer == ContinuationAnswer.negative) {
      _log_('NEGATIVE CONTINUATION MATCHED: heard="$transcript" declines the offer "${heard.text}" — acknowledging, no photo');
      _pipelineLog('continuation', 'negative -> declined photo offer');
      _guardFailedReplySpokenThisUtterance = true;
      _informGeminiToSpeakVerbatim(_photoOfferDeclinedText, reason: 'photo_offer_declined');
      return true;
    }

    // Which step "yes" means depends on where the camera is right now. A
    // captured photo awaiting keep/retake has its own decision flow.
    final trigger = (_screenTask == _ScreenTask.cameraLive && _cameraOpenConfirmed)
        ? 'capture_photo'
        : (_screenTask == _ScreenTask.none ? 'open_camera' : null);
    if (trigger == null) {
      _log_(
        'AFFIRMATIVE CONTINUATION: heard="$transcript" answers the offer "${heard.text}" but the camera is mid-step '
        '(${_screenTask.name}) — leaving it to normal routing',
      );
      return false;
    }
    _log_('AFFIRMATIVE CONTINUATION MATCHED: heard="$transcript" answers the offer "${heard.text}" -> $trigger');
    _pipelineLog('continuation', 'affirmative -> $trigger');
    if (_fireIntentTrigger(trigger, logLabel: 'AFFIRMATIVE CONTINUATION') || _guardFailedReplySpokenThisUtterance) {
      return true;
    }
    _log_('AFFIRMATIVE CONTINUATION: $trigger did not fire (guard/debounce) — falling back to normal routing');
    return false;
  }

  // ---------------------------------------------------------------------
  // QUESTION ANNOUNCEMENT — see `question_announcement.dart`. Job Detail
  // only, since it's the only screen whose unmatched speech reaches the KB
  // (KB GATE); elsewhere the utterance is routed exactly as before.
  // ---------------------------------------------------------------------

  /// When "I have a question" was answered, and in which utterance — the
  /// NEXT utterance (within [_questionAnnouncementWindow]) is the question.
  ({int utteranceSeq, DateTime at})? _questionAnnouncement;
  static const Duration _questionAnnouncementWindow = Duration(seconds: 20);

  /// The utterance that follows an announcement (kept across a late-
  /// transcript re-run of that same utterance's routing).
  int? _expectingQuestionForSeq;
  bool get _expectingQuestionThisUtterance => _expectingQuestionForSeq == _utteranceSeq;

  static const List<String> _questionAnnouncementReplies = [
    "Sure, what's your question?",
    'Go ahead, what do you want to know?',
    'Sure — what would you like to know?',
  ];
  int _questionAnnouncementReplyCursor = 0;

  /// Moves a pending announcement onto the current (later) utterance.
  void _consumeQuestionAnnouncement() {
    final pending = _questionAnnouncement;
    if (pending == null || pending.utteranceSeq == _utteranceSeq) return;
    _questionAnnouncement = null;
    if (DateTime.now().difference(pending.at) > _questionAnnouncementWindow) return;
    _expectingQuestionForSeq = _utteranceSeq;
  }

  bool _maybeHandleQuestionAnnouncement(String transcript) {
    if (transcript.isEmpty || _anyTriggerCommittedThisUtterance || _guardFailedReplySpokenThisUtterance) return false;
    if (!isQuestionAnnouncement(transcript)) return false;
    if (!_kbGateScreen().kbFallbackEnabled) {
      _log_('QUESTION ANNOUNCEMENT: "$transcript" heard off Job Details — left to the normal routing');
      return false;
    }
    _log_('QUESTION ANNOUNCEMENT DETECTED: heard="$transcript" action=asked_for_question');
    _pipelineLog('question_announcement', 'asked for the question');
    // Same "this utterance has its reply" flag every clarification sets —
    // the KB early match, intent layer and catch-all all stand down on it.
    _guardFailedReplySpokenThisUtterance = true;
    _questionAnnouncement = (utteranceSeq: _utteranceSeq, at: DateTime.now());
    _informGeminiToSpeakVerbatim(
      _questionAnnouncementReplies[_questionAnnouncementReplyCursor++ % _questionAnnouncementReplies.length],
      reason: 'question_announcement',
    );
    return true;
  }

  /// FUZZY WEAK — Job Detail keeps its existing "not sure what you need"
  /// reply; every other screen gets the CLARIFY FALLBACK, reconfirming the
  /// weak best guess ("Did you mean ...?").
  void _respondToWeakIntentMatch(String transcript, IntentDecision decision) {
    _guardFailedReplySpokenThisUtterance = true;
    if (_kbGateScreen().kbFallbackEnabled) {
      _respondToUnclearInput(reason: 'intent_weak_match');
      return;
    }
    _respondWithClarification(transcript: transcript, bestGuess: decision.best, reason: 'intent_weak_match');
  }

  /// Fires trigger [name] through its own evaluator, exactly as a phrase
  /// match would (guard, debounce, dispatch and reply all unchanged) — the
  /// fuzzy layer's confident case, a Gemini intent check's answer, and a
  /// "yes" to a reconfirm question all go through here. Speaks a queued
  /// guard-failed reply (e.g. "the camera's already open") the same way
  /// [_onInputTranscription] does. Returns whether a trigger committed.
  bool _fireIntentTrigger(String name, {required String logLabel}) {
    final evaluate = _buildTriggerEvaluators('')[name];
    if (evaluate == null) {
      _log_('$logLabel: no evaluator registered for "$name" — leaving it to the existing fallback');
      return false;
    }
    _forcedIntentTrigger = name;
    try {
      evaluate();
    } finally {
      _forcedIntentTrigger = null;
    }
    // Same post-loop handling [_onInputTranscription] gives a guard
    // failure (e.g. "the camera's already open").
    final guardFailedReply = _pendingGuardFailedReply;
    _pendingGuardFailedReply = null;
    if (!_anyTriggerCommittedThisUtterance && guardFailedReply != null) {
      _guardFailedReplySpokenThisUtterance = true;
      guardFailedReply();
    }
    return _anyTriggerCommittedThisUtterance;
  }

  // ---------------------------------------------------------------------
  // CLARIFY FALLBACK — replaces the KB catch-all on every screen except Job
  // Detail (see [_kbGateScreen]). Built on [_respondToUnclearInput], so the
  // camera / photo-note context lines and the 1st / 2nd / quiet escalation
  // are the same ones every other unclear input already gets.
  // ---------------------------------------------------------------------

  static const List<String> _clarificationReplies = [
    'Sorry, can you say that again?',
    "I didn't quite catch that — could you repeat it?",
    'Sorry, I missed that. What do you need?',
  ];
  int _clarificationReplyCursor = 0;

  String _nextClarificationReply() =>
      _clarificationReplies[_clarificationReplyCursor++ % _clarificationReplies.length];

  int _reconfirmReplyCursor = 0;

  /// Below this, a fuzzy candidate is too far off to name back to the
  /// technician in a "Did you mean ...?" question.
  static const double _clarifyBestGuessFloor = 0.4;

  /// The fuzzy matcher's best candidate for [transcript], if it is at least
  /// a borderline match — including one a question-shaped utterance kept
  /// below the acting threshold.
  IntentScore? _clarifyBestGuess(String transcript) {
    final decision = classifyCommandIntent(transcript);
    final best = decision.best ?? (decision.scores.isEmpty ? null : decision.scores.first);
    if (best == null || best.confidence < _clarifyBestGuessFloor) return null;
    return best;
  }

  /// A "Did you mean ...?" question that was just asked — a plain "yes"
  /// within [_pendingReconfirmWindow] fires that trigger; anything else
  /// clears it and is routed normally.
  ({String trigger, String label, int utteranceSeq, DateTime askedAt})? _pendingReconfirm;
  static const Duration _pendingReconfirmWindow = Duration(seconds: 15);

  static const Set<String> _reconfirmYesWords = {
    'yes', 'yeah', 'yep', 'yup', 'ya', 'sure', 'correct', 'exactly', 'right', 'affirmative', 'si', 'ok', 'okay',
  };
  static const Set<String> _reconfirmNoWords = {'no', 'nope', 'nah', 'neither', 'cancel', 'wrong'};

  void _respondWithClarification({required String transcript, required IntentScore? bestGuess, required String reason}) {
    _log_(
      'CLARIFY FALLBACK: screen=${_kbGateScreen().screen} heard="$transcript" '
      'bestGuess=${bestGuess?.trigger ?? 'none'} confidence=${bestGuess?.confidence.toStringAsFixed(2) ?? 'none'}',
    );
    _pipelineLog('clarify_fallback', 'bestGuess=${bestGuess?.trigger ?? 'none'} reason=$reason');
    // A captured photo awaiting keep/retake (or the note question) already
    // has its own pending question — naming some other action there would
    // only confuse it, so those keep their context lines.
    final contextAllowsReconfirm = _screenTask != _ScreenTask.cameraCaptured && _photoNote == null;
    String? reconfirmText;
    ({String trigger, String label})? guess;
    if (contextAllowsReconfirm && bestGuess != null) {
      final label = bestGuess.intent.label;
      guess = (trigger: bestGuess.trigger, label: label);
      reconfirmText = (_reconfirmReplyCursor++).isEven ? 'Did you mean $label?' : 'Sorry — did you want to $label?';
    } else if (contextAllowsReconfirm) {
      // A screen named in a statement ("we're still on the invoice screen")
      // that loose-nav matching declined to act on — ask which it was.
      final rejected = _looseNavRejectionFor(transcript);
      if (rejected != null) {
        guess = rejected;
        reconfirmText = 'Do you want me to ${rejected.label}, or are you telling me something else?';
      }
    }
    final reconfirmed = _respondToUnclearInput(reason: reason, clarify: true, reconfirmText: reconfirmText);
    _pendingReconfirm = reconfirmed && guess != null
        ? (trigger: guess.trigger, label: guess.label, utteranceSeq: _utteranceSeq, askedAt: DateTime.now())
        : null;
  }

  /// The trigger/label [lastLooseNavRejection] recorded for THIS transcript
  /// (recent, and the same words), or `null`.
  ({String trigger, String label})? _looseNavRejectionFor(String transcript) {
    final rejection = lastLooseNavRejection;
    if (rejection == null || DateTime.now().difference(rejection.at) > const Duration(seconds: 15)) return null;
    final heard = stemmedPaddedTriggerText(transcript).trim();
    final rejectedText = rejection.paddedText.trim();
    if (heard.isEmpty || !(heard.contains(rejectedText) || rejectedText.contains(heard))) return null;
    final intent = defaultCommandIntents.where((i) => i.trigger == rejection.trigger).firstOrNull;
    if (intent == null) return null;
    return (trigger: intent.trigger, label: intent.label);
  }

  /// See [_pendingReconfirm]. Only a short, whole-utterance yes/no counts,
  /// so "yes, and show me the invoice" is routed normally instead.
  bool _maybeAnswerPendingReconfirm(String transcript) {
    final pending = _pendingReconfirm;
    if (pending == null || pending.utteranceSeq == _utteranceSeq) return false;
    _pendingReconfirm = null;
    if (DateTime.now().difference(pending.askedAt) > _pendingReconfirmWindow) return false;
    final words = tokenizeTriggerText(transcript);
    if (words.isEmpty || words.length > 4) return false;
    final meaningful = words.where((w) => !const {'please', 'do', 'it', 'that', 'go', 'ahead', 'i', 'did'}.contains(w));
    if (meaningful.isEmpty) return false;
    if (meaningful.every(_reconfirmNoWords.contains)) {
      _log_('RECONFIRM: "$transcript" declined "${pending.label}" — asking what they need instead');
      _guardFailedReplySpokenThisUtterance = true;
      _informGeminiToSpeakVerbatim('Okay — what would you like to do?', reason: 'reconfirm_declined');
      return true;
    }
    if (!meaningful.every(_reconfirmYesWords.contains)) return false;
    _log_('RECONFIRM: "$transcript" confirmed "${pending.label}" — firing ${pending.trigger}');
    _pipelineLog('reconfirm', 'confirmed trigger=${pending.trigger}');
    return _fireIntentTrigger(pending.trigger, logLabel: 'RECONFIRM') || _guardFailedReplySpokenThisUtterance;
  }

  // ---------------------------------------------------------------------
  // GEMINI INTENT CHECK — a fallback layer AFTER the deterministic phrase
  // triggers and the fuzzy matcher (both unchanged and still first). When
  // neither is confident and a photo action would make sense right now
  // (live camera armed, or Job Detail with the camera closed), Gemini
  // itself classifies the utterance — any wording, accent, or language
  // (non-native and Spanish-speaking technicians) — through a dedicated
  // function call in the already-open Live session. Its audio is dropped
  // throughout (see [_onResponseAudioChunk]); "none", low confidence or no
  // answer in time falls back to the existing weak / catch-all handling.
  // ---------------------------------------------------------------------

  ({String id, int utteranceSeq, String transcript, IntentDecision decision, DateTime startedAt, Timer timeout})?
  _geminiIntentCheck;
  int _geminiIntentCheckCounter = 0;

  /// Checks retired (superseded or timed out) before Gemini answered them.
  /// With no id in the message any more, answers are matched by order:
  /// while one of these is outstanding, the next answer is its, not the
  /// current check's. Fails safe — a retired check Gemini never answers
  /// costs the next check its answer (it times out into the normal
  /// fallback) and expires after [_retiredIntentCheckAnswerWindow]; it can
  /// never fire a photo action for the wrong utterance.
  final List<DateTime> _retiredUnansweredIntentChecks = [];
  static const Duration _retiredIntentCheckAnswerWindow = Duration(seconds: 6);

  /// Long enough for a Live text turn plus function call; short enough that
  /// a missing answer only delays the fallback slightly. Trimmed from 3.5s
  /// (a7d30b48 log: two unanswered checks each held unclear speech ~3.5s
  /// before the clarification question, on top of 2-5.6s Live latency).
  static const Duration _geminiIntentCheckTimeout = Duration(milliseconds: 1800);

  /// Below this, Gemini's photo classification is treated as "none".
  static const double _geminiIntentMinConfidence = 0.6;

  /// Where the check applies: `capture_photo` with the live camera armed,
  /// `open_camera` on Job Detail with no camera flow active. `null` in
  /// every other state (camera still opening, a photo awaiting keep/
  /// retake, the note question, any other screen).
  String? _geminiIntentCheckContext() {
    if (_photoNote != null || widget.jobId == null) return null;
    if (_screenTask == _ScreenTask.cameraLive && _cameraOpenConfirmed) return 'capture_photo';
    if (_screenTask == _ScreenTask.none && _kbGateScreen().kbFallbackEnabled) return 'open_camera';
    return null;
  }

  bool _maybeStartGeminiIntentCheck(String transcript, IntentDecision decision) {
    final context = _geminiIntentCheckContext();
    if (context == null) return false;
    // Filler and small talk have their own replies in the catch-all.
    if (_looksLikeNonInformationalFiller(transcript) || classifySmallTalk(transcript) != SmallTalkKind.none) {
      return false;
    }
    final channel = _channel;
    if (channel == null || _sessionClosing) return false;
    final previous = _geminiIntentCheck;
    if (previous != null) {
      previous.timeout.cancel();
      _geminiIntentCheck = null;
      _retiredUnansweredIntentChecks.add(DateTime.now());
      _endFunctionCallInFlight('gemini intent check ${previous.id}');
      _log_(
        'GEMINI INTENT CHECK: heard="${previous.transcript}" geminiIntent=none action=discarded_superseded '
        '(check ${previous.id} replaced by a newer utterance)',
      );
    }

    final id = 'ic${++_geminiIntentCheckCounter}';
    final contextLine = context == 'capture_photo'
        ? 'Right now the camera is open with a live preview, ready to shoot: if they want a picture taken, in any '
              'wording, the intent is capture_photo.'
        : 'Right now the camera is not open: if they want to take a picture, in any wording, the intent is '
              'open_camera.';
    final heard = transcript.replaceAll('"', "'");
    // 9948b4d log (u=9): "Yes, take another one." came back `none` — this
    // check only ever saw the transcript, never the question it answered.
    // The last line the technician actually heard (audible only, recent
    // only) is now part of the check, so a yes/no answer can be read as one.
    final previousTurn = _recentlyHeardModelTurn();
    final previousLine = previousTurn == null
        ? ''
        : 'Just before that, the assistant said to them: "${previousTurn.text.replaceAll('"', "'")}". If that was a '
              'question offering a photo, then a yes-type answer ("yes", "yeah", "sure", "go ahead", "yes, take '
              'another one") means they want the photo, and a no-type answer ("no", "I\'m done", "that\'s fine") '
              'means "none". ';
    // 98badd29 log: Gemini SPOKE this message's old opening — "INTENT CHECK"
    // then " ic2", the local check id — instead of calling the function
    // (~690ms of generation before it could be muted). Nothing Gemini can
    // read aloud here carries an internal label or id any more: the check is
    // matched locally (one pending at a time — see [_resolveGeminiIntentCheck]),
    // and the message opens with the instruction to answer only by calling.
    final instruction =
        'Answer this only by calling $_geminiIntentCheckFunctionName, without saying anything out loud. A field '
        'technician just said: "$heard". This is automatic speech recognition, so it may be misspelled, cut '
        'short, heavily accented, informal, or partly in another language such as Spanish. $previousLine'
        '$contextLine Call $_geminiIntentCheckFunctionName exactly once with intent "open_camera", '
        '"capture_photo", or "none", and your confidence. Use "none" for questions, remarks, or anything that is '
        'not asking for a photo. Do not call any other function.';
    _logNoState(
      'INTERNAL LABEL LEAK PREVENTED: intent check $id sent to Gemini with no internal label or id in its text '
      '(the id stays local)',
    );
    final timeout = Timer(_geminiIntentCheckTimeout, () {
      if (_geminiIntentCheck?.id != id) return;
      _resolveGeminiIntentCheck(checkId: id, intent: null, confidence: null, source: 'timeout');
    });
    _geminiIntentCheck = (
      id: id,
      utteranceSeq: _utteranceSeq,
      transcript: transcript,
      decision: decision,
      startedAt: DateTime.now(),
      timeout: timeout,
    );
    // Keeps the "nothing resolved" safety timer and inactivity timers
    // deferring while the check is out, same as any real call.
    _beginFunctionCallInFlight('gemini intent check $id');
    channel.sink.add(
      jsonEncode({
        'clientContent': {
          'turns': [
            {
              'role': 'user',
              'parts': [
                {'text': instruction},
              ],
            },
          ],
          'turnComplete': true,
        },
      }),
    );
    _log_(
      'GEMINI INTENT CHECK: asking Gemini ($id) heard="$transcript" context=$context '
      '(matcher: ${decision.kind.name}${decision.best == null ? '' : ' best=${decision.best!.trigger}'})'
      '${previousTurn == null ? '' : ' previousTurn="${previousTurn.text}"'}',
    );
    _pipelineLog('intent_check', 'started id=$id context=$context');
    _noteClientContentSent('intent_check:$id');
    return true;
  }

  /// 98284112 log: Gemini answered the check by SPEAKING the call —
  /// output transcription `classify_camera_intent(check_id="ic1",
  /// intent="none", confidence=1.0)` ~1s in — instead of sending a
  /// `toolCall`. Only `toolCall` was handled, and that audio is muted during
  /// the check, so the real answer was lost and the check sat until its
  /// timeout ("via timeout, confidence=none"). The spoken form is parsed
  /// here the moment it's complete and resolves the check exactly as the
  /// toolCall would.
  static final RegExp _spokenIntentCheckCall =
      RegExp(r'classify[\s_]*camera[\s_]*intent\s*\(([^)]*)\)', caseSensitive: false);
  static final RegExp _spokenCallArg = RegExp(r'''(\w+)\s*[=:]\s*["']?([\w.]+)["']?''');

  /// Set when a check is resolved from its spoken form: the rest of that
  /// same turn is still call syntax, so it stays muted until the turn's
  /// boundary (`turnComplete`/`interrupted`), exactly as it was while the
  /// check was pending.
  bool _dropRestOfSpokenIntentCheckTurn = false;

  void _maybeResolveIntentCheckFromSpokenCall() {
    final check = _geminiIntentCheck;
    if (check == null) return;
    final match = _spokenIntentCheckCall.firstMatch(_currentTurnGeminiText);
    if (match == null) return; // not spoken (yet), or still mid-call
    final args = {
      for (final arg in _spokenCallArg.allMatches(match.group(1) ?? '')) arg.group(1)!.toLowerCase(): arg.group(2)!,
    };
    _log_('GEMINI INTENT CHECK: Gemini spoke the classification instead of calling it — "${match.group(0)}"');
    _dropRestOfSpokenIntentCheckTurn = true;
    _resolveGeminiIntentCheck(
      checkId: args['check_id'],
      intent: args['intent']?.toLowerCase(),
      confidence: double.tryParse(args['confidence'] ?? ''),
      source: 'spoken_function_call',
    );
  }

  void _resolveGeminiIntentCheck({
    required String? checkId,
    required String? intent,
    required double? confidence,
    required String source,
  }) {
    if (source == 'timeout') {
      // Gemini may still answer this one late — that answer must not be
      // taken for the next check's (see [_retiredUnansweredIntentChecks]).
      _retiredUnansweredIntentChecks.add(DateTime.now());
    } else {
      final cutoff = DateTime.now().subtract(_retiredIntentCheckAnswerWindow);
      _retiredUnansweredIntentChecks.removeWhere((at) => at.isBefore(cutoff));
      if (_retiredUnansweredIntentChecks.isNotEmpty) {
        _retiredUnansweredIntentChecks.removeAt(0);
        _log_(
          'GEMINI INTENT CHECK: answer ($source, intent=$intent) belongs to an earlier check that was already '
          'superseded or timed out — ignored, not applied to the current one',
        );
        return;
      }
    }
    final check = _geminiIntentCheck;
    if (check == null || (checkId != null && checkId != check.id)) {
      _log_('GEMINI INTENT CHECK: answer ($source, check_id=$checkId intent=$intent) matches no pending check — ignored');
      return;
    }
    _geminiIntentCheck = null;
    check.timeout.cancel();
    _endFunctionCallInFlight('gemini intent check ${check.id}');
    final elapsedMs = DateTime.now().difference(check.startedAt).inMilliseconds;
    final geminiIntent = intent ?? 'none';
    if (source != 'timeout') {
      _log_(
        'INTENT CHECK RESOLVED EARLY: id=${check.id} elapsedMs=$elapsedMs intent=$geminiIntent '
        'confidence=${confidence?.toStringAsFixed(2) ?? 'none'} via=$source',
      );
    }
    void logOutcome(String action) {
      _log_(
        'GEMINI INTENT CHECK: heard="${check.transcript}" geminiIntent=$geminiIntent action=$action '
        '(confidence=${confidence?.toStringAsFixed(2) ?? 'none'}, ${elapsedMs}ms, via $source)',
      );
      _pipelineLog('intent_check', 'resolved id=${check.id} geminiIntent=$geminiIntent action=$action');
    }

    if (!mounted || _sessionClosing) return;
    if (check.utteranceSeq != _utteranceSeq) {
      logOutcome('discarded_stale (a newer utterance started)');
      return;
    }
    if (_anyTriggerCommittedThisUtterance || _guardFailedReplySpokenThisUtterance) {
      logOutcome('none_needed (already resolved while waiting)');
      return;
    }

    final wantsPhoto = (intent == 'open_camera' || intent == 'capture_photo') &&
        (confidence ?? 0) >= _geminiIntentMinConfidence;
    // Either answer means "they want a photo" — the CURRENT state decides
    // which step that is (the camera may have changed while waiting).
    final trigger = !wantsPhoto
        ? null
        : (_screenTask == _ScreenTask.cameraLive && _cameraOpenConfirmed)
        ? 'capture_photo'
        : (_screenTask == _ScreenTask.none ? 'open_camera' : null);
    if (trigger != null) {
      logOutcome('fired_$trigger');
      if (_fireIntentTrigger(trigger, logLabel: 'GEMINI INTENT CHECK') || _guardFailedReplySpokenThisUtterance) return;
      _log_('GEMINI INTENT CHECK: $trigger did not fire (guard/debounce) — falling back');
    }

    if (check.decision.kind == IntentDecisionKind.weak) {
      if (trigger == null) logOutcome('fallback_weak_match');
      _respondToWeakIntentMatch(check.transcript, check.decision);
      return;
    }
    if (trigger == null) logOutcome('fallback_catch_all');
    // Job Detail -> KB catch-all as before; anywhere else the KB GATE turns
    // it into a clarification question.
    _maybeFallBackToKbAnswerCatchAll();
  }

  /// PART F item 4 (client-confirmed regression, twice over: "Is today
  /// Modi's birthday?" and "put president name of India" each slipped past
  /// keyword-based question detection with a DIFFERENT gap — proof that
  /// gap will always exist for SOME phrasing). Rather than keep patching
  /// opener-word lists, this inverts the logic entirely: if NOTHING else
  /// matched this utterance at all (not get_kb_answer's own phrase list,
  /// not get_job_details/get_job_timeline_answer/get_last_photo/
  /// meta_capability/acknowledge_presence/site_condition, not any
  /// navigation/camera/go_back trigger) once it's genuinely finished,
  /// route it to get_kb_answer anyway as the universal default. Safe to
  /// over-trigger: a read-only backend lookup. [_preemptiveDefaultMuteActive]
  /// was already muting Gemini's own audio for this utterance the whole
  /// time (see [_muteImmediatelyOnFirstChunkOfUtterance]), so this is purely
  /// about deciding WHAT to say now, never a race against Gemini's own
  /// free answer. Guarded by [_looksLikeNonInformationalFiller] so a bare
  /// "okay"/"thanks" gets a silent, unmuted resume instead of an
  /// unnecessary KB round-trip and boundary decline.
  void _maybeFallBackToKbAnswerCatchAll() {
    // ISSUE 1(a) — see [_utteranceEndDetectedAt]'s doc comment: logs how
    // long THIS decision itself took from the moment the utterance was
    // detected as over, at every return point below, so the next real log
    // can directly confirm this branch is near-instant rather than
    // inferring it from the absence of a bug report.
    void logDecision(String outcome) {
      final startedAt = _utteranceEndDetectedAt;
      final elapsedMs = startedAt == null ? null : DateTime.now().difference(startedAt).inMicroseconds / 1000.0;
      _log_(
        'KB CATCH-ALL: routing decision made in ${elapsedMs == null ? '?' : elapsedMs.toStringAsFixed(2)}ms — '
        '$outcome',
      );
    }

    // PART G item 1 — see [_utteranceAlreadyResolvedByTrigger]'s doc
    // comment: some OTHER trigger already resolved this utterance for real
    // (possibly several chunks ago, after which
    // [_clearAllTriggerBuffersAfterSuccess] wiped every per-trigger
    // `resolvedForCurrentUtterance` flag below back to `false` so a genuine
    // follow-up request could still be detected) — never treat that as
    // "nothing matched" and speak a second, wrong response over it.
    if (_utteranceAlreadyResolvedByTrigger) {
      logDecision('already resolved by another trigger — nothing to route');
      _clearPreemptiveDefaultMuteSilently('utterance already resolved by another trigger');
      return;
    }
    final kbTrigger = _deterministicTriggers['get_kb_answer']!;
    final siteConditionTrigger = _deterministicTriggers['site_condition']!;
    if (_otherSpecificTriggerAlreadyResolvedThisUtterance ||
        _guardFailedReplySpokenThisUtterance ||
        kbTrigger.resolvedForCurrentUtterance ||
        siteConditionTrigger.resolvedForCurrentUtterance) {
      logDecision('a specific trigger already owns this utterance — nothing to route');
      return;
    }
    // GEMINI INTENT CHECK pending for this utterance — its result decides
    // what happens next, and re-enters this catch-all itself if the answer
    // is "none" (see [_resolveGeminiIntentCheck]).
    if (_geminiIntentCheck != null && _geminiIntentCheck!.utteranceSeq == _utteranceSeq) {
      logDecision('a Gemini intent check is pending for this utterance — deferring to its result');
      return;
    }
    final transcript = kbTrigger.buffer.trim();
    if (transcript.isEmpty || _looksLikeNonInformationalFiller(transcript)) {
      if (transcript.isNotEmpty) {
        _log_(
          'KB CATCH-ALL: nothing else matched, but "$transcript" looks like non-informational filler — not '
          'asking the KB.',
        );
      }
      logDecision('filler or empty transcript — not asking the KB');
      _clearPreemptiveDefaultMuteSilently('KB catch-all found nothing worth asking about');
      return;
    }
    // Clearly conversational — not a question the KB could ever answer
    // (CONFIRMED: "No, this provision looks good" took a 13.2s KB round trip
    // to come back "not available", then a boundary decline 15.4s after the
    // technician stopped talking). Positive evidence only: anything with a
    // question, request or problem word stays on the KB path below exactly
    // as before — see `conversational_utterance.dart`.
    switch (classifySmallTalk(transcript)) {
      case SmallTalkKind.greeting:
        logDecision('"$transcript" is a greeting — same reply as "hello", not the KB');
        _pipelineLog('conversational_reply', 'greeting "$transcript" -> acknowledge_presence');
        _maybeTriggerAcknowledgePresence('hello');
        return;
      case SmallTalkKind.reaction:
        logDecision('"$transcript" is a conversational reaction — replying directly, not the KB');
        _pipelineLog('conversational_reply', 'reaction "$transcript" -> in-character acknowledgment');
        _guardFailedReplySpokenThisUtterance = true;
        _informGeminiToSpeakVerbatim(_conversationalReplyForCurrentState(), reason: 'conversational_reaction');
        return;
      case SmallTalkKind.none:
        break;
    }
    // The recognizer drifted into another language (Spanish in a real
    // trace) and it isn't recognizable small talk: the English-only KB
    // can't answer it either — ask for a repeat now, the same way
    // non-Latin-script text already is, rather than after a KB round trip.
    if (_looksLikeNonEnglishLatinTranscription(transcript)) {
      logDecision('"$transcript" looks like a non-English transcription — asking for a repeat, not the KB');
      _pipelineLog('conversational_reply', 'non-English transcription "$transcript" -> ask to repeat');
      _guardFailedReplySpokenThisUtterance = true;
      _respondToUnclearInput(reason: 'non_english_transcription');
      return;
    }
    // KB GATE — only Job Detail falls back to the knowledge base. Every
    // other screen gets a clarification question, and get_kb_answer is
    // never called at all.
    if (!_kbGateAllows('catch_all')) {
      logDecision('"$transcript" — KB fallback disabled on this screen, asking for clarification instead');
      _guardFailedReplySpokenThisUtterance = true;
      _respondWithClarification(transcript: transcript, bestGuess: _clarifyBestGuess(transcript), reason: 'clarify_fallback');
      return;
    }
    kbTrigger.resolvedForCurrentUtterance = true;
    kbTrigger.lastActivityAt = DateTime.now();
    // PART L item 1 — a real resolution attempt is now genuinely in flight
    // (the KB backend call has been observed taking up to ~13s), so the
    // "nothing matched at all" safety-net timeout — now shortened to 2s
    // specifically for the truly-garbled-STT case where NOTHING, not even
    // this catch-all, could find anything to dispatch — must not fire
    // against THIS call and speak the "didn't catch that" retry line over
    // an answer that's genuinely still on its way. Cancelled here, not
    // cleared via the normal graduation logic in
    // [_interruptGeminiForDeterministicTrigger], since [_preemptiveDefaultMuteActive]
    // itself must stay true (audio still muted) until the real answer
    // actually arrives.
    _preemptiveDefaultMuteSafetyTimer?.cancel();
    _preemptiveDefaultMuteSafetyTimer = null;
    logDecision('routing "$transcript" to get_kb_answer as a last resort');
    _log_('KB CATCH-ALL: nothing else matched this utterance — routing "$transcript" to get_kb_answer as a last resort.');
    // ISSUE 1(b) — see [_kbAnswerWaitSafetyTimer]'s doc comment: a separate,
    // longer, purely-diagnostic ceiling on top of
    // [_armPreemptiveDefaultMuteSafetyTimer]'s own indefinite defer-while-
    // in-flight behavior, so a genuinely stuck backend call is at least
    // visible in the log instead of silently waiting forever with no trace.
    _kbAnswerWaitSafetyTimer?.cancel();
    _kbAnswerWaitSafetyTimer = Timer(_kbAnswerWaitSafetyDelay, () {
      if (!_preemptiveDefaultMuteActive) return; // already resolved for real
      _log_(
        'KB CATCH-ALL: still waiting on the real get_kb_answer response after '
        '${_kbAnswerWaitSafetyDelay.inSeconds}s — NOT speaking a fallback message (that would risk the exact '
        'wrong-message bug Issue 1 fixed); continuing to wait for the real answer.',
      );
    });
    unawaited(
      _executeDeterministic(
        kbTrigger,
        args: {'question': transcript, 'job_id': ?widget.jobId},
        buildSpokenText: _buildKbCatchAllSpokenText,
      ),
    );
  }

  /// PART F item 4 — see [_kbNoAnswerText]'s doc comment
  /// for why the catch-all substitutes the boundary phrase instead of the
  /// KB's own raw "not available" decline specifically for THIS path
  /// (nothing else matched at all), while [_buildKbAnswerSpokenText] (used
  /// by get_kb_answer's own EARLY/intentional match — a genuine trade/
  /// how-to question the technician clearly asked) still speaks whatever
  /// the KB itself returned, decline included, unchanged.
  String _buildKbCatchAllSpokenText(Map<String, dynamic> result) {
    final answer = result['answer'] as String?;
    if (answer == null || _kbNoMatchLiteralAnswers.contains(answer)) {
      _log_('KB MISS: get_kb_answer returned no match (catch-all) — speaking the explicit no-answer line');
      return _kbNoAnswerText;
    }
    return answer;
  }

  /// PART F items 4-5 (replaces the PART C/D keyword-based "does this
  /// look like a question" classifier, proven unreliable twice over —
  /// see [_maybeFallBackToKbAnswerCatchAll]'s doc comment). PART I item 1:
  /// this now fires UNCONDITIONALLY on this utterance's first chunk — see
  /// this method's call site in [_onInputTranscription] — instead of only
  /// once every trigger-specific check for a chunk came back empty, which
  /// used to let an instant-fire trigger (acknowledge_presence/
  /// meta_capability) match+interrupt BEFORE this ever got a chance to
  /// arm at all. Reuses [_interruptGeminiForDeterministicTrigger] verbatim,
  /// the SAME mechanism every known trigger already uses to cut off
  /// Gemini's audio, rather than a second, parallel mute implementation.
  /// Once ANY known trigger matches (this same chunk, or a later one for
  /// this utterance), its own dispatch graduates/clears this automatically
  /// — see that method's doc comment. If the utterance ends with genuinely
  /// nothing matched, [_maybeArmPreemptiveMuteSafetyTimeout] (called at the
  /// END of [_onInputTranscription], after every trigger's own synchronous
  /// chance against this chunk) arms the last-resort timeout, and
  /// [_maybeFallBackToKbAnswerCatchAll] resolves it for real (a real KB
  /// answer, the boundary decline, or a silent clear for filler).
  void _muteImmediatelyOnFirstChunkOfUtterance() {
    // See [_utteranceAlreadyResolvedByTrigger]'s doc comment: a trailing/
    // corrected transcript chunk arriving for an utterance some OTHER
    // trigger already resolved a moment ago must never re-mute — that
    // utterance is done.
    if (_utteranceAlreadyResolvedByTrigger) return;
    if (_preemptiveDefaultMuteActive) return; // already muted this utterance
    // P0 FIX — see [_protectedConfirmationActive]'s doc comment: an
    // incidental utterance that hasn't resolved into anything yet must not
    // get the usual unconditional head-start mute while a protected
    // confirmation's audio is expected imminently — a GENUINE resolved
    // command still interrupts normally through its own trigger-specific
    // call once it actually matches later in [_onInputTranscription]; only
    // this blind preemptive step is skipped.
    if (_protectedConfirmationActive) {
      _log_(
        'PROTECTED CONFIRMATION: suppressing the usual preemptive mute for an incidental, not-yet-resolved '
        'utterance during the post-confirmation grace window — a genuine command will still interrupt normally '
        'once it actually matches.',
      );
      return;
    }
    // BUG 4 FIX — see [_trackSpeechLevel]'s own doc comment on the block
    // this moved out of. This is the moment REAL transcript text proves a
    // genuinely new utterance has started (this method only ever reaches
    // here once per utterance — see the two guards just above), unlike the
    // raw-amplitude edge in [_trackSpeechLevel], which fires on background
    // noise alone with no transcript at all. Any PCM chunk still queued
    // from the previous utterance's reinit is stale by now (that reinit
    // normally completes and flushes well within the debounce a genuinely
    // new utterance requires) UNLESS it's a still-wanted response the app
    // itself is waiting to play — which is exactly what discarding it here,
    // instead of on a bare noise blip, protects.
    if (_pendingPcmChunksAwaitingReinit.isNotEmpty) {
      _log_(
        'PCM QUEUE: discarding ${_pendingPcmChunksAwaitingReinit.length} queued response chunk(s) — a new '
        'utterance with real transcript text just started.',
      );
      _pendingPcmChunksAwaitingReinit.clear();
    }
    _log_(
      'PREEMPTIVE MUTE: first chunk of a new utterance — muting Gemini\'s audio immediately and '
      'unconditionally, before any trigger-specific logic (including acknowledge_presence/meta_capability) runs.',
    );
    debugPrint('PHOTO TIMING [preemptive_mute]: new utterance — muting NOW, unconditionally');
    _interruptGeminiForDeterministicTrigger('preemptive_default_mute');
    _preemptiveDefaultMuteActive = true;
  }

  /// P0 FIX (CONFIRMED in a real session: "I'm not able to take photos,
  /// but" played for ~500ms before open_camera's own "Camera's open" line).
  /// [_muteImmediatelyOnFirstChunkOfUtterance] only runs on the first
  /// INPUT TRANSCRIPTION chunk, but Gemini answers the raw mic audio and its
  /// first response audio can arrive before that transcription does. So
  /// from the speech-onset edge in [_trackSpeechLevel] until the first
  /// transcript chunk (or [_awaitingFirstTranscriptTimeout], for a noise
  /// blip that never transcribes), [_onResponseAudioChunk] drops any
  /// response audio we didn't ask for — the same audio the preemptive mute
  /// would cut off a moment later anyway, just without the audible head
  /// start. Lines we scripted ([_scriptedResponsePending]), a protected
  /// confirmation, and a pending-call filler are never held.
  bool _awaitingFirstTranscriptOfUtterance = false;
  Timer? _awaitingFirstTranscriptTimer;
  static const Duration _awaitingFirstTranscriptTimeout = Duration(milliseconds: 2500);

  /// Set when [_informGeminiToSpeakVerbatim] asks for a line, cleared on
  /// the next `turnComplete` — see [_awaitingFirstTranscriptOfUtterance].
  bool _scriptedResponsePending = false;

  /// TURN-IDENTITY GATE (P0, CONFIRMED twice on "I want to take photo", and
  /// on screen recording ~0:27: "I understand you want" / "Go ahead! What
  /// are" played and got cut off mid-word right before "Camera's open").
  ///
  /// WHY IDENTITY AND NOT TIMING: when [_informGeminiToSpeakVerbatim] sends
  /// "say exactly X", Gemini may ALREADY be generating its own free-text
  /// turn from the raw utterance. That stale turn's first chunk can reach
  /// us 150–200ms AFTER our send, so "arrived after the interrupt" does not
  /// mean "generated after the interrupt" — and every timing-based unmute
  /// (the 150ms idle safety timeout, the one-shot per-utterance interrupt)
  /// is a guess that loses exactly that race. The client can't see when the
  /// server generated a chunk, but it CAN see what the turn says: the
  /// scripted turn's output transcription matches X, and a stale turn's
  /// doesn't. So from the send until a turn is identified, response chunks
  /// are HELD, not played. A matching transcript flushes them, and a
  /// mismatching one — or the server's `interrupted` for that turn, which
  /// only a turn cut off by our clientContent gets — discards them.
  ///
  /// Normalized words of the scripted line we're waiting for, or `null`
  /// when no scripted line is pending identification.
  List<String>? _awaitingScriptedTurnWords;

  /// The turn currently arriving was identified as NOT the scripted one —
  /// drop its chunks until its turn boundary.
  bool _currentTurnKnownStale = false;
  String _scriptIdentityCandidateText = '';
  final List<({Uint8List bytes, String? mimeType})> _heldUnidentifiedTurnChunks = [];
  Timer? _scriptIdentityTimer;

  /// Held-but-unidentified chunks are released after this long without an
  /// identifying transcript — better a rare stale fragment than silently
  /// losing the real confirmation if transcription never arrives.
  static const Duration _scriptIdentityHoldTimeout = Duration(milliseconds: 2500);

  /// Gives up waiting if Gemini never starts ANY turn for the scripted line
  /// (nothing is held, so nothing is at risk — this only stops the pill
  /// showing "Thinking..." forever).
  static const Duration _scriptIdentityAbandonTimeout = Duration(seconds: 15);

  static const double _scriptIdentityMatchRatio = 0.6;

  /// The reply-injection reason ([_informGeminiToSpeakVerbatim]'s `reason`,
  /// e.g. `photo_note_readback`) of the scripted line being waited for —
  /// only for the READBACK TAIL SUPPRESSED log lines.
  String _awaitingScriptedTurnReason = '';

  void _beginAwaitingScriptedTurn(String text, {required String reason}) {
    _awaitingScriptedTurnWords = _normalizeForEchoCompare(text).split(' ').where((w) => w.isNotEmpty).toList();
    _awaitingScriptedTurnReason = reason;
    // READBACK TAIL FIX (a7d30b48 log, u=11): a model turn already in
    // flight at this moment began BEFORE this line was requested, so it can
    // only ever be a fragment — Gemini freely saying the same readback
    // (muted until now), whose trailing "…Save that?" matched the script
    // word-for-word and played out of context before the real line. That
    // whole turn is dropped until its boundary; only a turn that starts
    // after this point can be the scripted one. (Muted turns never flip
    // [_turnComplete], so in-flight is judged by this turn having produced
    // any audio or text since its last boundary.)
    _currentTurnKnownStale = _currentTurnHadAudioOrText;
    if (_currentTurnKnownStale) {
      _log_(
        'READBACK TAIL SUPPRESSED: trigger=$reason reason=turn_started_before_resolution — a model turn was already '
        'in flight when this line was requested; dropping the rest of it and waiting for the next turn.',
      );
    }
    _scriptIdentityCandidateText = '';
    _heldUnidentifiedTurnChunks.clear();
    _armScriptIdentityTimer(_scriptIdentityAbandonTimeout);
    _syncVoicePhase();
  }

  /// Whether the identifying transcript [words] OPENS like [script] — the
  /// script's first word (or second, if the first was swallowed) within
  /// the first three words heard, which still allows a short preamble
  /// ("Okay, camera's open…"). `null` while fewer than three words have
  /// arrived without an opening match. A turn whose words all appear in the
  /// script but which opens mid-line ("save that") started before the
  /// scripted turn could have — the old word-ratio check alone let exactly
  /// that tail play.
  bool? _transcriptOpensLikeScript(List<String> words, List<String> script) {
    if (script.isEmpty) return true;
    final openers = script.take(2).toSet();
    final lead = words.take(3);
    if (lead.any(openers.contains)) return true;
    return words.length < 3 ? null : false;
  }

  /// Held chunks whose partial transcript does NOT open like the script
  /// (misaligned, or too short to tell) — never released on a timeout or
  /// turn boundary, since they could be exactly that mid-line tail.
  bool get _heldCandidateNotAlignedWithScript {
    final script = _awaitingScriptedTurnWords;
    if (script == null || _scriptIdentityCandidateText.isEmpty) return false;
    final words = _normalizeForEchoCompare(_scriptIdentityCandidateText).split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return false;
    return _transcriptOpensLikeScript(words, script) != true;
  }

  void _armScriptIdentityTimer(Duration delay) {
    _scriptIdentityTimer?.cancel();
    _scriptIdentityTimer = Timer(delay, () {
      if (_awaitingScriptedTurnWords == null) return;
      if (_heldCandidateNotAlignedWithScript) {
        _log_(
          'READBACK TAIL SUPPRESSED: trigger=$_awaitingScriptedTurnReason reason=turn_started_before_resolution — '
          'held turn "$_scriptIdentityCandidateText" does not open like the scripted line; discarding it instead of '
          'releasing on the ${delay.inMilliseconds}ms timeout.',
        );
        _resolveScriptedTurn(play: false, reason: 'held transcript does not open like the script');
        return;
      }
      _resolveScriptedTurn(play: true, reason: 'no identifying transcript within ${delay.inMilliseconds}ms');
    });
  }

  /// Ends the wait. [play] flushes held chunks back through
  /// [_onResponseAudioChunk] (every OTHER gate still applies to them);
  /// otherwise they're discarded.
  void _resolveScriptedTurn({required bool play, required String reason}) {
    _scriptIdentityTimer?.cancel();
    _scriptIdentityTimer = null;
    final held = List.of(_heldUnidentifiedTurnChunks);
    _heldUnidentifiedTurnChunks.clear();
    _awaitingScriptedTurnWords = null;
    _currentTurnKnownStale = false;
    _scriptIdentityCandidateText = '';
    _log_('TURN IDENTITY: resolved ($reason) — ${play ? 'playing' : 'discarding'} ${held.length} held chunk(s)');
    if (play) {
      // This turn is the one we asked for, so whatever stale turn the
      // deterministic suppression was guarding against is already behind it.
      _clearDeterministicAudioSuppression('scripted turn identified ($reason)');
      for (final chunk in held) {
        _onResponseAudioChunk(chunk.bytes, mimeType: chunk.mimeType);
      }
    }
    _syncVoicePhase();
  }

  /// Called for every output-transcription fragment BEFORE the audits, so
  /// they see this turn's audibility correctly.
  void _classifyTurnAgainstScript(String fragment) {
    final script = _awaitingScriptedTurnWords;
    if (script == null || _currentTurnKnownStale) return;
    _scriptIdentityCandidateText = '$_scriptIdentityCandidateText $fragment'.trim();
    final words = _normalizeForEchoCompare(_scriptIdentityCandidateText).split(' ').where((w) => w.isNotEmpty).toList();
    if (words.length < 2) return; // too little to judge yet
    final scriptWords = script.toSet();
    final ratio = words.where(scriptWords.contains).length / words.length;
    if (ratio >= _scriptIdentityMatchRatio) {
      // READBACK TAIL FIX — matching the script's words isn't enough; the
      // turn must also start where the script starts.
      final opens = _transcriptOpensLikeScript(words, script);
      if (opens == null) return; // keep holding until the opening is clear
      if (!opens) {
        _currentTurnKnownStale = true;
        _log_(
          'READBACK TAIL SUPPRESSED: trigger=$_awaitingScriptedTurnReason reason=turn_started_before_resolution — '
          '"$_scriptIdentityCandidateText" matches the scripted line\'s words but opens mid-line; discarding '
          '${_heldUnidentifiedTurnChunks.length} held chunk(s) and dropping the rest of this turn.',
        );
        _heldUnidentifiedTurnChunks.clear();
        return;
      }
      // CONFIRMED via flutter_run_log 6038bc76: a scripted line interrupted
      // mid-playback was restarted, and releasing the restart the moment
      // it matched the script ("Yes, I") let "Yes, I can hear" play before
      // the duplicate check could run. With an interrupted-turn baseline
      // active, keep HOLDING (the same hold as above) until the duplicate
      // check can decide; a restart is dropped unplayed, anything else is
      // released. No baseline — the normal case — releases immediately,
      // exactly as before.
      if (_interruptedTurnBaseline != null) {
        final candidate = _scriptIdentityCandidateText;
        final result = _evaluateInterruptedTurnBaseline(words, candidate, maxBaselineWords: _baselineHoldCompareWords);
        switch (result.verdict) {
          case _BaselineVerdict.needMoreWords:
            _log_(
              'TURN IDENTITY: "$candidate" matches the script, but an interrupted-turn baseline '
              '("${_interruptedTurnBaseline?.text}") is active — still HOLDING ${_heldUnidentifiedTurnChunks.length} '
              'chunk(s) until the duplicate check can run',
            );
            return;
          case _BaselineVerdict.duplicate:
            _suppressTurnAsInterruptedDuplicate(candidate, result.overlap);
            _resolveScriptedTurn(
              play: false,
              reason: 'transcript "$candidate" restarts an interrupted turn — duplicate, dropped before any audio played',
            );
            return;
          case _BaselineVerdict.notDuplicate:
          case _BaselineVerdict.noBaseline:
            break;
        }
      }
      _resolveScriptedTurn(play: true, reason: 'transcript "$_scriptIdentityCandidateText" matches the script');
      return;
    }
    _currentTurnKnownStale = true;
    _log_(
      'TURN IDENTITY: STALE TURN — "$_scriptIdentityCandidateText" is not the scripted line; discarding '
      '${_heldUnidentifiedTurnChunks.length} held chunk(s) and dropping the rest of this turn.',
    );
    _heldUnidentifiedTurnChunks.clear();
  }

  /// A server turn boundary while waiting for the scripted turn.
  void _onTurnBoundaryWhileAwaitingScript({required bool interrupted}) {
    if (_awaitingScriptedTurnWords == null) return;
    if (_currentTurnKnownStale || interrupted) {
      // Stale turn over (an `interrupted` turn is one our clientContent cut
      // off). Keep waiting — the scripted turn comes next.
      if (_heldUnidentifiedTurnChunks.isNotEmpty) {
        _log_('TURN IDENTITY: discarding ${_heldUnidentifiedTurnChunks.length} held chunk(s) from a turn the server interrupted.');
      }
      _heldUnidentifiedTurnChunks.clear();
      _currentTurnKnownStale = false;
      _scriptIdentityCandidateText = '';
      _armScriptIdentityTimer(_scriptIdentityAbandonTimeout);
      return;
    }
    if (_heldUnidentifiedTurnChunks.isNotEmpty) {
      // A partial transcript that doesn't open like the script (e.g. a
      // two-word tail that ended before it could be judged) is dropped,
      // and the wait goes on for the real turn.
      if (_heldCandidateNotAlignedWithScript) {
        _log_(
          'READBACK TAIL SUPPRESSED: trigger=$_awaitingScriptedTurnReason reason=turn_started_before_resolution — '
          'turn "$_scriptIdentityCandidateText" ended without opening like the scripted line; discarding '
          '${_heldUnidentifiedTurnChunks.length} held chunk(s).',
        );
        _heldUnidentifiedTurnChunks.clear();
        _scriptIdentityCandidateText = '';
        _armScriptIdentityTimer(_scriptIdentityAbandonTimeout);
        return;
      }
      // Completed naturally with no identifying transcript yet — play it
      // rather than risk losing the real confirmation.
      _resolveScriptedTurn(play: true, reason: 'turn completed before its transcript arrived');
    }
  }

  /// Single source of truth for the voice pill's phase. Busy
  /// ("Thinking...") is tied to the real in-flight work — a dispatch
  /// ([_inFlightFunctionCalls]) or a scripted turn we're still waiting on —
  /// instead of dropping back to listening the moment the mic resumes while
  /// that work is still running.
  ///
  /// `listening` (the pill's green level bars) must mean exactly "mic audio
  /// is being sent to Gemini right now" — the same gates [_onMicChunk]
  /// applies before its `MIC SEND` lines: [_outgoingAudioPaused] (paused
  /// while Gemini's own audio plays, so the mic can't hear the speaker) and
  /// [_cameraNativeCallInProgress] (the camera hard-pause). Keying the pill
  /// off generic audio activity instead would light "listening" while the
  /// assistant itself was talking.
  ///
  /// Coalesced to one update per microtask — still before the next frame,
  /// so no visible lag — so a transient in-between state inside one
  /// synchronous step (e.g. a dispatch ending immediately before its
  /// scripted reply is requested) can't flash on the pill.
  void _syncVoicePhase() {
    if (_voicePhaseSyncScheduled) return;
    _voicePhaseSyncScheduled = true;
    scheduleMicrotask(() {
      _voicePhaseSyncScheduled = false;
      _applyVoicePhase();
    });
  }

  bool _voicePhaseSyncScheduled = false;

  void _applyVoicePhase() {
    final VoicePhase phase;
    if (_outgoingAudioPaused) {
      phase = VoicePhase.speaking;
    } else if (_cameraNativeCallInProgress ||
        _inFlightFunctionCalls > 0 ||
        _awaitingScriptedTurnWords != null ||
        _awaitingLateTranscript) {
      phase = VoicePhase.processing;
    } else {
      phase = VoicePhase.listening;
    }
    _pausedVoiceService?.setExternalSessionPhase(phase);
  }

  void _beginAwaitingFirstTranscript() {
    _awaitingFirstTranscriptOfUtterance = true;
    _awaitingFirstTranscriptTimer?.cancel();
    _awaitingFirstTranscriptTimer = Timer(_awaitingFirstTranscriptTimeout, () {
      _endAwaitingFirstTranscript('no transcript within ${_awaitingFirstTranscriptTimeout.inMilliseconds}ms');
    });
  }

  void _endAwaitingFirstTranscript(String reason) {
    _awaitingFirstTranscriptTimer?.cancel();
    _awaitingFirstTranscriptTimer = null;
    if (!_awaitingFirstTranscriptOfUtterance) return;
    _awaitingFirstTranscriptOfUtterance = false;
    debugPrint('UNCLASSIFIED UTTERANCE HOLD: released ($reason) at ${DateTime.now()}');
  }

  /// The same gates [_onResponseAudioChunk] checks first, in the same
  /// order — true while any response audio arriving now would be dropped
  /// rather than played.
  bool get _responseAudioCurrentlyDropped =>
      (_cameraNativeCallInProgress && !_fillerPassthroughActive) ||
      _awaitingScriptedTurnWords != null ||
      _holdingForUnclassifiedUtterance ||
      _suppressResponseAudioForDeterministic ||
      _preemptiveDefaultMuteActive ||
      _geminiIntentCheck != null ||
      _dropRestOfSpokenIntentCheckTurn;

  bool get _holdingForUnclassifiedUtterance =>
      _awaitingFirstTranscriptOfUtterance &&
      !_scriptedResponsePending &&
      !_protectedConfirmationActive &&
      !_fillerPassthroughActive;

  /// PART I item 1 — see [_muteImmediatelyOnFirstChunkOfUtterance]'s doc
  /// comment: that method now does the actual muting, unconditionally, on
  /// this utterance's first chunk. This method's only remaining job is the
  /// safety net: if nothing has resolved this utterance by the time every
  /// trigger above has had its synchronous chance against THIS chunk, arm
  /// (once — [_preemptiveDefaultMuteSafetyTimer] is the idempotency guard,
  /// since this runs on every chunk until something resolves) the 5s
  /// last-resort boundary decline.
  void _maybeArmPreemptiveMuteSafetyTimeout() {
    if (_utteranceAlreadyResolvedByTrigger) return;
    if (_otherSpecificTriggerAlreadyResolvedThisUtterance) return; // already matched something known
    if (_guardFailedReplySpokenThisUtterance) return; // a guard-failed clarification already answered it
    if (_deterministicTriggers['site_condition']!.resolvedForCurrentUtterance) return;
    if (_preemptiveDefaultMuteSafetyTimer != null) return; // already armed for this utterance
    _log_(
      'PREEMPTIVE DEFAULT MUTE: nothing matches a known command pattern yet — arming the '
      '${_preemptiveDefaultMuteSafetyDelay.inSeconds}s safety-net timeout.',
    );
    _armPreemptiveDefaultMuteSafetyTimer();
  }

  /// ISSUE 3(b) (CONFIRMED via f5a8bd8b-flutter_run_log.txt): same fix as
  /// [_armSuppressResponseAudioSafetyTimer], applied to this timer's own
  /// "nothing matched, speak the retry decline" path — a real dispatch
  /// genuinely being slow (get_kb_answer's catch-all round trip, observed
  /// taking 17.7s end to end) is not the same thing as "nothing was ever
  /// going to resolve this," and must not get the same canned retry line
  /// spoken over it once it finally does resolve. Checks
  /// [_inFlightFunctionCalls] before actually declining: while something is
  /// genuinely in flight, defers by re-arming itself instead, so only a
  /// real "nothing was even dispatched" STT/no-match failure ever reaches
  /// the decline.
  void _armPreemptiveDefaultMuteSafetyTimer() {
    _preemptiveDefaultMuteSafetyTimer = Timer(_preemptiveDefaultMuteSafetyDelay, () {
      if (!_preemptiveDefaultMuteActive) return;
      // ISSUE 1(a) fix (CONFIRMED via fbd877f0-flutter_run_log.txt: "Can you
      // tell me the president name of India?" — an 8-word question — was
      // still being SPOKEN when this fixed 2s timer, armed from the
      // utterance's first chunk, expired; the KB catch-all can only make
      // its routing decision once silence is actually detected (see
      // [_finalizeUtteranceEndDeterministicTriggers]/[_utteranceEndDetectedAt]),
      // so firing while the technician is still genuinely mid-sentence
      // speaks the wrong "didn't catch that" line over a request that
      // hasn't even finished being asked yet). Defers instead of declining
      // while [_isSpeaking] is true — the same raw-amplitude signal
      // [_trackSpeechLevel] itself uses to decide the utterance isn't over.
      if (_isSpeaking) {
        _log_(
          'PREEMPTIVE DEFAULT MUTE: safety timeout (${_preemptiveDefaultMuteSafetyDelay.inSeconds}s) reached but '
          'the technician is still actively speaking — deferring the retry decline until the utterance actually '
          'ends; checking again in another ${_preemptiveDefaultMuteSafetyDelay.inSeconds}s.',
        );
        _armPreemptiveDefaultMuteSafetyTimer();
        return;
      }
      if (_inFlightFunctionCalls > 0) {
        _log_(
          'PREEMPTIVE DEFAULT MUTE: safety timeout (${_preemptiveDefaultMuteSafetyDelay.inSeconds}s) reached but '
          '$_inFlightFunctionCalls function call(s) still genuinely in flight (e.g. a KB lookup) — deferring the '
          'retry decline instead of speaking it over a real dispatch; checking again in another '
          '${_preemptiveDefaultMuteSafetyDelay.inSeconds}s.',
        );
        _armPreemptiveDefaultMuteSafetyTimer();
        return;
      }
      _log_(
        'PREEMPTIVE DEFAULT MUTE: safety timeout (${_preemptiveDefaultMuteSafetyDelay.inSeconds}s) — nothing '
        'ever resolved this, not even a KB catch-all dispatch, and nothing genuinely in flight either — inviting '
        'a retry as a last resort so the session doesn\'t stay silently muted.',
      );
      _respondToUnclearInput(reason: 'preemptive_default_mute_timeout');
    });
  }

  /// Consecutive unclear-input fallbacks within [_unclearInputStreakWindow]
  /// — reset by any real trigger resolution (see
  /// [_clearAllTriggerBuffersAfterSuccess]) or by the window lapsing.
  int _unclearInputStreak = 0;
  DateTime? _lastUnclearInputAt;
  static const Duration _unclearInputStreakWindow = Duration(seconds: 40);
  static const String _unclearInputShortReply = 'Sorry, still not catching that.';

  /// P1 FIX (CONFIRMED: a run of unclear inputs — bad pickup, echo, noise —
  /// got a near-identical full "I didn't catch that, try again" line every
  /// single time, which reads as the app being stuck in a loop). Escalates
  /// instead: the 1st gets the full state-aware reply, the 2nd a distinctly
  /// shorter line, and from the 3rd on nothing is said (the on-screen UI
  /// still shows state) — Gemini's own stale free-text answer is still cut
  /// off, so going quiet never means Gemini fills the silence itself.
  ///
  /// [clarify] / [reconfirmText] — CLARIFY FALLBACK (see
  /// [_respondWithClarification]): with [reconfirmText] ("Did you mean
  /// ...?") that line is spoken in place of the flow / generic reply; with
  /// only [clarify], the camera/photo-note flow lines still win (they are
  /// already clarification questions), and otherwise the rotating natural
  /// "say that again" lines replace the generic examples menu. The
  /// escalation (1st, 2nd, quiet from the 3rd) is the same either way.
  /// Returns whether [reconfirmText] was actually spoken.
  bool _respondToUnclearInput({required String reason, bool clarify = false, String? reconfirmText}) {
    final now = DateTime.now();
    final last = _lastUnclearInputAt;
    if (last == null || now.difference(last) > _unclearInputStreakWindow) _unclearInputStreak = 0;
    _lastUnclearInputAt = now;
    _unclearInputStreak++;
    if (reconfirmText != null && _unclearInputStreak <= 2) {
      _log_('UNCLEAR INPUT: reconfirming the best guess (miss #$_unclearInputStreak, reason=$reason)');
      _informGeminiToSpeakVerbatim(reconfirmText, reason: reason);
      return true;
    }
    if (clarify && _unclearInputStreak <= 2) {
      final flowReply = _activeFlowUnclearReply(repeat: _unclearInputStreak == 2);
      _log_(
        'UNCLEAR INPUT: clarification question (miss #$_unclearInputStreak, reason=$reason'
        '${flowReply == null ? '' : ', activeFlow=${flowReply.flow}'})',
      );
      _informGeminiToSpeakVerbatim(flowReply?.text ?? _nextClarificationReply(), reason: reason);
      return false;
    }
    // Context first — see [_activeFlowUnclearReply]. Same 1st / short 2nd /
    // quiet 3rd+ escalation either way.
    final flowReply = _unclearInputStreak <= 2 ? _activeFlowUnclearReply(repeat: _unclearInputStreak == 2) : null;
    if (flowReply != null) {
      _log_(
        '${reason == 'transcript_never_arrived' ? 'TRANSCRIPT TIMEOUT' : 'UNCLEAR INPUT'}: context-aware fallback fired '
        '— activeFlow=${flowReply.flow} (miss #$_unclearInputStreak, reason=$reason)',
      );
    } else if (_unclearInputStreak <= 2 && reason == 'transcript_never_arrived') {
      _log_('TRANSCRIPT TIMEOUT: generic idle-state fallback fired — no active flow (miss #$_unclearInputStreak)');
    }
    if (_unclearInputStreak == 1) {
      _informGeminiToSpeakVerbatim(flowReply?.text ?? _unrecognizedReplyForCurrentState(), reason: reason);
    } else if (_unclearInputStreak == 2) {
      _log_('UNCLEAR INPUT: 2nd in a row — short reply instead of repeating the full line ($reason)');
      _informGeminiToSpeakVerbatim(flowReply?.text ?? _unclearInputShortReply, reason: reason);
    } else {
      _log_('UNCLEAR INPUT: $_unclearInputStreak in a row — staying quiet ($reason)');
      _interruptGeminiForDeterministicTrigger('unclear_input_quiet');
    }
    return false;
  }

  /// See [_preemptiveDefaultMuteActive]'s doc comment — clears it WITHOUT
  /// sending any `clientContent` (unlike every other resolution path,
  /// which goes through [_interruptGeminiForDeterministicTrigger]'s
  /// graduation logic instead): used only for the "turned out to be
  /// non-informational filler" case in [_maybeFallBackToKbAnswerCatchAll],
  /// where there is deliberately nothing worth saying at all. HONEST
  /// LIMITATION: [_suppressResponseAudioForDeterministic] (armed by the
  /// SAME initial preemptive-mute call) is a separate flag with its own
  /// short safety timeout, not cleared here — a filler acknowledgment can
  /// see a brief extra mute (up to that timeout) before Gemini's own
  /// natural response to it resumes, since no new `clientContent` turn
  /// exists here to prompt the server to mark the old one `interrupted`.
  void _clearPreemptiveDefaultMuteSilently(String reason) {
    if (!_preemptiveDefaultMuteActive) return;
    _preemptiveDefaultMuteActive = false;
    _preemptiveDefaultMuteSafetyTimer?.cancel();
    _preemptiveDefaultMuteSafetyTimer = null;
    _log_('PREEMPTIVE DEFAULT MUTE: cleared silently ($reason) — nothing worth saying.');
  }

  /// See [_maybeFallBackToKbAnswerCatchAll]'s doc comment — a short, closed
  /// set of common conversational acknowledgments that must never trigger
  /// an unnecessary KB lookup/decline on their own. Only matches when the
  /// WHOLE (normalized) utterance is exactly one of these — substantive
  /// text with one of these words in it still routes to the KB normally.
  bool _looksLikeNonInformationalFiller(String text) {
    final normalized = text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ').trim().replaceAll(RegExp(r'\s+'), ' ');
    return _nonInformationalFillerPhrases.contains(normalized);
  }

  /// Broad, NOT exact-phrase, whole-word/phrase pattern match for "the
  /// technician wants to see the estimate" — see
  /// [_viewEstimateIndicatorPhrases]'s doc comment for the CONFIRMED
  /// under-triggered-function bug this exists to catch. Same normalization/
  /// padding approach as [_looksLikeIntentionalGoBack] (lowercased, stripped
  /// to letters/spaces, space-padded substring checks against each
  /// multi-word phrase), so a false positive here only costs an extra
  /// NON_BLOCKING navigation call, never a write.
  bool _looksLikeViewEstimateRequest(String text) {
    // P0 FIX — the same literal-substring brittleness [_TranscriptTrigger.matches]
    // documents. Routed through the same shared matcher so word-form drift, one
    // inserted filler word, and the negation veto behave identically for the
    // hand-rolled triggers and the [_deterministicTriggers] map alike.
    final padded = stemmedPaddedTriggerText(text);
    final phraseMatch = matchAnyTriggerPhrase(text, _viewEstimateIndicatorPhrases);
    if (phraseMatch != null) {
      if (!phraseMatch.exact) {
        debugPrint('FUZZY TRIGGER MATCH [view_estimate]: ${phraseMatch.describe()} matched in "$text"');
      }
      return true;
    }
    // PART G item 2 / PART L item 1 — see [_looksLikeNounPlusActionIntent]'s
    // doc comment.
    return _looksLikeNounPlusActionIntent(
      padded,
      nouns: const ['estimate'],
      actionWords: _navigationActionIntentWords,
      logLabel: 'view_estimate',
    );
  }

  /// FIX 2 (CONFIRMED real problem): a single open_camera trigger was
  /// observed firing against a massive, ~10-exchange combined buffer —
  /// buffers were only ever cleared by [_utteranceBufferResetDebounce] (2s
  /// of genuine silence), never by real conversational progress. A
  /// successful function call — Gemini-initiated (tracked generically in
  /// [_handleToolCall]) OR this app's own deterministic trigger (tracked in
  /// every `_executeDeterministicX`/[_executeDeterministic]/
  /// [_maybeDetectPhotoDecision]) — is itself unambiguous evidence the
  /// technician's request was just resolved: everything accumulated in
  /// every trigger's buffer up to this point is stale, and whatever comes
  /// next is a genuinely NEW request. Called from every point in this file
  /// a function call succeeds, in addition to (not instead of) the
  /// silence-based reset in [_trackSpeechLevel].
  void _clearAllTriggerBuffersAfterSuccess(String reason, {bool endsUnclearInputStreak = true}) {
    // Kept across a go_back success in the same utterance — see
    // [_jobDetailsDestinationBuffer].
    if (!_goBackFiredThisUtterance) _jobDetailsDestinationBuffer = '';
    _jobDetailsDestinationResolvedForCurrentUtterance = false;
    _goBackIntentDetectionBuffer = '';
    _goBackTriggerResolvedForCurrentUtterance = false;
    _viewEstimateDetectionBuffer = '';
    _viewEstimateDetectionResolvedForCurrentUtterance = false;
    _getJobDetailsDetectionBuffer = '';
    _getJobDetailsDetectionResolvedForCurrentUtterance = false;
    _getCurrentScreenDetectionBuffer = '';
    _getCurrentScreenDetectionResolvedForCurrentUtterance = false;
    _metaCapabilityDetectionBuffer = '';
    _metaCapabilityDetectionResolvedForCurrentUtterance = false;
    _acknowledgePresenceDetectionBuffer = '';
    _acknowledgePresenceResolvedForCurrentUtterance = false;
    _photoDecisionDetectionBuffer = '';
    _photoDecisionResolvedForCurrentUtterance = false;
    for (final trigger in _deterministicTriggers.values) {
      trigger.resetForNewUtterance();
    }
    // Next speech chunk should be treated as unambiguously new, not
    // measured against a now-resolved, pre-success timestamp.
    _lastSpeechActivityAt = null;
    // PART G item 1 — see [_utteranceAlreadyResolvedByTrigger]'s doc
    // comment: this is the ONE place a real resolution is recorded on a
    // signal that survives the per-trigger buffer wipe just above, so a
    // later trailing chunk for this SAME utterance can never make
    // [_muteImmediatelyOnFirstChunkOfUtterance]/[_maybeFallBackToKbAnswerCatchAll]
    // treat it as brand new and unclassified. Cancelling the preemptive
    // mute/timer here too (not just relying on [_interruptGeminiForDeterministicTrigger]'s
    // own graduation logic, which some call sites reach only AFTER this
    // method runs) closes the race unconditionally, at the exact moment a
    // real resolution is known to exist.
    _utteranceAlreadyResolvedByTrigger = true;
    // See [_attributeTranscriptChunkToUtterance].
    _utteranceCommittedAt = DateTime.now();
    // A real resolution ends any unclear-input streak — see [_respondToUnclearInput].
    if (endsUnclearInputStreak) _unclearInputStreak = 0;
    // ...and any "Did you mean ...?" still waiting for a yes.
    _pendingReconfirm = null;
    if (_preemptiveDefaultMuteActive) {
      _log_('PREEMPTIVE DEFAULT MUTE: cleared — "$reason" resolved this utterance for real.');
    }
    _preemptiveDefaultMuteActive = false;
    _preemptiveDefaultMuteSafetyTimer?.cancel();
    _preemptiveDefaultMuteSafetyTimer = null;
    // ISSUE 1(b) — a real resolution just happened (this method's whole
    // purpose), so any pending KB-wait diagnostic ceiling for THIS
    // utterance is no longer relevant.
    _kbAnswerWaitSafetyTimer?.cancel();
    _kbAnswerWaitSafetyTimer = null;
    _log_('trigger buffers cleared (function call succeeded: $reason)');
  }

  /// Called from [_onInputTranscription] on EVERY transcript chunk (no
  /// "activation" gate — a request can start the conversation at any point).
  /// Accumulates [textChunk] into the current utterance's buffer and, once
  /// [_looksLikeViewEstimateRequest] recognizes it, fires view_estimate
  /// directly — UNLESS [_lastViewEstimateActivityAt] shows Gemini (or a
  /// previous deterministic trigger) already handled view_estimate within
  /// [_viewEstimateDebounce]. Resolves at most once per utterance — see
  /// [_viewEstimateDetectionResolvedForCurrentUtterance].
  void _maybeTriggerViewEstimate(String textChunk) {
    // P0 FIX — see [_maybeTriggerDeterministic]'s matching guard/doc
    // comment: the same hard "one trigger per utterance" rule, applied
    // here since this predates and isn't routed through that shared
    // engine.
    if (_utteranceAlreadyResolvedByTrigger) return;
    if (_viewEstimateDetectionResolvedForCurrentUtterance) return;
    _viewEstimateDetectionBuffer = '$_viewEstimateDetectionBuffer $textChunk'.trim();

    // See the same check in [_maybeTriggerDeterministic].
    if (_forcedIntentTrigger != 'view_estimate' && !_looksLikeViewEstimateRequest(_viewEstimateDetectionBuffer)) {
      return;
    }

    final transcript = _viewEstimateDetectionBuffer;
    final now = DateTime.now();
    final lastActivity = _lastViewEstimateActivityAt;
    if (lastActivity != null && now.difference(lastActivity) < _viewEstimateDebounce) {
      _viewEstimateDetectionResolvedForCurrentUtterance = true;
      _pipelineLog(
        'matched_not_fired',
        'trigger=view_estimate reason=debounce (ran ${now.difference(lastActivity).inMilliseconds}ms ago — assumes it '
            'is already being handled)',
      );
      _log_(
        'DETERMINISTIC VIEW ESTIMATE TRIGGER: pattern matched ("$transcript") but view_estimate ran '
        '${now.difference(lastActivity).inMilliseconds}ms ago (within the ${_viewEstimateDebounce.inSeconds}s '
        'debounce) — GEMINI already handling this, staying out of the way.',
      );
      return;
    }

    final jobId = widget.jobId;
    if (jobId == null) {
      _viewEstimateDetectionResolvedForCurrentUtterance = true;
      _log_(
        'DETERMINISTIC VIEW ESTIMATE TRIGGER: pattern matched ("$transcript") but no job_id known (standalone '
        'mode) — skipping.',
      );
      return;
    }

    _viewEstimateDetectionResolvedForCurrentUtterance = true;
    // Claimed immediately, before the async dispatch call even starts, so a
    // transcript chunk arriving a moment later (still describing the same
    // utterance) can't also see a "stale" _lastViewEstimateActivityAt and
    // race a second trigger.
    _lastViewEstimateActivityAt = now;
    // PART G item 3 — see [_maybeTriggerDeterministic]'s matching comment:
    // interrupt HERE, the instant the match is confirmed, not only later
    // inside [_informGeminiToSpeakVerbatim] after the dispatch resolves.
    _interruptGeminiForDeterministicTrigger('view_estimate');
    _log_(
      'DETERMINISTIC VIEW ESTIMATE TRIGGER: pattern matched ("$transcript") with no recent view_estimate '
      'activity — firing view_estimate directly, not waiting for Gemini.',
    );
    debugPrint(
      'GEMINI DETERMINISTIC TRIGGER: firing view_estimate directly (app-side pattern detection, Gemini did '
      'not call it)',
    );
    unawaited(_executeDeterministicViewEstimate(jobId: jobId));
  }

  /// Directly executes `view_estimate` through the SAME dispatcher every
  /// genuine server-sent toolCall already goes through
  /// ([dispatchGeminiFunctionCall]) — bypassing Gemini's own decision to
  /// call it. This is [_maybeTriggerViewEstimate]'s actual dispatch step,
  /// same "deterministic pattern detection, don't wait for the LLM's own
  /// judgment" principle used for every other deterministic trigger in this
  /// file.
  ///
  /// On success, also arms the go_back cooldown exactly like a genuine
  /// Gemini-issued `view_*` success does in [_handleToolCall] — the
  /// technician was just navigated to the Estimate screen either way, so
  /// the same "don't let an unprompted go_back immediately pop it back off"
  /// protection applies regardless of which path opened it.
  Future<void> _executeDeterministicViewEstimate({required String jobId}) async {
    // ISSUE 2 — see [_dispatchGenerationCounter]'s doc comment.
    final myDispatchGeneration = _beginNewDispatchGeneration();
    Map<String, dynamic> result;
    _beginFunctionCallInFlight('deterministic view_estimate');
    try {
      result = await _pipelineDispatch(
        name: 'view_estimate',
        source: 'deterministic',
        call: () => dispatchGeminiFunctionCall(
          ref: ref,
          cameraSession: _cameraSession,
          navigationSession: _navigationSession,
          name: 'view_estimate',
          args: {'job_id': jobId},
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('GEMINI DETERMINISTIC TRIGGER ERROR (view_estimate): $e\n$stackTrace');
      _log_('DETERMINISTIC VIEW ESTIMATE TRIGGER: view_estimate FAILED: $e');
      return;
    } finally {
      _endFunctionCallInFlight('deterministic view_estimate');
    }

    _log_('DETERMINISTIC VIEW ESTIMATE TRIGGER: view_estimate succeeded: $result');
    debugPrint('GEMINI DETERMINISTIC TRIGGER: view_estimate succeeded');
    _clearAllTriggerBuffersAfterSuccess('deterministic view_estimate');
    _recordDispatchSucceeded(myDispatchGeneration, 'view_estimate');
    _updateScreenTaskForToolCall('view_estimate', result);

    if (_viewResultNavigated(result)) {
      _lastViewFunctionSucceededAt = DateTime.now();
      _intentionalGoBackHeardSinceLastView = false;
      _currentViewScreenName = 'view_estimate';
    }

    if (_discardIfStaleDispatch(generation: myDispatchGeneration, triggerName: 'view_estimate')) return;
    _informGeminiOfDeterministicViewEstimate(result: result);
  }

  /// Sends Gemini a `clientContent` turn describing what the deterministic
  /// view_estimate trigger just did. Hands Gemini the real estimate data
  /// from [result] so its own conversation can speak the estimate details,
  /// since the navigation (and the data lookup) already happened whether or
  /// not Gemini itself decided to call view_estimate.
  void _informGeminiOfDeterministicViewEstimate({required Map<String, dynamic> result}) {
    final text = result['status'] == 'already_on_screen'
        ? _alreadyOnScreenSpokenText('view_estimate')
        : _buildViewEstimateSpokenText(result);
    _informGeminiToSpeakVerbatim(text, reason: 'deterministic view_estimate');
  }

  /// The dispatcher's view_* no-op guard (`_pushUnlessAlreadyOnTop` in
  /// `gemini_function_dispatcher.dart`) returns `already_on_screen` instead
  /// of stacking a duplicate — say so plainly rather than "the invoice is
  /// up", which would read as though it just navigated again.
  String _alreadyOnScreenSpokenText(String name) {
    final label = switch (name) {
      'view_estimate' => 'the estimate',
      'view_change_orders' => 'the change orders',
      'view_invoice' => 'the invoice',
      'view_job_history' => 'the job history',
      _ => 'that screen',
    };
    return "We're already on $label.";
  }

  /// See the repeat check at the top of [_informGeminiToSpeakVerbatim].
  ({String text, DateTime at})? _lastNoChangeStatusLine;
  static const Duration _noChangeRepeatWindow = Duration(seconds: 10);
  static const String _noChangeRepeatAck = 'Yep, still there.';

  /// Lines that report "nothing changed" rather than an action taken:
  /// [_alreadyOnScreenSpokenText], go_back's already-home reply, and
  /// get_current_screen's answers ([_describeCurrentScreen]).
  bool _isNoChangeStatusLine(String text) =>
      text.startsWith("We're already on ") ||
      text == "You're already on the job details screen." ||
      text.startsWith("You're currently on ") ||
      text == "You're on the main job details screen.";

  /// Whether a view_* result actually put a new screen on top — `false` for
  /// an error or the dispatcher's `already_on_screen` no-op, neither of
  /// which should re-arm the go_back cooldown (re-arming it on a redundant
  /// fire is part of what made "go back" look like it did nothing).
  bool _viewResultNavigated(Map<String, dynamic> result) =>
      !result.containsKey('error') && result['status'] != 'already_on_screen';

  /// CONFIRMED ghost-call bug: broad, NOT exact-phrase, whole-word/phrase
  /// pattern match for "the technician wants to know about this job" — same
  /// normalization/padding approach as [_looksLikeViewEstimateRequest]. A
  /// false positive here only costs an extra read-only lookup + an
  /// informational clientContent message, never a write.
  bool _looksLikeGetJobDetailsRequest(String text) {
    // P0 FIX — see [_TranscriptTrigger.matches]'s doc comment: shared
    // stem/filler/negation-aware matching instead of a literal substring check.
    final phraseMatch = matchAnyTriggerPhrase(text, _getJobDetailsIndicatorPhrases);
    if (phraseMatch == null) return false;
    if (!phraseMatch.exact) {
      debugPrint('FUZZY TRIGGER MATCH [get_job_details]: ${phraseMatch.describe()} matched in "$text"');
    }
    return true;
  }

  /// Called from [_onInputTranscription] on EVERY transcript chunk — same
  /// accumulate/resolve/debounce shape as [_maybeTriggerViewEstimate], just
  /// applied to [_getJobDetailsIndicatorPhrases]/[_getJobDetailsDebounce].
  void _maybeTriggerGetJobDetails(String textChunk) {
    // P0 FIX — see [_maybeTriggerDeterministic]'s matching guard/doc
    // comment.
    if (_utteranceAlreadyResolvedByTrigger) return;
    if (_getJobDetailsDetectionResolvedForCurrentUtterance) return;
    _getJobDetailsDetectionBuffer = '$_getJobDetailsDetectionBuffer $textChunk'.trim();

    if (!_looksLikeGetJobDetailsRequest(_getJobDetailsDetectionBuffer)) return;

    final transcript = _getJobDetailsDetectionBuffer;
    final now = DateTime.now();
    final lastActivity = _lastGetJobDetailsActivityAt;
    if (lastActivity != null && now.difference(lastActivity) < _getJobDetailsDebounce) {
      _getJobDetailsDetectionResolvedForCurrentUtterance = true;
      _log_(
        'DETERMINISTIC GET JOB DETAILS TRIGGER: pattern matched ("$transcript") but get_job_details ran '
        '${now.difference(lastActivity).inMilliseconds}ms ago (within the ${_getJobDetailsDebounce.inSeconds}s '
        'debounce) — GEMINI already handling this, staying out of the way.',
      );
      return;
    }

    final jobId = widget.jobId;
    if (jobId == null) {
      _getJobDetailsDetectionResolvedForCurrentUtterance = true;
      _log_(
        'DETERMINISTIC GET JOB DETAILS TRIGGER: pattern matched ("$transcript") but no job_id known (standalone '
        'mode) — skipping.',
      );
      return;
    }

    _getJobDetailsDetectionResolvedForCurrentUtterance = true;
    _lastGetJobDetailsActivityAt = now;
    // PART G item 3 — see [_maybeTriggerDeterministic]'s matching comment.
    _interruptGeminiForDeterministicTrigger('get_job_details');
    _log_(
      'DETERMINISTIC GET JOB DETAILS TRIGGER: pattern matched ("$transcript") with no recent get_job_details '
      'activity — firing get_job_details directly, not waiting for Gemini.',
    );
    debugPrint(
      'GEMINI DETERMINISTIC TRIGGER: firing get_job_details directly (app-side pattern detection, Gemini did '
      'not call it)',
    );
    unawaited(_executeDeterministicGetJobDetails(jobId: jobId));
  }

  /// Directly executes `get_job_details` through the SAME dispatcher every
  /// genuine server-sent toolCall already goes through
  /// ([dispatchGeminiFunctionCall]) — same principle as
  /// [_executeDeterministicViewEstimate]. Unlike view_estimate, this is a
  /// pure data lookup with no screen to navigate to, so there's no
  /// `_updateScreenTaskForToolCall`/go-back-cooldown bookkeeping here.
  Future<void> _executeDeterministicGetJobDetails({required String jobId}) async {
    // ISSUE 2 — see [_dispatchGenerationCounter]'s doc comment.
    final myDispatchGeneration = _beginNewDispatchGeneration();
    Map<String, dynamic> result;
    _beginFunctionCallInFlight('deterministic get_job_details');
    try {
      result = await _pipelineDispatch(
        name: 'get_job_details',
        source: 'deterministic',
        call: () => dispatchGeminiFunctionCall(
          ref: ref,
          cameraSession: _cameraSession,
          navigationSession: _navigationSession,
          name: 'get_job_details',
          args: {'job_id': jobId},
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('GEMINI DETERMINISTIC TRIGGER ERROR (get_job_details): $e\n$stackTrace');
      _log_('DETERMINISTIC GET JOB DETAILS TRIGGER: get_job_details FAILED: $e');
      return;
    } finally {
      _endFunctionCallInFlight('deterministic get_job_details');
    }

    _log_('DETERMINISTIC GET JOB DETAILS TRIGGER: get_job_details succeeded: $result');
    debugPrint('GEMINI DETERMINISTIC TRIGGER: get_job_details succeeded');
    _clearAllTriggerBuffersAfterSuccess('deterministic get_job_details');
    _recordDispatchSucceeded(myDispatchGeneration, 'get_job_details');

    if (_discardIfStaleDispatch(generation: myDispatchGeneration, triggerName: 'get_job_details')) return;
    _informGeminiOfDeterministicGetJobDetails(result: result);
  }

  /// Sends Gemini a `clientContent` turn describing what the deterministic
  /// get_job_details trigger just did — same shape as
  /// [_informGeminiOfDeterministicViewEstimate].
  void _informGeminiOfDeterministicGetJobDetails({required Map<String, dynamic> result}) {
    // `summary` is a pre-built, ready-to-speak sentence (see `_getJobDetails`
    // in gemini_function_dispatcher.dart) with no job id or raw field names
    // in it at all — spoken directly, verbatim, never reconstructed.
    final summary = result['summary'] as String? ?? 'No details were found for this job.';
    _informGeminiToSpeakVerbatim(summary, reason: 'deterministic get_job_details');
  }

  /// Broad, NOT exact-phrase, whole-word/phrase pattern match for "the
  /// technician wants to know what screen they're on" — same
  /// normalization/padding approach as [_looksLikeViewEstimateRequest].
  bool _looksLikeGetCurrentScreenRequest(String text) {
    // P0 FIX — see [_TranscriptTrigger.matches]'s doc comment.
    final phraseMatch = matchAnyTriggerPhrase(text, _getCurrentScreenIndicatorPhrases);
    if (phraseMatch == null) {
      // Any word order — see `looksLikeCurrentScreenQuestion`.
      if (!looksLikeCurrentScreenQuestion(text)) return false;
      debugPrint('STRUCTURAL TRIGGER MATCH [get_current_screen]: screen question in "$text"');
      return true;
    }
    if (!phraseMatch.exact) {
      debugPrint('FUZZY TRIGGER MATCH [get_current_screen]: ${phraseMatch.describe()} matched in "$text"');
    }
    return true;
  }

  /// Hand-rolled deterministic trigger for get_current_screen — NOT routed
  /// through [_maybeTriggerDeterministic]/[_TranscriptTrigger] since
  /// answering doesn't call [dispatchGeminiFunctionCall] at all (see
  /// [_describeCurrentScreen]); no job_id gating either, since describing
  /// the current screen works the same in standalone mode. Same
  /// accumulate/resolve/debounce shape as [_maybeTriggerGetJobDetails]
  /// otherwise.
  void _maybeTriggerGetCurrentScreen(String textChunk) {
    // P0 FIX — see [_maybeTriggerDeterministic]'s matching guard/doc
    // comment.
    if (_utteranceAlreadyResolvedByTrigger) return;
    if (_getCurrentScreenDetectionResolvedForCurrentUtterance) return;
    _getCurrentScreenDetectionBuffer = '$_getCurrentScreenDetectionBuffer $textChunk'.trim();

    if (!_looksLikeGetCurrentScreenRequest(_getCurrentScreenDetectionBuffer)) return;

    final transcript = _getCurrentScreenDetectionBuffer;
    final now = DateTime.now();
    final lastActivity = _lastGetCurrentScreenActivityAt;
    if (lastActivity != null && now.difference(lastActivity) < _getCurrentScreenDebounce) {
      _getCurrentScreenDetectionResolvedForCurrentUtterance = true;
      _log_(
        'DETERMINISTIC GET CURRENT SCREEN TRIGGER: pattern matched ("$transcript") but get_current_screen ran '
        '${now.difference(lastActivity).inMilliseconds}ms ago (within the '
        '${_getCurrentScreenDebounce.inSeconds}s debounce) — GEMINI already handling this, staying out of the '
        'way.',
      );
      return;
    }

    _getCurrentScreenDetectionResolvedForCurrentUtterance = true;
    _lastGetCurrentScreenActivityAt = now;
    final description = _describeCurrentScreen();
    _log_(
      'DETERMINISTIC GET CURRENT SCREEN TRIGGER: pattern matched ("$transcript") with no recent '
      'get_current_screen activity — answering directly, not waiting for Gemini: $description',
    );
    _log_(
      'CURRENT SCREEN QUERY ANSWERED: heard="$transcript" screen=${_kbGateScreen().screen} answer="$description" '
      '(local, no KB / intent check)',
    );
    debugPrint(
      'GEMINI DETERMINISTIC TRIGGER: firing get_current_screen directly (app-side pattern detection, Gemini '
      'did not call it)',
    );
    _clearAllTriggerBuffersAfterSuccess('deterministic get_current_screen');
    _informGeminiOfDeterministicCurrentScreen(description);
  }

  /// Sends Gemini a `clientContent` turn describing what the deterministic
  /// get_current_screen trigger just found — same shape as
  /// [_informGeminiOfDeterministicGetJobDetails], with the plain-language
  /// [description] itself (not raw state) as the only thing Gemini is told
  /// to speak.
  void _informGeminiOfDeterministicCurrentScreen(String description) {
    _informGeminiToSpeakVerbatim(description, reason: 'deterministic get_current_screen');
  }

  /// Broad, NOT exact-phrase, whole-word/phrase pattern match for "the
  /// technician is asking what this assistant can do" — same
  /// normalization/padding approach as [_looksLikeGetCurrentScreenRequest].
  bool _looksLikeMetaCapabilityRequest(String text) {
    final normalized = text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ');
    final words = normalized.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final padded = ' ${words.join(' ')} ';
    // P0 FIX — see [_TranscriptTrigger.matches]'s doc comment. The two
    // wildcard regexes below deliberately keep running against the RAW
    // padded text: they match on sentence SHAPE, not on a stemmable
    // vocabulary, so stemming could only break them for no gain.
    final phraseMatch = matchAnyTriggerPhrase(text, _metaCapabilityIndicatorPhrases);
    if (phraseMatch != null) {
      if (!phraseMatch.exact) {
        debugPrint('FUZZY TRIGGER MATCH [meta_capability]: ${phraseMatch.describe()} matched in "$text"');
      }
      return true;
    }
    // PART G item 2 — see [_metaCapabilityWildcardShape1]'s doc comment.
    return _metaCapabilityWildcardShape1.hasMatch(padded) || _metaCapabilityWildcardShape2.hasMatch(padded);
  }

  /// PART A item 3 — hand-rolled deterministic trigger for meta/capability
  /// questions, same shape as [_maybeTriggerGetCurrentScreen] (bypasses
  /// [dispatchGeminiFunctionCall] entirely; no job_id gating, since
  /// describing capabilities works the same in standalone mode). Unlike
  /// [_informGeminiOfDeterministicCurrentScreen]'s "in your own words"
  /// instruction, [_informGeminiOfMetaCapability] tells Gemini to speak
  /// [_metaCapabilityCannedResponse] VERBATIM — the whole point of this
  /// trigger is a fixed, correct answer that can never drift into a generic
  /// "I can help with a lot of things" response, regardless of whether
  /// Gemini's own judgment (or the `toolConfig`/`mode: ANY` setup field) is
  /// actually steering it away from that.
  void _maybeTriggerMetaCapability(String textChunk) {
    // P0 FIX — see [_maybeTriggerDeterministic]'s matching guard/doc
    // comment.
    if (_utteranceAlreadyResolvedByTrigger) return;
    if (_metaCapabilityDetectionResolvedForCurrentUtterance) return;
    _metaCapabilityDetectionBuffer = '$_metaCapabilityDetectionBuffer $textChunk'.trim();

    if (!_looksLikeMetaCapabilityRequest(_metaCapabilityDetectionBuffer)) return;

    final transcript = _metaCapabilityDetectionBuffer;
    final now = DateTime.now();
    final lastActivity = _lastMetaCapabilityActivityAt;
    if (lastActivity != null && now.difference(lastActivity) < _metaCapabilityDebounce) {
      _metaCapabilityDetectionResolvedForCurrentUtterance = true;
      _log_(
        'DETERMINISTIC META CAPABILITY TRIGGER: pattern matched ("$transcript") but this canned response ran '
        '${now.difference(lastActivity).inMilliseconds}ms ago (within the ${_metaCapabilityDebounce.inSeconds}s '
        'debounce) — staying out of the way.',
      );
      return;
    }

    _metaCapabilityDetectionResolvedForCurrentUtterance = true;
    _lastMetaCapabilityActivityAt = now;
    // PART J item 1 (CONFIRMED regression via 44c910b3-flutter_run_log.txt:
    // this direct call — immediately followed by [_informGeminiOfMetaCapability]'s
    // OWN interrupt call a few lines down, with no logic in between — was
    // one of three interrupt calls firing back-to-back for a single
    // utterance, queuing three PCM reinit generations and dropping the
    // entire real response as "reinit still in flight" while generation 3
    // was in progress. Removed: [_muteImmediatelyOnFirstChunkOfUtterance]
    // already mutes unconditionally before this trigger's own logic ever
    // runs, and this trigger calls [_informGeminiToSpeakVerbatim] (which
    // interrupts again) synchronously right below with no `await` in
    // between — so this call added nothing except a redundant PCM reinit
    // attempt. (The interrupt is now idempotent per utterance regardless —
    // see [_pcmReinitIssuedForCurrentUtterance] — but removing the
    // pointless duplicate call here is still correct on its own.)
    _log_(
      'DETERMINISTIC META CAPABILITY TRIGGER: pattern matched ("$transcript") with no recent activity — '
      'answering directly with the canned capability response, not waiting for Gemini: '
      '"$_metaCapabilityCannedResponse"',
    );
    debugPrint(
      'GEMINI DETERMINISTIC TRIGGER: firing meta_capability directly (app-side pattern detection, canned '
      'response, Gemini never asked to answer this)',
    );
    _clearAllTriggerBuffersAfterSuccess('deterministic meta_capability');
    _informGeminiOfMetaCapability();
  }

  /// Sends Gemini a `clientContent` turn instructing it to speak
  /// [_metaCapabilityCannedResponse] verbatim — see
  /// [_maybeTriggerMetaCapability]'s doc comment for why this is a VERBATIM
  /// instruction (get_kb_answer's pattern) rather than
  /// [_informGeminiOfDeterministicCurrentScreen]'s "in your own words" one.
  void _informGeminiOfMetaCapability() {
    _informGeminiToSpeakVerbatim(_metaCapabilityCannedResponse, reason: 'meta_capability');
  }

  /// PART D item 1 — broad, NOT exact-phrase, whole-word/phrase pattern
  /// match for a plain greeting/presence-check, same normalization/padding
  /// approach as [_looksLikeMetaCapabilityRequest].
  bool _looksLikeAcknowledgePresenceRequest(String text) {
    // P0 FIX — see [_TranscriptTrigger.matches]'s doc comment.
    final phraseMatch = matchAnyTriggerPhrase(text, _acknowledgePresenceIndicatorPhrases);
    if (phraseMatch == null) return false;
    if (!phraseMatch.exact) {
      debugPrint('FUZZY TRIGGER MATCH [acknowledge_presence]: ${phraseMatch.describe()} matched in "$text"');
    }
    return true;
  }

  /// PART D items 1-2 — hand-rolled deterministic trigger for plain
  /// greetings/presence-checks, same shape as [_maybeTriggerMetaCapability]
  /// (bypasses [dispatchGeminiFunctionCall] entirely; fixed, canned,
  /// verbatim-spoken response; no job_id gating). Returns whether it
  /// matched/fired — its caller
  /// ([_GeminiLiveTestScreenState._onInputTranscription]) uses this to
  /// skip [_maybeMuteImmediatelyForSuspectedQuestion] ENTIRELY for this
  /// chunk when it did, per this trigger's own doc comment: a "?" or
  /// "can you" alone must never be enough to fall into the mute-and-wait
  /// path when what's actually being said is just "can you hear me."
  /// Deliberately checked (and, on a match, consumed) BEFORE the
  /// preemptive-mute check ever runs, not after — see the CONFIRMED
  /// regression this fixes in [_acknowledgePresenceIndicatorPhrases]'s doc
  /// comment.
  bool _maybeTriggerAcknowledgePresence(String textChunk) {
    // P0 FIX — see [_maybeTriggerDeterministic]'s matching guard/doc
    // comment. `false`, not `true`: this utterance was resolved by
    // something ELSE, not by acknowledge_presence itself, so callers must
    // not read this as "acknowledge_presence handled it."
    if (_utteranceAlreadyResolvedByTrigger) return false;
    if (_acknowledgePresenceResolvedForCurrentUtterance) return true;
    _acknowledgePresenceDetectionBuffer = '$_acknowledgePresenceDetectionBuffer $textChunk'.trim();
    if (!_looksLikeAcknowledgePresenceRequest(_acknowledgePresenceDetectionBuffer)) return false;

    _acknowledgePresenceResolvedForCurrentUtterance = true;
    // PART J item 1 — see [_maybeTriggerMetaCapability]'s matching comment
    // (44c910b3-flutter_run_log.txt): this WAS a direct
    // [_interruptGeminiForDeterministicTrigger] call here, immediately
    // followed by [_informGeminiOfAcknowledgePresence]'s own interrupt call
    // a few lines down with no logic in between — the literal duplicate
    // call that was one of the three interrupts firing per utterance.
    // Removed for the same reason: [_muteImmediatelyOnFirstChunkOfUtterance]
    // already mutes unconditionally before this trigger's own logic runs,
    // and [_informGeminiToSpeakVerbatim] below interrupts again
    // synchronously with no `await` gap to protect against.
    _log_(
      'DETERMINISTIC ACKNOWLEDGE PRESENCE TRIGGER: pattern matched ("$_acknowledgePresenceDetectionBuffer") — '
      'answering instantly with the canned response, never reaching the preemptive-question-mute path.',
    );
    debugPrint(
      'GEMINI DETERMINISTIC TRIGGER: firing acknowledge_presence directly (app-side pattern detection, canned '
      'response, no mute/wait)',
    );
    _clearAllTriggerBuffersAfterSuccess('deterministic acknowledge_presence');
    _informGeminiOfAcknowledgePresence();
    return true;
  }

  /// Sends Gemini a `clientContent` turn instructing it to speak
  /// [_acknowledgePresenceCannedResponse] verbatim — same VERBATIM pattern
  /// as [_informGeminiOfMetaCapability].
  void _informGeminiOfAcknowledgePresence() {
    _informGeminiToSpeakVerbatim(_nextAcknowledgePresenceResponse(), reason: 'acknowledge_presence');
  }

  /// Shared dispatch step for every [_TranscriptTrigger] — see that class's
  /// doc comment for why this one implementation replaces six more
  /// hand-rolled `_executeDeterministicX` methods. Runs [trigger.name]
  /// through the SAME dispatcher every genuine server-sent toolCall already
  /// goes through ([dispatchGeminiFunctionCall]), then the exact same
  /// generic post-success bookkeeping [_handleToolCall] runs for a genuine
  /// call: a screen-task update (a no-op for any non-camera function name —
  /// see [_updateScreenTaskForToolCall]) and go-back cooldown arming for any
  /// `view_*` success (see [_goBackCooldownDuration]'s doc comment).
  Future<void> _executeDeterministic(
    _TranscriptTrigger trigger, {
    required Map<String, dynamic> args,
    required String Function(Map<String, dynamic> result) buildSpokenText,
  }) async {
    // DIAGNOSTIC (added after the "zero deterministic triggers fired"
    // regression report): unconditional entry log — this MUST print for
    // every single trigger firing, camera or not, since `unawaited(
    // _executeDeterministic(...))` at the `_maybeTriggerDeterministic` call
    // site means a synchronous throw before this point wouldn't reach here
    // at all; if a future report says "no output whatsoever" again, that
    // proves the break is in `_maybeTriggerDeterministic` (matches/guard/
    // debounce) or upstream in `_onInputTranscription`, NOT in this method.
    debugPrint('PHOTO TIMING [_executeDeterministic]: ENTERED for trigger="${trigger.name}" args=$args');
    // ISSUE 2 — see [_dispatchGenerationCounter]'s doc comment: captured
    // BEFORE the dispatch below, so this represents exactly when the
    // technician's request for `trigger.name` began, not when its (possibly
    // much slower) backend call happens to finish.
    final myDispatchGeneration = _beginNewDispatchGeneration();
    Map<String, dynamic> result;
    _beginFunctionCallInFlight('deterministic ${trigger.name}');
    try {
      // CONFIRMED gap (real 22.6s open_camera attempt produced no 5s
      // acknowledgment and no 15s timeout): this shared engine backs EVERY
      // `_deterministicTriggers` entry, including `open_camera` — and this
      // call used to go straight to `dispatchGeminiFunctionCall`, bypassing
      // `_dispatchWithOpenCameraSafeguards` entirely. Since this codebase's
      // own confirmed finding is that Gemini calls functions natively
      // approximately never (see this class's doc comment on
      // `_deterministicTriggers`), the deterministic path here — not
      // `_handleToolCall`'s toolCall branch — is the one real `open_camera`
      // calls actually take in practice, so the safeguards have to live
      // here too, not just there. `_dispatchWithOpenCameraSafeguards`
      // no-ops straight through to `dispatchGeminiFunctionCall` for every
      // OTHER trigger name, so this is a pure superset for every non-camera
      // trigger using this same shared method.
      debugPrint('PHOTO TIMING [_executeDeterministic]: about to call _dispatchWithOpenCameraSafeguards for "${trigger.name}"');
      result = await _pipelineDispatch(
        name: trigger.name,
        source: _forcedIntentTrigger == trigger.name ? 'deterministic(fuzzy intent)' : 'deterministic',
        call: () => _dispatchWithOpenCameraSafeguards(name: trigger.name, args: args),
      );
      debugPrint('PHOTO TIMING [_executeDeterministic]: _dispatchWithOpenCameraSafeguards RETURNED for "${trigger.name}": $result');
    } catch (e, stackTrace) {
      debugPrint('PHOTO TIMING [_executeDeterministic]: EXCEPTION for "${trigger.name}": $e');
      debugPrint('GEMINI DETERMINISTIC TRIGGER ERROR (${trigger.name}): $e\n$stackTrace');
      _log_('DETERMINISTIC ${trigger.name.toUpperCase()} TRIGGER: ${trigger.name} FAILED: $e');
      // A KB lookup that genuinely failed (network/timeout — not a "no
      // match") used to end here in silence; say so instead, unless a newer
      // request already superseded it.
      if (trigger.name == 'get_kb_answer' &&
          !_discardIfStaleDispatch(generation: myDispatchGeneration, triggerName: trigger.name)) {
        _informGeminiToSpeakVerbatim(_kbHardErrorSpokenText(e.toString()), reason: 'deterministic get_kb_answer error');
      }
      return;
    } finally {
      _endFunctionCallInFlight('deterministic ${trigger.name}');
    }

    _log_('DETERMINISTIC ${trigger.name.toUpperCase()} TRIGGER: ${trigger.name} succeeded: $result');
    debugPrint('GEMINI DETERMINISTIC TRIGGER: ${trigger.name} succeeded');
    if (!result.containsKey('error')) {
      _clearAllTriggerBuffersAfterSuccess('deterministic ${trigger.name}');
      // ISSUE 2 — record success BEFORE the staleness check below, so a
      // newer dispatch's own success is visible to it immediately (and, in
      // the reverse case, so THIS dispatch correctly becomes the new
      // "latest" for any older, still-pending dispatch to recognize itself
      // as stale against once it finally resolves).
      _recordDispatchSucceeded(myDispatchGeneration, trigger.name);
    }

    _updateScreenTaskForToolCall(trigger.name, result);
    if (_isNavigatingScreenFunction(trigger.name) && _viewResultNavigated(result)) {
      _lastViewFunctionSucceededAt = DateTime.now();
      _intentionalGoBackHeardSinceLastView = false;
      _currentViewScreenName = trigger.name;
      _log_(
        'GO BACK COOLDOWN: "${trigger.name}" succeeded (deterministic) — go_back cooldown armed for '
        '${_goBackCooldownDuration.inSeconds}s unless an intentional go-back phrase is heard first.',
      );
    }

    // ISSUE 2 (HIGH PRIORITY, CONFIRMED via f5a8bd8b-flutter_run_log.txt) —
    // see [_discardIfStaleDispatch]'s doc comment: a newer request (e.g.
    // open_camera) may have already succeeded and started speaking its own
    // confirmation while THIS dispatch (e.g. an abandoned get_kb_answer
    // question) was still in flight. Speaking now would interrupt/overwrite
    // that current confirmation mid-word with a stale, unrelated answer.
    if (_discardIfStaleDispatch(generation: myDispatchGeneration, triggerName: trigger.name)) {
      _pipelineLog('reply_skipped', 'function=${trigger.name} reason=stale (a newer request superseded it)');
      return;
    }
    // Set by [_updateScreenTaskForToolCall] for an open_camera cancelled on
    // behalf of something that speaks (or shows) its own outcome.
    if (result['silent'] == true) {
      _pipelineLog('reply_skipped', 'function=${trigger.name} reason=result marked silent');
      _log_('DETERMINISTIC ${trigger.name.toUpperCase()} TRIGGER: result marked silent — not speaking');
      return;
    }
    _informGeminiToSpeakVerbatim(buildSpokenText(result), reason: 'deterministic ${trigger.name}');
  }

  /// PART F (replaces the old behavior — dumping the raw result JSON into
  /// a `[SYSTEM: ...]` instruction and letting Gemini reconstruct its own
  /// phrasing, which is exactly the loose framing that let it ramble):
  /// delegates to [_buildSpokenTextForResult], the single local text
  /// builder shared with [_handleToolCall]'s genuine-toolCall path,
  /// falling back to the already-natural "I've $appAction." for any
  /// `name` that builder doesn't specifically handle. Gemini then speaks
  /// whatever this returns verbatim, via [_informGeminiToSpeakVerbatim]'s
  /// tight framing. [humanAction] is unused now (kept only so every
  /// existing call site's `buildSpokenText:` callback needs no changes).
  String _defaultDeterministicSpokenText({
    required String name,
    required String humanAction,
    required String appAction,
    required Map<String, dynamic> result,
  }) {
    return _buildSpokenTextForResult(name: name, result: result) ?? "I've $appAction.";
  }

  /// PART F — the single, local source of truth for "what should we say
  /// after function [name] returns [result]", used by BOTH paths that can
  /// trigger a function: every deterministic app-side trigger (via
  /// [_defaultDeterministicSpokenText] or directly, for the hand-rolled
  /// triggers) AND a genuine Gemini-initiated toolCall (see
  /// [_handleToolCall]). Replaces asking Gemini to freely narrate/
  /// paraphrase its own function results — this builds the exact sentence
  /// locally, from the real structured data, and Gemini speaks it
  /// verbatim via [_informGeminiToSpeakVerbatim]. Returns `null` when
  /// nothing should be said (a deliberately silent no-op, e.g. a blocked
  /// unprompted go_back, or a function this builder has no specific
  /// wording for).
  String? _buildSpokenTextForResult({required String name, required Map<String, dynamic> result}) {
    if (result.containsKey('error')) {
      if (name == 'get_kb_answer') return _kbHardErrorSpokenText('${result['error']}');
      return "Sorry, something went wrong doing that — please try again.";
    }
    if (result['status'] == 'already_on_screen') return _alreadyOnScreenSpokenText(name);
    switch (name) {
      case 'get_job_details':
        return (result['summary'] as String?) ?? 'No details were found for this job.';
      case 'get_kb_answer':
        return _buildKbAnswerSpokenText(result);
      case 'get_job_timeline_answer':
        return _buildJobTimelineSpokenText(result);
      case 'view_estimate':
        return _buildViewEstimateSpokenText(result);
      case 'view_change_orders':
        return _buildViewChangeOrdersSpokenText(result);
      case 'view_invoice':
        // PART H item 2: natural, coworker-toned confirmation replacing the
        // old flat "I've opened the invoice for you." status-log line.
        return "The invoice is up — anything you'd like me to check on it?";
      case 'view_job_history':
        return "The job history screen is open — want me to walk you through what's happened so far?";
      case 'go_back':
        return _buildGoBackSpokenText(result);
      case 'open_camera':
        return result['status'] == 'camera_open'
            ? "Camera's open — ready when you are."
            : ((result['message'] as String?) ?? "I couldn't open the camera — please try again.");
      case 'capture_photo':
        return result['status'] == 'captured'
            ? "Got it — I've taken the photo. Keep it, or retake it?"
            : ((result['message'] as String?) ?? "I couldn't take that photo — please try again.");
      case 'confirm_photo_upload':
        // "Keep" only — nothing is uploaded until the one-time photo-note
        // ask (appended when that flow was just entered) is answered, so
        // this must not claim an upload (see [_startPhotoNoteUpload]).
        return 'Got it — keeping that photo.${_photoNotePromptSuffix()}';
      case 'retake_photo':
        return "I've discarded that photo — go ahead and take another one when you're ready.";
      case 'get_last_photo':
        return (result['found'] as bool? ?? false)
            ? "Here's the last photo taken on this job."
            : 'No photos have been taken on this job yet.';
      case 'site_condition':
        return "I've saved that note.";
      case 'get_current_screen':
        return result['screen_description'] as String?;
      default:
        return null;
    }
  }

  /// See [_buildSpokenTextForResult]'s `get_kb_answer` case (get_kb_answer's
  /// own EARLY/intentional match, not the catch-all — see
  /// [_buildKbCatchAllSpokenText] for that one) — the already KB-vetted
  /// `answer` field, spoken exactly as returned via
  /// [_informGeminiToSpeakVerbatim]'s tight verbatim framing, decline
  /// included, unchanged.
  /// When the current/most recent get_kb_answer dispatch started — only for
  /// the elapsed time in the KB TIMEOUT/ERROR SPOKEN line.
  DateTime? _kbCallStartedAt;

  /// A get_kb_answer call that FAILED (network error, or the
  /// `kbAnswerRequestTimeout` bound) — distinct from a genuine no-match,
  /// which says [_kbNoAnswerText]. Logs the KB TIMEOUT/ERROR SPOKEN marker.
  String _kbHardErrorSpokenText(String error) {
    final startedAt = _kbCallStartedAt;
    final elapsedMs = startedAt == null ? -1 : DateTime.now().difference(startedAt).inMilliseconds;
    final outcome = error.contains('TimeoutException') ? 'timeout_reduced' : 'error_spoken';
    _log_('KB TIMEOUT/ERROR SPOKEN: trigger=get_kb_answer elapsedMs=$elapsedMs outcome=$outcome error=$error');
    return "Sorry, I couldn't reach the knowledge base right now — try again in a moment.";
  }

  String _buildKbAnswerSpokenText(Map<String, dynamic> result) {
    final answer = result['answer'] as String?;
    // KB miss only — a found answer is spoken exactly as returned, unchanged.
    if (answer == null || _kbNoMatchLiteralAnswers.contains(answer)) {
      _log_('KB MISS: get_kb_answer returned no match — speaking the explicit no-answer line');
      return _kbNoAnswerText;
    }
    return answer;
  }

  /// See [_buildSpokenTextForResult]'s `view_estimate` case — built from
  /// the real `estimate` data `_viewEstimate` in
  /// `gemini_function_dispatcher.dart` already returns (id/status/
  /// total_amount/line_items), not left for a model to phrase.
  String _buildViewEstimateSpokenText(Map<String, dynamic> result) {
    final estimate = result['estimate'] as Map<String, dynamic>?;
    if (estimate == null) return "I've opened the estimate — there isn't one on this job yet.";
    // PART H item 2: natural, coworker-toned confirmation replacing the old
    // data-recited "It's $status, totaling $total, with N line items."
    // status-log phrasing.
    return "Here's the estimate — want me to read out any part of it?";
  }

  /// See [_buildSpokenTextForResult]'s `view_change_orders` case — built
  /// from the real `change_orders` list `_viewChangeOrders` in
  /// `gemini_function_dispatcher.dart` already returns.
  String _buildViewChangeOrdersSpokenText(Map<String, dynamic> result) {
    final changeOrders = (result['change_orders'] as List<dynamic>?) ?? const [];
    if (changeOrders.isEmpty) return "I've opened the change orders — there aren't any on this job yet.";
    // PART H item 2: natural, coworker-toned confirmation replacing the old
    // data-recited "There are N on this job." status-log phrasing.
    return "Change orders are open. Let me know if you want details on any of them.";
  }

  /// See [_buildSpokenTextForResult]'s `get_job_timeline_answer` case —
  /// built from the real, chronologically-ordered `events` list
  /// `_getJobTimelineAnswer` in `gemini_function_dispatcher.dart` already
  /// returns (oldest first, so the LAST entry is the most recent). HONEST
  /// LIMITATION: without a model in the loop to interpret which specific
  /// event answers an arbitrary question ("when did we arrive" vs. "what
  /// have we done"), this reports the total count plus the single most
  /// recent event as a reasonable, deterministic default rather than
  /// guessing intent.
  String _buildJobTimelineSpokenText(Map<String, dynamic> result) {
    final events = (result['events'] as List<dynamic>?) ?? const [];
    if (events.isEmpty) return "There's no logged activity on this job yet.";
    final latest = events.last as Map<String, dynamic>;
    final description = latest['description'] as String? ?? 'an event';
    final eventWord = events.length == 1 ? 'event' : 'events';
    return "There ${events.length == 1 ? 'is' : 'are'} ${events.length} logged $eventWord on this job. The most "
        'recent: $description.';
  }

  /// See [_buildSpokenTextForResult]'s `go_back` case — `blocked_cooldown`
  /// is a deliberate silent no-op (see [_isGoBackInCooldown]'s doc
  /// comment: an UNPROMPTED go_back right after a view_* succeeded), never
  /// spoken.
  String? _buildGoBackSpokenText(Map<String, dynamic> result) {
    final status = result['status'] as String?;
    if (status == 'blocked_cooldown') return null;
    // PART H item 2: natural, coworker-toned confirmation replacing the old
    // "Okay, heading back." phrasing.
    if (status == 'navigated_back') return "Okay, I've taken you back.";
    return "You're already on the job details screen.";
  }

  /// Called from [_onInputTranscription] on EVERY transcript chunk for each
  /// [_deterministicTriggers] entry — same accumulate/resolve/debounce shape
  /// as [_maybeTriggerViewEstimate]/[_maybeTriggerGetJobDetails], generalized
  /// via [_TranscriptTrigger] instead of hand-rolled per function. [guard],
  /// when given, must also return `true` before this fires (used by
  /// open_camera to skip while a camera/photo flow is already active).
  void _maybeTriggerDeterministic(
    _TranscriptTrigger trigger,
    String textChunk, {
    required bool requireJobId,
    required Map<String, dynamic> Function(String transcript, String? jobId) buildArgs,
    required String Function(Map<String, dynamic> result) buildSpokenText,
    bool Function()? guard,
    // PART N item 1 (CONFIRMED via 3ebd9995-flutter_run_log.txt: "Let's take
    // a photo," said while the camera was ALREADY open, correctly failed
    // this exact guard — but then silently fell through to nothing being
    // said at all, which is how the very NEXT thing that DID match
    // (capture_photo's now-fixed over-permissive loose matcher) got to fire
    // an unconfirmed shutter capture unnoticed). Called instead of the
    // silent skip below when the utterance genuinely matched [trigger] but
    // [guard] said no — e.g. open_camera heard again while already live —
    // so restating the original request gets an explicit spoken
    // clarification instead of silence a DIFFERENT trigger might wrongly
    // fill. Marks [trigger] resolved for this utterance either way, so
    // nothing else (the KB catch-all, the unrecognized-utterance timeout)
    // also tries to answer it.
    void Function()? onGuardFailed,
  }) {
    // P0 FIX (CONFIRMED via a real session: "Show me the estimate. Try me
    // again. For example, show the job history or take a photo." — one
    // contaminated transcript chunk containing three DIFFERENT triggers'
    // phrases — fired view_estimate, view_job_history, AND open_camera in
    // sequence within 44ms, each navigating over the last). HARD RULE,
    // independent of whatever caused that specific contamination: the
    // instant ANY trigger — this one or any other, hand-rolled or via this
    // shared engine — resolves an utterance for real
    // ([_clearAllTriggerBuffersAfterSuccess] is the ONE place that sets
    // [_utteranceAlreadyResolvedByTrigger]), every OTHER trigger stops
    // being evaluated against that SAME utterance, full stop. Checked
    // first, before even buffering this chunk — once resolved, there is
    // nothing left for any other trigger to usefully accumulate toward.
    if (_utteranceAlreadyResolvedByTrigger) {
      debugPrint('DETERMINISTIC SKIP: trigger=${trigger.name} — this utterance was already resolved by a different trigger');
      return;
    }
    if (trigger.resolvedForCurrentUtterance) {
      debugPrint('DETERMINISTIC SKIP: trigger=${trigger.name} already resolved for this utterance');
      return;
    }
    trigger.buffer = '${trigger.buffer} $textChunk'.trim();

    // [_maybeResolveByIntent] already matched this utterance to this
    // trigger by keyword/similarity; everything after the phrase check —
    // guard, debounce, job_id, dispatch, reply — still applies unchanged.
    final forcedByIntent = _forcedIntentTrigger == trigger.name;
    if (!forcedByIntent && !trigger.matches(trigger.buffer)) {
      debugPrint(
        'DETERMINISTIC NO MATCH: trigger=${trigger.name} pattern=${trigger.phrases} against '
        "text='${trigger.buffer}'",
      );
      return;
    }
    if (guard != null && !guard()) {
      _pipelineLog('matched_not_fired', 'trigger=${trigger.name} reason=guard (screenTask=${_screenTask.name})');
      debugPrint('DETERMINISTIC SKIP: trigger=${trigger.name} matched but guard() returned false');
      // P0 FIX (CONFIRMED in a real session: every "Take the photo." while
      // the camera was open hit open_camera's guard, which marked the
      // utterance resolved, so the one-trigger-per-utterance loop never
      // reached capture_photo — capture was impossible once open). A
      // guard-failed match is a NON-event: it neither marks this trigger
      // resolved nor commits the utterance. Its clarification reply is only
      // queued, and [_onInputTranscription] speaks it after the loop only if
      // no other trigger actually committed this chunk.
      if (onGuardFailed != null && !_guardFailedReplySpokenThisUtterance) {
        _pendingGuardFailedReply ??= onGuardFailed;
      }
      return;
    }

    final transcript = trigger.buffer;
    final now = DateTime.now();
    final lastActivity = trigger.lastActivityAt;
    if (lastActivity != null && now.difference(lastActivity) < _deterministicTriggerDebounce) {
      trigger.resolvedForCurrentUtterance = true;
      _pipelineLog(
        'matched_not_fired',
        'trigger=${trigger.name} reason=debounce (${trigger.name} ran ${now.difference(lastActivity).inMilliseconds}ms '
            'ago — assumes it is already being handled)',
      );
      _log_(
        'DETERMINISTIC ${trigger.name.toUpperCase()} TRIGGER: pattern matched ("$transcript") but '
        '${trigger.name} ran ${now.difference(lastActivity).inMilliseconds}ms ago (within the '
        '${_deterministicTriggerDebounce.inSeconds}s debounce) — GEMINI already handling this, staying out of '
        'the way.',
      );
      return;
    }

    final jobId = widget.jobId;
    if (requireJobId && jobId == null) {
      trigger.resolvedForCurrentUtterance = true;
      _pipelineLog('matched_not_fired', 'trigger=${trigger.name} reason=no job_id (standalone session)');
      _log_(
        'DETERMINISTIC ${trigger.name.toUpperCase()} TRIGGER: pattern matched ("$transcript") but no job_id '
        'known (standalone mode) — skipping.',
      );
      return;
    }

    trigger.resolvedForCurrentUtterance = true;
    trigger.lastActivityAt = now;
    _pipelineLog('matched_firing', 'trigger=${trigger.name}${forcedByIntent ? ' (via fuzzy intent layer)' : ''} text="$transcript"');
    // PART G item 3 (CONFIRMED regression: a small residual audio leak
    // measured on action triggers too, not just acknowledge_presence/
    // meta_capability). Root cause found here specifically: unlike those
    // two hand-rolled triggers, this shared engine never called the
    // interrupt at MATCH time — only much later, inside
    // [_informGeminiToSpeakVerbatim], after `_executeDeterministic`'s
    // `await`ed dispatch (navigation/camera/KB lookup) had already
    // resolved. If the whole utterance arrives as one transcription chunk
    // (common for a short phrase), this trigger matches and bypassed the
    // OLD conditional mute-arming entirely (see
    // `_otherSpecificTriggerAlreadyResolvedThisUtterance`; superseded by
    // PART I item 1's unconditional [_muteImmediatelyOnFirstChunkOfUtterance]
    // call, which no longer depends on this), leaving
    // Gemini's own organic audio completely unmuted for the ENTIRE dispatch
    // duration. Interrupting HERE, the instant the match is confirmed —
    // same as acknowledge_presence/meta_capability — closes that gap.
    _interruptGeminiForDeterministicTrigger(trigger.name);
    _log_(
      'DETERMINISTIC ${trigger.name.toUpperCase()} TRIGGER: pattern matched ("$transcript") with no recent '
      '${trigger.name} activity — firing ${trigger.name} directly, not waiting for Gemini.',
    );
    debugPrint(
      'GEMINI DETERMINISTIC TRIGGER: firing ${trigger.name} directly (app-side pattern detection, Gemini did '
      'not call it)',
    );
    unawaited(_executeDeterministic(trigger, args: buildArgs(transcript, jobId), buildSpokenText: buildSpokenText));
  }

  /// "Go to Job Details" as a named destination — always lands on Job
  /// Details, whatever the back stack holds (see `navigation_destination.dart`
  /// for the 1b059096 evidence). Available on every screen, like go_back,
  /// and never gated by the per-screen registry. Plain destination-less
  /// "go back" / "previous screen" never match here and keep going through
  /// [_maybeDetectIntentionalGoBack] exactly as before.
  ///
  /// Already on Job Details it stands down entirely, so "show me the job
  /// details" there still reads the summary (get_job_details) and "go home"
  /// still gets go_back's own "already there" reply.
  void _maybeTriggerJobDetailsDestination(String textChunk) {
    if (_jobDetailsDestinationFiredThisUtterance) return;
    final overridingGoBack = _goBackFiredThisUtterance;
    if (_anyTriggerCommittedThisUtterance && !overridingGoBack) return;
    _jobDetailsDestinationBuffer = '$_jobDetailsDestinationBuffer $textChunk'.trim();
    final match = matchJobDetailsDestination(_jobDetailsDestinationBuffer);
    if (match == null) return;
    final from = _kbGateScreen().screen;
    if (!overridingGoBack && from.startsWith('JobDetailScreen')) return;

    _jobDetailsDestinationFiredThisUtterance = true;
    _jobDetailsDestinationResolvedForCurrentUtterance = true;
    _interruptGeminiForDeterministicTrigger('view_job_details');
    _log_(
      'DESTINATION TRIGGER MATCHED: view_job_details — "$_jobDetailsDestinationBuffer" names Job Details '
      '(${match.how}) on $from'
      '${overridingGoBack ? ' — overriding the generic go_back already fired for this utterance' : ''}'
      ' — navigating straight there, not one screen back',
    );
    unawaited(_executeJobDetailsDestination(overridingGoBack: overridingGoBack));
  }

  Future<void> _executeJobDetailsDestination({required bool overridingGoBack}) async {
    final jobId = widget.jobId;
    if (jobId == null) {
      _log_('DESTINATION TRIGGER: no job_id known (standalone mode) — skipping.');
      return;
    }
    final myDispatchGeneration = _beginNewDispatchGeneration();
    Map<String, dynamic> result;
    _beginFunctionCallInFlight('deterministic view_job_details');
    try {
      result = await _pipelineDispatch(
        name: 'view_job_details',
        source: 'deterministic',
        call: () async {
          // The camera sits above every screen: close it the same way a
          // spoken go_back does, then unwind the screens beneath it.
          if (_screenTask != _ScreenTask.none || _cameraSession.controller != null) {
            await _maybeCloseCameraFlowForGoBack(
              {'status': 'already_at_job_details', 'job_id': jobId},
              jobId: jobId,
              tornDownReason: 'voice_go_to_job_details',
            );
          }
          final status = _navigationSession.goToJobDetails(jobDetailRoute: activeJobDetailRoute);
          return {'status': status, 'job_id': jobId};
        },
      );
    } catch (e, stackTrace) {
      debugPrint('GEMINI DETERMINISTIC TRIGGER ERROR (view_job_details): $e\n$stackTrace');
      _log_('DESTINATION TRIGGER: view_job_details FAILED: $e');
      return;
    } finally {
      _endFunctionCallInFlight('deterministic view_job_details');
    }

    _log_('DESTINATION TRIGGER: view_job_details result=$result');
    _clearAllTriggerBuffersAfterSuccess('deterministic view_job_details');
    _recordDispatchSucceeded(myDispatchGeneration, 'view_job_details');
    if (_discardIfStaleDispatch(generation: myDispatchGeneration, triggerName: 'view_job_details')) return;
    final status = result['status'];
    final text = status == 'navigated_to_job_details' || (status == 'already_at_job_details' && overridingGoBack)
        ? "Okay — you're on the job details screen."
        : status == 'already_at_job_details'
        ? "You're already on the job details screen."
        : "I couldn't get to the job details screen — try the back arrow.";
    _informGeminiToSpeakVerbatim(text, reason: 'deterministic view_job_details');
  }

  /// FIX 2: whole-word/phrase match against [_intentionalGoBackPhrases] —
  /// same normalization/padding approach as [_looksLikeViewEstimateRequest]
  /// (lowercased, stripped to letters/spaces, space-padded substring
  /// checks), so "backpack" never matches "back" and "gone" never matches
  /// "go".
  bool _looksLikeIntentionalGoBack(String text) {
    // P0 FIX — see [_TranscriptTrigger.matches]'s doc comment. The
    // "'gone' never matches 'go'" property above still holds: the shared
    // stemmer deliberately leaves irregular past tenses alone (see
    // `_irregularStems` in `trigger_phrase_matcher.dart`).
    final phraseMatch = matchAnyTriggerPhrase(text, _intentionalGoBackPhrases);
    if (phraseMatch == null) return false;
    if (!phraseMatch.exact) {
      debugPrint('FUZZY TRIGGER MATCH [go_back]: ${phraseMatch.describe()} matched in "$text"');
    }
    _logIgnoredNegationPrefix('go_back', phraseMatch, text);
    return true;
  }

  /// Called from [_onInputTranscription] on every chunk. Serves TWO
  /// independent purposes:
  ///  1. view_* cooldown-lifting — a no-op once
  ///     [_intentionalGoBackHeardSinceLastView] is already true, or if no
  ///     `view_*` has succeeded yet ([_lastViewFunctionSucceededAt] is
  ///     `null` — there's no cooldown active to lift). Flips
  ///     [_intentionalGoBackHeardSinceLastView] the instant
  ///     [_looksLikeIntentionalGoBack] recognizes a genuine request — from
  ///     then on, [_isGoBackInCooldown] lets `go_back` through immediately.
  ///  2. The deterministic go_back trigger itself — CONFIRMED bug: this
  ///     used to fire [_executeDeterministicGoBack] ONLY while a camera/
  ///     photo task was active, relying on Gemini to call `go_back` on its
  ///     own once the cooldown above lifted for every other case. A full
  ///     real session confirmed Gemini calls ZERO functions natively, so
  ///     that reliance never paid off outside a camera flow. Now fires in
  ///     ANY context the instant [_looksLikeIntentionalGoBack] matches, same
  ///     "don't wait for the LLM's own judgment" principle as every other
  ///     deterministic trigger here, debounced against [_lastGoBackActivityAt]
  ///     so it stays out of the way if Gemini already handled it itself.
  ///     Deliberately does NOT check [_isGoBackInCooldown]: that cooldown
  ///     exists only to block an UNPROMPTED go_back Gemini might fire right
  ///     after opening a screen (see its own doc comment) — this firing is
  ///     the opposite, a genuinely just-heard "go back" request, which that
  ///     same doc comment says must never be delayed.
  void _maybeDetectIntentionalGoBack(String textChunk) {
    // P0 FIX — see [_maybeTriggerDeterministic]'s matching guard/doc
    // comment. Applied uniformly here too, including the cooldown-lifting
    // side effect below: a technician's own words genuinely belong to
    // whichever trigger already resolved this utterance, not to a second
    // one layering more state changes on top of the same breath.
    if (_utteranceAlreadyResolvedByTrigger) return;
    final viewCooldownActive = _lastViewFunctionSucceededAt != null && !_intentionalGoBackHeardSinceLastView;

    _goBackIntentDetectionBuffer = '$_goBackIntentDetectionBuffer $textChunk'.trim();
    if (!_looksLikeIntentionalGoBack(_goBackIntentDetectionBuffer)) return;

    if (viewCooldownActive) {
      _intentionalGoBackHeardSinceLastView = true;
      _log_(
        'GO BACK COOLDOWN: intentional go-back phrase detected ("$_goBackIntentDetectionBuffer") — cooldown '
        'lifted, a go_back call will now be allowed through immediately.',
      );
    }

    if (_goBackTriggerResolvedForCurrentUtterance) return;
    final now = DateTime.now();
    final lastActivity = _lastGoBackActivityAt;
    if (lastActivity != null && now.difference(lastActivity) < _goBackTriggerDebounce) {
      _goBackTriggerResolvedForCurrentUtterance = true;
      _log_(
        'DETERMINISTIC GO BACK TRIGGER: intentional phrase detected ("$_goBackIntentDetectionBuffer") but '
        'go_back ran ${now.difference(lastActivity).inMilliseconds}ms ago (within the '
        '${_goBackTriggerDebounce.inSeconds}s debounce) — GEMINI already handling this, staying out of the way.',
      );
      return;
    }
    _goBackTriggerResolvedForCurrentUtterance = true;
    _goBackFiredThisUtterance = true;
    _lastGoBackActivityAt = now;
    // PART G item 3 — see [_maybeTriggerDeterministic]'s matching comment.
    _interruptGeminiForDeterministicTrigger('go_back');
    _log_(
      'DETERMINISTIC GO BACK TRIGGER: intentional phrase detected ("$_goBackIntentDetectionBuffer") — firing '
      'go_back directly, not waiting for Gemini.',
    );
    debugPrint('GEMINI DETERMINISTIC TRIGGER: firing go_back directly (app-side pattern detection)');
    unawaited(_executeDeterministicGoBack());
  }

  /// FIX 2: whether an UNPROMPTED `go_back` toolCall should be blocked right
  /// now — see [_goBackCooldownDuration]'s doc comment for the full
  /// reasoning, and [_handleToolCall]'s `go_back` branch for where this is
  /// actually enforced. `true` only when a `view_*` succeeded within the
  /// last [_goBackCooldownDuration] AND no [_intentionalGoBackPhrases] match
  /// has been heard since — i.e. Gemini calling `go_back` on its own
  /// initiative right after opening a screen the technician just asked to
  /// see, not in response to an actual "take me back".
  bool _isGoBackInCooldown() {
    final lastView = _lastViewFunctionSucceededAt;
    if (lastView == null || _intentionalGoBackHeardSinceLastView) return false;
    return DateTime.now().difference(lastView) < _goBackCooldownDuration;
  }

  /// Every function name that pushes a real screen via
  /// [GeminiNavigationSession.push] — every `view_*` PLUS get_last_photo
  /// (pushes [PhotoViewerScreen] the same way). Used wherever the go-back
  /// cooldown/[_currentViewScreenName] bookkeeping needs to apply to "any
  /// pushed screen," not just the original four `view_*` functions.
  bool _isNavigatingScreenFunction(String name) => name.startsWith('view_') || name == 'get_last_photo';

  /// get_current_screen — describes [_screenTask]/[_viewScreenActive]/
  /// [_currentViewScreenName] in plain language, reusing exactly that
  /// existing state rather than tracking anything new for this beyond
  /// [_currentViewScreenName] itself (see that field's doc comment for why
  /// one small addition was still needed).
  String _describeCurrentScreen() {
    if (_screenTask == _ScreenTask.cameraCaptured && _keptPhotoPreviewFile != null) {
      return "You're looking at the photo you're keeping — I'm asking whether you want to add a note to it.";
    }
    if (_screenTask == _ScreenTask.cameraCaptured) {
      return "You're looking at the photo you just took, waiting for you to say keep it or retake it.";
    }
    if (_screenTask == _ScreenTask.cameraLive) {
      // P2: the preview can be showing before open_camera has reported
      // success, so this distinguishes "you can see it" from "it's armed" —
      // get_current_screen must never tell a technician the camera is ready
      // to shoot when capture_photo's own guard would still refuse.
      return _cameraOpenConfirmed
          ? "You're in the camera, ready to take a photo."
          : "You're in the camera — the preview is up and it'll be ready to shoot in a moment.";
    }
    if (_screenTask == _ScreenTask.cameraOpening) {
      return "The camera is opening right now — it'll be up in a moment.";
    }
    if (_screenTask == _ScreenTask.cameraClosing) {
      return "The camera is closing — you'll be back on the job screen in a moment.";
    }
    // The registry knows the screen actually showing — including one the
    // technician tapped into, which this session's own push bookkeeping
    // below never sees.
    final registered = switch (ref.read(voiceCommandRegistryProvider.notifier).activeScreen) {
      'JobDetailScreen' => 'the main job details screen',
      'EstimateScreen' => 'the Estimate screen',
      'ChangeOrdersScreen' => 'the Change Orders screen',
      'InvoiceScreen' => 'the Invoice screen',
      'InvoiceReviewScreen' => 'the Invoice Review screen',
      'JobHistoryScreen' => 'the Job History screen',
      'PhotoCaptureScreen' => 'the camera screen',
      'PhotoPreviewScreen' => 'the photo preview screen',
      'VoiceAssistantScreen' => 'the Voice Assistant screen',
      _ => null,
    };
    if (registered != null) return "You're on $registered.";
    if (_viewScreenActive) {
      final label = switch (_navigationSession.topScreenName ?? _currentViewScreenName) {
        'view_estimate' => 'the Estimate screen',
        'view_change_orders' => 'the Change Orders screen',
        'view_invoice' => 'the Invoice screen',
        'view_job_history' => 'the Job History screen',
        'get_last_photo' => 'the photo viewer, looking at the most recent photo',
        _ => 'another screen',
      };
      return "You're currently on $label.";
    }
    return "You're on the main job details screen.";
  }

  /// KB GATE — which screen an unmatched utterance is being routed from,
  /// and whether that screen allows the knowledge-base fallback (the
  /// per-screen `kbFallbackEnabled` flag registered alongside each screen's
  /// VOICE REGISTRY command set; `true` only for Job Detail). The camera
  /// and photo-preview surfaces live inside this ambient overlay rather
  /// than as routes, so Job Detail stays the registry's active screen
  /// underneath them — [_screenTask] is checked first for exactly that
  /// reason. Falls back to this session's own view bookkeeping (same as
  /// [_describeCurrentScreen]) only for the single frame between one
  /// screen unregistering and the next one's deferred registration.
  ({String screen, bool kbFallbackEnabled}) _kbGateScreen() {
    switch (_screenTask) {
      case _ScreenTask.cameraOpening:
      case _ScreenTask.cameraLive:
      case _ScreenTask.cameraClosing:
        return (screen: 'CameraCapture', kbFallbackEnabled: false);
      case _ScreenTask.cameraCaptured:
        return (screen: 'PhotoPreview', kbFallbackEnabled: false);
      case _ScreenTask.none:
        break;
    }
    if (_photoNote != null) return (screen: 'PhotoPreview', kbFallbackEnabled: false);
    final registry = ref.read(voiceCommandRegistryProvider.notifier);
    final active = registry.activeScreen;
    if (active != null) return (screen: active, kbFallbackEnabled: registry.activeScreenKbFallbackEnabled);
    if (_viewScreenActive) {
      final screen = switch (_navigationSession.topScreenName ?? _currentViewScreenName) {
        'view_estimate' => 'EstimateScreen',
        'view_change_orders' => 'ChangeOrdersScreen',
        'view_invoice' => 'InvoiceScreen',
        'view_job_history' => 'JobHistoryScreen',
        'get_last_photo' => 'PhotoViewerScreen',
        _ => 'UnknownViewScreen',
      };
      return (screen: screen, kbFallbackEnabled: false);
    }
    return (screen: 'JobDetailScreen(no registrar yet)', kbFallbackEnabled: true);
  }

  /// Checks [_kbGateScreen] and logs the `KB GATE:` decision line. [source]
  /// names which of the three KB entry points asked (early phrase match,
  /// the catch-all, or a Gemini-initiated toolCall).
  bool _kbGateAllows(String source) {
    final gate = _kbGateScreen();
    _log_(
      'KB GATE: screen=${gate.screen} kbFallbackEnabled=${gate.kbFallbackEnabled} '
      'action=${gate.kbFallbackEnabled ? 'routed_to_kb' : 'routed_to_clarification'} source=$source',
    );
    return gate.kbFallbackEnabled;
  }

  /// Directly executes `go_back` through the SAME dispatcher every genuine
  /// server-sent toolCall already goes through, plus the SAME camera-flow
  /// close-out [_handleToolCall]'s own go_back branch applies (see
  /// [_maybeCloseCameraFlowForGoBack]) — bypassing Gemini's own decision to
  /// call it. See [_maybeDetectIntentionalGoBack]'s doc comment for why the
  /// camera/photo workflow needs its own deterministic trigger rather than
  /// just listening for a cooldown to lift.
  Future<void> _executeDeterministicGoBack() async {
    final jobId = widget.jobId;
    if (jobId == null) {
      _log_('DETERMINISTIC GO BACK TRIGGER: no job_id known (standalone mode) — skipping.');
      return;
    }

    // ISSUE 2 — see [_dispatchGenerationCounter]'s doc comment.
    final myDispatchGeneration = _beginNewDispatchGeneration();
    Map<String, dynamic> result;
    _beginFunctionCallInFlight('deterministic go_back');
    try {
      result = await _pipelineDispatch(
        name: 'go_back',
        source: 'deterministic',
        call: () => dispatchGeminiFunctionCall(
          ref: ref,
          cameraSession: _cameraSession,
          navigationSession: _navigationSession,
          name: 'go_back',
          args: {'job_id': jobId},
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('GEMINI DETERMINISTIC TRIGGER ERROR (go_back): $e\n$stackTrace');
      _log_('DETERMINISTIC GO BACK TRIGGER: go_back FAILED: $e');
      return;
    } finally {
      _endFunctionCallInFlight('deterministic go_back');
    }

    result = await _maybeCloseCameraFlowForGoBack(result, jobId: jobId);

    _log_('DETERMINISTIC GO BACK TRIGGER: go_back succeeded: $result');
    debugPrint('GEMINI DETERMINISTIC TRIGGER: go_back succeeded');
    _clearAllTriggerBuffersAfterSuccess('deterministic go_back');
    _recordDispatchSucceeded(myDispatchGeneration, 'go_back');
    if (_discardIfStaleDispatch(generation: myDispatchGeneration, triggerName: 'go_back')) return;
    _informGeminiOfDeterministicGoBack(result: result);
  }

  /// `go_back` while a camera/photo-workflow task is active — see
  /// [_screenTask]'s doc comment. `GeminiNavigationSession.goBack()`
  /// (inside [dispatchGeminiFunctionCall]) only pops a real PUSHED `view_*`
  /// screen; open_camera/capture_photo/retake_photo/confirm_photo_upload
  /// never push a route at all (see [_buildCameraTaskBody] — camera is
  /// driven purely by [_screenTask] inside this SAME ambient overlay), so a
  /// `go_back` call during an active camera flow used to come back
  /// `already_at_job_details` and silently do nothing. Called from BOTH
  /// [_handleToolCall]'s own go_back branch (a genuine Gemini-issued call)
  /// and [_executeDeterministicGoBack] (this app's own trigger), so either
  /// path closing out of the camera flow behaves identically.
  ///
  /// A no-op (returns [responsePayload] unchanged) if that call already
  /// failed, already genuinely navigated back a pushed screen, or no camera
  /// task is active — only steps in for the specific gap this exists to
  /// close.
  ///
  /// Actually releases the camera hardware via [GeminiCameraSession.dispose]
  /// (the same real cleanup [_teardown] does at session end) rather than
  /// just hiding the preview — "going back" mid-photo abandons whatever was
  /// in progress (an open live preview, or a captured-but-unconfirmed
  /// photo), matching [GeminiCameraSession.retake]'s own "discard, don't
  /// save" semantics, so the technician isn't left with the camera silently
  /// locked for the rest of the session.
  ///
  /// [tornDownReason] — see [_closeCameraFlowForNavigation]: the same close,
  /// reached by the phone's back button or by moving to another screen
  /// rather than a spoken go_back. Only changes the CAMERA OVERLAY TORN
  /// DOWN log reason.
  Future<Map<String, dynamic>> _maybeCloseCameraFlowForGoBack(
    Map<String, dynamic> responsePayload, {
    required String jobId,
    String tornDownReason = 'voice_go_back',
  }) async {
    if (responsePayload.containsKey('error')) return responsePayload;
    if (responsePayload['status'] == 'navigated_back') return responsePayload;
    if (_screenTask != _ScreenTask.none) {
      _log_('CAMERA OVERLAY TORN DOWN: reason=$tornDownReason (screenTask=${_screenTask.name})');
    }
    // Reliability audit hardening (CHECK 5): consult the REAL camera
    // resource, not just `_screenTask`, as a defense-in-depth backstop —
    // `_screenTask` is now kept in sync with the resource on every camera
    // function's success/failure (see `_updateScreenTaskForToolCall`), but
    // checking the actual controller here too means a future desync
    // between the two can never strand an open camera that go_back has no
    // way left to find and release.
    final cameraActuallyOpen = _cameraSession.controller != null;
    if (_screenTask == _ScreenTask.none && !cameraActuallyOpen) return responsePayload;

    final closedTask = _screenTask;
    _cameraOpenConfirmed = false;
    // Still opening: stop waiting on the native open (see
    // [GeminiCameraSession.cancelPendingOpen]) instead of queueing this close
    // behind it for however long it takes — the abandoned open releases its
    // own controller when it finally returns, and nothing was ever shown.
    if (_cameraSession.cancelPendingOpen()) {
      // Read when the cancelled dispatch returns (asynchronously, after this).
      _cameraOpenCancelIntent = _CameraOpenCancelIntent.goBack;
      _log_('go_back: camera was still opening ($closedTask) — cancelled the pending open, nothing to release yet');
    } else {
      // See [_ScreenTask.cameraClosing]: shown BEFORE the release is awaited.
      _log_('go_back: closing camera flow ($closedTask -> ${_ScreenTask.cameraClosing}) — releasing the native camera');
      if (mounted) setState(() => _screenTask = _ScreenTask.cameraClosing);
      await _cameraSession.dispose();
    }
    _log_('go_back: closed active camera flow ($closedTask -> none, cameraActuallyOpen=$cameraActuallyOpen), camera released');
    if (mounted) setState(() => _screenTask = _ScreenTask.none);
    _pausedVoiceService?.setScreenTaskActive(false);
    return {'status': 'navigated_back', 'job_id': jobId, 'closed_camera_flow': true};
  }

  /// Sends Gemini a `clientContent` turn describing what the deterministic
  /// camera-flow go_back trigger just did — same mechanism
  /// [_informGeminiOfDeterministicViewEstimate] uses. Tells Gemini the
  /// camera flow is already closed so its own conversation can acknowledge
  /// correctly instead of trying to call go_back (or a camera function)
  /// again.
  void _informGeminiOfDeterministicGoBack({required Map<String, dynamic> result}) {
    final text = _buildGoBackSpokenText(result);
    if (text != null) _informGeminiToSpeakVerbatim(text, reason: 'deterministic go_back');
  }

  /// State-aware reply for an utterance nothing could route: while a captured
  /// photo awaits a decision (or the live preview awaits a shutter word), the
  /// useful thing to say is the pending question, not a generic examples line.
  /// A short, in-character acknowledgment for a conversational reaction
  /// (see [_maybeFallBackToKbAnswerCatchAll]) — acknowledges and points back
  /// at what can happen next on this job; never answers anything itself.
  String _conversationalReplyForCurrentState() {
    if (_screenTask == _ScreenTask.cameraCaptured) {
      return _photoDecisionDispatchInFlight
          ? 'Still working on that photo — one moment.'
          : 'Got it. Do you want to keep this photo, or retake it?';
    }
    if (_screenTask == _ScreenTask.cameraLive) return "Got it. Say 'capture it' whenever you're ready.";
    return _conversationalReplies[_conversationalReplyCursor++ % _conversationalReplies.length];
  }

  int _conversationalReplyCursor = 0;
  static const List<String> _conversationalReplies = [
    'Sounds good. Just let me know what you need next on this job.',
    "Got it. I'm here if you need anything else on this job.",
    'Okay. Say the word if you want the estimate, the change orders, or a photo.',
  ];

  /// The unclear-input / transcript-timeout reply for whatever multi-turn
  /// flow is open right now, or `null` when none is (then the existing
  /// generic replies apply, unchanged). CONFIRMED need (logcat 09-28,
  /// field_events.id=192): with a photo note pending, a missed transcript
  /// answered with the generic "…show the estimate, change orders, or take
  /// a photo?" menu — unrelated to the question just asked.
  ///
  /// Photo note: asks about the note in that phase's own terms, and COUNTS
  /// as that phase's one re-prompt, so the flow's own re-prompt never fires
  /// on top of it. Camera: already state-aware and never the generic menu,
  /// so its texts are returned EXACTLY as before (the existing first-miss
  /// line from [_unrecognizedReplyForCurrentState], the existing short
  /// line on a repeat) — named here only so the log shows the flow.
  ({String flow, String text})? _activeFlowUnclearReply({required bool repeat}) {
    final note = _photoNote;
    if (note != null) {
      if (note.phase == _PhotoNotePhase.awaitingConfirmation) {
        note.confirmReprompted = true;
        return (
          flow: 'photo_note.awaitingConfirmation',
          text: repeat
              ? 'Sorry, still didn\'t catch that — save the note, yes or no?'
              : 'Sorry, didn\'t catch that — should I save that note? Yes or no?',
        );
      }
      note.descriptionReprompted = true;
      return (
        flow: 'photo_note.awaitingPhotoDescription',
        text: repeat
            ? 'Sorry, still didn\'t catch that — add a note, or skip?'
            : 'Sorry, didn\'t catch that — want to add a note about the photo, or skip it?',
      );
    }
    final cameraFlow = switch (_screenTask) {
      _ScreenTask.cameraCaptured => 'camera.keepOrRetake',
      _ScreenTask.cameraLive => 'camera.live',
      _ => null,
    };
    if (cameraFlow == null) return null;
    return (flow: cameraFlow, text: repeat ? _unclearInputShortReply : _unrecognizedReplyForCurrentState());
  }

  String _unrecognizedReplyForCurrentState() {
    if (_screenTask == _ScreenTask.cameraCaptured) {
      // BUG 5 FIX (CONFIRMED via flutter_run_log_new.txt, build #56): a
      // confirm_photo_upload/retake_photo decision that's ALREADY been
      // dispatched and is genuinely in flight (compressing/uploading, which
      // has taken as long as ~23s in a real run) used to still hit this
      // exact "keep it, or retake it?" reprompt for every stray unresolved
      // utterance during that whole wait — [_screenTask] only leaves
      // [cameraCaptured] once the dispatch SUCCEEDS, not when it STARTS, so
      // from the technician's perspective the app looked like it never
      // heard the decision at all, even 3 repeats in. See
      // [_photoDecisionDispatchInFlight]'s own doc comment.
      if (_photoDecisionDispatchInFlight) {
        if (!_photoDecisionDispatchAcknowledgedUnresolved) {
          _photoDecisionDispatchAcknowledgedUnresolved = true;
          return "Still working on that photo — one moment.";
        }
        return "Still processing — almost done.";
      }
      // P0 FIX — see [_photoDecisionAmbiguousStreak]'s doc comment: a
      // "nothing matched at all" miss (not an ambiguous one — this is a
      // genuinely separate code path) still needs the same stricter
      // wording once escalated, so the technician gets ONE consistent
      // instruction regardless of which of the two paths produced it.
      if (_photoDecisionAmbiguousStreak >= _photoDecisionAmbiguousEscalationThreshold) {
        return _photoDecisionAmbiguousPrompt();
      }
      const replies = [
        "Sorry, I missed that — do you want to keep this photo, or retake it?",
        "I didn't catch that. Say 'keep it' to save the photo, or 'retake' to shoot it again.",
      ];
      return replies[_retryReplyCursor++ % replies.length];
    }
    // cameraLive can be reached early off the preview texture (see
    // [_ScreenTask.cameraOpening]) — don't say "the camera's open" until
    // the real open has completed.
    if (_screenTask == _ScreenTask.cameraLive && !_cameraOpenConfirmed) {
      return "The camera's still opening — give it a moment.";
    }
    if (_screenTask == _ScreenTask.cameraLive) {
      const replies = [
        "Sorry, I missed that — say 'ready' or 'capture it' when you want the photo.",
        "I didn't catch that. The camera's open — say 'capture it' when you're set.",
      ];
      return replies[_retryReplyCursor++ % replies.length];
    }
    return _nextUnrecognizedUtteranceReply();
  }

  /// Reliability audit finding (CHECK 4): `capture_photo`'s required
  /// follow-up — confirm_photo_upload or retake_photo — had NO
  /// deterministic backstop at all, the same under-triggered-function gap
  /// already proven for view_estimate/go_back. Armed ONLY while
  /// [_screenTask] is [_ScreenTask.cameraCaptured] (a captured-but-
  /// undecided photo actually exists to act on); resolves at most once per
  /// utterance. See [classifyPhotoDecision]'s doc comment for the actual
  /// decision logic (P0 FIX, build #59) — a genuinely ambiguous utterance
  /// (both retake and confirm evidence, neither negated into the other)
  /// asks the technician to repeat clearly rather than guessing which way
  /// to gamble a real upload/discard decision.
  void _maybeDetectPhotoDecision(String textChunk) {
    // P0 FIX — see [_maybeTriggerDeterministic]'s matching guard/doc
    // comment.
    if (_utteranceAlreadyResolvedByTrigger) return;
    if (_screenTask != _ScreenTask.cameraCaptured || _photoDecisionResolvedForCurrentUtterance) return;
    // The Review Photo surface also stays up for an already-KEPT photo
    // during the note question ([_keptPhotoPreviewFile]) — there's no
    // keep/retake decision pending then; "yes, save that" is a note answer.
    if (_keptPhotoPreviewFile != null) return;
    _photoDecisionDetectionBuffer = '$_photoDecisionDetectionBuffer $textChunk'.trim();

    // P0 FIX — see [_photoDecisionAmbiguousStreakDecay]'s doc comment: an
    // escalation this stale is from a cascade that's clearly over, not
    // ongoing genuine confusion — let normal evidence-scoring matching
    // resume rather than leaving the technician locked into bare-word-only
    // mode for the rest of this photo's decision.
    final lastAmbiguous = _lastPhotoDecisionAmbiguousAt;
    if (_photoDecisionAmbiguousStreak > 0 &&
        lastAmbiguous != null &&
        DateTime.now().difference(lastAmbiguous) > _photoDecisionAmbiguousStreakDecay) {
      _log_(
        'PHOTO DECISION: ambiguous streak decayed (${DateTime.now().difference(lastAmbiguous).inSeconds}s since '
        'the last ambiguous hit, > ${_photoDecisionAmbiguousStreakDecay.inSeconds}s) — resuming normal '
        'evidence-scoring matching instead of staying in strict bare-word-only mode.',
      );
      _photoDecisionAmbiguousStreak = 0;
    }

    // P0 FIX — see [_photoDecisionAmbiguousStreak]'s doc comment: once
    // escalated, a bare-word-only check REPLACES the normal evidence
    // scoring entirely — an echoed full sentence (the strict prompt or the
    // original question) always has extra words around "keep"/"retake", so
    // it can never satisfy this, breaking the echo-reinforced loop even
    // without a perfect echo fix.
    final escalated = _photoDecisionAmbiguousStreak >= _photoDecisionAmbiguousEscalationThreshold;
    final decision = escalated
        ? classifyStrictBareWordPhotoDecision(_photoDecisionDetectionBuffer)
        : classifyPhotoDecision(_photoDecisionDetectionBuffer);
    if (decision == PhotoDecision.none) {
      // retake_photo/confirm_photo_upload aren't in `_deterministicTriggers`
      // (so they never got a "DETERMINISTIC NO MATCH" line) — log the
      // decision-state miss explicitly so it's visible.
      debugPrint('PHOTO DECISION: no confirm/retake match for "$_photoDecisionDetectionBuffer"');
      return;
    }
    if (decision == PhotoDecision.ambiguous) {
      // P0 FIX — see [classifyPhotoDecision]'s doc comment: a genuine,
      // unresolved conflict (e.g. "yes retake") must never be guessed on a
      // fork this high-stakes. Resolves the utterance (so this exact text
      // doesn't keep re-triggering ambiguous on every subsequent chunk) but
      // fires neither action — asks for a clear repeat instead.
      _photoDecisionResolvedForCurrentUtterance = true;
      _photoDecisionAmbiguousStreak++;
      _lastPhotoDecisionAmbiguousAt = DateTime.now();
      _log_(
        'DETERMINISTIC PHOTO DECISION TRIGGER: "$_photoDecisionDetectionBuffer" matched BOTH keep and retake '
        'evidence with nothing to resolve the conflict (streak=$_photoDecisionAmbiguousStreak) — asking for a '
        'clear repeat instead of guessing.',
      );
      _interruptGeminiForDeterministicTrigger('photo_decision_ambiguous');
      _informGeminiToSpeakVerbatim(_photoDecisionAmbiguousPrompt(), reason: 'photo_decision_ambiguous');
      return;
    }

    final action = decision == PhotoDecision.confirm ? 'confirm_photo_upload' : 'retake_photo';
    _photoDecisionResolvedForCurrentUtterance = true;
    _photoDecisionAmbiguousStreak = 0;
    final now = DateTime.now();
    final lastActivity = _lastPhotoDecisionActivityAt;
    if (lastActivity != null && now.difference(lastActivity) < _photoDecisionDebounce) {
      _log_(
        'DETERMINISTIC PHOTO DECISION TRIGGER: pattern matched ("$_photoDecisionDetectionBuffer" -> $action) but '
        'a photo decision ran ${now.difference(lastActivity).inMilliseconds}ms ago (within the '
        '${_photoDecisionDebounce.inSeconds}s debounce) — GEMINI already handling this, staying out of the way.',
      );
      return;
    }

    _lastPhotoDecisionActivityAt = now;
    // PART G item 3 — see [_maybeTriggerDeterministic]'s matching comment.
    _interruptGeminiForDeterministicTrigger(action);
    _log_(
      'DETERMINISTIC PHOTO DECISION TRIGGER: pattern matched ("$_photoDecisionDetectionBuffer") with no recent '
      'activity — firing $action directly, not waiting for Gemini.',
    );
    debugPrint(
      'GEMINI DETERMINISTIC TRIGGER: firing $action directly (app-side pattern detection during camera flow)',
    );
    unawaited(_executeDeterministicPhotoDecision(action: action));
  }

  /// Directly executes `confirm_photo_upload`/`retake_photo` through the
  /// SAME dispatcher every genuine server-sent toolCall already goes
  /// through — bypassing Gemini's own decision to call it, same principle
  /// as every other deterministic trigger in this file.
  Future<void> _executeDeterministicPhotoDecision({required String action}) async {
    final jobId = widget.jobId;
    if (jobId == null) {
      _log_('DETERMINISTIC PHOTO DECISION TRIGGER: no job_id known (standalone mode) — skipping.');
      return;
    }

    // ISSUE 2 — see [_dispatchGenerationCounter]'s doc comment.
    final myDispatchGeneration = _beginNewDispatchGeneration();
    Map<String, dynamic> result;
    _beginFunctionCallInFlight('deterministic $action');
    // BUG 5 FIX — see [_photoDecisionDispatchInFlight]'s doc comment.
    _photoDecisionDispatchInFlight = true;
    _photoDecisionDispatchAcknowledgedUnresolved = false;
    // No "Uploading…" overlay here any more: confirm_photo_upload only marks
    // the photo kept — the upload runs after the photo-note question (see
    // [_startPhotoNoteUpload]).
    try {
      // P2 FIX (CONFIRMED via flutter_run_log_new.txt, build #59): this
      // used to call [dispatchGeminiFunctionCall] DIRECTLY — bypassing
      // [_dispatchWithOpenCameraSafeguards] entirely, unlike EVERY other
      // camera-flow deterministic trigger (open_camera/capture_photo, both
      // routed through it via [_maybeTriggerDeterministic]). That's exactly
      // why the BUG 2 audio-hard-pause fix (widening
      // `needsAudioHardPause` to `confirm_photo_upload`, applied inside
      // [_dispatchWithOpenCameraSafeguards]) never actually took effect for
      // a confirm_photo_upload fired from THIS path — the log showed
      // compress still taking 4.4s with no `audio_hard_pause_engaged` line
      // at all for it, even though the code change was genuinely present
      // and DID engage correctly for open_camera/capture_photo in the same
      // log. Routed through the same safeguards wrapper now so
      // confirm_photo_upload/retake_photo get identical protection
      // regardless of which of the two call sites fires them.
      result = await _pipelineDispatch(
        name: action,
        source: 'deterministic(photo decision)',
        call: () => _dispatchWithOpenCameraSafeguards(name: action, args: {'job_id': jobId}),
      );
    } catch (e, stackTrace) {
      debugPrint('GEMINI DETERMINISTIC TRIGGER ERROR ($action): $e\n$stackTrace');
      _log_('DETERMINISTIC PHOTO DECISION TRIGGER: $action FAILED: $e');
      return;
    } finally {
      _endFunctionCallInFlight('deterministic $action');
      _photoDecisionDispatchInFlight = false;
      if (_photoUploadInFlight && mounted) setState(() => _photoUploadInFlight = false);
    }

    _log_('DETERMINISTIC PHOTO DECISION TRIGGER: $action succeeded: $result');
    debugPrint('GEMINI DETERMINISTIC TRIGGER: $action succeeded');
    _clearAllTriggerBuffersAfterSuccess('deterministic $action');
    _recordDispatchSucceeded(myDispatchGeneration, action);
    _updateScreenTaskForToolCall(action, result);
    if (_discardIfStaleDispatch(generation: myDispatchGeneration, triggerName: action)) return;
    _informGeminiOfDeterministicPhotoDecision(action: action, result: result);
  }

  /// Sends Gemini a `clientContent` turn describing what the deterministic
  /// photo-decision trigger just did — same mechanism
  /// [_informGeminiOfDeterministicViewEstimate]/[_informGeminiOfDeterministicGoBack]
  /// use.
  void _informGeminiOfDeterministicPhotoDecision({required String action, required Map<String, dynamic> result}) {
    final text = _buildSpokenTextForResult(name: action, result: result);
    if (text == null) return;
    // P0 FIX — see [_beginProtectedConfirmation]'s doc comment: the
    // post-confirm_photo_upload "I've uploaded the photo" line is a direct,
    // app-triggered consequence of an action the app itself just took (a
    // real upload that took real seconds) — it must not be able to get
    // silently swept by an incidental utterance's own preemptive mute the
    // instant it starts streaming back.
    if (action == 'confirm_photo_upload') _beginProtectedConfirmation();
    _informGeminiToSpeakVerbatim(text, reason: 'deterministic $action');
  }

  // ===========================================================================
  // VOICE PHOTO DESCRIPTION ("awaitingPhotoDescription")
  //
  // Entered the moment a photo is genuinely KEPT (confirm_photo_upload
  // succeeded, from either the deterministic path or a Gemini toolCall — see
  // [_updateScreenTaskForToolCall]), carrying that exact photo's own
  // field_events id. The keep confirmation line itself asks once ("Want to
  // add a note about this photo?" — see [_photoNotePromptSuffix]); while
  // active, the technician's speech is routed HERE before the normal trigger
  // matchers (see [_routeTranscriptToPhotoNote]):
  //  - a clear decline ends it, nothing saved;
  //  - an unmistakable command ("take another photo") ends it and runs
  //    through the normal trigger path untouched;
  //  - anything else is the note, read back for confirmation — the same
  //    interrupt + speak-verbatim + bounded-re-ask shape the photo_decision
  //    ambiguous clarification uses — and only saved once confirmed;
  //  - ~5s of quiet ends it silently, nothing saved.
  // Every step logs a greppable `PHOTO NOTE [stage]:` line.
  // ===========================================================================

  _PhotoNoteFlow? _photoNote;
  Timer? _photoNoteTicker;
  Timer? _photoNoteSettleTimer;

  /// Total quiet window for the technician's FIRST answer to "Want to add a
  /// note…?" — CONFIRMED too short at 5s with no retry (logcat 09-28
  /// 16:45:24-16:46:47, field_events.id=192). Same shape as the
  /// confirmation window: after [_photoNoteDescriptionRepromptAfter] of
  /// quiet it asks ONCE more ([_photoNoteDescriptionRepromptText]), then
  /// the rest of the window runs from when that re-prompt finished; only
  /// then, with no speech at all, does the flow skip silently. Any speech
  /// (even one whose transcript is still on its way) keeps it open.
  static const Duration _photoNoteDescriptionWindow = Duration(seconds: 15);
  static const Duration _photoNoteDescriptionRepromptAfter = Duration(milliseconds: 7500);
  static const String _photoNoteDescriptionRepromptText = 'Still there? Want to add a note, or should I skip it?';

  /// A late transcript for speech that BEGAN while the flow was open, but
  /// only arrived after it timed out (Gemini transcripts have been
  /// CONFIRMED 17.5s late), reopens it this long after the timeout — see
  /// [_maybeReopenPhotoNoteForLateAnswer].
  static const Duration _photoNoteLateAnswerGrace = Duration(seconds: 20);
  ({_PhotoNoteFlow flow, DateTime exitedAt})? _timedOutPhotoNote;

  /// Quiet window after the read-back ("…Should I save that?"). Much longer
  /// than [_photoNoteQuietTimeout] (CONFIRMED via flutter_run_log 3fd07e31:
  /// a correctly heard note was discarded after 5247ms while the technician
  /// was still handling equipment) — a note has already been dictated here,
  /// so waiting costs nothing and silence loses real work. Its own
  /// constant, deliberately unrelated to the session inactivity watchdog.
  static const Duration _photoNoteConfirmQuietTimeout = Duration(seconds: 15);

  /// The one re-prompt after the first confirmation timeout or an unclear
  /// answer — see [_repromptPhotoNoteConfirmation].
  static const String _photoNoteConfirmRepromptText = 'Save that note — yes or no?';

  /// Hard ceiling on any ONE step of the flow (restarted every time the
  /// flow speaks), whatever the quiet tracking thinks — a stuck "busy"
  /// signal must never leave later speech being swallowed as a note.
  static const Duration _photoNoteMaxStepDuration = Duration(seconds: 45);

  /// After the utterance ends (or a late chunk arrives), wait this long for
  /// more before acting — a natural mid-sentence pause must not cut a
  /// description in half.
  static const Duration _photoNoteSettleDelay = Duration(milliseconds: 1200);

  /// Bounded re-asks after a read-back — same idea as
  /// [_photoDecisionAmbiguousEscalationThreshold]: never loop forever.
  static const int _photoNoteMaxReasks = 2;

  static const String _photoNotePromptText = 'Want to add a note about this photo?';

  void _photoNoteLog(String stage, String detail) {
    _log_('PHOTO NOTE [$stage]: $detail at ${DateTime.now()}');
  }

  bool get _photoNoteOwnsCurrentUtterance => _photoNote?.ownedUtteranceSeq == _utteranceSeq;

  /// Called on every genuine confirm_photo_upload ("keep") success — BEFORE
  /// anything is compressed or uploaded: the kept photo waits in
  /// [_cameraSession] for this flow's answer (see [_startPhotoNoteUpload]).
  void _enterPhotoNote({required int? keptId, required String? jobId}) {
    _exitPhotoNote('replaced by a newly kept photo', outcome: 'superseded');
    if (keptId == null || jobId == null) {
      _photoNoteLog('state', 'NOT entered — keep result carried no kept_id/job_id (kept_id=$keptId, job_id=$jobId)');
      return;
    }
    final flow = _PhotoNoteFlow(keptId, jobId, DateTime.now());
    _photoNote = flow;
    _timedOutPhotoNote = null;
    // The photo preview stays up (camera held) for the whole note question
    // — see [_finishKeptPhotoPreview].
    _keptPhotoPreviewFile = _cameraSession.keptFile(keptId);
    _photoNoteLog('state', 'entered awaitingPhotoDescription for ${flow.describePhoto()}');
    _photoNoteTicker = Timer.periodic(const Duration(milliseconds: 250), (_) => _photoNoteTick());
  }

  /// Appended to the keep confirmation line — the ONE time the flow asks.
  String _photoNotePromptSuffix() {
    final flow = _photoNote;
    if (flow == null || flow.prompted) return '';
    flow.prompted = true;
    _photoNoteLog('prompt', 'asking once: "$_photoNotePromptText" (${flow.describePhoto()})');
    return ' $_photoNotePromptText';
  }

  /// Outcomes after which the no-note upload is spoken about (with its
  /// pending-call filler, like any upload the technician is waiting on).
  /// Every other no-note exit (a command took over, a new photo, the
  /// session ending) uploads silently in the background, so it never talks
  /// or hard-pauses audio over whatever is happening instead.
  static const Set<String> _photoNoteAudibleUploadOutcomes = {
    'timed_out',
    'declined_by_technician',
    'declined',
    'cancelled',
  };

  /// [uploadLeadIn]: the flow's own closing line for this exit ("Okay — no
  /// note.") — spoken together with the upload's result once the upload
  /// finishes, not before it (the upload hard-pauses audio).
  void _exitPhotoNote(String reason, {required String outcome, String? uploadLeadIn}) {
    final flow = _photoNote;
    if (flow == null) return;
    _photoNote = null;
    // Only a silence timeout can be undone by a late answer — every other
    // exit was a decision (see [_maybeReopenPhotoNoteForLateAnswer]).
    _timedOutPhotoNote = outcome == 'timed_out' ? (flow: flow, exitedAt: DateTime.now()) : null;
    _photoNoteTicker?.cancel();
    _photoNoteTicker = null;
    _photoNoteSettleTimer?.cancel();
    _photoNoteSettleTimer = null;
    _photoNoteLog(
      'state',
      'exited — outcome=$outcome ($reason); ${outcome == 'saved' ? 'note saved' : 'no note saved'} for '
          '${flow.describePhoto()}',
    );
    // Declined, skipped, timed out, or anything else that isn't a saved
    // note: the kept photo is uploaded now, without a note.
    if (flow.upload != null) {
      _finishKeptPhotoPreview('note flow ended ($outcome)');
      if (uploadLeadIn != null) _speakPhotoNoteLine(uploadLeadIn, reason: 'photo_note_exit');
      return;
    }
    final audible = _photoNoteAudibleUploadOutcomes.contains(outcome);
    _photoNoteLog(
      'upload',
      'no note ($outcome) — compressing + uploading ${flow.describePhoto()} now without a note '
          '(${audible ? 'spoken, with the pending-call filler' : 'silently in the background'})',
    );
    final upload = _startPhotoNoteUpload(flow, note: null, audible: audible);
    _finishKeptPhotoPreview('no-note upload started ($outcome)');
    if (!audible) return;
    unawaited(upload.then((result) {
      if (!mounted) return;
      final line = _keptPhotoUploadSpokenText(result);
      _speakPhotoNoteLine(uploadLeadIn == null ? line : '$uploadLeadIn $line', reason: 'photo_upload_no_note');
    }));
  }

  /// The kept photo shown on the Review Photo surface while the note
  /// question is asked (the camera stays held behind it) — `null` when no
  /// kept photo is being shown.
  XFile? _keptPhotoPreviewFile;

  /// "Keep" used to end the camera flow on the spot (dismiss the photo
  /// view, release the camera). With the note asked BEFORE the upload, that
  /// happens here instead, once the note flow is genuinely finished: the
  /// note was saved (photo + note written together), or the flow ended
  /// without one and the no-note upload has started.
  void _finishKeptPhotoPreview(String why) {
    if (_keptPhotoPreviewFile == null) return;
    _keptPhotoPreviewFile = null;
    // Something else already moved the screen on (a command, a new camera
    // action, the session ending) — leave it where it is.
    if (_screenTask != _ScreenTask.cameraCaptured || _cameraSession.capturedFile != null) return;
    _log_(
      'PHOTO CONFIRM: navigated to job details ($why; photo view dismissed -> ${_ScreenTask.none}; the ambient '
      'overlay returns to the conversation over the job screen) — releasing camera',
    );
    if (mounted) setState(() => _screenTask = _ScreenTask.none);
    _pausedVoiceService?.setScreenTaskActive(false);
    _scheduleCameraReleaseWhenIdle();
  }

  /// Starts [flow]'s deferred upload — at most once per flow (a second call
  /// returns the first one's future). [note] goes in the same
  /// `field_events` write as the photo. [audible]: through
  /// [_dispatchWithOpenCameraSafeguards], i.e. the same audio hard pause and
  /// "Still uploading, one more second." pending-call filler the upload had
  /// when it ran inside confirm_photo_upload; otherwise silent (see
  /// [_photoNoteAudibleUploadOutcomes]). Resolves to the dispatcher's result
  /// (`kept_photo_ref` names the row), or `null` if the upload threw.
  Future<Map<String, dynamic>?> _startPhotoNoteUpload(_PhotoNoteFlow flow, {required String? note, required bool audible}) {
    final existing = flow.upload;
    if (existing != null) return existing;
    final upload = audible
        ? _runAudibleKeptPhotoUpload(flow, note: note)
        : _uploadKeptPhotoSilently(flow.keptId, why: flow.describePhoto());
    flow.upload = upload;
    return upload;
  }

  Future<Map<String, dynamic>?> _runAudibleKeptPhotoUpload(_PhotoNoteFlow flow, {required String? note}) async {
    final args = <String, dynamic>{'job_id': flow.jobId, 'kept_id': flow.keptId, 'note': ?note};
    _beginFunctionCallInFlight('photo upload (kept_id=${flow.keptId})');
    // The "Uploading…" overlay on the still-showing photo preview.
    if (mounted) setState(() => _photoUploadInFlight = true);
    try {
      final result = await _pipelineDispatch(
        name: uploadKeptPhotoFunctionName,
        source: 'photo_note',
        call: () => _dispatchWithOpenCameraSafeguards(name: uploadKeptPhotoFunctionName, args: args),
      );
      _recordKeptPhotoUploaded(flow.keptId, result);
      return result;
    } catch (e, stackTrace) {
      debugPrint('PHOTO NOTE ERROR (upload): $e\n$stackTrace');
      _photoNoteLog('upload', 'FAILED for kept photo #${flow.keptId}: $e');
      return null;
    } finally {
      _endFunctionCallInFlight('photo upload (kept_id=${flow.keptId})');
      if (_photoUploadInFlight && mounted) setState(() => _photoUploadInFlight = false);
    }
  }

  /// No audio hard pause, no filler, no in-flight/inactivity bookkeeping,
  /// no `ref` — safe to run while another command is being answered, and
  /// after this screen is torn down (a session ending mid-question still
  /// uploads the photo).
  Future<Map<String, dynamic>?> _uploadKeptPhotoSilently(int keptId, {required String why}) async {
    try {
      final outcome = await _cameraSession.uploadKept(keptId);
      final result = <String, dynamic>{
        'status': outcome.result == PhotoUploadResult.queuedOffline ? 'queued_offline' : 'uploaded',
        'kept_photo_ref': outcome.ref,
      };
      _recordKeptPhotoUploaded(keptId, result);
      return result;
    } catch (e, stackTrace) {
      debugPrint('PHOTO NOTE ERROR (background upload, $why): $e\n$stackTrace');
      _log_('PHOTO NOTE [upload]: background upload FAILED for kept photo #$keptId ($why): $e at ${DateTime.now()}');
      return null;
    }
  }

  void _recordKeptPhotoUploaded(int keptId, Map<String, dynamic> result) {
    final photo = result['kept_photo_ref'] as KeptPhotoRef?;
    _log_(
      'PHOTO NOTE [upload]: kept photo #$keptId ${result['status']}${result.containsKey('note_status') ? ' '
          '(note ${result['note_status']})' : ' (no note)'} — ${photo?.describe() ?? 'no row reference'} at ${DateTime.now()}',
    );
    // P0 TRUST FIX — completed-upload phrasing is licensed by the REAL
    // upload finishing, not by "keep" (see [_updateScreenTaskForToolCall]).
    if (mounted && photo != null) _recordPhotoActionSuccess('confirm_photo_upload');
  }

  /// The spoken result of a no-note upload.
  String _keptPhotoUploadSpokenText(Map<String, dynamic>? result) {
    if (result == null || result['kept_photo_ref'] == null) return "Sorry — I couldn't upload that photo.";
    return result['status'] == 'queued_offline'
        ? "I've saved that photo — it'll upload once you're back online."
        : "I've uploaded the photo.";
  }

  /// Anything that means the conversation isn't quiet yet: the technician
  /// talking, our own line still playing/pending, a transcript still
  /// expected, or a note waiting to settle/save.
  bool get _photoNoteBusy =>
      _isSpeaking ||
      !_turnComplete ||
      _pcmRemainingFrames > 0 ||
      _scriptedResponsePending ||
      _awaitingScriptedTurnWords != null ||
      _awaitingLateTranscript ||
      _inFlightFunctionCalls > 0 ||
      (_photoNoteSettleTimer?.isActive ?? false) ||
      (_photoNote?.saving ?? false);

  void _photoNoteTick() {
    final flow = _photoNote;
    if (flow == null) return;
    final now = DateTime.now();
    if (now.difference(flow.stepStartedAt) > _photoNoteMaxStepDuration && !flow.saving) {
      _exitPhotoNote(
        'hard ceiling of ${_photoNoteMaxStepDuration.inSeconds}s reached while ${flow.phase.name}'
            '${flow.candidate != null ? ' (unconfirmed candidate "${flow.candidate}" discarded)' : ''}',
        outcome: 'timed_out',
      );
      return;
    }
    if (_photoNoteBusy) {
      flow.quietSince = now;
      return;
    }
    final quietFor = now.difference(flow.quietSince);
    if (flow.resumePending) {
      // A break-out command was just answered (see
      // [_photoNoteBreakOutToRealCommand]) — once that answer has finished,
      // come back to the pending note ONE time; its timeout then discards.
      if (quietFor < _photoNoteResumeDelay) return;
      flow.resumePending = false;
      flow.confirmReprompted = true;
      final spoken = (flow.candidate ?? '').replaceFirst(RegExp(r'[.!\s]+$'), '');
      _photoNoteLog(
        'prompt',
        'resuming after the break-out command — asking once more about candidate "${flow.candidate}" '
            '(window ${_photoNoteConfirmQuietTimeout.inSeconds}s, no further re-prompt)',
      );
      _speakPhotoNoteLine('Back to the photo note — save "$spoken"? Yes or no?', reason: 'photo_note_resume');
      return;
    }
    final confirming = flow.phase == _PhotoNotePhase.awaitingConfirmation;
    if (!confirming) {
      // awaitingDescription — see [_photoNoteDescriptionWindow].
      if (!flow.descriptionReprompted) {
        if (quietFor < _photoNoteDescriptionRepromptAfter) return;
        _repromptPhotoNoteDescription(flow, why: 'nothing heard for ${quietFor.inMilliseconds}ms');
        return;
      }
      final rest = _photoNoteDescriptionWindow - _photoNoteDescriptionRepromptAfter;
      if (quietFor < rest) return;
      _exitPhotoNote(
        'no speech at all for the full ${_photoNoteDescriptionWindow.inSeconds}s window while awaitingDescription '
            '(${_photoNoteDescriptionRepromptAfter.inMilliseconds}ms, one re-prompt, then ${quietFor.inMilliseconds}ms)',
        outcome: 'timed_out',
      );
      return;
    }
    if (quietFor < _photoNoteConfirmQuietTimeout) return;
    if (!flow.confirmReprompted) {
      _repromptPhotoNoteConfirmation(flow, why: 'nothing heard for ${quietFor.inMilliseconds}ms after the read-back');
      return;
    }
    _exitPhotoNote(
      'nothing heard for ${quietFor.inMilliseconds}ms while ${flow.phase.name} '
          '(window ${_photoNoteConfirmQuietTimeout.inSeconds}s, after the one re-prompt)'
          '${flow.candidate != null ? ' (unconfirmed candidate "${flow.candidate}" discarded)' : ''}',
      outcome: 'timed_out',
    );
  }

  /// The ONE re-prompt for the first answer to "Want to add a note…?" —
  /// see [_photoNoteDescriptionWindow].
  void _repromptPhotoNoteDescription(_PhotoNoteFlow flow, {required String why}) {
    flow.descriptionReprompted = true;
    final rest = _photoNoteDescriptionWindow - _photoNoteDescriptionRepromptAfter;
    _photoNoteLog(
      'prompt',
      're-prompting once while awaitingDescription ($why): "$_photoNoteDescriptionRepromptText" — '
          '${rest.inMilliseconds}ms more of quiet after it before skipping',
    );
    _speakPhotoNoteLine(_photoNoteDescriptionRepromptText, reason: 'photo_note_description_reprompt');
  }

  /// See [_photoNoteLateAnswerGrace]. Called for every transcript chunk
  /// while no flow is open: if the flow timed out only moments ago and THIS
  /// speech began while it was still open, the answer is late, not new —
  /// the flow is restored as it was (phase, candidate, re-prompt state) and
  /// the chunk is routed to it like any other.
  void _maybeReopenPhotoNoteForLateAnswer() {
    final recent = _timedOutPhotoNote;
    if (_photoNote != null || recent == null) return;
    final now = DateTime.now();
    if (now.difference(recent.exitedAt) > _photoNoteLateAnswerGrace) {
      _timedOutPhotoNote = null;
      return;
    }
    final started = _currentUtteranceStartedAt;
    if (started == null || !started.isBefore(recent.exitedAt) || started.isBefore(recent.flow.enteredAt)) return;
    _timedOutPhotoNote = null;
    final flow = recent.flow;
    flow.buffer = '';
    flow.quietSince = now;
    flow.stepStartedAt = now;
    _photoNote = flow;
    _photoNoteTicker?.cancel();
    _photoNoteTicker = Timer.periodic(const Duration(milliseconds: 250), (_) => _photoNoteTick());
    _photoNoteLog(
      'state',
      're-opened (${flow.phase.name}) for ${flow.describePhoto()} — a late transcript arrived for speech that began '
          'at $started, while the flow was still open (it timed out at ${recent.exitedAt}); processing it normally',
    );
  }

  /// The ONE confirmation re-prompt — after the first quiet timeout or an
  /// unclear answer, whichever comes first. The candidate and phase are
  /// kept; the confirmation window starts over.
  void _repromptPhotoNoteConfirmation(_PhotoNoteFlow flow, {required String why}) {
    flow.confirmReprompted = true;
    _photoNoteLog(
      'prompt',
      're-prompting once ($why): "$_photoNoteConfirmRepromptText" — candidate "${flow.candidate}" still pending, '
          'window ${_photoNoteConfirmQuietTimeout.inSeconds}s again',
    );
    _speakPhotoNoteLine(_photoNoteConfirmRepromptText, reason: 'photo_note_confirm_reprompt');
  }

  /// Routes one transcript chunk while the flow is active. Returns `null`
  /// when the flow consumed it (no normal trigger sees it), or the text the
  /// normal trigger path should evaluate instead — the whole utterance so
  /// far, not just this chunk, when an interrupting command ended the flow
  /// (its first words were consumed here before the command was complete).
  String? _routeTranscriptToPhotoNote(String textChunk) {
    final flow = _photoNote!;
    // A late trailing chunk of the "keep it" utterance that STARTED this
    // flow is not a note — it goes through the normal path exactly as it
    // did before this flow existed.
    final utteranceStartedAt = _currentUtteranceStartedAt;
    if (utteranceStartedAt != null && utteranceStartedAt.isBefore(flow.enteredAt)) {
      _pipelineLog('photo_note', 'chunk "$textChunk" belongs to an utterance from before the photo was kept — not a note');
      return textChunk;
    }
    // Deliberately NOT reset per utterance: until the settle timer acts on
    // it, a description that resumes after a pause is the same note.
    flow.buffer = '${flow.buffer} $textChunk'.trim();
    flow.lastHeardAt = DateTime.now();

    // Same command set in BOTH phases, whatever candidate is pending — see
    // [photoNoteInterruptCommand] for why "No, go back." used to fail.
    final command = photoNoteInterruptCommand(flow.buffer);
    if (command != null) {
      final utterance = flow.buffer;
      _pipelineLog('photo_note', 'interrupting command "$command" (heard "$utterance") — handing to the normal trigger path');
      _exitPhotoNote(
        'interrupting command "$command" (heard "$utterance", phase ${flow.phase.name}) — routed to the normal '
            'trigger path${flow.candidate != null ? ' (unconfirmed candidate "${flow.candidate}" discarded)' : ''}',
        outcome: 'interrupted_by_command',
      );
      // Consumed chunks of this same utterance marked it resolved — undo
      // that so the evaluator loop actually runs on the command. The
      // command is handed over WITHOUT its "No," lead-in, which the normal
      // matchers would otherwise read as negating it.
      _utteranceAlreadyResolvedByTrigger = false;
      return command;
    }

    flow.ownedUtteranceSeq = _utteranceSeq;
    // Claims the utterance: the evaluator loop, the preemptive-mute safety
    // timer, the KB catch-all and the intent layer all stand down, and the
    // preemptive mute armed on this utterance's first chunk stays on until
    // our own reply — Gemini's free-text answer to a photo note is never
    // heard.
    _utteranceAlreadyResolvedByTrigger = true;
    _pipelineLog('photo_note', 'consumed by awaitingPhotoDescription (${flow.phase.name}): "${flow.buffer}"');
    _armPhotoNoteSettleTimer();
    return null;
  }

  void _armPhotoNoteSettleTimer() {
    _photoNoteSettleTimer?.cancel();
    _photoNoteSettleTimer = Timer(_photoNoteSettleDelay, () {
      _photoNoteSettleTimer = null;
      final flow = _photoNote;
      if (flow == null) return;
      final lastHeard = flow.lastHeardAt;
      if (_isSpeaking || (lastHeard != null && DateTime.now().difference(lastHeard) < _photoNoteSettleDelay)) {
        _armPhotoNoteSettleTimer();
        return;
      }
      _processPhotoNoteUtterance();
    });
  }

  /// End-of-utterance hook from [_finalizeUtteranceEndDeterministicTriggers]
  /// — only for an utterance this flow already owns.
  void _onPhotoNoteUtteranceEnd() {
    _pipelineLog('photo_note', 'utterance end — owned by awaitingPhotoDescription, normal end-of-utterance routing skipped');
    _armPhotoNoteSettleTimer();
  }

  void _processPhotoNoteUtterance() {
    final flow = _photoNote;
    if (flow == null) return;
    final heard = flow.buffer.trim();
    flow.buffer = '';
    if (heard.isEmpty) return;
    // Any new speech supersedes a pending "back to the photo note" prompt.
    flow.resumePending = false;

    // Our own prompt/read-back leaking back in past the echo backstop must
    // never become the note. Only for replies of the echo backstop's own
    // minimum length: CONFIRMED via flutter_run_log 6038bc76, a genuine
    // "No" was discarded here because the read-back ("…No, I don't want to
    // add notes…") contained the word "no" — a 1-2 word answer is always
    // inside SOME earlier line and is never evidence of echo.
    final normalizedHeard = _normalizeForEchoCompare(heard);
    final heardWordCount = normalizedHeard.split(' ').where((w) => w.isNotEmpty).length;
    if (heardWordCount >= _echoBackstopMinWords &&
        normalizedHeard.length >= _echoBackstopMinChars &&
        _normalizeForEchoCompare(_lastVerbatimScriptText).contains(normalizedHeard)) {
      _photoNoteLog('candidate', 'ignored "$heard" — it is our own last spoken line echoing back');
      _clearPreemptiveDefaultMuteSilently('photo note: echo of our own line ignored');
      return;
    }

    if (flow.phase == _PhotoNotePhase.awaitingDescription) {
      final reply = classifyPhotoNoteReply(heard);
      switch (reply.kind) {
        case PhotoNoteReplyKind.interruptCommand:
          // Caught per chunk in [_routeTranscriptToPhotoNote]; unreachable.
          return;
        case PhotoNoteReplyKind.decline:
          _photoNoteLog('decision', 'DECLINED — "$heard" matched a decline/skip/cancel pattern; nothing read back');
          _exitPhotoNote('technician declined ("$heard")', outcome: 'declined_by_technician', uploadLeadIn: 'Okay — no note.');
          return;
        case PhotoNoteReplyKind.affirmOnly:
          _photoNoteLog('decision', 'affirmed without a note yet ("$heard") — waiting for the description');
          flow.descriptionReprompted = false;
          _speakPhotoNoteLine('Go ahead.', reason: 'photo_note_go_ahead');
          return;
        case PhotoNoteReplyKind.redo:
          _photoNoteLog('decision', 'REDO requested ("$heard") — still listening for a fresh description');
          flow.descriptionReprompted = false;
          _speakPhotoNoteLine('Go ahead — what should the note say?', reason: 'photo_note_redo');
          return;
        case PhotoNoteReplyKind.description:
          // A real command/question is answered, never saved as a note.
          if (_photoNoteBreakOutToRealCommand(flow, heard)) return;
          _photoNoteLog('candidate', 'description candidate received: "${reply.text}" (heard "$heard")');
          _readBackPhotoNote(flow, reply.text);
          return;
      }
    }

    final candidate = flow.candidate ?? '';
    final confirmation = classifyPhotoNoteConfirmation(heard);
    switch (confirmation.kind) {
      case PhotoNoteConfirmationKind.interruptCommand:
        return; // see above — handled per chunk
      case PhotoNoteConfirmationKind.unclear:
        if (!flow.confirmReprompted) {
          _repromptPhotoNoteConfirmation(flow, why: 'unclear answer "$heard"');
          return;
        }
        _photoNoteLog('decision', 'still unclear after the one re-prompt ("$heard") — candidate "$candidate" discarded');
        _exitPhotoNote(
          'unclear answer after the re-prompt ("$heard")',
          outcome: 'declined',
          uploadLeadIn: "Okay, I won't save a note.",
        );
        return;
      case PhotoNoteConfirmationKind.confirm:
        _photoNoteLog('decision', 'CONFIRMED "$candidate" ("$heard")');
        unawaited(_savePhotoNote(flow, candidate));
        return;
      case PhotoNoteConfirmationKind.discard:
        _photoNoteLog('decision', 'CANCELLED at confirmation — "$heard" matched a cancel phrase; candidate "$candidate" discarded');
        _exitPhotoNote(
          'technician cancelled the note ("$heard")',
          outcome: 'cancelled',
          uploadLeadIn: "Okay, I won't save a note.",
        );
        return;
      case PhotoNoteConfirmationKind.reask:
        flow.reasks++;
        if (flow.reasks > _photoNoteMaxReasks) {
          _photoNoteLog('decision', 'still not confirmed after ${flow.reasks - 1} re-asks ("$heard") — giving up, nothing saved');
          _exitPhotoNote(
            'too many re-asks',
            outcome: 'declined',
            uploadLeadIn: "Okay, I'll leave the photo without a note.",
          );
          return;
        }
        _photoNoteLog('decision', 'rejected read-back ("$heard") — re-asking (${flow.reasks}/$_photoNoteMaxReasks)');
        flow.phase = _PhotoNotePhase.awaitingDescription;
        flow.descriptionReprompted = false;
        flow.candidate = null;
        _speakPhotoNoteLine(
          flow.reasks == 1 ? "Okay — what should the note say? Or say 'skip'." : "Tell me the note once more, or say 'skip'.",
          reason: 'photo_note_reask',
        );
        return;
      case PhotoNoteConfirmationKind.redo:
        _photoNoteLog('decision', 'REDO requested ("$heard") — candidate "$candidate" dropped, listening for a fresh description');
        flow.phase = _PhotoNotePhase.awaitingDescription;
        flow.candidate = null;
        flow.descriptionReprompted = false;
        _speakPhotoNoteLine('Okay — go ahead and say the note again.', reason: 'photo_note_redo');
        return;
      case PhotoNoteConfirmationKind.correction:
        // Only text that is NOT a real command/question is a correction.
        if (_photoNoteBreakOutToRealCommand(flow, heard)) return;
        _photoNoteLog('candidate', 'CORRECTION received: "${confirmation.text}" (was "$candidate", heard "$heard")');
        _readBackPhotoNote(flow, confirmation.text);
        return;
      case PhotoNoteConfirmationKind.addition:
        if (_photoNoteBreakOutToRealCommand(flow, heard)) return;
        final extended = '${candidate.replaceFirst(RegExp(r'[.!\s]+$'), '')}. ${confirmation.text}';
        _photoNoteLog('candidate', 'ADDITION received: "${confirmation.text}" -> "$extended" (heard "$heard")');
        _readBackPhotoNote(flow, extended);
        return;
    }
  }

  /// Per-chunk evaluators NOT used for the break-out check: the camera/photo
  /// decision ones (a note mentioning "the photo shows…" must not re-open
  /// the camera via open_camera's loose noun+action matcher — the explicit
  /// capture phrasings already break out per chunk, see
  /// [classifyPhotoNoteReply]'s interruptCommand).
  static const Set<String> _photoNoteBreakOutExcludedTriggers = {'open_camera', 'capture_photo', 'photo_decision'};

  /// How long quiet must last after a break-out command's own answer
  /// before the one "back to the photo note" prompt.
  static const Duration _photoNoteResumeDelay = Duration(milliseconds: 1500);

  /// CONFIRMED via flutter_run_log 97579c46: "Can you tell me which screen
  /// we are" (three times), "Go back." and more were each read back as a
  /// photo-note CORRECTION until the session itself closed. Before any
  /// speech is accepted as a note or correction, it is run through the
  /// REAL routing — the same per-chunk evaluators [_onInputTranscription]
  /// uses, then the fuzzy intent layer, confident matches only — not a
  /// copy of their phrase lists. If one of them commits, that trigger
  /// answers/navigates exactly as it normally would, and this returns true.
  ///
  /// Then the flow decides whether to stay open: with a read-back still
  /// pending it stays open ONCE and re-asks after the answer (see
  /// [_photoNoteTick]); otherwise (no candidate yet, or a second break-out)
  /// it closes, nothing saved.
  bool _photoNoteBreakOutToRealCommand(_PhotoNoteFlow flow, String heard) {
    // Only a request/question can be a break-out — a declarative note that
    // merely contains a command's words stays a note (see
    // [looksLikeRequestOrQuestion]).
    if (!looksLikeRequestOrQuestion(heard)) return false;
    // Release the utterance so the real triggers are allowed to commit.
    final previousOwner = flow.ownedUtteranceSeq;
    flow.ownedUtteranceSeq = null;
    _utteranceAlreadyResolvedByTrigger = false;
    _pendingGuardFailedReply = null;

    String? routedTo;
    for (final entry in _buildTriggerEvaluators(heard).entries) {
      if (_photoNoteBreakOutExcludedTriggers.contains(entry.key)) continue;
      entry.value();
      if (_anyTriggerCommittedThisUtterance) {
        routedTo = entry.key;
        break;
      }
    }
    if (routedTo == null) {
      final decision = classifyCommandIntent(heard);
      final best = decision.best?.trigger;
      if (decision.kind == IntentDecisionKind.confident &&
          best != null &&
          !_photoNoteBreakOutExcludedTriggers.contains(best)) {
        final kbTrigger = _deterministicTriggers['get_kb_answer']!;
        kbTrigger.buffer = heard;
        _maybeResolveByIntent();
        kbTrigger.buffer = '';
        if (_anyTriggerCommittedThisUtterance) routedTo = 'intent layer -> $best';
      }
    }
    // A queued guard-failed clarification only belongs to a normal utterance.
    _pendingGuardFailedReply = null;

    if (routedTo == null) {
      // Not a command — the flow keeps the utterance; it's note text.
      flow.ownedUtteranceSeq = previousOwner;
      _utteranceAlreadyResolvedByTrigger = true;
      return false;
    }

    _pipelineLog('photo_note', 'break-out: "$heard" is a real command ($routedTo) — routed normally, not note text');
    final candidate = flow.candidate;
    if (flow.phase == _PhotoNotePhase.awaitingConfirmation && candidate != null && !flow.resumedAfterCommand) {
      flow.resumedAfterCommand = true;
      flow.resumePending = true;
      flow.stepStartedAt = DateTime.now();
      flow.quietSince = DateTime.now();
      _photoNoteLog(
        'state',
        'BREAK-OUT: "$heard" matched real command ($routedTo) — answered through normal routing, NOT saved as a '
            'correction; flow kept open for candidate "$candidate", will re-ask once after the answer',
      );
    } else {
      _exitPhotoNote(
        'BREAK-OUT: "$heard" matched real command ($routedTo) — answered through normal routing, NOT saved as note '
            'text${candidate != null ? ' (unconfirmed candidate "$candidate" discarded — already re-asked once after a command)' : ''}',
        outcome: 'interrupted_by_command',
      );
    }
    return true;
  }

  void _readBackPhotoNote(_PhotoNoteFlow flow, String candidate) {
    flow.candidate = candidate;
    flow.phase = _PhotoNotePhase.awaitingConfirmation;
    flow.confirmReprompted = false;
    _photoNoteLog(
      'prompt',
      'reading back "$candidate" — confirmation window ${_photoNoteConfirmQuietTimeout.inSeconds}s, one re-prompt allowed',
    );
    final spoken = candidate.replaceFirst(RegExp(r'[.!\s]+$'), '');
    _speakPhotoNoteLine('Got it — noted: $spoken. Should I save that?', reason: 'photo_note_readback');
  }

  /// Every flow reply goes out the same way a deterministic trigger's does:
  /// buffers cleared as resolved (which also ends the preemptive mute
  /// cleanly), then a constrained verbatim line that interrupts whatever
  /// Gemini was saying on its own.
  void _speakPhotoNoteLine(String text, {required String reason}) {
    _clearAllTriggerBuffersAfterSuccess(reason);
    final flow = _photoNote;
    if (flow != null) {
      flow.quietSince = DateTime.now();
      flow.stepStartedAt = DateTime.now();
    }
    _informGeminiToSpeakVerbatim(text, reason: reason);
  }

  /// The confirmed note. Normally the photo is still waiting — it's
  /// compressed and uploaded NOW, with the note in the same `field_events`
  /// write. Only a flow re-opened by a late answer after its timeout had
  /// already started the no-note upload writes the note separately, onto
  /// the row that upload created.
  Future<void> _savePhotoNote(_PhotoNoteFlow flow, String note) async {
    flow.saving = true;
    if (flow.upload == null) {
      _photoNoteLog('save', 'uploading ${flow.describePhoto()} together with its note "$note" — one field_events write');
      final result = await _startPhotoNoteUpload(flow, note: note, audible: true);
      final photo = result?['kept_photo_ref'] as KeptPhotoRef?;
      final noteStatus = result?['note_status'] as String?;
      if (photo == null) {
        _photoNoteLog('save', 'FAILURE — the photo upload itself failed; note "$note" not saved');
        if (identical(_photoNote, flow)) _exitPhotoNote('photo upload failed', outcome: 'save_failed');
        _speakPhotoNoteLine("Sorry — I couldn't upload that photo or its note.", reason: 'photo_note_save_failed');
        return;
      }
      final photoQueued = result!['status'] == 'queued_offline';
      _photoNoteLog(
        'save',
        switch (noteStatus) {
          'written' => 'SUCCESS — photo and note written together in one field_events write for ${photo.describe()} '
              '(transcript="$note")',
          'queued' => 'QUEUED OFFLINE — note will be written for ${photo.describe()} on reconnect (transcript="$note")',
          _ => 'FAILURE — photo uploaded but its note was not saved for ${photo.describe()}',
        },
      );
      final saved = noteStatus == 'written' || noteStatus == 'queued';
      if (identical(_photoNote, flow)) {
        _exitPhotoNote(saved ? 'note confirmed' : 'note write failed', outcome: saved ? 'saved' : 'save_failed');
      }
      _speakPhotoNoteLine(
        !saved
            ? "I've uploaded the photo, but I couldn't save the note."
            : photoQueued
                ? "Photo and note saved — they'll upload once you're back online."
                : noteStatus == 'queued'
                    ? "I've uploaded the photo — the note will sync once you're back online."
                    : "I've uploaded the photo with your note.",
        reason: 'photo_note_saved',
      );
      return;
    }

    final uploaded = await flow.upload;
    final photo = uploaded?['kept_photo_ref'] as KeptPhotoRef?;
    if (photo == null) {
      _photoNoteLog('save', 'FAILURE — the earlier no-note upload failed; note "$note" has no row to go on');
      if (identical(_photoNote, flow)) _exitPhotoNote('photo upload failed', outcome: 'save_failed');
      _speakPhotoNoteLine("Sorry — I couldn't save that note.", reason: 'photo_note_save_failed');
      return;
    }
    _photoNoteLog('save', 'photo already uploaded (late answer) — writing transcript to ${photo.describe()} — "$note"');
    try {
      final wroteNow = await ref.read(offlineUploadQueueProvider.notifier).savePhotoNote(photo, note);
      ref.read(jobPhotosProvider(photo.jobId).notifier).applyPhotoNote(photo, note);
      _photoNoteLog(
        'save',
        wroteNow
            ? 'SUCCESS — field_events.transcript UPDATE reached and matched the row for ${photo.describe()} '
                  '(transcript="$note")'
            : 'QUEUED OFFLINE — field_events.transcript UPDATE NOT reached yet; will be written for '
                  '${photo.describe()} on reconnect (transcript="$note")',
      );
      if (identical(_photoNote, flow)) _exitPhotoNote('note confirmed', outcome: 'saved');
      _speakPhotoNoteLine(
        wroteNow ? 'Note saved.' : "Note saved — it'll sync once you're back online.",
        reason: 'photo_note_saved',
      );
    } catch (e, stackTrace) {
      debugPrint('PHOTO NOTE ERROR (save): $e\n$stackTrace');
      _photoNoteLog('save', 'FAILURE for ${photo.describe()}: $e');
      if (identical(_photoNote, flow)) _exitPhotoNote('save failed: $e', outcome: 'save_failed');
      _speakPhotoNoteLine("Sorry — I couldn't save that note.", reason: 'photo_note_save_failed');
    }
  }

  /// The camera flow is the only tool group with real, function-call-
  /// triggered screen content behind it today (see [_ScreenTask]'s doc
  /// comment) â€” a no-op for every other function name. On success, moves
  /// [_screenTask] to whatever real content that call just made visible
  /// (open_camera/retake_photo -> the live preview, capture_photo -> the
  /// captured still, confirm_photo_upload -> back to pure conversation,
  /// same "task complete" point the ticket describes). On FAILURE, resets
  /// to `none` rather than leaving [VoiceInteractionOverlay] shrunk with
  /// nothing real behind it â€” e.g. open_camera throwing on a denied
  /// permission must not strand the technician staring at a shrunk corner
  /// pill over whatever screen happened to be underneath.
  ///
  /// Pushes the resulting active/inactive flag straight through to
  /// `GlobalVoiceService.setScreenTaskActive`, which is what actually
  /// drives [VoiceInteractionOverlay]'s shrink/expand â€” [_screenTask]
  /// itself only controls what THIS screen's own body renders (see
  /// [_buildCameraTaskBody]).
  void _updateScreenTaskForToolCall(String name, Map<String, dynamic> responsePayload) {
    // A voice navigation to another screen while the camera is up moves
    // past the camera — including "already on that screen" (e.g. Invoice
    // under a camera opened from Invoice), where nothing gets pushed for
    // the host route to notice.
    if (_isNavigatingScreenFunction(name) && !responsePayload.containsKey('error') && _screenTask != _ScreenTask.none) {
      unawaited(_closeCameraFlowForNavigation('screen_changed'));
    }
    const cameraFunctionNames = {'open_camera', 'capture_photo', 'confirm_photo_upload', 'retake_photo'};
    if (!cameraFunctionNames.contains(name)) return;

    // CONFIRMED regression fix: a rejected duplicate/overlapping call (see
    // `_openCamera`/`_captureStagedPhoto` in gemini_function_dispatcher.dart)
    // must be a true no-op here — it never touched the camera, so it must
    // never touch this screen's task state either. Checked BEFORE the
    // generic `error` branch below: this response has no `error` key at all
    // (it's a normal, non-throwing result), but even if it did, resetting
    // to `none` here would wrongly blank out the live preview/captured
    // photo that the genuinely-first, still-in-flight call owns and will
    // update correctly itself once it finishes.
    if (responsePayload['status'] == 'rejected_overlap') {
      _log_('screen task: "$name" rejected as an overlapping duplicate call — leaving $_screenTask unchanged');
      return;
    }

    // FIX 2: `_dispatchWithOpenCameraSafeguards`'s hard timeout — the camera
    // was never confirmed open (the real call may still be running in the
    // background, see that method's doc comment), so this is the same
    // "nothing was ever opened" case as an `open_camera` failure below,
    // handled explicitly here rather than falling through to the generic
    // success switch (which would have wrongly jumped to `cameraLive`).
    if (responsePayload['status'] == 'cancelled') {
      // See [GeminiCameraSession.cancelPendingOpen] — the native open is
      // abandoned, not failed; nothing was ever shown open.
      final intent = _cameraOpenCancelIntent ?? _CameraOpenCancelIntent.user;
      _cameraOpenCancelIntent = null;
      _cameraOpenConfirmed = false;
      if (intent == _CameraOpenCancelIntent.retry) {
        // Stay on the opening surface; the retry's own open queues behind
        // the abandoned one and starts the moment the camera is free. Spoken
        // audio would be dropped by the retry's own hard-pause anyway, so
        // the surface says "Retrying" instead.
        responsePayload['silent'] = true;
        _log_('screen task: open_camera cancelled for RETRY — staying on ${_ScreenTask.cameraOpening}');
        _cameraOpeningStartedAt = DateTime.now();
        _cameraOpenIsRetry = true;
        unawaited(Future(_startCameraOpenRetry));
        return;
      }
      // go_back already speaks its own reply for this.
      if (intent == _CameraOpenCancelIntent.goBack) responsePayload['silent'] = true;
      _log_('screen task: open_camera CANCELLED ($intent) -> ${_ScreenTask.none}');
      if (_screenTask == _ScreenTask.cameraOpening && mounted) setState(() => _screenTask = _ScreenTask.none);
      _pausedVoiceService?.setScreenTaskActive(_screenTask != _ScreenTask.none);
      return;
    }

    if (responsePayload['status'] == 'timeout') {
      _log_('screen task: "$name" TIMED OUT -> ${_ScreenTask.none} (nothing was confirmed open)');
      _cameraOpenConfirmed = false;
      if (_screenTask != _ScreenTask.none && mounted) setState(() => _screenTask = _ScreenTask.none);
      _pausedVoiceService?.setScreenTaskActive(false);
      return;
    }

    if (responsePayload.containsKey('error')) {
      // Reliability audit finding (CHECK 3/5): a camera-function FAILURE
      // does not always mean the underlying resource is gone.
      // `open_camera` failing (permission denied, no camera found) genuinely
      // means nothing was ever opened -> `none` is correct. But
      // `capture_photo`/`confirm_photo_upload`/`retake_photo` can all fail
      // with the controller/captured file still fully intact (see each of
      // their own doc comments in gemini_function_dispatcher.dart — none of
      // them tear anything down on the way out). Forcibly resetting to
      // `none` for those three used to hide a still-open camera or
      // still-pending photo from the UI entirely (confirmed by tracing
      // `_buildAmbientUi`, which routes to the pure-conversation view and
      // never reaches `_buildCameraTaskBody` when `_screenTask == none`) —
      // and, worse, left `_maybeCloseCameraFlowForGoBack` (which trusts
      // `_screenTask` as its only signal) unable to ever find and release
      // that orphaned resource again. Leaving `_screenTask` exactly as it
      // already was is what's actually still true for those three.
      final nextTask = name == 'open_camera' ? _ScreenTask.none : _screenTask;
      // P2 — an open_camera failure also retracts the early "there is
      // something to look at" state the preview callback may have set, and
      // must leave capture disarmed either way.
      if (name == 'open_camera') _cameraOpenConfirmed = false;
      _log_(
        'screen task: "$name" FAILED -> $nextTask '
        '(${name == "open_camera" ? "nothing was ever opened" : "resource state left unchanged"})',
      );
      if (nextTask != _screenTask && mounted) setState(() => _screenTask = nextTask);
      _pausedVoiceService?.setScreenTaskActive(nextTask != _ScreenTask.none);
      return;
    }

    // P0 FIX — see [_photoDecisionAmbiguousStreak]'s doc comment: a fresh
    // capture starts a brand new keep/retake decision cycle, so any
    // escalation earned by a PREVIOUS photo's ambiguous loop must not carry
    // over and immediately put this new one into strict bare-word mode.
    if (name == 'capture_photo') _photoDecisionAmbiguousStreak = 0;

    // awaitingPhotoDescription: entered on a genuine keep, carrying THAT
    // photo's kept id — the photo is uploaded only once the note question
    // is answered; any other camera action means the technician has moved
    // on (which uploads a still-waiting kept photo, no note).
    if (name == 'confirm_photo_upload') {
      _enterPhotoNote(keptId: responsePayload['kept_id'] as int?, jobId: responsePayload['job_id'] as String?);
    } else {
      _exitPhotoNote('"$name" succeeded — technician moved on', outcome: 'superseded');
    }

    final nextTask = switch (name) {
      'open_camera' || 'retake_photo' => _ScreenTask.cameraLive,
      'capture_photo' => _ScreenTask.cameraCaptured,
      // confirm_photo_upload ("keep"): the photo preview stays up, camera
      // held, for the whole note question — [_finishKeptPhotoPreview] moves
      // on once it's done. Straight back to pure conversation only if the
      // note flow couldn't start.
      _ => _keptPhotoPreviewFile != null ? _ScreenTask.cameraCaptured : _ScreenTask.none,
    };

    // P0 TRUST FIX — where a genuine photo-action success is recorded for
    // [_auditGeminiCompletionClaim]. Reached from both the deterministic
    // trigger path ([_executeDeterministic]) and a genuine server-sent
    // toolCall ([_handleToolCall]), and only past every
    // rejected_overlap/timeout/error early-return above it — so "we got
    // here" is exactly "this function really did what it says". Except
    // confirm_photo_upload: "keep" uploads nothing yet, so completed-upload
    // phrasing is licensed only when the real upload finishes (see
    // [_recordKeptPhotoUploaded]).
    if (name != 'confirm_photo_upload') _recordPhotoActionSuccess(name);

    // P2 — the ACTION gate (see [_cameraOpenConfirmed]). Only a genuine
    // open_camera/retake_photo SUCCESS arms capture; confirm_photo_upload
    // ends the flow and disarms it. capture_photo itself leaves it alone —
    // the camera is still open behind the captured still, which is what
    // makes retake work.
    if (name == 'open_camera' || name == 'retake_photo') {
      _cameraOpenConfirmed = true;
    } else if (name == 'confirm_photo_upload') {
      _cameraOpenConfirmed = false;
    }

    _log_('screen task: "$name" succeeded -> $nextTask');
    if (mounted) setState(() => _screenTask = nextTask);
    _pausedVoiceService?.setScreenTaskActive(nextTask != _ScreenTask.none);
    if (name == 'confirm_photo_upload' && nextTask == _ScreenTask.cameraCaptured) {
      _log_(
        'PHOTO CONFIRM: keep — staying on the photo preview with the camera held until the photo-note question '
        'is finished (see _finishKeptPhotoPreview)',
      );
    } else if (name == 'confirm_photo_upload') {
      // The note flow couldn't start: back on the job (screen task -> none).
      // Release the camera hardware too — confirm used to leave it open
      // behind the conversation view, holding the camera (the next
      // open_camera reopens it cleanly; retake, by contrast, keeps it open on
      // purpose).
      _log_(
        'PHOTO CONFIRM: navigated to job details (photo view dismissed -> $_screenTask; the ambient overlay '
        'returns to the conversation over the job screen) — releasing camera',
      );
      _scheduleCameraReleaseWhenIdle();
    }
  }

  /// CONFIRMED via the build #41 log: releasing the camera the instant
  /// confirm succeeded took 40s ("CAMERA CLOSE: complete (40114ms)"), during
  /// which the main thread stalled (Choreographer "Skipped 545 frames") and
  /// the PCM release/setup reinit for the spoken confirmation sat behind it
  /// (27 chunks queued). The camera plugin's native close runs on the main
  /// thread and is not something Dart can speed up (the native
  /// `CameraDevice#close` itself only took 240ms — the time went into the
  /// platform thread being saturated/blocked around it). So take it OFF the
  /// critical path instead: release only once the session is genuinely quiet
  /// (confirmation spoken, PCM ready, mic not paused, nothing in flight, nobody
  /// talking), and never while a new camera task is active. A new open_camera
  /// simply reopens (its own open path disposes first).
  Timer? _cameraReleaseTimer;

  void _scheduleCameraReleaseWhenIdle() {
    _cameraReleaseTimer?.cancel();
    final scheduledAt = DateTime.now();
    _cameraReleaseTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted || _screenTask != _ScreenTask.none) {
        timer.cancel();
        _cameraReleaseTimer = null;
        _log_('CAMERA RELEASE: cancelled — a new camera task started (or screen closed) before idle release');
        return;
      }
      final waited = DateTime.now().difference(scheduledAt);
      final quiet = _pcmReady && !_outgoingAudioPaused && !_isSpeaking && _inFlightFunctionCalls == 0;
      if (waited < const Duration(seconds: 5) || !quiet) return;
      timer.cancel();
      _cameraReleaseTimer = null;
      _log_('CAMERA RELEASE: session idle after ${waited.inMilliseconds}ms — releasing camera now (off the audio critical path)');
      unawaited(_cameraSession.dispose());
    });
  }

  /// BUG 2 backstop: is [chunk] very likely Gemini's own voice leaking back
  /// through the mic rather than genuine technician speech? Deliberately
  /// CONSERVATIVE — a false positive here silently swallows real technician
  /// speech (including exactly the short, high-value confirmation words
  /// like "keep it"/"confirm"/"ready" this session depends on most), which
  /// is a worse failure than occasionally missing a genuine echo. So this
  /// only fires for a SUBSTANTIAL match:
  ///  - at least [_echoBackstopMinWords] words AND [_echoBackstopMinChars]
  ///    normalized characters (rules out short phrases like "keep it" (2
  ///    words) or "ready" (1 word) ever being caught here, even though
  ///    those words plausibly also appear in whatever Gemini just said —
  ///    e.g. Gemini asking "would you like to keep it or retake it?" must
  ///    never cause a genuine technician reply of "keep it" to be discarded)
  ///  - AND the whole normalized chunk appears verbatim as a substring of
  ///    the comparison pool (see [_looksLikeGeminiEcho]'s own doc comment
  ///    for what that pool is).
  /// CONFIRMED real leaked examples this is sized to catch: "Is that
  /// correct?" (3 words), "What would you like to do next?" (7 words) — both
  /// comfortably clear these thresholds. Also shared with (and originally
  /// sized for) [_auditGeminiDuplicateResponse]'s unrelated turn-to-turn
  /// duplicate check — a real, deliberate reuse, not a leftover coupling:
  /// both are "is this text substantially the same as that text" checks
  /// that should agree on how short is too short to judge.
  static const int _echoBackstopMinWords = 3;
  static const int _echoBackstopMinChars = 12;

  /// Used by [_auditGeminiDuplicateResponse]'s turn-to-turn duplicate check
  /// ONLY — [_looksLikeGeminiEcho] used to share this too, but was moved
  /// onto [wordEditDistance]/[looksLikeCloseSequenceMatch] instead (see
  /// that pair's own doc comment for why: this UNORDERED "appears
  /// somewhere nearby" scoring is exactly what let unrelated common words
  /// scattered across a long comparison text falsely "match" a short real
  /// command). Left exactly as-is here and still correct for duplicate
  /// detection, which compares a whole turn against ANOTHER WHOLE, DISCRETE
  /// prior turn (never a growing multi-turn blob) — the failure mode that
  /// motivated moving echo detection off this algorithm doesn't apply to
  /// that comparison shape.
  ///
  /// Finds the best-aligned window in [recentWords] of about the same
  /// length as [chunkWords] (checking one word shorter and one word longer
  /// too, so a genuinely dropped/inserted word at the boundary doesn't
  /// misalign the rest) and returns the highest fraction of [chunkWords]
  /// found anywhere within that window. Deliberately word-level
  /// containment, not a full edit-distance implementation —
  /// `photo_decision_classifier.dart` already covers per-word typo drift
  /// for the keep/retake fork specifically; this only needs to survive a
  /// handful of genuinely swapped/garbled words between two turns that are
  /// otherwise near-verbatim repeats of each other.
  static double _bestWordOverlapRatio(List<String> chunkWords, List<String> recentWords) {
    if (chunkWords.isEmpty || recentWords.isEmpty) return 0;
    var best = 0.0;
    for (final windowLen in {chunkWords.length - 1, chunkWords.length, chunkWords.length + 1}) {
      if (windowLen <= 0 || windowLen > recentWords.length) continue;
      for (var start = 0; start <= recentWords.length - windowLen; start++) {
        final window = recentWords.sublist(start, start + windowLen);
        final matches = chunkWords.where(window.contains).length;
        final ratio = matches / chunkWords.length;
        if (ratio > best) best = ratio;
      }
    }
    return best;
  }

  // P0 ECHO FALSE-POSITIVE FIX — the actual word-sequence-similarity
  // algorithm (word-level edit distance, deliberately DIFFERENT from
  // [_bestWordOverlapRatio]'s unordered overlap — see that function's own
  // doc comment for why) now lives in `echo_sequence_matcher.dart`
  // ([wordEditDistance]/[looksLikeCloseSequenceMatch], imported above),
  // split out the same way `trigger_phrase_matcher.dart`/
  // `photo_decision_classifier.dart`/`completion_claim_detector.dart`
  // already were — a P0-severity text-matching fix earns its own
  // unit-testable module rather than staying an inline private method with
  // no automated regression coverage of its own.

  /// P0 ECHO FALSE-POSITIVE FIX — regression guard (item 3 of the fix this
  /// belongs to): an echo discard is, by [_looksLikeGeminiEcho]'s own
  /// deliberately conservative design, ALWAYS accepted as correct without
  /// further proof — there's no way to be MORE sure from text alone. This
  /// makes a false positive VISIBLE the moment it happens instead of
  /// silently swallowing a real command: checked right before the discard
  /// actually takes effect, against every real deterministic trigger this
  /// app has (every [_deterministicTriggers] entry, PLUS the keep/retake
  /// decision, which lives outside that map). Logging only — this NEVER
  /// changes the discard decision itself (this backstop still can't tell
  /// "genuine echo that happens to resemble a command" from "a real
  /// command wrongly caught" from text alone), but a line naming exactly
  /// which pattern it would have matched turns an invisible loss into
  /// something the next real run's log can be grepped for directly.
  void _logIfEchoDiscardWouldHaveMatchedATrigger(String chunk) {
    final matchedTriggers = _commandsMatchingText(chunk);
    if (matchedTriggers.isEmpty) return;
    _log_(
      'ECHO BACKSTOP FALSE-POSITIVE RISK: the chunk just discarded as echo ("$chunk") ALSO matches '
      '${matchedTriggers.join(", ")} — if this was genuinely the technician speaking, that command was just '
      'silently swallowed. The discard itself is unchanged; this line exists purely to make that risk visible '
      'in the log instead of invisible.',
    );
  }

  /// Every command [chunk] would trigger — the same set the FALSE-POSITIVE
  /// RISK line reports.
  List<String> _commandsMatchingText(String chunk) {
    final matchedTriggers = [
      for (final trigger in _deterministicTriggers.values)
        if (trigger.matches(chunk)) trigger.name,
    ];
    final photoDecision = classifyPhotoDecision(chunk);
    if (photoDecision != PhotoDecision.none) {
      matchedTriggers.add('photo_decision:${photoDecision.name}');
    }
    return matchedTriggers;
  }

  /// When the current utterance's speech began (the "genuinely new
  /// utterance" edge in [_trackSpeechLevel]).
  DateTime? _currentUtteranceStartedAt;

  /// When the native player last confirmed it had played everything fed to
  /// it (a "0 remaining" report covering every acknowledged feed), or its
  /// queue was torn down — see [_nativePlaybackDrainConfirmed].
  DateTime? _nativePlaybackEndConfirmedAt;

  /// When the most recent response playback started (outgoing mic paused
  /// for it).
  DateTime? _lastResponsePlaybackStartedAt;

  /// The echo backstop's text match stays the default verdict; this lets a
  /// matched COMMAND through only when the technician started speaking
  /// after our audio had provably finished — see `echo_override_policy.dart`
  /// for the rule and the trace it was checked against.
  EchoDecision _decideEchoOverride(String chunk) {
    final commands = _commandsMatchingText(chunk);
    final decision = decideEcho(
      textLooksLikeEcho: true,
      commandMatched: commands.isNotEmpty,
      speechStartedAt: _currentUtteranceStartedAt,
      playbackConfirmedEndedAt: _nativePlaybackEndConfirmedAt,
      lastPlaybackStartedAt: _lastResponsePlaybackStartedAt,
    );
    if (decision == EchoDecision.override) {
      final gapMs = _currentUtteranceStartedAt!.difference(_nativePlaybackEndConfirmedAt!).inMilliseconds;
      _log_(
        'ECHO BACKSTOP OVERRIDDEN: "$chunk" reads like our own recent speech, but it matches '
        '${commands.join(", ")} and the technician started speaking ${gapMs}ms AFTER the player confirmed our '
        'audio had finished — nothing of ours was playing, so this cannot be mic bleed. Treating it as a real '
        'command and letting it fire.',
      );
      _pipelineLog(
        'echo_override',
        'command ${commands.join(", ")} fires despite echo-like text (speech began ${gapMs}ms after playback '
            'confirmed ended)',
      );
    }
    return decision;
  }

  /// BUG 2 backstop: is [chunk] very likely Gemini's own voice leaking back
  /// through the mic rather than genuine technician speech?
  ///
  /// P0 ECHO FALSE-POSITIVE FIX (CONFIRMED, a real ~2.5 minute session): the
  /// PREVIOUS design compared [chunk] against a single accumulated string
  /// spanning the WHOLE session (nominally capped at 600 characters, but
  /// 600 characters is ~100-120 words — easily several DISTINCT turns of
  /// unrelated conversation). A genuine "Take the photo." was discarded
  /// because "take"/"the"/"photo" each happened to appear SOMEWHERE nearby
  /// each other in that long blob, unrelated to anything actually just
  /// said — capture_photo fired ZERO times in the entire session as a
  /// direct result.
  ///
  /// The comparison pool is now exactly two entries, each checked
  /// SEPARATELY (never concatenated — concatenating them would just
  /// recreate the same blob problem one level up):
  ///  - [_currentTurnAudiblyPlayedText] — whatever Gemini is speaking RIGHT
  ///    NOW, if anything (the most likely real echo source).
  ///  - [_lastCompletedTurnAudiblyPlayedText] — the turn Gemini MOST
  ///    RECENTLY finished, but ONLY while still within
  ///    [_echoComparisonTrailingWindowFor] of finishing (scaled by that
  ///    turn's own length — see its doc comment). Once that window
  ///    passes, it drops out of the pool entirely — never "anything said
  ///    this session," exactly as this fix requires.
  /// Each candidate is tried verbatim-substring first (cheap, zero false-
  /// positive risk when it hits), then [looksLikeCloseSequenceMatch]
  /// (word-level edit distance, NOT [_bestWordOverlapRatio]'s unordered
  /// overlap — see that function's own doc comment for why this backstop
  /// specifically needed a stricter, ORDER-aware algorithm).
  bool _looksLikeGeminiEcho(String chunk) {
    final normalizedChunk = _normalizeForEchoCompare(chunk);
    if (normalizedChunk.length < _echoBackstopMinChars) return false;
    final chunkWords = normalizedChunk.split(' ').where((w) => w.isNotEmpty).toList();
    if (chunkWords.length < _echoBackstopMinWords) return false;

    final candidates = <String>[_currentTurnAudiblyPlayedText];
    var lastFinishedAt = _lastCompletedTurnFinishedAt;
    // ECHO LOOP FIX — see [_pcmFeedsInFlight]: the trailing window counts
    // from when that audio actually finished PLAYING, not from the server's
    // turnComplete. On the camera screens the native player routinely got
    // the audio seconds late (CONFIRMED: an echo of a line generated 17s
    // earlier slipped past this window), so a server-time window closed
    // before the echo was even audible.
    final ackEnd = _ackBasedPlaybackEndAt;
    if (lastFinishedAt != null && ackEnd != null && ackEnd.isAfter(lastFinishedAt)) lastFinishedAt = ackEnd;
    if (lastFinishedAt != null) {
      final window = _echoComparisonTrailingWindowFor(_lastCompletedTurnAudiblyPlayedText);
      if (DateTime.now().difference(lastFinishedAt) <= window) {
        candidates.add(_lastCompletedTurnAudiblyPlayedText);
      }
    }

    for (final candidate in candidates) {
      if (_chunkEchoesTurn(chunk, normalizedChunk, chunkWords, candidate)) return true;
    }

    // P1 FIX (CONFIRMED: "I'm here, loud and clear. What can I do for you?"
    // came back through the mic as input 42s/77s after Gemini said it, but a
    // newer turn had finished in between, so it was no longer in the pool
    // above and was treated as real speech). Older turns from
    // [_recentAudibleTurns] are checked too — but ONLY as a whole-turn
    // echo: the chunk must cover most of that turn. Our own prompts contain
    // command phrases ("say 'take the photo' when you're ready"), and
    // matching a short real command against any recent prompt is exactly
    // the false positive the P0 fix above removed.
    final now = DateTime.now();
    for (final turn in _recentAudibleTurns.reversed) {
      if (now.difference(turn.at) > _recentAudibleTurnsWindow) break;
      final turnWords = _normalizeForEchoCompare(turn.text).split(' ').where((w) => w.isNotEmpty).toList();
      if (turnWords.isEmpty ||
          chunkWords.length < _olderTurnEchoMinWords ||
          chunkWords.length < turnWords.length * _olderTurnEchoMinCoverage) {
        continue;
      }
      if (_chunkEchoesTurn(chunk, normalizedChunk, chunkWords, turn.text)) {
        _log_(
          'ECHO BACKSTOP: "$chunk" is a whole-turn echo of Gemini speech from '
          '${now.difference(turn.at).inSeconds}s ago ("${turn.text}")',
        );
        return true;
      }
    }
    // P1 FIX (CONFIRMED via flutter_run_log_new.txt, build #65): note that
    // a RECOGNIZED echo above is discarded regardless of whether it ALSO
    // matches a command pattern — see
    // [_logIfEchoDiscardWouldHaveMatchedATrigger]'s doc comment for why
    // that's now made visible in the log rather than silently accepted,
    // and this function's own header for why the matching itself is now
    // far less likely to be a false alarm in the first place.
    return false;
  }

  /// One candidate comparison for [_looksLikeGeminiEcho]: verbatim substring
  /// first, then [looksLikeCloseSequenceMatch].
  bool _chunkEchoesTurn(String chunk, String normalizedChunk, List<String> chunkWords, String candidate) {
    final normalizedCandidate = _normalizeForEchoCompare(candidate);
    if (normalizedCandidate.isEmpty) return false;
    if (normalizedCandidate.contains(normalizedChunk)) {
      _logIfEchoDiscardWouldHaveMatchedATrigger(chunk);
      return true;
    }
    final candidateWords = normalizedCandidate.split(' ').where((w) => w.isNotEmpty).toList();
    if (looksLikeCloseSequenceMatch(chunkWords, candidateWords)) {
      _log_(
        'ECHO BACKSTOP: "$chunk" did not match verbatim but closely matches (word-sequence edit distance, '
        'not unordered overlap) recent Gemini speech ("$candidate") — treating as likely ASR-drifted echo.',
      );
      _logIfEchoDiscardWouldHaveMatchedATrigger(chunk);
      return true;
    }
    return false;
  }

  String _normalizeForEchoCompare(String text) {
    return text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// P0 FIX (CONFIRMED via a real session: "Show me the estimate. Try me
  /// again. For example, show the job history or take a photo." — the
  /// technician's real request, followed in the SAME STT segment by this
  /// app's OWN scripted fallback prompt — `_unrecognizedUtteranceReplies`'
  /// "I missed that one. Try me again — for example, show the job history
  /// or take a photo." — leaking back and being transcribed as one
  /// continuous chunk). [_looksLikeGeminiEcho] is deliberately whole-chunk:
  /// it can only say "this ENTIRE chunk is (or isn't) essentially a
  /// near-verbatim echo," which correctly refuses to fire here — the
  /// chunk is NOT purely echo, it genuinely contains the technician's own
  /// words too, and discarding the whole thing would lose that.
  ///
  /// The actual longest-trailing-match search lives in
  /// `echo_sequence_matcher.dart`'s [longestTrailingEchoStrip] — same
  /// module, same reasoning as [looksLikeCloseSequenceMatch]/
  /// [wordEditDistance], and testable the same way. This is the thin
  /// screen-side wrapper: builds the SAME comparison pool
  /// ([_currentTurnAudiblyPlayedText]/[_lastCompletedTurnAudiblyPlayedText])
  /// [_looksLikeGeminiEcho] already uses, then does the actual slicing and
  /// logging.
  String _stripTrailingEchoContamination(String chunk) {
    final normalizedChunk = _normalizeForEchoCompare(chunk);
    final chunkWords = normalizedChunk.split(' ').where((w) => w.isNotEmpty).toList();
    final candidates = <List<String>>[
      for (final candidate in [_currentTurnAudiblyPlayedText, _lastCompletedTurnAudiblyPlayedText])
        _normalizeForEchoCompare(candidate).split(' ').where((w) => w.isNotEmpty).toList(),
    ];
    final stripCount = longestTrailingEchoStrip(chunkWords, candidates, minWords: _echoBackstopMinWords);
    if (stripCount == 0) return chunk;

    // Stripping happens on the NORMALIZED word list (letters/spaces only,
    // apostrophes already split) rather than the raw string — a raw-text
    // word count can differ from the normalized one (e.g. "don't" is one
    // raw word but two normalized ones), and every trigger matcher already
    // re-normalizes its input the same way internally, so handing them an
    // already-normalized, stripped string costs nothing downstream.
    final keptWords = chunkWords.sublist(0, chunkWords.length - stripCount);
    final stripped = keptWords.join(' ');
    _log_(
      'TRANSCRIPT CONTAMINATION STRIPPED: removed a trailing $stripCount-word run closely matching Gemini\'s '
      'own recent speech from "$chunk" -> "$stripped"',
    );
    return stripped;
  }

  /// STEP 3 audio-echo investigation: `FlutterPcmSound`'s self-reported
  /// `remainingFrames` hitting 0 doesn't guarantee the physical speaker has
  /// actually finished — native/OS audio buffering can lag behind what the
  /// plugin tracks by anywhere from tens to a couple hundred milliseconds.
  /// Resuming mic send the INSTANT `remainingFrames` hit 0 (the previous
  /// behavior) left a real window where trailing playback could still be
  /// audible and leak back into the mic, get sent to Gemini, and be
  /// transcribed as if it were fresh technician speech — a plausible
  /// explanation for `inputTranscription` lines that read like Gemini's own
  /// words. [_resumeGraceTimer] adds a short buffer before actually
  /// resuming; [_onResponseAudioChunk] cancels/restarts it if more audio
  /// arrives first, so a still-playing response is never cut short by this.
  Timer? _resumeGraceTimer;
  // P0 AUDIO-ECHO FIX (CONFIRMED via a real session: "Camera's open — ready
  // when you are." spoken identically three times, ~6-7s apart, each
  // immediately preceded by an ECHO BACKSTOP log discarding an
  // inputTranscription chunk that verbatim-matched this exact sentence —
  // i.e. echo was STILL leaking into the mic well after this delay had
  // already elapsed and sending had already resumed). Two earlier rounds
  // already raised this fixed delay once (250ms -> 400ms -> 600ms) chasing
  // the same symptom each time, and it was STILL too short — proof a
  // single fixed number can't be sized correctly here at all: how long
  // trailing speaker output takes to actually decay below what the mic
  // picks up depends on device speaker/mic proximity, room acoustics,
  // playback volume and how much the platform's own AEC (this app already
  // requests `AudioSource.voice_communication` — see `_startMicStreaming`
  // — which engages Android's built-in acoustic echo cancellation where
  // available) manages to suppress, none of which is knowable in advance
  // or stable run to run.
  //
  // So this is no longer the ONLY gate: [_resumeGraceDelay] is now
  // strictly the FLOOR for the ORIGINAL, narrower concern it was created
  // for (native PCM-buffer under-reporting, "tens to a couple hundred ms"
  // per FlutterPcmSound's own docs) — lowered back to a value that
  // reasoning actually justifies, since the much larger, more variable
  // acoustic-decay concern that drove it up to 600ms is now handled
  // separately, adaptively, by real signal instead of a guess: see
  // [_lastLoudMicChunkAt] and [_echoTailQuietRequirement], consulted in
  // [_maybeResumeOutgoingAudio] AFTER this floor has elapsed. The existing
  // [_micPauseWatchdogIdleThreshold] (2s) stays exactly as-is as the
  // ultimate backstop, so a noisy environment that never reports "quiet"
  // still can't stall the mic forever.
  static const Duration _resumeGraceDelay = Duration(milliseconds: 400);

  /// P0 AUDIO-ECHO FIX — see [_resumeGraceDelay]'s doc comment. Timestamp
  /// of the most recent mic chunk whose RMS amplitude exceeded
  /// [_speechRmsThreshold], updated unconditionally (paused or not) in
  /// [_trackSpeechLevel] — the one place per-chunk amplitude is already
  /// computed for every chunk that arrives, echo-relevant or not. Consulted
  /// only while [_outgoingAudioPaused], where "the mic just registered real
  /// energy" is the most direct available evidence that trailing speaker
  /// playback (or anything else audible) hasn't actually finished decaying
  /// yet, REGARDLESS of what `FlutterPcmSound`'s own self-reported queue
  /// depth says.
  DateTime? _lastLoudMicChunkAt;

  /// How long the mic must show NO chunk above [_speechRmsThreshold] before
  /// [_maybeResumeOutgoingAudio] treats the acoustic tail as genuinely
  /// settled. Deliberately tighter than [_utteranceBufferResetDebounce]
  /// (2s — exists to tolerate a technician's natural mid-sentence pause, a
  /// completely different concern) — this only needs to bridge real
  /// speaker ring-down, not wait out conversational pacing. Re-armed every
  /// time a new above-threshold chunk arrives during the wait (see
  /// [_maybeResumeOutgoingAudio]), so a longer-than-usual echo tail gets
  /// exactly as long as it actually needs, not a single fixed guess —
  /// capped only by the pre-existing [_micPauseWatchdogIdleThreshold] (2s)
  /// safety valve, which runs as a fully independent periodic check and
  /// forces a resume regardless if this ever stalls unreasonably long (a
  /// persistently noisy site, not decaying echo).
  static const Duration _echoTailQuietRequirement = Duration(milliseconds: 450);

  /// P0 AUDIO-ECHO FIX — see [_onInputTranscription]'s "ECHO TIMING" log
  /// line. Timestamp of the most recent point outgoing mic audio actually
  /// started sending again (a normal grace-period resume OR a watchdog
  /// force-resume — both are "the mic started sending" events equally
  /// relevant here), so a subsequent echo-flagged chunk can report exactly
  /// how long after resuming it arrived. This is the real, run-to-run
  /// measurement data this fix's own reasoning depends on: proof of
  /// whether [_resumeGraceDelay] + [_echoTailQuietRequirement] together are
  /// now wide enough, taken from the actual device instead of guessed at
  /// again.
  DateTime? _lastOutgoingMicResumedAt;

  /// BUG 2 fix: timestamp of the most recent GENUINE (non-suppressed,
  /// `_pcmReady`) `FlutterPcmSound.feed()` call — see
  /// [_maybeResumeOutgoingAudio]'s use of this. Closes a SEQUENCING race
  /// `_pcmRemainingFrames` alone can't: that field is only as fresh as the
  /// last native `OnFeedSamples` callback, so if `turnComplete` arrives in
  /// the SAME server message as (or immediately after) the last audio
  /// chunk, `_pcmRemainingFrames` can still read a STALE "drained" value
  /// from BEFORE that final `feed()` call's frames were ever reflected —
  /// letting `_maybeResumeOutgoingAudio` conclude playback is done when a
  /// chunk was, in wall-clock time, fed only moments ago. Requiring real
  /// elapsed time since the LAST feed (not just the plugin's own
  /// self-reported queue depth) closes that gap independently.
  DateTime? _lastAudioChunkFedAt;

  /// PART F (restored, generalized): whether Gemini's own in-flight/
  /// upcoming response audio for the CURRENT (now-stale) turn should be
  /// discarded on arrival rather than played — armed by
  /// [_interruptGeminiForDeterministicTrigger], which every deterministic
  /// trigger's informing step (and the new default-mute classifier from
  /// item 4) calls the instant it has something better to say than
  /// whatever Gemini might already be generating. There is no explicit
  /// cancel/interrupt message in the Live API client protocol (only
  /// `setup`/`clientContent`/`realtimeInput`/`toolResponse` exist) —
  /// sending a NEW `clientContent` turn IS the protocol-level interrupt
  /// signal; the server is expected to mark the stale turn
  /// `interrupted: true` in response. What that does NOT fix on its own:
  /// audio chunks for the stale turn that were already in flight/queued
  /// locally in `FlutterPcmSound`'s native buffer keep playing regardless,
  /// since that plugin has no partial-flush API (confirmed — its only
  /// methods are `setup`/`feed`/`setFeedThreshold`/`setFeedCallback`/
  /// `start`/`release`, nothing that clears an already-fed buffer). While
  /// `true`, [_onResponseAudioChunk] drops every incoming chunk instead of
  /// feeding it, so the technician hears silence (not the confused stale
  /// response) until the real interrupt/turnComplete signal for the OLD
  /// turn arrives.
  bool _suppressResponseAudioForDeterministic = false;

  /// P0 FIX (CONFIRMED via two separate real runs: one where queued PCM
  /// chunks for "I've uploaded the photo." got wiped by
  /// [_trackSpeechLevel]'s raw-amplitude "new utterance" reset — see that
  /// method's own doc comment — and a SECOND, DIFFERENT run where every
  /// chunk for the SAME line was instead dropped here, in
  /// [_onResponseAudioChunk], logged "DETERMINISTIC INTERRUPT: dropping
  /// N-byte response chunk (stale/superseded turn)"). Root cause of the
  /// second path: [_muteImmediatelyOnFirstChunkOfUtterance] preemptively
  /// re-arms [_suppressResponseAudioForDeterministic] the INSTANT any new
  /// transcript chunk arrives — including incidental background
  /// speech/mumbling that never resolves into any real command — racing
  /// against and re-suppressing the confirmation's own just-requested audio
  /// before it ever plays. The turn-interrupt system treats ALL Gemini
  /// audio as equally interruptible, with no notion that some of it is a
  /// direct, app-triggered consequence of an action the app itself just
  /// took (a real upload that took real seconds) and deserves priority over
  /// an utterance that hasn't resolved into anything yet.
  ///
  /// True for a short, bounded grace window (see
  /// [_protectedConfirmationGraceDuration]) starting the instant a
  /// protected confirmation (currently: confirm_photo_upload's own
  /// "uploaded" line) is requested. While true,
  /// [_muteImmediatelyOnFirstChunkOfUtterance] does NOT preemptively mute
  /// for an incidental utterance that hasn't matched anything yet — a
  /// GENUINE resolved command (open_camera, retake_photo, a real KB
  /// question, ...) still interrupts normally through its own trigger-
  /// specific [_interruptGeminiForDeterministicTrigger] call once it
  /// actually matches; only the blind, unconditional "mute on literally any
  /// new chunk" head-start is deferred for this window. Auto-clears via
  /// [_protectedConfirmationTimer] rather than needing to track exactly
  /// which turn a later `interrupted`/`turnComplete` server message belongs
  /// to (the Live API gives no turn ID to key off).
  bool _protectedConfirmationActive = false;
  Timer? _protectedConfirmationTimer;

  /// Generous for a short spoken confirmation sentence's worth of TTS
  /// generation + playback (a real observed case took ~1s from request to
  /// first audio byte) without leaving normal preemptive-mute responsiveness
  /// degraded for any longer than necessary.
  static const Duration _protectedConfirmationGraceDuration = Duration(seconds: 8);

  /// See [_protectedConfirmationActive]'s doc comment.
  void _beginProtectedConfirmation() {
    _protectedConfirmationActive = true;
    _protectedConfirmationTimer?.cancel();
    _protectedConfirmationTimer = Timer(_protectedConfirmationGraceDuration, () {
      _protectedConfirmationActive = false;
      _protectedConfirmationTimer = null;
    });
  }

  /// Safety net for [_suppressResponseAudioForDeterministic]: cleared the
  /// instant a genuine `interrupted`/`turnComplete` server message arrives
  /// (see [_onServerMessage]), but if the server never sends either for
  /// some reason, this guarantees playback un-mutes on its own instead of
  /// staying silently muted for the rest of the session.
  ///
  /// HONEST LIMITATION: `turnComplete`/`interrupted` don't carry a turn ID,
  /// so if the stale generation had ALREADY fully finished by the moment
  /// this fires (no genuine overlap this time), the very next
  /// `turnComplete`/`interrupted` this code sees will actually belong to
  /// the NEW, correct, deterministic-informed response — clearing
  /// suppression at that point is too late to have played it, so that
  /// response's audio would be silently dropped instead. Keeping this delay
  /// short bounds how much of a genuinely-new response can be lost to that
  /// edge case; `interrupted` (as opposed to `turnComplete`) is the
  /// stronger signal of the two — the server only ever sends it in
  /// response to a genuine barge-in — but both are handled the same way
  /// here since there's no way to tell them apart from the wire alone.
  Timer? _suppressResponseAudioSafetyTimer;
  static const Duration _suppressResponseAudioSafetyDelay = Duration(milliseconds: 1200);

  /// P0 FIX — see [_interruptGeminiForDeterministicTrigger]'s doc comment.
  /// Used instead of [_suppressResponseAudioSafetyDelay] whenever
  /// [_turnComplete] was ALREADY true the instant a deterministic trigger's
  /// own interrupt call fired — meaning there was genuinely nothing
  /// mid-turn for the server to ever send an `interrupted`/`turnComplete`
  /// ack for, so waiting the full delay only blocks THIS SAME call's own
  /// brand new audio behind a signal that will never arrive. Still long
  /// enough to safely drop a couple of already-in-flight network chunks
  /// from a genuinely old turn, if any physically remain.
  static const Duration _suppressResponseAudioSafetyDelayWhenIdle = Duration(milliseconds: 150);

  /// BUG 1 fix (CONFIRMED crash: `PlatformException(Setup, must call setup
  /// first)`, repeated): root-caused to a race between
  /// [_interruptGeminiForDeterministicTrigger]'s async `release()` +
  /// `setup()` reinit (needed because `FlutterPcmSound` has no partial-flush
  /// API — see that method's doc comment) and
  /// [_suppressResponseAudioForDeterministic] being cleared independently,
  /// by a SEPARATE code path ([_clearDeterministicAudioSuppression] on
  /// `turnComplete`/`interrupted`, or the safety timeout) — nothing
  /// previously stopped that clear from happening WHILE `release()` had
  /// already torn down the native player but `setup()` hadn't finished
  /// re-establishing it yet. The instant suppression cleared, the very next
  /// response chunk's `FlutterPcmSound.feed()` call in
  /// [_onResponseAudioChunk] hit the native side with no completed `setup()`
  /// behind it — exactly this exception. `_pcmReady` is a SEPARATE, purely
  /// mechanical "is it actually safe to call `feed()` right now" gate,
  /// independent of whether we WANT to play what arrives (that's still
  /// [_suppressResponseAudioForDeterministic]'s job) — [_onResponseAudioChunk]
  /// checks both before ever calling `feed()`. Starts `false`; set `true`
  /// only once the initial `setup()` in `_startTest` completes, and briefly
  /// `false` again during every [_interruptGeminiForDeterministicTrigger]
  /// reinit.
  bool _pcmReady = false;

  /// Serializes every `release()`+`setup()` reinit through one chained
  /// Future — without this, two deterministic triggers firing close together
  /// (the whole open_camera -> capture_photo flow can do exactly this) could
  /// call `release()`/`setup()` concurrently on the SAME platform channel,
  /// which is itself a second, independent way to hit "must call setup
  /// first" (whichever call's `release()` lands between the other's
  /// `release()` and `setup()`). Each new reinit chains onto whatever the
  /// previous one left pending, so the native side only ever sees one
  /// release/setup pair in flight at a time.
  Future<void> _pcmReinitChain = Future<void>.value();

  /// Bumped on every [_interruptGeminiForDeterministicTrigger] call — a
  /// reinit only marks [_pcmReady] `true` when it's still the MOST RECENT
  /// one requested by the time it finishes, so a stale/superseded reinit
  /// (superseded by a newer trigger that fired before the old one finished)
  /// can never mark readiness for a player state that's already been torn
  /// down again by the newer one.
  int _pcmReinitGeneration = 0;

  /// Resumes sending mic audio to Gemini once BOTH the server has said the
  /// turn is done (`_turnComplete`) AND playback has actually drained
  /// everything queued for it (`_pcmRemainingFrames <= 0`) — checking only
  /// the server signal would resume while the speaker is still audibly
  /// finishing the response, recreating the same mic-picks-up-speaker
  /// problem this is meant to fix. Called both from the
  /// turnComplete/interrupted handling in [_onServerMessage] and from
  /// [_onPcmFeedCallback], since either can be the one that arrives second.
  /// MIC WATCHDOG (CONFIRMED via build #38's flutter_run_log.txt, two ~55s
  /// stalls: mic paused 13:51:42 -> resumed 13:52:37, and 13:52:46 ->
  /// 13:53:41, both resolving right around the 50s inactivity warning). The
  /// normal resume path in [_maybeResumeOutgoingAudio] needs BOTH a server
  /// `turnComplete`/`interrupted` AND a native feed callback reporting
  /// drained playback. After a client-side interrupt ([_interruptGeminiForDeterministicTrigger]
  /// tears the native player down with release()/setup()) neither is
  /// guaranteed: the stale turn's server signal can be late/absent, and the
  /// native feed callback has nothing left to fire about — so the only thing
  /// that ever re-ran the check was some unrelated event. This watchdog does
  /// not depend on either signal: it polls independently for as long as the
  /// mic is paused, and force-resumes once the estimated real end of
  /// playback ([_expectedPlaybackEndAt], derived from the bytes actually
  /// fed) is more than [_micPauseWatchdogIdleThreshold] in the past.
  Timer? _micPauseWatchdogTimer;
  DateTime? _micPausedAt;
  DateTime? _expectedPlaybackEndAt;
  static const Duration _micPauseWatchdogPollInterval = Duration(seconds: 1);
  static const Duration _micPauseWatchdogIdleThreshold = Duration(seconds: 2);

  void _startMicPauseWatchdog() {
    _micPausedAt = DateTime.now();
    _micPauseWatchdogTimer?.cancel();
    _micPauseWatchdogTimer = Timer.periodic(_micPauseWatchdogPollInterval, (_) => _checkMicPauseWatchdog());
  }

  void _stopMicPauseWatchdog() {
    _micPauseWatchdogTimer?.cancel();
    _micPauseWatchdogTimer = null;
    _micPausedAt = null;
  }

  /// Force-resumes the mic if it's paused and no genuine playback is (or is
  /// expected to still be) underway. [idleThreshold] is shortened by the
  /// mute/drop paths (see [_onResponseAudioChunk]) — chunks being DROPPED
  /// are proof nothing real is playing for them, so there's no reason to
  /// wait out the full default.
  void _checkMicPauseWatchdog({Duration idleThreshold = _micPauseWatchdogIdleThreshold}) {
    if (!_outgoingAudioPaused) {
      _stopMicPauseWatchdog();
      return;
    }
    // ECHO LOOP FIX — see [_pcmFeedsInFlight]: audio still on its way to
    // the native player hasn't even started playing yet, so nothing about
    // it can be "idle". Capped: a feed that hasn't come back 30s after the
    // last chunk was sent is never going to, and the mic must not stay
    // paused forever on it.
    //
    // Nor while the player still reports queued frames or hasn't confirmed
    // it played everything (CONFIRMED in a real trace: every one of six
    // echo transcripts came right after this watchdog force-resumed on its
    // time estimate — once with 7341 frames still reported queued — while
    // the reply was still playing, 2.6-11.7s before the player's own "0
    // remaining" arrived).
    final now = DateTime.now();
    final lastFedAt = _lastAudioChunkFedAt;
    final playerNotConfirmedDone = _pcmFeedsInFlight > 0 || _pcmRemainingFrames > 0 || !_nativePlaybackDrainConfirmed;
    if (playerNotConfirmedDone && lastFedAt != null && now.difference(lastFedAt) < const Duration(seconds: 30)) {
      return;
    }
    final pausedAt = _micPausedAt ?? now;
    // Idle time is measured from whichever is LATEST: when the pause began,
    // when the audio we fed should have finished playing counting from when
    // we SENT it, or counting from when the native player actually GOT it
    // ([_ackBasedPlaybackEndAt] — later than the first whenever the Android
    // main thread delays delivery, which the camera screens routinely do).
    var idleSince = pausedAt;
    for (final end in [_expectedPlaybackEndAt, _ackBasedPlaybackEndAt]) {
      if (end != null && end.isAfter(idleSince)) idleSince = end;
    }
    final idleFor = now.difference(idleSince);
    if (idleFor < idleThreshold) return;
    final stuckMs = now.difference(pausedAt).inMilliseconds;
    _log_(
      'MIC WATCHDOG: forcing resume after ${stuckMs}ms stuck paused (no audio playing or expected to be playing '
      'for ${idleFor.inMilliseconds}ms; turnComplete=$_turnComplete, pcmRemainingFrames=$_pcmRemainingFrames)',
    );
    _resumeGraceTimer?.cancel();
    _resumeGraceTimer = null;
    _turnComplete = true;
    _outgoingAudioPaused = false;
    _stopMicPauseWatchdog();
    // P0 AUDIO-ECHO FIX — see [_lastOutgoingMicResumedAt]'s doc comment: a
    // forced watchdog resume is still "the mic started sending again" for
    // the ECHO TIMING measurement's purposes, so it counts too.
    _lastOutgoingMicResumedAt = DateTime.now();
    _syncVoicePhase();
    _resetInactivityTimer(reason: 'mic watchdog forced resume');
  }

  void _maybeResumeOutgoingAudio() {
    if (!_outgoingAudioPaused) return;
    if (!_turnComplete) return;
    if (_pcmRemainingFrames > 0) return;
    // ECHO LOOP FIX — see [_pcmFeedsInFlight]. `_pcmRemainingFrames == 0`
    // only means "drained" if it was reported AFTER the native player had
    // received every chunk we fed; before that it's a stale reading of an
    // empty queue the reply hasn't reached yet.
    if (!_nativePlaybackDrainConfirmed) return;
    if (_pcmPrebuffer.isNotEmpty) return; // jitter buffer still holds audio not yet written
    if (_resumeGraceTimer != null) return;
    _log_(
      'outgoing mic audio: playback appears drained — waiting at least ${_resumeGraceDelay.inMilliseconds}ms '
      '(native-buffer floor) before resuming, then requiring the mic itself to report '
      '${_echoTailQuietRequirement.inMilliseconds}ms of genuine quiet on top of that (P0 audio-echo fix — see '
      '[_resumeGraceDelay]\'s doc comment for why a single fixed delay alone was proven insufficient)',
    );
    // P0 AUDIO-ECHO FIX: every re-arm below now schedules
    // [_resumeGraceTimerFired] itself (never this outer method) as the
    // timer callback, and that shared callback unconditionally nulls
    // [_resumeGraceTimer] as its very first line. Previously a re-armed
    // timer's callback was this SAME outer method, whose own guard
    // (`if (_resumeGraceTimer != null) return;`, checked above) would
    // still see its own not-yet-nulled Timer object as "in flight" the
    // instant it fired — silently swallowing that resume attempt entirely
    // until the separate 2s mic-pause watchdog eventually bailed it out.
    // Rare in practice (only the BUG 2 lastFed race path could hit it),
    // but the new echo-tail re-arm below would hit this same trap far more
    // routinely (it's expected to re-arm whenever real trailing echo is
    // detected), so this is fixed as part of building it correctly rather
    // than inherited.
    _resumeGraceTimer = Timer(_resumeGraceDelay, _resumeGraceTimerFired);
  }

  void _resumeGraceTimerFired() {
    _resumeGraceTimer = null;
    // Re-check: more audio may have arrived (a new response chunk, or the
    // turn was un-completed) since this timer was armed.
    if (!_outgoingAudioPaused || !_turnComplete || _pcmRemainingFrames > 0) {
      _log_('outgoing mic audio: grace period elapsed but conditions changed — not resuming yet');
      return;
    }
    // BUG 2 fix: also require real wall-clock time since the last GENUINE
    // feed() call — closes a sequencing race `_pcmRemainingFrames` alone
    // can't (see [_lastAudioChunkFedAt]'s doc comment: that field is only
    // as fresh as the last native callback, so it can still read
    // "drained" from BEFORE the last chunk's `feed()` call is reflected).
    // If a chunk was genuinely fed more recently than the full grace
    // delay, wait out the remainder instead of resuming early.
    final lastFed = _lastAudioChunkFedAt;
    if (lastFed != null) {
      final elapsed = DateTime.now().difference(lastFed);
      if (elapsed < _resumeGraceDelay) {
        final remaining = _resumeGraceDelay - elapsed;
        _log_(
          'outgoing mic audio: last chunk fed only ${elapsed.inMilliseconds}ms ago (< '
          '${_resumeGraceDelay.inMilliseconds}ms floor) — waiting ${remaining.inMilliseconds}ms more before '
          'resuming',
        );
        _resumeGraceTimer = Timer(remaining, _resumeGraceTimerFired);
        return;
      }
    }
    // P0 AUDIO-ECHO FIX — the real fix. The native-buffer floor above has
    // now genuinely elapsed; before resuming, also require the MIC ITSELF
    // to have shown no above-threshold energy for [_echoTailQuietRequirement]
    // — real evidence trailing speaker output has actually decayed, rather
    // than trusting a fixed delay to have guessed correctly. If the mic
    // registered energy very recently (real echo still audible, OR the
    // technician has already started talking over the tail — either way,
    // sending right now risks exactly the leak this whole mechanism exists
    // to prevent), wait out the remainder and re-check; re-armed for as
    // long as fresh energy keeps arriving, bounded only by the existing,
    // fully independent [_micPauseWatchdogIdleThreshold] (2s) safety valve
    // so persistent background noise (a loud job site, not decaying echo)
    // can never stall the mic indefinitely.
    final lastLoud = _lastLoudMicChunkAt;
    if (lastLoud != null) {
      final sinceLoud = DateTime.now().difference(lastLoud);
      if (sinceLoud < _echoTailQuietRequirement) {
        final remaining = _echoTailQuietRequirement - sinceLoud;
        _log_(
          'outgoing mic audio: mic registered real energy ${sinceLoud.inMilliseconds}ms ago (< '
          '${_echoTailQuietRequirement.inMilliseconds}ms quiet requirement) — likely still-decaying speaker '
          'echo, waiting ${remaining.inMilliseconds}ms more before resuming (P0 audio-echo adaptive fix)',
        );
        _resumeGraceTimer = Timer(remaining, _resumeGraceTimerFired);
        return;
      }
    }
    _outgoingAudioPaused = false;
    _stopMicPauseWatchdog();
    final now = DateTime.now();
    _lastOutgoingMicResumedAt = now;
    _log_(
      'outgoing mic audio RESUMED (response playback finished, ${_resumeGraceDelay.inMilliseconds}ms floor '
      'elapsed, mic quiet for >= ${_echoTailQuietRequirement.inMilliseconds}ms)',
    );
    _syncVoicePhase();
    // P0 FIX (CONFIRMED regression, REMOVED — was: resetting the
    // inactivity timer here too "so a session kept alive purely by long
    // back-and-forth turns never times out while genuinely active"):
    // this made the 50s-warning/60s-close pair unreliable to the point of
    // never firing at all. [_fireInactivityWarning] speaks its own "Still
    // there?" line through this EXACT pause->resume cycle — so the very
    // act of warning the technician immediately re-armed the FULL 50s/60s
    // window again, every time, forever. CONFIRMED via a real session:
    // the warning spoke in full three separate times over ~75s and the
    // session never actually closed. The genuine "a long real response
    // must not be mistaken for silence" concern this was protecting is
    // already covered by TWO other, more targeted mechanisms that don't
    // have this self-defeating property: [_inFlightFunctionCalls] (every
    // dispatch, deterministic or toolCall, suspends both timers for its
    // own duration — this is what actually protects a slow open_camera/
    // get_kb_answer call, not this site) and the genuine technician input
    // that started the exchange in the first place (which already reset
    // the full window via 'technician transcription chunk received'
    // before Gemini ever started responding). Neither of those can be
    // re-triggered by Gemini's own voice the way this site could.
  }

  /// [FlutterPcmSound.setFeedCallback] fires with how many sample frames are
  /// still buffered for playback — used only to detect "playback has fully
  /// drained" for [_maybeResumeOutgoingAudio]; nothing here needs feeding on
  /// demand since chunks are pushed in directly as they arrive over the
  /// WebSocket (see [_onResponseAudioChunk]).
  void _onPcmFeedCallback(int remainingFrames) {
    _pcmRemainingFrames = remainingFrames;
    // This report was sent by the native side after it had processed every
    // feed() already acknowledged back to us (both travel the same
    // platform-channel queue, in order) — so it describes those chunks.
    _pcmFeedSeqAtLastReport = _pcmFeedSeqAcked;
    if (remainingFrames == 0 && _nativePlaybackDrainConfirmed) _nativePlaybackEndConfirmedAt = DateTime.now();
    _maybeResumeOutgoingAudio();
  }

  /// ECHO LOOP FIX (CONFIRMED in a real trace, every instance on the camera
  /// screens): the mic resumed at 14:58:42.167 on a "playback drained"
  /// reading, and only AFTER that did the native player report
  /// `remaining_frames: 5675 … 7975 … 0` — Gemini's "Camera's open — ready
  /// when you are." was still queued and then played into the open mic,
  /// which transcribed it as the technician speaking, and the replies to
  /// those echoes echoed in turn. Cause: `FlutterPcmSound.feed()` and the
  /// native "frames remaining" report both travel through the Android main
  /// thread, which the camera keeps busy for seconds at a time (the
  /// capture probe measured 2.4-19s round trips), so the reply was still in
  /// transit to the player when the stale "0 remaining" was read as
  /// drained. These three track what the native side has actually
  /// confirmed: feeds not yet acknowledged, the newest acknowledged feed,
  /// and which acknowledged feed the latest remaining-frames report covers.
  int _pcmFeedsInFlight = 0;
  int _pcmFeedSeq = 0;
  int _pcmFeedSeqAcked = 0;
  int _pcmFeedSeqAtLastReport = 0;

  /// Earliest the fed audio can finish playing, counting from when the
  /// native player acknowledged each chunk rather than when it was sent.
  DateTime? _ackBasedPlaybackEndAt;

  /// Every chunk fed has reached the native player, and its latest
  /// remaining-frames report was sent after that.
  bool get _nativePlaybackDrainConfirmed => _pcmFeedsInFlight == 0 && _pcmFeedSeqAtLastReport == _pcmFeedSeq;

  /// The native player (and its queue) was torn down and rebuilt — nothing
  /// fed before this can still play, so nothing is left to confirm.
  void _markNativePlaybackQueueReset() {
    _pcmFeedSeqAcked = _pcmFeedSeq;
    _pcmFeedSeqAtLastReport = _pcmFeedSeq;
    _nativePlaybackEndConfirmedAt = DateTime.now();
  }

  /// Matches the `rate=<digits>` parameter Gemini puts on the response
  /// inlineData's `mimeType`, e.g. `audio/pcm;rate=24000`.
  static final RegExp _mimeTypeRateRegExp = RegExp(r'rate=(\d+)');

  /// FIX 1: called the instant a deterministic trigger succeeds, BEFORE the
  /// matching informing step sends its `clientContent` turn (which is
  /// itself the protocol-level interrupt signal — see
  /// [_suppressResponseAudioForDeterministic]'s doc comment). Two things,
  /// both necessary:
  ///  1. Hard-stops whatever's CURRENTLY audible right now — `release()`
  ///     then a fresh `setup()`+`start()` is the only way to discard
  ///     already-queued samples with this plugin (no flush API exists), so
  ///     this is a full teardown/reinit of the native audio player, not a
  ///     graceful pause.
  ///  2. Arms [_suppressResponseAudioForDeterministic] so any chunk for the
  ///     now-stale turn that's still in flight over the WebSocket (network
  ///     jitter — it was sent before the interrupt reached the server) gets
  ///     dropped on arrival instead of played, until the server confirms
  ///     the stale turn is actually closed out (`interrupted`/`turnComplete`
  ///     in [_onServerMessage]) or [_suppressResponseAudioSafetyDelay]
  ///     elapses, whichever first.
  void _interruptGeminiForDeterministicTrigger(String reason) {
    // P0 FIX (CONFIRMED via flutter_run_log_new.txt, build #63): the
    // "protected confirmation" fix from the previous round stopped an
    // INCIDENTAL utterance from re-arming suppression, but did nothing
    // about THIS call's own initiating interrupt — confirm_photo_upload's
    // post-success "I've uploaded the photo." request goes through
    // [_informGeminiToSpeakVerbatim], which calls this method FIRST,
    // before sending the clientContent instruction. That call sets
    // [_suppressResponseAudioForDeterministic] true (correct — it must cut
    // off any STALE prior audio before the new instruction goes out), but
    // then [_armSuppressResponseAudioSafetyTimer] waited the FULL
    // [_suppressResponseAudioSafetyDelay] (1.2s) for a server
    // `interrupted`/`turnComplete` ack that, in this exact scenario,
    // NEVER ARRIVES — because the previous turn had already completed
    // cleanly ~9 seconds earlier (the whole upload duration), so there was
    // genuinely nothing mid-turn to interrupt in the first place. The
    // confirmation's OWN brand new audio started streaming back almost
    // immediately and got dropped as "stale/superseded" for the entire
    // 1.2s, chunk by chunk, until the safety timeout finally fired — by
    // which point the whole line had already played out and been
    // discarded.
    //
    // [_turnComplete] (true only once a turn has genuinely finished AND no
    // new response has started arriving — see its own doc comment)
    // captured HERE, before anything below changes it, tells us exactly
    // whether there's a genuine mid-turn stale response to wait for an ack
    // on. When there isn't, the safety timer uses a much shorter delay —
    // still enough to safely drop a couple of already-in-flight network
    // chunks from a truly old turn, if any, but not a full 1.2s blocking
    // this call's own just-requested audio.
    final safetyDelay = _turnComplete ? _suppressResponseAudioSafetyDelayWhenIdle : _suppressResponseAudioSafetyDelay;
    // Snapshot BEFORE anything below zeroes it: was the native player
    // actually holding any audio? Outgoing mic audio only resumes once
    // playback has fully drained (see [_maybeResumeOutgoingAudio]), and
    // [_pcmRemainingFrames] is the native queue's own report — so with the
    // mic sending and nothing reported queued, a release/setup below would
    // have nothing to discard. See the camera branch in the reinit chain.
    // Also requires the player's own confirmation that it played every
    // chunk we fed it ([_nativePlaybackDrainConfirmed]) — the time estimate
    // alone was proven wrong by seconds on the camera screens.
    final nativePlaybackWasIdle = !_outgoingAudioPaused &&
        _pcmRemainingFrames == 0 &&
        _nativePlaybackDrainConfirmed &&
        !(_expectedPlaybackEndAt?.isAfter(DateTime.now()) ?? false);
    // PART F items 4-5: any REAL resolution (a known trigger firing, or
    // the KB catch-all's own real answer/boundary decline — anything
    // other than the preemptive mute's own initial call) graduates/
    // supersedes the preemptive default-mute — this is the ONE place that
    // clears it, so every resolution path unmutes correctly without
    // needing its own special-case wiring.
    if (_preemptiveDefaultMuteActive && reason != 'preemptive_default_mute') {
      _log_('PREEMPTIVE DEFAULT MUTE: real resolution ("$reason") superseded the preemptive mute — clearing it.');
      _preemptiveDefaultMuteActive = false;
      _preemptiveDefaultMuteSafetyTimer?.cancel();
      _preemptiveDefaultMuteSafetyTimer = null;
    }
    _log_('DETERMINISTIC INTERRUPT: muting/discarding any in-progress Gemini audio ($reason)');
    debugPrint('PHOTO TIMING [interrupt]: deterministic trigger cutting off Gemini\'s own response ($reason)');
    // P0 FIX — see [_currentResponseTurnId]'s doc comment: unconditionally,
    // every call (not gated on whether a real PCM reinit happens below) —
    // "I'm about to ask for something new" is true regardless of whether
    // the native player itself needs rebuilding.
    _currentResponseTurnId++;
    _suppressResponseAudioForDeterministic = true;
    _pcmRemainingFrames = 0;
    _discardPcmPrebuffer('deterministic interrupt');
    // MIC WATCHDOG — the native player is being torn down right now, so
    // whatever was queued for playback is silenced immediately: the
    // estimated playback end is now, not whenever the discarded audio would
    // have finished.
    _expectedPlaybackEndAt = DateTime.now();
    // BUG 1 fix: `_pcmReady = false` is set SYNCHRONOUSLY, right now, before
    // any `await` — so even if `_suppressResponseAudioForDeterministic`
    // gets cleared a moment later by a completely independent code path
    // (turnComplete/interrupted arriving, or the safety timeout),
    // [_onResponseAudioChunk] still can't call `feed()` until this reinit
    // has genuinely finished and confirmed itself still current.
    // PART J item 1 — see [_pcmReinitIssuedForCurrentUtterance]'s doc
    // comment: at most ONE real PCM reinit per utterance, no matter how
    // many times this function is called for it. Every OTHER effect above
    // (suppress-flag, preemptive-mute graduation) still runs on every call —
    // only the expensive native teardown/rebuild is skipped past the first.
    if (_pcmReinitIssuedForCurrentUtterance) {
      debugPrint(
        'PHOTO TIMING [interrupt]: PCM reinit SKIPPED (no-op, reason=$reason) — already reinitialized once for '
        'this utterance (generation $_pcmReinitGeneration)',
      );
      _armSuppressResponseAudioSafetyTimer(safetyDelay);
      return;
    }
    _pcmReinitIssuedForCurrentUtterance = true;

    _pcmReady = false;
    final myGeneration = ++_pcmReinitGeneration;
    // Chains onto whatever reinit (if any) is already in flight, rather than
    // firing a second concurrent release()/setup() pair at the native side —
    // see [_pcmReinitChain]'s doc comment.
    _pcmReinitChain = _pcmReinitChain.then((_) async {
      // CAPTURE SPEED FIX (CONFIRMED via a real trace: platform_capture_call
      // took 11.1s, ~6.4s of it BEFORE CameraX even started the capture).
      // FlutterPcmSound's release()/setup() both run `cleanup()` ON THE
      // ANDROID MAIN THREAD, which joins the playback thread (blocked in a
      // WRITE_BLOCKING AudioTrack write) — measured 0.8-4.4s per reinit in
      // that trace, and this reinit is issued on the first transcript chunk
      // of EVERY utterance, i.e. milliseconds before the capture/open it
      // resolves to starts its own chain of main-thread CameraX calls. When
      // that camera call is in flight AND the player held nothing to
      // discard (the normal case: the technician could only be heard
      // because playback had already drained), tearing the player down
      // bought nothing and cost the camera seconds — so the native
      // release/setup is skipped. Every other effect of the interrupt
      // (turn id bump, Dart-side suppression and prebuffer discard) already
      // ran above, unchanged; if anything WAS playing, this reinit runs
      // exactly as before.
      //
      // LATENCY FIX (CONFIRMED in the next trace): the same skip now applies
      // whenever the player is confirmed idle, not only during a camera
      // call. Every large reply-latency spike in that trace (19.1s, 16.7s,
      // 11.5s, and a 15s-late scripted line) was a scripted reply that
      // Gemini had generated correctly within ~0.7s, then held in the PCM
      // queue behind one of these release/setup pairs taking 1.5-15s on the
      // congested main thread — while the player had nothing to discard.
      if (nativePlaybackWasIdle) {
        if (myGeneration == _pcmReinitGeneration) {
          _pcmReady = true;
          debugPrint(
            'PHOTO TIMING [interrupt]: PCM reinit SKIPPED — player confirmed idle (generation $myGeneration, '
            'reason=$reason, cameraNativeCallInProgress=$_cameraNativeCallInProgress) — nothing was queued for '
            'playback, and release/setup would hold the next reply behind seconds of Android main-thread work',
          );
          _flushQueuedPcmChunksForGeneration(myGeneration);
        }
        return;
      }
      try {
        final nativeWatch = Stopwatch()..start();
        await FlutterPcmSound.release();
        final releaseMs = nativeWatch.elapsedMilliseconds;
        await FlutterPcmSound.setup(sampleRate: _outputSampleRateHz, channelCount: 1);
        // Every feed sent before the release was processed ahead of it
        // (same platform queue), then destroyed with the old player.
        _markNativePlaybackQueueReset();
        debugPrint(
          'PHOTO TIMING [interrupt]: PCM native release took ${releaseMs}ms, setup took '
          '${nativeWatch.elapsedMilliseconds - releaseMs}ms (both on the Android main thread; '
          'cameraNativeCallInProgress=$_cameraNativeCallInProgress)',
        );
        FlutterPcmSound.setFeedCallback(_onPcmFeedCallback);
        FlutterPcmSound.start();
        if (myGeneration == _pcmReinitGeneration) {
          _pcmReady = true;
          debugPrint('PHOTO TIMING [interrupt]: PCM reinit complete (generation $myGeneration) — feed() safe again');
          _flushQueuedPcmChunksForGeneration(myGeneration);
        } else {
          debugPrint(
            'PHOTO TIMING [interrupt]: PCM reinit generation $myGeneration finished but generation '
            '$_pcmReinitGeneration already superseded it — NOT marking ready (that newer reinit owns readiness now)',
          );
        }
      } catch (e, stackTrace) {
        debugPrint('GEMINI LIVE TEST ERROR (interrupt: PCM reinit): $e\n$stackTrace');
      }
    });
    _armSuppressResponseAudioSafetyTimer(safetyDelay);
  }

  /// ISSUE 3(b) (CONFIRMED via f5a8bd8b-flutter_run_log.txt: this 1.2s
  /// safety timeout un-muted Gemini's audio while the technician's real
  /// get_kb_answer request was still genuinely being resolved — a stale/
  /// forbidden general-knowledge fragment played audibly in the resulting
  /// window before the request actually finished). Un-muting after a fixed
  /// delay is only correct for the genuine "nothing is happening, stop
  /// waiting" case — a real dispatch that's simply slow (backend latency,
  /// not a bug on its own) must never be treated the same way. Checks
  /// [_inFlightFunctionCalls] (see [_beginFunctionCallInFlight]/
  /// [_endFunctionCallInFlight] — incremented the instant ANY real function
  /// call, deterministic or genuine toolCall, starts dispatching) before
  /// actually un-muting: if something is still genuinely in flight, this
  /// defers by re-arming itself for another [delay] instead, repeating for
  /// as long as that stays true. Only un-mutes once nothing is pending — a
  /// genuine STT/pattern-match failure with no dispatch to wait for at all.
  /// [delay] is [_suppressResponseAudioSafetyDelay] normally, or the much
  /// shorter [_suppressResponseAudioSafetyDelayWhenIdle] when the caller
  /// ([_interruptGeminiForDeterministicTrigger]) already knew nothing was
  /// genuinely mid-turn — see that method's doc comment.
  void _armSuppressResponseAudioSafetyTimer(Duration delay) {
    _suppressResponseAudioSafetyTimer?.cancel();
    _suppressResponseAudioSafetyTimer = Timer(delay, () {
      if (!_suppressResponseAudioForDeterministic) return;
      if (_inFlightFunctionCalls > 0) {
        _log_(
          'DETERMINISTIC INTERRUPT: safety timeout (${delay.inMilliseconds}ms) reached but '
          '$_inFlightFunctionCalls function call(s) still genuinely in flight — deferring un-mute instead of '
          'letting a stale/forbidden response play over a real dispatch still in progress; checking again in '
          'another ${delay.inMilliseconds}ms.',
        );
        _armSuppressResponseAudioSafetyTimer(delay);
        return;
      }
      _log_(
        'DETERMINISTIC INTERRUPT: safety timeout (${delay.inMilliseconds}ms) — no '
        'interrupted/turnComplete seen for the stale turn, nothing genuinely in flight either, un-muting anyway',
      );
      _suppressResponseAudioForDeterministic = false;
    });
  }

  /// PART F item 3 (client-confirmed regression: the original "speak this
  /// word for word, exactly as written — do not paraphrase, shorten,
  /// second-guess, or add anything from your own general knowledge"
  /// framing wasn't tight enough — Gemini padded canned/boundary text with
  /// unsolicited preamble, e.g. "I can help with tasks like drafting..."
  /// before finally saying the actual line, instead of treating it as a
  /// fixed script). Tightened to an explicit, constrained script-reading
  /// instruction and centralized here — every canned/deterministic
  /// informing call site in this file goes through this ONE function now,
  /// so the wording can never drift back out of sync between them.
  /// Calls [_interruptGeminiForDeterministicTrigger] first, exactly like
  /// every informing call already did, so whatever Gemini might already be
  /// generating for the ORIGINAL utterance is cut off before this new,
  /// correct turn plays.
  ///
  /// P0 investigation (double-generation regression — see
  /// [_currentResponseTurnId]'s doc comment for the actual fix): confirmed
  /// this file's OWN existing doc comments are correct that the Live API
  /// client protocol has no separate cancel-then-wait-then-instruct
  /// exchange — `setup`/`clientContent`/`realtimeInput`/`toolResponse` are
  /// the entire client message vocabulary, so sending a new `clientContent`
  /// turn IS simultaneously the interrupt signal AND the new instruction;
  /// there is no earlier, separate message this method could send and
  /// await an ack for before the real instruction goes out. This method
  /// already sends its interrupt (via [_interruptGeminiForDeterministicTrigger])
  /// as early as this app's text-based trigger matching can possibly fire
  /// (synchronously, the instant a match resolves — see
  /// [_muteImmediatelyOnFirstChunkOfUtterance], which goes further and
  /// interrupts unconditionally on an utterance's FIRST transcript chunk,
  /// before any specific trigger has even matched). Given the model can
  /// start generating a free-text reply from raw realtimeInput audio
  /// BEFORE this app's own transcript-based matching has anything to react
  /// to at all, some window for a race is architecturally unavoidable —
  /// what actually closes the confirmed failure (the technician hearing
  /// NOTHING) is making sure the client-side handling of that race can
  /// never silently eat the one turn that should have played, which is
  /// what [_currentResponseTurnId]'s per-chunk tagging now guarantees.
  /// Spoken lines the APP starts on its own — not replies to anything the
  /// technician said — keyed by their [_informGeminiToSpeakVerbatim] reason,
  /// with the label their `LATENCY EXCLUDED (...)` line carries.
  static const Map<String, String> _systemInitiatedReplyLabels = {
    'inactivity_warning': 'inactivity turn',
    'session_greeting': 'session greeting turn',
    'session_greeting_replay': 'session greeting turn',
  };

  /// The most recent app-initiated line and when it was requested — its
  /// first audible chunk is never timed against speech that came before
  /// the request (see the LATENCY block in [_onResponseAudioChunk]).
  ({String label, DateTime requestedAt})? _systemInitiatedTurn;

  void _informGeminiToSpeakVerbatim(String text, {required String reason, bool isFiller = false}) {
    if (_sessionClosing) {
      _pipelineLog('reply_requested', 'reason=$reason — NOT SENT: session is closing (left job scope) text="$text"');
      return;
    }
    final channel = _channel;
    _pipelineLog(
      'reply_requested',
      'reason=$reason${channel == null ? ' — NOT SENT: WebSocket already closed' : ''} text="$text"',
    );
    if (channel == null) {
      _log_('$reason: WebSocket already closed — cannot inform Gemini');
      return;
    }
    // P1 FIX — a no-change status line ("We're already on the estimate.")
    // repeated word-for-word seconds later, because the technician repeated
    // the command, reads as the app being stuck. Only these no-op lines are
    // shortened; a real action's confirmation always speaks in full.
    if (!isFiller && _isNoChangeStatusLine(text)) {
      final last = _lastNoChangeStatusLine;
      final now = DateTime.now();
      if (last != null && last.text == text && now.difference(last.at) < _noChangeRepeatWindow) {
        _log_('$reason: same no-change line spoken ${now.difference(last.at).inMilliseconds}ms ago — short ack instead');
        text = _noChangeRepeatAck;
      } else {
        _lastNoChangeStatusLine = (text: text, at: now);
      }
    }
    _interruptGeminiForDeterministicTrigger(reason);
    // See [_awaitingFirstTranscriptOfUtterance]: this line's audio is ours.
    _scriptedResponsePending = true;
    // P0 FIX — see [_verbatimInstructionRetryCount]'s doc comment: the
    // retry budget is per-LINE, not a single session-wide allowance. A
    // genuinely NEW/different line (not [reason] itself — a retry reuses
    // the exact same [text] under a different reason string) gets a fresh
    // budget; a retry of the SAME text (the leak-recovery call site
    // itself) must NOT reset its own counter back to 0, or the bound
    // would never actually apply.
    //
    // [isFiller] — see [_speakPendingCallFiller]: a filler must not touch
    // either field, or it would become the line the audit exempts and the
    // leak-retry re-speaks.
    if (!isFiller) {
      if (text != _lastVerbatimScriptText) {
        _verbatimInstructionRetryCount = 0;
      }
      // P0 TRUST FIX — see [_lastVerbatimScriptText]: remembered so
      // [_auditGeminiCompletionClaim] can tell a line WE scripted (always
      // post-success by construction) from a free-text guess.
      _lastVerbatimScriptText = text;
    }
    final instruction =
        'Say exactly and only the following, with no additions, no preamble, and no extra commentary: '
        "'$text'";
    final message = jsonEncode({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': instruction},
            ],
          },
        ],
        'turnComplete': true,
      },
    });
    channel.sink.add(message);
    _noteClientContentSent('verbatim:$reason');
    _log_('$reason: informed Gemini via clientContent (constrained verbatim instruction)');
    final systemTurnLabel = _systemInitiatedReplyLabels[reason];
    if (systemTurnLabel != null) {
      _systemInitiatedTurn = (label: systemTurnLabel, requestedAt: DateTime.now());
    }
    // See [_awaitingScriptedTurnWords]: from THIS send on, a turn only
    // plays once it's identified as this line, not because a timer fired.
    _beginAwaitingScriptedTurn(text, reason: reason);
  }

  /// Un-mutes [_suppressResponseAudioForDeterministic] the instant the
  /// server confirms the stale, superseded turn is actually closed out —
  /// called from both `turnComplete` and `interrupted` handling in
  /// [_onServerMessage], since either can be the signal that arrives for a
  /// given stale turn. A no-op if suppression wasn't active (the normal
  /// case for every turn that ISN'T following a deterministic trigger).
  void _clearDeterministicAudioSuppression(String reason) {
    if (!_suppressResponseAudioForDeterministic) return;
    _suppressResponseAudioSafetyTimer?.cancel();
    _suppressResponseAudioSafetyTimer = null;
    _suppressResponseAudioForDeterministic = false;
    _log_('DETERMINISTIC INTERRUPT: un-muted ($reason) — next response audio will play normally');
  }

  void _onResponseAudioChunk(Uint8List pcmBytes, {required String? mimeType}) {
    // ISSUE 3(c) (CONFIRMED via fbd877f0-flutter_run_log.txt: "Skipped 120
    // frames" — a genuine ~2s main-thread freeze — fired DURING the live
    // camera preview window). Root cause: every one of the three drop
    // branches below used to call `_log_`, which calls `setState` — a full
    // widget-tree rebuild — for EVERY SINGLE dropped response chunk, not
    // just once per gate engaging. While muted (preemptive-default-mute in
    // particular can now legitimately last several seconds waiting on a
    // real KB answer — see ISSUE 1), Gemini's own response audio keeps
    // streaming in at normal chunk cadence, so this was tens of setState
    // calls per second, competing directly with CameraX's own preview
    // rendering for the same main thread/isolate. `debugPrint` alone (same
    // text, same "PHOTO TIMING"-style convention every high-frequency log
    // line in this file already uses — see [_onMicChunk]'s own
    // edge-triggered logging for the identical "don't flood the log/UI"
    // reasoning) keeps this fully visible in the real log file without ever
    // touching widget state.
    // MIC WATCHDOG item 4 — a chunk dropped by any mute path below is proof
    // nothing real is playing for it, so don't make the technician's mic
    // wait out that discarded turn: check the watchdog immediately with a
    // short idle threshold (a no-op unless the mic is actually paused, and
    // only ever logs when it force-resumes).
    if (_cameraNativeCallInProgress && !_fillerPassthroughActive) {
      debugPrint(
        'GEMINI LIVE TEST: CAMERA OPEN IN PROGRESS: dropping ${pcmBytes.length}-byte response chunk — all audio '
        'feed processing is hard-paused until the camera controller reports back',
      );
      return;
    }
    if (_holdingForUnclassifiedUtterance) {
      debugPrint(
        'GEMINI LIVE TEST: UNCLASSIFIED UTTERANCE HOLD: dropping ${pcmBytes.length}-byte response chunk — '
        'technician is speaking and no transcript has arrived yet to classify it',
      );
      return;
    }
    // Turn-identity gate — see [_awaitingScriptedTurnWords]. While we're
    // waiting to see which turn is the scripted one, a known-stale turn is
    // dropped and an unidentified one is HELD, never played on timing alone.
    if (_awaitingScriptedTurnWords != null) {
      if (_currentTurnKnownStale) {
        debugPrint(
          'GEMINI LIVE TEST: STALE TURN: dropping ${pcmBytes.length}-byte response chunk — this turn is not '
          'the scripted line we asked for (it started before our clientContent was processed)',
        );
        if (_outgoingAudioPaused) _checkMicPauseWatchdog(idleThreshold: const Duration(milliseconds: 1000));
        return;
      }
      if (_heldUnidentifiedTurnChunks.isEmpty) _armScriptIdentityTimer(_scriptIdentityHoldTimeout);
      _heldUnidentifiedTurnChunks.add((bytes: pcmBytes, mimeType: mimeType));
      debugPrint(
        'GEMINI LIVE TEST: TURN IDENTITY: holding ${pcmBytes.length}-byte response chunk '
        '(${_heldUnidentifiedTurnChunks.length} held) until its transcript shows whether it is the scripted line',
      );
      return;
    }
    if (_suppressResponseAudioForDeterministic) {
      // P0 FIX — see [_protectedConfirmationActive]'s doc comment: this is
      // exactly the second code path that CONFIRMED-dropped an entire
      // post-confirm_photo_upload "uploaded" confirmation, chunk by chunk,
      // in a real run. [_muteImmediatelyOnFirstChunkOfUtterance] no longer
      // re-arms suppression for an incidental unresolved utterance during
      // the protected window, so reaching this branch while
      // [_protectedConfirmationActive] is still true means suppression was
      // re-armed by something else — most likely a GENUINE resolved command
      // legitimately interrupting, which is correct, but loud and
      // greppable either way so a future regression here can't hide.
      if (_protectedConfirmationActive) {
        debugPrint(
          'GEMINI LIVE TEST: PROTECTED CONFIRMATION AUDIO DROPPED: ${pcmBytes.length}-byte chunk dropped as '
          'stale/superseded WHILE a protected confirmation was still pending — check what re-armed '
          '_suppressResponseAudioForDeterministic during this window.',
        );
      }
      debugPrint(
        'GEMINI LIVE TEST: DETERMINISTIC INTERRUPT: dropping ${pcmBytes.length}-byte response chunk '
        '(stale/superseded turn)',
      );
      if (_outgoingAudioPaused) _checkMicPauseWatchdog(idleThreshold: const Duration(milliseconds: 1000));
      return;
    }
    // P0 AUDIO-ECHO FIX — see [_suppressResponseAudioForDuplicate]'s doc
    // comment: a SEPARATE gate from the one above, deliberately not
    // sharing its machinery. [_auditGeminiDuplicateResponse] already
    // logged the one detailed "DUPLICATE RESPONSE SUPPRESSED" line the
    // instant it made this call; every chunk dropped here for the rest of
    // the turn only needs a cheap, high-frequency-safe debugPrint (same
    // "don't setState per dropped chunk" reasoning as every other drop
    // branch in this method).
    if (_suppressResponseAudioForDuplicate) {
      debugPrint(
        'GEMINI LIVE TEST: DUPLICATE RESPONSE: dropping ${pcmBytes.length}-byte response chunk — this turn was '
        'already identified as repeating a recent prior turn',
      );
      if (_outgoingAudioPaused) _checkMicPauseWatchdog(idleThreshold: const Duration(milliseconds: 1000));
      return;
    }
    // P0 FIX — see [_suppressResponseAudioForLeakedWrapper]'s doc comment:
    // a SEPARATE gate, same reasoning as the duplicate-response one just
    // above. [_auditGeminiForLeakedInstructionWrapper] already logged the
    // one detailed "VERBATIM INSTRUCTION LEAK" line the instant it made
    // this call.
    if (_suppressResponseAudioForLeakedWrapper) {
      debugPrint(
        'GEMINI LIVE TEST: LEAKED WRAPPER: dropping ${pcmBytes.length}-byte response chunk — this turn was '
        'identified as Gemini reading its own "say exactly" instruction out loud',
      );
      if (_outgoingAudioPaused) _checkMicPauseWatchdog(idleThreshold: const Duration(milliseconds: 1000));
      return;
    }
    // PART F items 4-5: SEPARATE gate from the one above — see
    // [_preemptiveDefaultMuteActive]'s doc comment for why this can't
    // share [_suppressResponseAudioForDeterministic]'s own 1.2s
    // safety-unmute (which would wrongly let Gemini's free answer through
    // before a real resolution exists). Never lets an utterance that
    // hasn't yet matched a known command get raw Gemini speech.
    if (_preemptiveDefaultMuteActive) {
      debugPrint(
        'GEMINI LIVE TEST: PREEMPTIVE DEFAULT MUTE: dropping ${pcmBytes.length}-byte response chunk — not yet '
        'resolved by a known trigger or the KB catch-all',
      );
      if (_outgoingAudioPaused) _checkMicPauseWatchdog(idleThreshold: const Duration(milliseconds: 1000));
      return;
    }
    // GEMINI INTENT CHECK — the classification turn is never meant to be
    // heard, even if the model answers it out loud instead of (or as well
    // as) calling the function. See [_maybeStartGeminiIntentCheck].
    if (_geminiIntentCheck != null || _dropRestOfSpokenIntentCheckTurn) {
      debugPrint(
        'GEMINI LIVE TEST: GEMINI INTENT CHECK: dropping ${pcmBytes.length}-byte response chunk — intent '
        'classification ${_geminiIntentCheck != null ? 'pending' : 'turn (spoken call syntax)'}',
      );
      if (_outgoingAudioPaused) _checkMicPauseWatchdog(idleThreshold: const Duration(milliseconds: 1000));
      return;
    }
    if (_fillerPassthroughActive && !_fillerAudioStarted) {
      _fillerAudioStarted = true;
      debugPrint('PENDING CALL FILLER: first filler chunk passed all gates at ${DateTime.now()} — playing');
    }
    // BUG 1 fix: never call `FlutterPcmSound.feed()` while a
    // release()/setup() reinit is still in flight (see `_pcmReady`'s doc
    // comment) — this is the guard that actually prevents the confirmed
    // `PlatformException(Setup, must call setup first)` crash.
    //
    // PART J item 2 (CONFIRMED regression: this used to `return` here —
    // permanently DROPPING a chunk indistinguishably from a genuinely
    // stale/superseded one. But by this point in the function, both gates
    // above already passed: this chunk is NOT suppressed and NOT preemptive-
    // muted, meaning it genuinely belongs to the CURRENT, resolved turn —
    // the native sink just hasn't finished rebuilding yet. Queued instead,
    // tagged with the generation in flight right now, and flushed in order
    // the instant that SAME generation's reinit completes — see
    // [_pendingPcmChunksAwaitingReinit]'s doc comment and
    // [_flushQueuedPcmChunksForGeneration]. A newer interrupt bumping the
    // generation again before this flushes makes these entries stale,
    // discarded right here the next time that happens (not kept forever).
    if (!_pcmReady) {
      if (_pendingPcmChunksGeneration != _pcmReinitGeneration) {
        if (_pendingPcmChunksAwaitingReinit.isNotEmpty) {
          _log_(
            'DETERMINISTIC INTERRUPT: discarding ${_pendingPcmChunksAwaitingReinit.length} queued response '
            'chunk(s) from generation $_pendingPcmChunksGeneration — superseded by newer PCM reinit generation '
            '$_pcmReinitGeneration',
          );
        }
        _pendingPcmChunksAwaitingReinit.clear();
        _pendingPcmChunksGeneration = _pcmReinitGeneration;
      }
      // P0 FIX — see [_currentResponseTurnId]'s doc comment: tagged with
      // WHICH TURN this chunk belongs to, not just which reinit generation,
      // so a later per-turn decision (duplicate suppression) can find and
      // remove exactly this turn's entries without touching any other
      // turn's still-queued, still-wanted audio.
      _pendingPcmChunksAwaitingReinit.add((bytes: pcmBytes, mimeType: mimeType, turnId: _currentResponseTurnId));
      _log_(
        'PCM QUEUE: queuing ${pcmBytes.length}-byte response chunk (generation $_pcmReinitGeneration, turn '
        '$_currentResponseTurnId, ${_pendingPcmChunksAwaitingReinit.length} now queued) — PCM reinit still in '
        'flight, will flush in order once ready, NOT dropped',
      );
      return;
    }
    _responseChunksReceived++;

    // STEP 3 audio-echo fix: a new chunk arriving means playback is
    // genuinely NOT done yet, regardless of what `_pcmRemainingFrames` last
    // reported — cancels any pending grace-period resume so it can't fire
    // against a now-stale "drained" reading (see [_resumeGraceTimer]'s doc
    // comment).
    _resumeGraceTimer?.cancel();
    _resumeGraceTimer = null;

    if (!_outgoingAudioPaused) {
      _outgoingAudioPaused = true;
      _lastResponsePlaybackStartedAt = DateTime.now();
      _startMicPauseWatchdog();
      _turnComplete = false;
      // P0 AUDIO-ECHO FIX — a loud reading from BEFORE this pause even
      // began (e.g. a brief incidental mic blip just before playback
      // started) must never count toward THIS pause's own echo-tail-quiet
      // requirement; cleared here so [_resumeGraceTimerFired] only ever
      // sees energy genuinely observed during (or after) this playback.
      _lastLoudMicChunkAt = null;
      _log_('outgoing mic audio PAUSED (response playback starting — avoids the mic picking up the speaker and Gemini self-interrupting)');
      _syncVoicePhase();
      // P0 FIX (CONFIRMED regression, REMOVED — was: resetting the
      // inactivity timer here too, "a response starting to play IS the
      // conversation being active"). Same self-defeating loop as the
      // matching RESUME-side removal a few hundred lines down (see that
      // one's doc comment for the full evidence/reasoning) — this PAUSE
      // reset alone was already enough to re-arm the full 50s/60s window
      // every single time Gemini spoke ANYTHING, including its own
      // inactivity warning, which is what let the warning fire on an
      // infinite loop instead of the session ever actually closing.
      // Removing both sites together (this one alone would have been
      // sufficient to keep re-arming the loop even with the RESUME site
      // fixed) is what actually breaks the cycle.
    }

    // Confirmed via mimeType logging that Gemini's real output rate matches
    // _outputSampleRateHz (24000hz), which [FlutterPcmSound.setup] in
    // _startTest is now fixed to for the whole streaming session — unlike
    // the old per-chunk WAV header, there's no per-chunk rate to feed here,
    // so a chunk reporting a different rate can't be corrected for; it's
    // only flagged, since it would play back pitch/speed-distorted.
    final rateMatch = mimeType == null ? null : _mimeTypeRateRegExp.firstMatch(mimeType);
    final parsedRate = rateMatch == null ? null : int.tryParse(rateMatch.group(1)!);

    if (_responseChunksReceived == 1) {
      _log_(
        'first response audio chunk received (${pcmBytes.length} bytes) — '
        'mimeType=$mimeType, streaming at fixed ${_outputSampleRateHz}hz via FlutterPcmSound'
        '${parsedRate == null || parsedRate == _outputSampleRateHz ? "" : " (WARNING: chunk reports ${parsedRate}hz — will sound distorted at the fixed ${_outputSampleRateHz}hz stream rate)"}',
      );
    } else if (parsedRate != null && parsedRate != _outputSampleRateHz) {
      _log_('response chunk sample rate ($parsedRate hz) differs from the fixed stream rate ($_outputSampleRateHz hz) — playback will sound distorted');
    }

    final stoppedAt = _speechStoppedAt;
    if (stoppedAt != null) {
      _speechStoppedAt = null;
      final now = DateTime.now();
      // MEASUREMENT ONLY (nothing here affects triggers, audio or timing).
      // CONFIRMED misattribution: the stopwatch used to start on ANY
      // "stopped speaking" edge — including bursts heard while outgoing
      // mic audio was paused (our own reply, or speech over it, none of
      // which Gemini ever received) — so a 12.9s figure was really ~2.4s of
      // response after a transcript for speech the level meter never saw.
      // Now: measured from the end of speech Gemini actually received
      // ([_latencySpeechEndAt]); if the level meter never caught that
      // speech, or its edge predates this transcript by more than the late
      // -transcript window (so it belongs to earlier, unrelated sound),
      // from when the transcript arrived instead — labelled either way,
      // with the split, so a slow transcript still shows as slow.
      final speechEnd = _latencySpeechEndAt;
      final transcriptAt = _latencyTranscriptAt;
      final speechEndUsable = speechEnd != null &&
          (transcriptAt == null || !transcriptAt.isAfter(speechEnd.add(_lateTranscriptMaxWait)));
      final reference = speechEndUsable ? speechEnd : (transcriptAt ?? stoppedAt);
      final latency = now.difference(reference);
      final from = speechEndUsable
          ? 'end of speech Gemini received'
          : (transcriptAt != null ? 'transcript arrival (end of that speech not detected)' : 'last silence edge');
      // 9948b4d log: "LATENCY ... 47704ms (from last silence edge)" was the
      // inactivity warning — the reply to the speech before it never played
      // audibly, so the stopwatch was still running ~50s later and the app's
      // own "Still there?" got timed as a response. A turn the APP asked for
      // after the technician's last speech answers nothing they said, so it
      // is excluded from the metric entirely (see [_systemInitiatedTurn]).
      final systemTurn = _systemInitiatedTurn;
      if (systemTurn != null && reference.isBefore(systemTurn.requestedAt)) {
        _systemInitiatedTurn = null;
        _log_(
          'LATENCY EXCLUDED (${systemTurn.label}): first response byte of an app-initiated turn — the stopwatch\'s '
          'reference ($from) was ${latency.inMilliseconds}ms ago, before the app asked for this line, so it times '
          'nothing the technician said; not counted',
        );
      } else {
        _lastLatency = latency;
        _log_('LATENCY (stopped speaking -> first response byte): ${latency.inMilliseconds}ms (from $from)');
        _log_(
          'LATENCY BREAKDOWN: speech end -> transcript '
          '${speechEnd != null && transcriptAt != null ? '${transcriptAt.difference(speechEnd).inMilliseconds}ms${speechEndUsable ? '' : ' (too far apart to be the same speech)'}' : 'n/a'}, '
          'transcript -> first response byte ${transcriptAt != null ? '${now.difference(transcriptAt).inMilliseconds}ms' : 'n/a'}, '
          'old any-silence-edge figure ${now.difference(stoppedAt).inMilliseconds}ms',
        );
      }
      _latencySpeechEndAt = null;
      _latencyTranscriptAt = null;
      if (mounted) setState(() {});
    } else if (_systemInitiatedTurn != null) {
      // Nothing was being timed: the app-initiated line just plays.
      _systemInitiatedTurn = null;
    }

    _captureGreetingChunk(pcmBytes);
    _enqueuePcmForPlayback(pcmBytes);
  }

  /// JITTER BUFFER (P1, CONFIRMED: "W/AudioTrack: releaseBuffer() ...
  /// disabled due to previous underrun, restarting" 13x in one ~6 min
  /// session). flutter_pcm_sound sizes its native AudioTrack at
  /// `getMinBufferSize` — only tens of ms at 24kHz mono — and writes each
  /// chunk the moment it arrives, so any network gap between Gemini's
  /// chunks longer than that drains the track mid-speech. The native size
  /// isn't configurable without forking the plugin, so the headroom is
  /// built here instead: when nothing is playing, chunks are collected until
  /// [_pcmPrebufferTarget] of audio (or [_pcmPrebufferMaxWait] passes) and
  /// written as one block; while playback is ahead, chunks go straight
  /// through, landing in the plugin's own queue behind that headroom.
  final List<Uint8List> _pcmPrebuffer = [];
  int _pcmPrebufferBytes = 0;
  Timer? _pcmPrebufferTimer;
  static const Duration _pcmPrebufferTarget = Duration(milliseconds: 200);
  static const Duration _pcmPrebufferMaxWait = Duration(milliseconds: 250);

  /// Playback counts as "running" only while this much queued audio is
  /// still ahead — below it, the next chunk starts a fresh prebuffer.
  static const Duration _pcmPlayingMargin = Duration(milliseconds: 40);

  void _enqueuePcmForPlayback(Uint8List pcmBytes) {
    final end = _expectedPlaybackEndAt;
    final playing = end != null && end.isAfter(DateTime.now().add(_pcmPlayingMargin));
    if (playing && _pcmPrebuffer.isEmpty) {
      _feedPcmNow(pcmBytes);
      return;
    }
    _pcmPrebuffer.add(pcmBytes);
    _pcmPrebufferBytes += pcmBytes.length;
    final buffered = Duration(microseconds: (_pcmPrebufferBytes ~/ 2) * 1000000 ~/ _outputSampleRateHz);
    if (buffered >= _pcmPrebufferTarget) {
      _flushPcmPrebuffer('${buffered.inMilliseconds}ms buffered');
      return;
    }
    _pcmPrebufferTimer ??= Timer(_pcmPrebufferMaxWait, () => _flushPcmPrebuffer('max wait reached'));
  }

  /// Writes whatever the jitter buffer holds as one block — also called at
  /// `turnComplete` so a response shorter than [_pcmPrebufferTarget] isn't
  /// held back.
  void _flushPcmPrebuffer(String reason) {
    _pcmPrebufferTimer?.cancel();
    _pcmPrebufferTimer = null;
    if (_pcmPrebuffer.isEmpty) return;
    if (!_pcmReady) {
      // A reinit started since these were buffered (see
      // [_interruptGeminiForDeterministicTrigger]) — they belong to audio
      // that was just cut off.
      _discardPcmPrebuffer('PCM reinit in flight');
      return;
    }
    final builder = BytesBuilder(copy: false);
    for (final chunk in _pcmPrebuffer) {
      builder.add(chunk);
    }
    final count = _pcmPrebuffer.length;
    _pcmPrebuffer.clear();
    _pcmPrebufferBytes = 0;
    final block = builder.takeBytes();
    debugPrint('PCM JITTER BUFFER: feeding $count chunk(s) as one ${block.length}-byte block ($reason)');
    _feedPcmNow(block);
  }

  void _discardPcmPrebuffer(String reason) {
    _pcmPrebufferTimer?.cancel();
    _pcmPrebufferTimer = null;
    if (_pcmPrebuffer.isEmpty) return;
    debugPrint('PCM JITTER BUFFER: discarding ${_pcmPrebuffer.length} buffered chunk(s) ($reason)');
    _pcmPrebuffer.clear();
    _pcmPrebufferBytes = 0;
  }

  void _feedPcmNow(Uint8List pcmBytes) {
    final fedAt = DateTime.now();
    _lastAudioChunkFedAt = fedAt;
    // MIC WATCHDOG — see [_micPauseWatchdogTimer]: accumulate when this fed
    // audio should actually finish playing (chunks queue back-to-back), so
    // the watchdog never force-resumes while real playback is still going.
    final chunkDuration = Duration(microseconds: (pcmBytes.length ~/ 2) * 1000000 ~/ _outputSampleRateHz);
    final currentEnd = _expectedPlaybackEndAt;
    final playbackStart = (currentEnd != null && currentEnd.isAfter(fedAt)) ? currentEnd : fedAt;
    _expectedPlaybackEndAt = playbackStart.add(chunkDuration);
    final seq = ++_pcmFeedSeq;
    _pcmFeedsInFlight++;
    unawaited(
      FlutterPcmSound.feed(PcmArrayInt16.fromList(_pcm16BytesToSamples(pcmBytes))).whenComplete(() {
        _pcmFeedsInFlight--;
        if (seq > _pcmFeedSeqAcked) _pcmFeedSeqAcked = seq;
        final ackedAt = DateTime.now();
        final ackEnd = _ackBasedPlaybackEndAt;
        _ackBasedPlaybackEndAt = (ackEnd != null && ackEnd.isAfter(ackedAt) ? ackEnd : ackedAt).add(chunkDuration);
        final lagMs = ackedAt.difference(fedAt).inMilliseconds;
        if (lagMs >= 500) {
          debugPrint(
            'PCM FEED LAG: a response chunk reached the native player ${lagMs}ms after it was fed (Android main '
            'thread busy) — mic stays paused until the player confirms it has played',
          );
        }
      }),
    );
  }

  /// PART J item 2/4 — see [_pendingPcmChunksAwaitingReinit]'s doc comment.
  /// Called from [_interruptGeminiForDeterministicTrigger]'s reinit chain
  /// the instant [generation] finishes AND is still the latest one (mirrors
  /// the same `myGeneration == _pcmReinitGeneration` check right next to
  /// this call). Re-feeds every chunk queued for [generation] back through
  /// [_onResponseAudioChunk] itself, in original arrival order, now that
  /// `_pcmReady` is true again — so each one gets the exact same
  /// bookkeeping (outgoing-mic pause, latency log, chunk counter) a chunk
  /// that had simply arrived a moment later would have gotten, instead of a
  /// bespoke bypass straight to `feed()`. A no-op if nothing is queued, or
  /// if the queue belongs to an older, already-superseded generation (that
  /// case is handled by [_onResponseAudioChunk] discarding it on the next
  /// real chunk instead).
  void _flushQueuedPcmChunksForGeneration(int generation) {
    if (_pendingPcmChunksGeneration != generation || _pendingPcmChunksAwaitingReinit.isEmpty) return;
    final queued = List.of(_pendingPcmChunksAwaitingReinit);
    _pendingPcmChunksAwaitingReinit.clear();
    // P0 FIX — the turn ids present here are purely informational at this
    // point: any turn [_auditGeminiDuplicateResponse] already decided to
    // suppress had its own entries PROACTIVELY purged from the queue the
    // instant that decision was made (see that method's doc comment), so
    // whatever remains by the time this runs is exactly what should still
    // be fed — no per-chunk filtering needed HERE, just visibility into
    // which turn(s) this flush actually covers.
    final turnIds = queued.map((c) => c.turnId).toSet().toList()..sort();
    _log_(
      'PCM QUEUE: flushing ${queued.length} queued response chunk(s) (generation $generation, turn(s) '
      '$turnIds) now that the PCM reinit has completed — feeding them in order, none dropped.',
    );
    for (final chunk in queued) {
      _onResponseAudioChunk(chunk.bytes, mimeType: chunk.mimeType);
    }
  }

  /// Decodes little-endian PCM16LE bytes into the signed 16-bit sample
  /// values [PcmArrayInt16.fromList] expects — the same byte layout
  /// [_trackSpeechLevel] already reads for the mic's own RMS check, just
  /// collected into a list instead of accumulated into a running sum.
  List<int> _pcm16BytesToSamples(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final sampleCount = bytes.length ~/ 2;
    return [for (var i = 0; i < sampleCount; i++) data.getInt16(i * 2, Endian.little)];
  }

  void _onWsError(Object error, StackTrace stackTrace) {
    final message = _scrubCredentials(error);
    debugPrint('GEMINI LIVE TEST ERROR (WebSocket): $message\n$stackTrace');
    _log_('ERROR (WebSocket): $message');
    if (!mounted) return;
    setState(() {
      _phase = _TestPhase.error;
      _errorMessage = message;
    });
  }

  /// `dart:io`'s WebSocket handshake errors quote the full connection URL —
  /// including `?access_token=<the Gemini token>` — so every error that can
  /// come from the socket goes through this before being logged or shown.
  static String _scrubCredentials(Object error) => error.toString().replaceAllMapped(
    RegExp(r'((?:access_token|key)=)[^&\s"' "'" r')]+'),
    (m) => '${m[1]}<redacted>',
  );

  void _onWsDone() {
    _log_('WebSocket closed by server (closeCode=${_channel?.closeCode}, closeReason=${_channel?.closeReason})');
    if (!mounted) return;
    setState(() => _phase = _TestPhase.closed);
  }

  /// [reason] is logged so a trace shows what ended the session — CONFIRMED
  /// needed: a real session ended mid-capture with only "Stop Test tapped" in
  /// the log, indistinguishable between the End button, end_session and the
  /// inactivity timeout (it was the button, pressed ~68s into a silent capture).
  Future<void> _stopTest({String reason = 'Stop/End button tapped'}) async {
    _log_(
      'Stop Test tapped (reason: $reason)'
      '${_inFlightFunctionCalls > 0 ? ' — WARNING: $_inFlightFunctionCalls function call(s) still in flight; their results will have no session to report to' : ''}',
    );
    await _teardown();
    if (!mounted) return;
    setState(() => _phase = _TestPhase.closed);
    _log_('connection closed');

    // Ambient sessions are inserted via a raw OverlayEntry, not pushed as a
    // Navigator route (see GeminiLiveTestScreen.onAmbientSessionEnded's doc
    // comment for why) — ending one calls that callback, which removes the
    // entry, instead of popping. Guarded so a second call (e.g. a race
    // between the corner cluster's close button and a voice end_session)
    // can never try to remove an already-removed OverlayEntry, which throws.
    if (widget.ambient) {
      if (!_ambientSessionEndedCalled) {
        _ambientSessionEndedCalled = true;
        widget.onAmbientSessionEnded?.call();
      }
      return;
    }

    // Job-scoped MANUAL mode only ("Voice Assistant" tap-fallback button):
    // teardown above has already fully closed the mic/WebSocket/PCM stream,
    // so popping back to JobDetailScreen here is a CLEAN return, not an
    // interruption — the existing FieldLoop system underneath was never
    // touched and is immediately available again. Standalone mode
    // (widget.jobId == null) deliberately stays on this screen instead,
    // same as always, since there's no job screen to return to.
    if (widget.jobId != null && mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _teardown() async {
    // CONFIRMED CRASH ("_lifecycleState != _ElementLifecycle.defunct") — the
    // same class of bug fixed several times elsewhere in this codebase (see
    // e.g. JobDetailScreen.dispose's `Future(() { _viewedJobIdController.state
    // = null; })`). _teardown() runs TWICE per session end: once from
    // _stopTest() while genuinely mounted (safe), and again from dispose()
    // itself (_stopTest() -> widget.onAmbientSessionEnded -> entry.remove()
    // -> Flutter unmounts this Element on a later frame -> dispose() ->
    // _teardown() again). During that SECOND call, `mounted` (State.mounted,
    // which only checks `_element != null`) still reads TRUE — Flutter
    // doesn't clear it until AFTER dispose() returns — even though the
    // ELEMENT itself was already marked defunct just before dispose() was
    // invoked (StatefulElement.unmount() calls super.unmount(), which sets
    // Element._lifecycleState = defunct, THEN calls state.dispose()). So a
    // plain `if (mounted) setState(...)` here is not actually safe: it
    // passes the check and then crashes inside setState's own
    // `Element.markNeedsBuild()`. Deferring via `Future(() {...})` — the
    // exact fix already proven correct elsewhere — pushes the check/write
    // past dispose()'s synchronous return, at which point `mounted` is
    // finally accurate (false), so the deferred callback correctly no-ops
    // for this second, unmount-triggered call, while still updating the UI
    // on the FIRST, genuinely-mounted call (mounted stays true by the time
    // this fires, since nothing else disposes the widget in between).
    Future(() {
      if (mounted) setState(() {});
    });
    // A session ending mid-greeting (left the job, "Loop Off") silences it.
    widget.wakeGreeting?.stop(WakeGreetingOutcome.cancelled, 'session ended');
    _abandonGreetingCapture('session ended');
    _greetingReplayTimer?.cancel();
    _greetingReplayTimer = null;
    _greetingReplayArmed = false;
    _transcriptStallTimer?.cancel();
    _transcriptStallTimer = null;
    _screenTask = _ScreenTask.none;
    // The overlay (and with it the post-frame host sync) is going away, so
    // the camera's host route is removed here — never left orphaned on the
    // stack after the session (see [_syncCameraHostRoute]).
    final hostRoute = _cameraHostRoute;
    _cameraHostRoute = null;
    if (hostRoute != null) _removeCameraHostRoute(hostRoute, why: 'voice session ended');
    _cameraOpenConfirmed = false;
    _exitPhotoNote('voice session ended', outcome: 'session_ended');
    // The exit above already started its own photo's upload; anything else
    // still kept-but-not-uploaded is never lost to the session ending.
    for (final keptId in _cameraSession.keptPhotoIdsAwaitingUpload) {
      unawaited(_uploadKeptPhotoSilently(keptId, why: 'voice session ended'));
    }
    _stopOutgoingAudioSummary();
    unawaited(VoiceSessionPower.stopForegroundSession());
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _speechStuckWatchdogTimer?.cancel();
    _speechStuckWatchdogTimer = null;
    _protectedConfirmationTimer?.cancel();
    _protectedConfirmationTimer = null;
    _awaitingFirstTranscriptTimer?.cancel();
    _awaitingFirstTranscriptTimer = null;
    _scriptIdentityTimer?.cancel();
    _scriptIdentityTimer = null;
    _awaitingScriptedTurnWords = null;
    _heldUnidentifiedTurnChunks.clear();
    _resumeGraceTimer?.cancel();
    _resumeGraceTimer = null;
    _cameraReleaseTimer?.cancel();
    _cameraOpeningTicker?.cancel();
    _cameraOpeningTicker = null;
    _discardPcmPrebuffer('teardown');
    _recentAudibleTurns.clear();
    _cameraReleaseTimer = null;
    _cameraPrewarmAutoReleaseTimer?.cancel();
    _cameraPrewarmAutoReleaseTimer = null;
    _cameraSpeculativelyPrewarming = false;
    _stopMicPauseWatchdog();
    _expectedPlaybackEndAt = null;
    _suppressResponseAudioSafetyTimer?.cancel();
    _suppressResponseAudioSafetyTimer = null;
    _suppressResponseAudioForDeterministic = false;
    _cancelInactivityTimer();
    _lateTranscriptTimeout?.cancel();
    _lateTranscriptTimeout = null;
    _lateTranscriptFinalizeTimer?.cancel();
    _lateTranscriptFinalizeTimer = null;
    _awaitingLateTranscript = false;
    _geminiIntentCheck?.timeout.cancel();
    _geminiIntentCheck = null;
    _dropRestOfSpokenIntentCheckTurn = false;
    _pendingReconfirm = null;
    _questionAnnouncement = null;
    // A session that failed or ended before setupComplete: its buffered
    // audio is discarded, never sent. A capture still opening is stopped
    // (generation bump) and waited for, so the recorder stop/close below
    // always sees its final state.
    _micCaptureGeneration++;
    _bufferingPreSetupAudio = false;
    _preSetupAudio.clear();
    _preSetupAudioBytes = 0;
    final pendingCapture = _micCaptureFuture;
    _micCaptureFuture = null;
    if (pendingCapture != null) {
      try {
        await pendingCapture;
      } catch (e) {
        debugPrint('GEMINI LIVE TEST: mic capture had failed before teardown ($e)');
      }
    }
    await _micSub?.cancel();
    _micSub = null;
    await _wsSub?.cancel();
    _wsSub = null;
    try {
      await _channel?.sink.close();
    } catch (e, stackTrace) {
      debugPrint('GEMINI LIVE TEST ERROR (WebSocket close): $e\n$stackTrace');
    }
    _channel = null;

    // PART M (CONFIRMED via 204dd37f-flutter_run_log.txt — see
    // [_cameraOpenRealCallInFlight]'s doc comment): if a real open_camera
    // hardware call is still genuinely running in the background (its own
    // 15s hard timeout already gave up WAITING on it, but the platform
    // call itself is still in flight), the recorder stop/close and
    // wake-word restart just below MUST NOT run concurrently with it —
    // that main-thread contention is what turned a sub-second CameraX
    // operation into 15+ extra seconds of jank. Waiting here, AFTER the
    // websocket is already closed (so the harmless "WebSocket already
    // closed — cannot inform Gemini" line some ambient late-completion
    // messaging produces is expected, not a bug), defers ONLY the
    // recorder/wake-word teardown until it's safe.
    final cameraOpenInFlight = _cameraOpenRealCallInFlight;
    if (cameraOpenInFlight != null) {
      _log_(
        'TEARDOWN: open_camera still genuinely in flight — deferring recorder/wake-word pipeline teardown '
        'until it resolves, so the two never contend for the main thread.',
      );
      await cameraOpenInFlight;
    }
    _log_(
      'TEARDOWN: starting recorder/wake-word pipeline teardown+rebuild now '
      '(triggered by: ${cameraOpenInFlight != null ? _cameraOpenRealCallOutcome ?? "unknown outcome" : "normal teardown, no camera call was in flight"}).',
    );
    if (_recorderOpen) {
      try {
        if (_recorder.isRecording) {
          await _recorder.stopRecorder();
        }
        await _recorder.closeRecorder();
      } catch (e, stackTrace) {
        debugPrint('GEMINI LIVE TEST ERROR (recorder stop/close): $e\n$stackTrace');
      }
      _recorderOpen = false;
    }
    await _micStreamController?.close();
    _micStreamController = null;
    // BUG 1 fix: bump the generation counter so any reinit still chained in
    // `_pcmReinitChain` from a deterministic trigger that fired right before
    // teardown can never mark `_pcmReady = true` again after this session
    // has released the player for good.
    _pcmReinitGeneration++;
    _pcmReady = false;
    try {
      FlutterPcmSound.setFeedCallback(null);
      await FlutterPcmSound.release();
    } catch (e, stackTrace) {
      debugPrint('GEMINI LIVE TEST ERROR (pcm sound release): $e\n$stackTrace');
    }
    // Resumes FieldLoop's wake-word loop — see _startTest's pause and
    // _pausedVoiceService's doc comment for why this uses the captured
    // reference instead of ref.read() (unsafe here: _teardown() also runs
    // from dispose(), by which point this widget's Element can already be
    // detached). resumeAfterExternalSession() itself re-derives whether
    // FieldLoop should actually start listening again from its own current
    // state, so this is safe to call unconditionally on every teardown,
    // paused or not.
    final voiceService = _pausedVoiceService;
    _pausedVoiceService = null;
    if (voiceService != null) {
      try {
        await voiceService.resumeAfterExternalSession('gemini_live_session');
      } catch (e, stackTrace) {
        debugPrint('GEMINI LIVE TEST ERROR (voice service resume): $e\n$stackTrace');
      }
    }

    // Cleans up an orphaned open camera controller and/or an unconfirmed
    // captured file if the session ended mid-flow (camera opened but never
    // captured, or captured but never confirmed/retaken) — see
    // GeminiCameraSession.dispose's doc comment.
    try {
      await _cameraSession.dispose();
    } catch (e, stackTrace) {
      debugPrint('GEMINI LIVE TEST ERROR (camera session dispose): $e\n$stackTrace');
    }
  }

  String get _phaseLabel {
    switch (_phase) {
      case _TestPhase.idle:
        return 'Idle';
      case _TestPhase.requestingToken:
        return 'Requesting token…';
      case _TestPhase.connecting:
        return 'Connecting…';
      case _TestPhase.connected:
        return _setupComplete ? 'Connected (streaming)' : 'Connected (awaiting setup ack)';
      case _TestPhase.closed:
        return 'Closed';
      case _TestPhase.error:
        return 'Error';
    }
  }

  Color get _phaseColor {
    switch (_phase) {
      case _TestPhase.connected:
        return AppColors.primaryGreen;
      case _TestPhase.error:
        return AppColors.error;
      case _TestPhase.connecting:
      case _TestPhase.requestingToken:
        return AppColors.amber;
      case _TestPhase.idle:
      case _TestPhase.closed:
        return AppColors.neutralGrey;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.ambient) return _buildAmbientUi(context);

    final isRunning = _phase == _TestPhase.connecting ||
        _phase == _TestPhase.connected ||
        _phase == _TestPhase.requestingToken;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(widget.jobId == null ? 'Gemini Live Test (Debug)' : 'Voice Assistant'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.borderGrey),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: _phaseColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _phaseLabel,
                        style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textDark),
                      ),
                    ),
                    if (_lastLatency != null)
                      Text(
                        '${_lastLatency!.inMilliseconds}ms',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryGreenDark,
                          fontSize: 16,
                        ),
                      ),
                  ],
                ),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(_errorMessage!, style: const TextStyle(color: AppColors.error, fontSize: 12)),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: isRunning ? null : _startTest,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryGreen,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(widget.jobId == null ? 'Start Test' : 'Start Session'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: isRunning ? _stopTest : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.error,
                        side: const BorderSide(color: AppColors.error),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(widget.jobId == null ? 'Stop Test' : 'End Session'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Log',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: AppColors.neutralGrey),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: ListView.builder(
                    reverse: true,
                    itemCount: _log.length,
                    itemBuilder: (context, index) {
                      final line = _log[_log.length - 1 - index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1.5),
                        child: Text(
                          line,
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // CAMERA HOST ROUTE (367d62af log) — the camera UI is painted by this
  // ambient overlay, which lives OUTSIDE the Navigator, so on its own it
  // had no place in the navigation stack: no VOICE REGISTRY transition, the
  // phone's back button popped the screen underneath it, and screens pushed
  // afterwards never dismissed it. While a camera flow is active, a plain
  // placeholder route is pushed on the root navigator so the camera is a
  // real, tracked screen on top of the one it was opened from. The camera
  // itself is still drawn here (the overlay always paints above every
  // route — `Overlay.rearrange` re-inserts foreign entries on top), so
  // nothing about the camera/photo/note flow moves; the route only gives it
  // a position:
  //  - back button on it -> close the camera, exactly like a spoken go_back
  //    (CAMERA OVERLAY TORN DOWN: reason=manual_nav);
  //  - another screen pushed over it, or a voice navigation to any screen
  //    -> close the camera (reason=screen_changed);
  //  - camera flow over by any path -> the route is popped, returning to
  //    exactly the screen underneath (which re-registers its commands).
  // ---------------------------------------------------------------------

  Route<void>? _cameraHostRoute;
  bool _cameraHostSyncScheduled = false;

  /// A navigation-driven close is running — no host route may be (re)pushed
  /// meanwhile, and a second close request is a no-op.
  bool _cameraNavCloseInProgress = false;

  bool get _wantsCameraHostRoute =>
      mounted && widget.ambient && _screenTask != _ScreenTask.none && !_sessionClosing && !_cameraNavCloseInProgress;

  /// Called from every ambient build — every camera-state change goes
  /// through `setState`, so this sees them all. The push/pop itself happens
  /// after the frame (never during build).
  void _scheduleCameraHostSync() {
    if (!widget.ambient || _cameraHostSyncScheduled) return;
    if ((_screenTask != _ScreenTask.none) == (_cameraHostRoute != null)) return;
    _cameraHostSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _cameraHostSyncScheduled = false;
      _syncCameraHostRoute();
    });
  }

  void _syncCameraHostRoute() {
    final route = _cameraHostRoute;
    if (_wantsCameraHostRoute && route == null) {
      final navigator = rootNavigatorKey.currentState;
      if (navigator == null) return;
      final from = _kbGateScreen().screen;
      late final Route<void> newRoute;
      newRoute = PageRouteBuilder<void>(
        settings: const RouteSettings(name: 'gemini_camera'),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => _CameraHostPage(
          onBackPressed: () => unawaited(_closeCameraFlowForNavigation('manual_nav')),
          onCovered: () => unawaited(_closeCameraFlowForNavigation('screen_changed')),
        ),
      );
      _cameraHostRoute = newRoute;
      _log_('CAMERA HOST: camera flow (${_screenTask.name}) is now the foreground screen — pushed its route over $from');
      unawaited(
        navigator.push(newRoute).then((_) {
          if (!identical(_cameraHostRoute, newRoute)) return; // removed by us
          // Removed by someone else (e.g. a pop-to-home) while the camera
          // was still up — the camera goes with it. A session already
          // closing (leaving the job) releases the camera in its own
          // teardown.
          _cameraHostRoute = null;
          if (_sessionClosing || !mounted) return;
          _log_('CAMERA HOST: route removed externally while the camera was up');
          unawaited(_closeCameraFlowForNavigation('screen_changed'));
        }),
      );
      return;
    }
    if (!_wantsCameraHostRoute && route != null && !_cameraNavCloseInProgress) {
      _cameraHostRoute = null;
      _removeCameraHostRoute(route, why: 'camera flow ended (${_screenTask.name})');
    }
  }

  /// Pops [route] when it's on top (so the screen underneath gets its
  /// didPopNext and re-registers its voice commands — `removeRoute` would
  /// skip that), otherwise removes it in place. Deferred past the current
  /// frame/navigator operation.
  void _removeCameraHostRoute(Route<void> route, {required String why}) {
    Future(() {
      final navigator = route.navigator;
      if (navigator == null || !route.isActive) return;
      _log_('CAMERA HOST: removing the camera route ($why)');
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    });
  }

  /// Closes the camera flow because the technician moved past it by some
  /// means other than a spoken go_back — the SAME close a spoken go_back
  /// does ([_maybeCloseCameraFlowForGoBack]). A close requested while a
  /// native capture/upload is mid-flight waits for it rather than pulling
  /// the camera out from under it.
  Future<void> _closeCameraFlowForNavigation(String reason, {int attempt = 0}) async {
    if (!mounted || _cameraNavCloseInProgress || _screenTask == _ScreenTask.none) return;
    if (_cameraNativeCallInProgress || _photoUploadInFlight) {
      if (attempt == 0) {
        _log_('CAMERA HOST: close ($reason) waiting — a native capture/upload is still in flight');
      }
      if (attempt < 120) {
        Timer(const Duration(milliseconds: 500), () => _closeCameraFlowForNavigation(reason, attempt: attempt + 1));
      }
      return;
    }
    _cameraNavCloseInProgress = true;
    try {
      await _maybeCloseCameraFlowForGoBack(
        const {'status': 'already_at_job_details'},
        jobId: widget.jobId ?? '',
        tornDownReason: reason,
      );
    } finally {
      _cameraNavCloseInProgress = false;
      if (mounted) setState(() {}); // re-sync: the host route comes off now
    }
  }

  /// The ambient-mode UI (see [GeminiLiveTestScreen.ambient]'s doc
  /// comment) — routes to one of three presentations:
  ///  - [_viewScreenActive] (a view_* screen — Estimate/Change Orders/
  ///    Invoice/Job History — is pushed on top): renders NOTHING. That
  ///    screen already has its own `VoicePhaseIndicator` in its own AppBar,
  ///    and since this screen is inserted as an `OverlayEntry` OUTSIDE the
  ///    Navigator's own route ordering, it can end up positioned ABOVE that
  ///    later-pushed route in z-order — painting nothing here is what
  ///    avoids a redundant second indicator floating over it, or (for
  ///    [_ScreenTask.cameraLive]/[cameraCaptured]) obscuring it entirely.
  ///  - Else, [_ScreenTask.none] (pure conversation): [_buildAmbientPureConversationUi],
  ///    which paints almost nothing so the real screen underneath (Job
  ///    Detail, wherever the technician was) stays visible and tappable.
  ///  - Else (a function call navigated to real content — the camera):
  ///    [_buildAmbientScreenTaskUi], a normal opaque `Scaffold`, since that
  ///    content needs its own solid background.
  Widget _buildAmbientUi(BuildContext context) {
    _scheduleCameraHostSync();
    // An active camera flow is ALWAYS the foreground screen — its own host
    // route sits on top of whatever screen it was opened from (see
    // [_syncCameraHostRoute]). 367d62af log: opened from Invoice, the
    // camera went live while this returned nothing, so it stayed invisible
    // until the technician backed out of Invoice and found it underneath.
    if (_viewScreenActive && _screenTask == _ScreenTask.none) return const SizedBox.shrink();
    return _screenTask == _ScreenTask.none
        ? _buildAmbientPureConversationUi(context)
        : _buildAmbientScreenTaskUi(context);
  }

  /// Opaque, full-screen presentation for [_ScreenTask.cameraLive]/
  /// [_ScreenTask.cameraCaptured] — the exact same `Scaffold` shape this
  /// screen used for ALL of ambient mode before this fix, now scoped to
  /// only the moments there's real content that needs a solid background.
  /// No close button: technicians kept hitting it by accident while using
  /// the camera, ending the whole voice session. A session ends by voice
  /// ("Loop Off"/"FieldLoop stop"), end_session, or the inactivity timeout.
  Widget _buildAmbientScreenTaskUi(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_screenTaskTitle),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
        actions: [
          // VoiceInteractionOverlay has long since shrunk to its corner pill
          // by the time any real screen content shows (see
          // GlobalVoiceService.setScreenTaskActive) â€” this AppBar-slot
          // indicator is what keeps the technician able to see the mic is
          // still live, exactly the same widget/slot every other job-scoped
          // screen (Photo Capture, Photo Preview, ...) already uses for the
          // same purpose.
          const Padding(padding: EdgeInsets.only(right: 14), child: Center(child: VoicePhaseIndicator())),
        ],
      ),
      body: SafeArea(child: _buildCameraTaskBody()),
    );
  }

  String get _screenTaskTitle => switch (_screenTask) {
    _ScreenTask.cameraOpening => 'Opening Camera',
    _ScreenTask.cameraClosing => 'Closing Camera',
    _ScreenTask.cameraLive => 'Camera',
    _ScreenTask.cameraCaptured => 'Review Photo',
    _ScreenTask.none => 'Voice Assistant',
  };

  /// Pure-conversation ambient body — CHANGED (was: a full opaque `Scaffold`
  /// with a big centered [VoicePhaseIndicator]/title/close button, blocking
  /// whatever screen was open when the wake word was heard for the ENTIRE
  /// conversation). Now paints ONLY a small corner status cluster — the
  /// same [VoicePhaseIndicator] pill every other job-scoped screen's AppBar
  /// already uses (the "End session" X that sat next to it is gone — see
  /// [_buildAmbientScreenTaskUi]) — and
  /// leaves every other point on screen unpainted, so hit-testing falls
  /// straight through to whatever's genuinely underneath (this screen is
  /// inserted via a raw `OverlayEntry`, not a `Navigator` route — see
  /// [GeminiLiveTestScreen.onAmbientSessionEnded]'s doc comment for why a
  /// route, even a non-opaque one, turned out NOT to let touches pass
  /// through on a real device). Deliberately NOT wrapped in a `Scaffold`/
  /// any opaque `Material`, which would paint a full-screen background and
  /// defeat the whole point — `Material(type: MaterialType.transparency)`
  /// wraps just the small cluster itself, purely so `IconButton`'s
  /// ink-splash machinery has the `Material` ancestor it needs without
  /// painting anything.
  ///
  /// Positioned manually off [MediaQuery]'s top padding rather than
  /// `SafeArea` — `SafeArea` would insert a full-width `Padding`, which is
  /// harmless for hit-testing (`Padding` doesn't intercept touches) but
  /// this is simpler to reason about alongside the explicit `Positioned`
  /// placement below.
  Widget _buildAmbientPureConversationUi(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;

    return Stack(
      children: [
        Positioned(
          top: topInset + 10,
          right: 10,
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 8, offset: const Offset(0, 2)),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: VoicePhaseIndicator()),
                ],
              ),
            ),
          ),
        ),
        if (_errorMessage != null)
          Positioned(
            top: topInset + 54,
            right: 10,
            left: 10,
            child: Material(
              type: MaterialType.transparency,
              child: Align(
                alignment: Alignment.centerRight,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 260),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 8, offset: const Offset(0, 2)),
                    ],
                  ),
                  child: Text(_errorMessage!, style: const TextStyle(color: AppColors.error, fontSize: 12)),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// The real screen content [_screenTask] currently calls for â€” the SAME
  /// `CameraController`/captured `XFile` [_cameraSession] itself is driving
  /// via `open_camera`/`capture_photo` (see [GeminiCameraSession.controller]/
  /// [GeminiCameraSession.capturedFile]), not a second camera session, so
  /// there's exactly one live controller in play for the whole flow. Read-
  /// only: capture/confirm/retake still only ever happen via Gemini function
  /// calls (see [_handleToolCall]) â€” this purely shows what's already
  /// happening, matching ambient mode's existing no-manual-controls design
  /// (see [GeminiLiveTestScreen.ambient]'s doc comment).
  /// The camera-shaped dark surface shown while opening or closing — a
  /// spinner, a caption, and optional actions.
  Widget _buildCameraStatusSurface({required String caption, required Color spinnerColor, List<Widget>? actions}) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: double.infinity,
          color: const Color(0xFF15181A),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: spinnerColor),
                  ),
                  const SizedBox(height: 14),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      caption,
                      key: ValueKey(caption),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ),
                  if (actions != null) ...[
                    const SizedBox(height: 18),
                    Row(mainAxisSize: MainAxisSize.min, children: actions),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCameraTaskBody() {
    // See [_ScreenTask.cameraClosing]. Checked first: the controller is
    // still initialized (and mid-release) here, so the live-preview branch
    // below must never render it.
    if (_screenTask == _ScreenTask.cameraClosing) {
      return _buildCameraStatusSurface(caption: 'Closing the camera…', spinnerColor: AppColors.amber);
    }
    if (_screenTask == _ScreenTask.cameraCaptured) {
      // A kept photo stays on screen through the photo-note question — see
      // [_keptPhotoPreviewFile].
      final capturedFile = _cameraSession.capturedFile ?? _keptPhotoPreviewFile;
      if (capturedFile == null) {
        // Defensive only â€” _screenTask is only ever set to cameraCaptured
        // right after a successful capture_photo, which always leaves a
        // captured file behind (see GeminiCameraSession.capture).
        return const Center(child: CircularProgressIndicator());
      }
      return Padding(
        padding: const EdgeInsets.all(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Container(
            width: double.infinity,
            color: const Color(0xFF15181A),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(File(capturedFile.path), fit: BoxFit.contain),
                // Purely visual — the audio side of this same window is the
                // confirm_photo_upload pending-call filler.
                AnimatedOpacity(
                  opacity: _photoUploadInFlight ? 1 : 0,
                  duration: const Duration(milliseconds: 250),
                  child: IgnorePointer(
                    child: Container(
                      color: Colors.black54,
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 180,
                              child: LinearProgressIndicator(
                                minHeight: 4,
                                color: Colors.white,
                                backgroundColor: Colors.white24,
                                borderRadius: BorderRadius.all(Radius.circular(2)),
                              ),
                            ),
                            SizedBox(height: 14),
                            Text('Uploading photo…', style: TextStyle(color: Colors.white, fontSize: 14)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final controller = _cameraSession.controller;
    if (controller == null || !controller.value.isInitialized) {
      // P2 — see [_ScreenTask.cameraOpening]. This window has measured 9-30s
      // on real hardware, and it used to render nothing at all (the screen
      // task stayed `none` until open_camera returned, so the ambient
      // pure-conversation overlay was all the technician saw). A bare
      // spinner over a black rectangle is not much better: it doesn't say
      // what is happening or that it is expected to take a moment. Shows the
      // camera-shaped surface it is about to become instead, so the swap to
      // the live preview is a fill-in rather than a screen change.
      // Elapsed-time aware (see [_cameraOpeningTicker]) so a slow open never
      // reads as frozen: the caption escalates, and past
      // [cameraOpenSlowWarningAfter] Retry/Cancel are offered.
      final startedAt = _cameraOpeningStartedAt;
      final elapsed = startedAt == null ? Duration.zero : DateTime.now().difference(startedAt);
      final slow = elapsed >= _cameraOpenSlowCaptionAfter;
      final offerActions = elapsed >= cameraOpenSlowWarningAfter;
      final String caption;
      if (offerActions) {
        caption = 'The camera is taking a while to open.';
      } else if (slow) {
        caption = 'Still opening the camera — this is taking longer than usual…';
      } else {
        caption = _cameraOpenIsRetry ? 'Retrying the camera…' : 'Opening the camera…';
      }
      return _buildCameraStatusSurface(
        caption: caption,
        spinnerColor: Colors.white70,
        actions: offerActions
            ? [
                OutlinedButton(
                  onPressed: () => _onSlowCameraOpenAction(retry: false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                  ),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () => _onSlowCameraOpenAction(retry: true),
                  style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                  child: const Text('Retry'),
                ),
              ]
            : null,
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: double.infinity,
          color: const Color(0xFF15181A),
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: controller.value.previewSize?.height ?? 1,
              height: controller.value.previewSize?.width ?? 1,
              child: CameraPreview(controller),
            ),
          ),
        ),
      ),
    );
  }
}

/// The camera flow's placeholder page on the root navigator — see the
/// CAMERA HOST ROUTE notes in [_GeminiLiveTestScreenState]. Paints only a
/// plain background (the ambient overlay draws the actual camera above
/// it), registers as its own VOICE REGISTRY screen with no commands and no
/// KB fallback, turns the phone's back button into "close the camera", and
/// reports another screen being pushed over it.
class _CameraHostPage extends ConsumerStatefulWidget {
  const _CameraHostPage({required this.onBackPressed, required this.onCovered});

  final VoidCallback onBackPressed;
  final VoidCallback onCovered;

  @override
  ConsumerState<_CameraHostPage> createState() => _CameraHostPageState();
}

class _CameraHostPageState extends ConsumerState<_CameraHostPage>
    with SafeRefDisposal<_CameraHostPage>, VoiceCommandRegistrarMixin<_CameraHostPage> {
  @override
  List<VoiceCommand> buildVoiceCommands() => const [];

  @override
  void didPushNext() {
    super.didPushNext();
    widget.onCovered();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onBackPressed();
      },
      child: const ColoredBox(color: AppColors.background, child: SizedBox.expand()),
    );
  }
}
