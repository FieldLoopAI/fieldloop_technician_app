import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/env.dart';
import '../providers/global_voice_service_provider.dart';
import '../services/gemini_function_dispatcher.dart';
import '../theme/app_theme.dart';
import '../widgets/voice_phase_indicator.dart';

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
  const GeminiLiveTestScreen({super.key, this.jobId, this.ambient = false, this.onAmbientSessionEnded});

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
}

const int _inputSampleRateHz = 16000;
const int _outputSampleRateHz = 24000;

/// Model updated 2026-09-07 after gemini-2.5-flash-live-preview was found to
/// return API key rejection errors, root-caused to model deprecation via a
/// 404 on the equivalent text model. NOTE: this is gemini-3.1, which the
/// original test plan flagged as having a function-calling freeze bug - safe
/// for Day 1 bare connectivity testing (no functions wired yet), but must be
/// re-evaluated before Day 2's function-calling work begins.
const String _geminiModel = 'gemini-3.1-flash-live-preview';

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
    'with a supervisor. Do not guess or give general advice.';

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
    'description': 'Uploads the photo that was just captured (call capture_photo first) and attaches it to '
        "the job's photo record. Call this when the technician says to keep, save, upload, or confirm the "
        'photo — phrases like "keep it", "save it", "upload it", "that looks good", "use that one", or "yes, '
        'keep that" should ALWAYS trigger this function.',
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
  /// ASR output for get_job_timeline_answer's arrival-time question). Given
  /// the SAME normalized/space-padded text [matches] itself checks against
  /// [phrases].
  final bool Function(String normalizedPaddedText)? extraMatcher;

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

  /// Same broad, NOT exact-phrase, whole-word/phrase pattern match as
  /// [_GeminiLiveTestScreenState._looksLikeViewEstimateRequest] — lowercased,
  /// stripped to letters/spaces, space-padded substring checks against each
  /// multi-word phrase in [phrases] — PLUS [extraMatcher], when given.
  bool matches(String text) {
    final normalized = text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ');
    final words = normalized.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final padded = ' ${words.join(' ')} ';
    if (phrases.any((phrase) => padded.contains(' $phrase '))) return true;
    return extraMatcher?.call(padded) ?? false;
  }
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
bool _looksLikeNounPlusActionIntent(
  String paddedText, {
  required List<String> nouns,
  required List<String> actionWords,
  List<String> excludeIfContains = const [],
  String? logLabel,
}) {
  for (final word in excludeIfContains) {
    if (paddedText.contains(' $word ')) return false;
  }
  String? matchedNoun;
  for (final noun in nouns) {
    if (paddedText.contains(' $noun ')) {
      matchedNoun = noun;
      break;
    }
  }
  if (matchedNoun == null) return false;
  final label = logLabel == null ? '' : ' [$logLabel]';
  for (final word in actionWords) {
    if (paddedText.contains(' $word ')) {
      debugPrint(
        'LOOSE NAV MATCH$label: noun="$matchedNoun" + action="$word" matched in "$paddedText"',
      );
      return true;
    }
  }
  if (paddedText.contains(' screen ') || paddedText.contains(' page ')) {
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
  'go ahead',
  'ready',
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
  for (final phrase in openCameraOnlyPhrases) {
    if (paddedText.contains(' $phrase ')) return false;
  }
  const shutterConfirmWords = ['capture', 'snap', 'take it', 'ready', 'confirm', 'go ahead', 'keep it'];
  for (final word in shutterConfirmWords) {
    if (paddedText.contains(' $word ')) {
      debugPrint('LOOSE CAPTURE MATCH: shutter/confirm word "$word" matched in "$paddedText"');
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
const String _kbCatchAllBoundaryDeclineText =
    "I'm sorry, I can only help with things related to this job — I can't answer that.";

/// PART L item 1 (CONFIRMED via 4127d46d-flutter_run_log.txt: "I see you
/// good egg." — STT's mangled transcription of what was clearly meant to be
/// a change-orders request — has no usable keywords at all no matter how
/// loose the matching gets; that's a genuine speech-recognition failure,
/// not something pattern-matching can fix). Spoken ONLY by
/// [_GeminiLiveTestScreenState._maybeArmPreemptiveMuteSafetyTimeout]'s own
/// safety-net timeout — deliberately DIFFERENT from
/// [_kbCatchAllBoundaryDeclineText] (spoken when the KB catch-all genuinely
/// ran and had nothing to say, e.g. a real off-topic question like "who is
/// the president of India"): THIS case is "I couldn't even tell what you
/// said," not "I understood you and it's out of scope," so it invites a
/// retry with concrete examples instead of flatly declining.
const String _unrecognizedUtteranceRetryText =
    "Sorry, I didn't catch that — you can say things like 'show me the change orders' or 'take a photo'.";

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
/// KB's own raw decline instead of [_kbCatchAllBoundaryDeclineText] — a
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
  'are you there',
  'you there',
  'hello',
  'hi',
  'hey',
];

/// See [_acknowledgePresenceIndicatorPhrases]'s doc comment — spoken
/// verbatim (never paraphrased), same "speak this word for word" pattern
/// as [_metaCapabilityCannedResponse].
const String _acknowledgePresenceCannedResponse = 'Yes, I can hear you. How can I help with the job?';

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

/// Reliability audit finding (CHECK 4): `capture_photo`'s required
/// follow-up decision — confirm_photo_upload or retake_photo — had NO
/// deterministic backstop at all, unlike view_estimate and go_back's
/// camera-flow trigger. Same "strengthened description alone has not
/// proven reliable enough" reasoning as those two. See
/// [_GeminiLiveTestScreenState._looksLikePhotoConfirmRequest].
const List<String> _photoConfirmIndicatorPhrases = [
  'keep it',
  'save it',
  'upload it',
  'looks good',
  'that works',
  'use that',
  'keep that',
  'yes keep',
  // CONFIRMED gap: zero occurrences of confirm_photo_upload firing in a
  // real session where a photo was captured — broadened to the technician's
  // actual observed phrasing.
  'confirm',
  // VERIFIED via a standalone normalize/match check (not assumed): the
  // input-side normalization (`replaceAll(RegExp('[^a-z ]'), ' ')`) turns
  // an apostrophe into a SPACE, not nothing — "that's good" normalizes to
  // "that s good" (three words), NOT "thats good" (two words, no space).
  // Caught this the hard way: an earlier version of this phrase list used
  // 'thats good' (matching this file's existing 'doesnt'/'whats'-style
  // no-apostrophe convention elsewhere) and a real match-logic test proved
  // it NEVER matches "That's good". Since it's unverified whether Gemini's
  // real transcription ever emits the apostrophe at all, both normalized
  // forms are listed so this matches either way.
  'that s good',
  'thats good',
  'yes upload',
  'use this one',
];

/// See [_photoConfirmIndicatorPhrases]'s doc comment. Checked the same
/// whole-word/phrase way — see
/// [_GeminiLiveTestScreenState._looksLikePhotoRetakeRequest].
const List<String> _photoRetakeIndicatorPhrases = [
  'retake',
  'try again',
  'take another',
  'redo that',
  'redo it',
  'doesnt look right',
  'take it again',
  'no retake',
  // CONFIRMED gap: zero occurrences of retake_photo firing in a real
  // session — broadened to the technician's actual observed phrasing.
  'retake it',
  'no good',
  'delete it',
  'take another one',
  'do it again',
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
/// [_GeminiLiveTestScreenState._dispatchWithOpenCameraSafeguards] races the
/// real `open_camera` dispatch against these two independent thresholds:
///  - [_openCameraAckDelay]: still open after this long -> speak
///    [_openCameraAckText] so it doesn't feel broken.
///  - [_openCameraHardTimeout]: still open after this much longer -> give up
///    waiting, tell Gemini to ask the technician to retry, and log it
///    clearly as a timeout (never a silent hang). The real dispatch keeps
///    running in the background after this point; see that method's own
///    doc comment for how its eventual outcome is handled.
const Duration _openCameraAckDelay = Duration(seconds: 5);
const Duration _openCameraHardTimeout = Duration(seconds: 15);

/// See [_openCameraAckDelay]'s doc comment. Sent to Gemini as a
/// `clientContent` "say exactly this" instruction — same mechanism as
/// [_inactivityWarningText]/[_GeminiLiveTestScreenState._fireInactivityWarning],
/// not a separate on-device TTS call, for the same mic-lock-contention
/// reasoning given there.
const String _openCameraAckText = 'Just a moment, opening the camera.';

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
  /// [_unrecognizedUtteranceRetryText], not [_kbCatchAllBoundaryDeclineText]
  /// — see that constant's doc comment for why the two cases need different
  /// wording.
  Timer? _preemptiveDefaultMuteSafetyTimer;
  static const Duration _preemptiveDefaultMuteSafetyDelay = Duration(seconds: 2);

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
  final List<({Uint8List bytes, String? mimeType})> _pendingPcmChunksAwaitingReinit = [];
  int _pendingPcmChunksGeneration = 0;

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
      _goBackTriggerResolvedForCurrentUtterance ||
      _photoDecisionResolvedForCurrentUtterance ||
      (_deterministicTriggers['view_change_orders']?.resolvedForCurrentUtterance ?? false) ||
      (_deterministicTriggers['view_invoice']?.resolvedForCurrentUtterance ?? false) ||
      (_deterministicTriggers['view_job_history']?.resolvedForCurrentUtterance ?? false) ||
      (_deterministicTriggers['open_camera']?.resolvedForCurrentUtterance ?? false) ||
      (_deterministicTriggers['capture_photo']?.resolvedForCurrentUtterance ?? false) ||
      (_deterministicTriggers['get_last_photo']?.resolvedForCurrentUtterance ?? false) ||
      (_deterministicTriggers['get_job_timeline_answer']?.resolvedForCurrentUtterance ?? false);

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
  /// transcript for [_looksLikePhotoConfirmRequest]/[_looksLikePhotoRetakeRequest]
  /// — same per-utterance accumulate/reset pattern as
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
  /// generalized/renamed from `_cameraOpenInProgress` accordingly): set the
  /// instant EITHER open_camera's OR capture_photo's real native dispatch
  /// starts, BEFORE anything else that call does — see
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
  /// session — never reset afterward. See [_teardown]'s own doc comment on
  /// this field for why the late-completion `open_camera` handler needs it
  /// specifically (distinguishing "screenTask reads none because nothing
  /// happened yet" from "screenTask reads none because teardown just reset
  /// it").
  bool _teardownStarted = false;

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
    _navigationSession = GeminiNavigationSession(
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
    if (widget.ambient) {
      // Deferred to a post-frame callback — same reasoning as every other
      // "write provider state / start real work right as a screen first
      // mounts" callback in this app (see JobDetailScreen.initState):
      // doing this synchronously, mid-build, is unsafe.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _log_('ambient mode: auto-starting session (reached via wake word/"Loop On")');
        unawaited(_startTest());
      });
    }
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
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

  Future<void> _startTest() async {
    if (_phase == _TestPhase.connecting || _phase == _TestPhase.connected) return;

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
    final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
    final tokenFuture = accessToken == null ? null : _requestGeminiToken(accessToken);
    if (tokenFuture != null) {
      unawaited(tokenFuture.catchError((_) => ''));
      _log_(
        'requesting Gemini ephemeral token from $apiBaseUrl/voice/gemini-token (started now, in parallel with '
        'voice-service pause + mic permission check below) ...',
      );
    }

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
    _pausedVoiceService!.setExternalSessionPhase(VoicePhase.processing);

    try {
      if (accessToken == null || tokenFuture == null) {
        throw StateError('No Supabase session — log in before running this test.');
      }

      // flutter_sound does not request/check mic permission itself (per its
      // own docs) — that's explicitly the app's responsibility.
      final permissionStatus = await Permission.microphone.request();
      _log_('mic permission check: status=$permissionStatus');
      if (!permissionStatus.isGranted) {
        throw StateError('Microphone permission denied.');
      }

      final token = await tokenFuture;
      _log_('token received (${_redact(token)})');

      if (!mounted) return;
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
          e.key: (e.key == 'access_token' || e.key == 'key') ? _redact(e.value) : e.value,
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
            'triggerTokens': '6000',
            'slidingWindow': {'targetTokens': '3000'},
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
        'inputAudioTranscription.languageCodes=[en-US], outputAudioTranscription=enabled, '
        'contextWindowCompression=trigger 6000/target 3000 tokens, '
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
      await FlutterPcmSound.setup(sampleRate: _outputSampleRateHz, channelCount: 1);
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
      debugPrint('GEMINI LIVE TEST ERROR: $e\n$stackTrace');
      _log_('ERROR: $e');
      if (!mounted) return;
      setState(() {
        _phase = _TestPhase.error;
        _errorMessage = e.toString();
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

  Future<String> _requestGeminiToken(String supabaseAccessToken) async {
    final uri = Uri.parse('$apiBaseUrl/voice/gemini-token');
    final response = await http.post(uri, headers: {'Authorization': 'Bearer $supabaseAccessToken'});
    if (response.statusCode != 200) {
      throw StateError('gemini-token request failed (${response.statusCode}): ${response.body}');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final token = decoded['token'] as String?;
    if (token == null || token.isEmpty) {
      throw StateError('gemini-token response missing "token": ${response.body}');
    }
    return token;
  }

  String _redact(String value) {
    if (value.length <= 8) return '<redacted, len=${value.length}>';
    return '${value.substring(0, 4)}...${value.substring(value.length - 4)} (len=${value.length})';
  }

  Future<void> _startMicStreaming() async {
    _log_('opening flutter_sound recorder session...');
    await _recorder.openRecorder();
    _recorderOpen = true;

    final controller = StreamController<Uint8List>();
    _micStreamController = controller;
    _micSub = controller.stream.listen(
      _onMicChunk,
      onError: (Object e, StackTrace stackTrace) {
        debugPrint('GEMINI LIVE TEST ERROR (mic stream): $e\n$stackTrace');
        _log_('ERROR (mic stream): $e');
      },
    );

    _log_('starting mic stream (pcm16, ${_inputSampleRateHz}hz, mono)...');
    await _recorder.startRecorder(
      codec: Codec.pcm16,
      toStream: controller.sink,
      sampleRate: _inputSampleRateHz,
      numChannels: 1,
    );
    _pausedVoiceService?.setExternalSessionPhase(VoicePhase.listening);

    // Original Day 2 spec: the silence auto-timeout starts counting the
    // moment the session actually becomes active — i.e. right here, once the
    // mic is genuinely capturing and forwarding the technician's audio, not
    // back when the WebSocket merely connected or the setup message was
    // sent (neither of which means anyone can be heard yet).
    _resetInactivityTimer(reason: 'session became active');
  }

  void _onMicChunk(Uint8List chunk) {
    final channel = _channel;
    if (channel == null) return;

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
    if (_audioChunksSent == 1) {
      _log_('first audio chunk sent (${chunk.length} bytes)');
    }
  }

  /// BUG 2 diagnostic: tracks the edge for the [_onMicChunk] logging above —
  /// separate from [_outgoingAudioPaused] itself so the log lines fire
  /// exactly once per transition, at the real send-gating site.
  bool _micSendCurrentlyPaused = false;

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

    if (amplitude > _speechRmsThreshold) {
      final now = DateTime.now();
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
        debugPrint(
          'DETERMINISTIC RESET: new utterance — clearing all trigger buffers/resolved flags '
          '(outgoingAudioPaused=$_outgoingAudioPaused)',
        );
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
        for (final trigger in _deterministicTriggers.values) {
          trigger.resetForNewUtterance();
        }
        // PART G item 1 — see [_utteranceAlreadyResolvedByTrigger]'s doc
        // comment: THIS is the only place that flag is allowed to clear —
        // a genuinely new utterance, not the more frequent mid-utterance
        // reset in [_clearAllTriggerBuffersAfterSuccess].
        _utteranceAlreadyResolvedByTrigger = false;
        // PART J item 1 — see [_pcmReinitIssuedForCurrentUtterance]'s doc
        // comment: same lifecycle as the flag just above — a genuinely new
        // utterance is allowed exactly one more real PCM reinit.
        _pcmReinitIssuedForCurrentUtterance = false;
        // Hygiene: any chunk still queued from the previous utterance's
        // reinit (should be rare/empty by now — that reinit normally
        // completes and flushes well within the 2s new-utterance debounce)
        // is stale the instant a new utterance starts; never carry it into
        // this one.
        if (_pendingPcmChunksAwaitingReinit.isNotEmpty) {
          _log_(
            'PCM QUEUE: discarding ${_pendingPcmChunksAwaitingReinit.length} queued response chunk(s) still '
            'pending from the previous utterance — a new utterance just started.',
          );
          _pendingPcmChunksAwaitingReinit.clear();
        }
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
        _isSpeaking = false;
        _speechStoppedAt = DateTime.now();
        _silenceTimer = null;
        _log_('detected user stopped speaking — latency stopwatch started');
        _finalizeUtteranceEndDeterministicTriggers();
      });
    }
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
  ///  - a response STARTING playback ([_onResponseAudioChunk], the
  ///    outgoing-mic-audio PAUSE) and FINISHING playback
  ///    ([_maybeResumeOutgoingAudio], the RESUME) — so a long Gemini
  ///    response with little raw silence around it never starves the timer
  ///  - a toolCall message arriving, AND each function call within it
  ///    succeeding ([_onServerMessage]/[_handleToolCall])
  /// Cancels any previously scheduled pair first so a reset always restarts
  /// the full window rather than layering timers on top of each other. The
  /// 50s warning/60s close should therefore only ever fire after genuinely
  /// continuous silence from BOTH the technician and Gemini for that full
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
    unawaited(_stopTest());
  }

  /// Sends Gemini a `clientContent` turn instructing it to speak [text]
  /// verbatim over its own Live conversation turn — same mechanism as
  /// [_fireInactivityWarning], factored out so [_dispatchWithOpenCameraSafeguards]
  /// can reuse it for the FIX 2 open_camera acknowledgment without
  /// duplicating the message shape.
  void _speakAcknowledgment(String text) {
    _informGeminiToSpeakVerbatim(text, reason: 'acknowledgment');
  }

  /// FIX 2: every function EXCEPT `open_camera` dispatches exactly as
  /// before — this only adds the acknowledgment/hard-timeout safeguards
  /// around `open_camera` itself, since that's the one call the reliability
  /// audit found can occasionally run far longer than the ~2-3s typical
  /// case. See [_openCameraAckDelay]/[_openCameraHardTimeout]'s doc comments
  /// for the thresholds.
  ///
  /// The real dispatch (`dispatchGeminiFunctionCall`) is started
  /// immediately and never cancelled outright — Dart's `Future`s aren't
  /// preemptible, and the underlying call is a real platform camera
  /// operation mid-flight, not something safe to abandon in place. Instead:
  ///  - at [_openCameraAckDelay], if it hasn't finished, [_speakAcknowledgment]
  ///    fires so the technician hears something instead of dead air.
  ///  - at [_openCameraHardTimeout], if it STILL hasn't finished, this method
  ///    stops WAITING on it (via [Future.timeout]) and returns a
  ///    `status: timeout` response so `_handleToolCall` can tell Gemini to
  ///    ask the technician to try again — logged clearly as
  ///    "HARD TIMEOUT", never a silent hang.
  /// The real call keeps running in the background after that; its eventual
  /// outcome is only logged (never re-surfaced to Gemini — the technician
  /// has already been told to retry). If it eventually SUCCEEDS after the
  /// timeout already fired, the now-unused open `CameraController` is
  /// disposed immediately here (rather than left to leak until some future
  /// `open_camera` call's own `_discardPending()` happens to clean it up),
  /// so the camera hardware is freed for a retry as soon as possible.
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
      final needsAudioHardPause = name == 'capture_photo';
      if (needsAudioHardPause) {
        _cameraNativeCallInProgress = true;
        _preemptiveDefaultMuteSafetyTimer?.cancel();
        _preemptiveDefaultMuteSafetyTimer = null;
        _log_(
          'capture_photo: hard-pausing ALL audio feed processing until the native shutter call reports back '
          '— see PART N item 3.',
        );
        debugPrint('PHOTO TIMING [capture_photo]: audio_hard_pause_engaged at ${DateTime.now()}');
      }
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
        if (needsAudioHardPause) {
          _cameraNativeCallInProgress = false;
          debugPrint('PHOTO TIMING [capture_photo]: audio_hard_pause_released at ${DateTime.now()}');
        }
      }
    }

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
      _speakAcknowledgment(_openCameraAckText);
    });

    try {
      return await realCall.timeout(
        _openCameraHardTimeout,
        onTimeout: () {
          debugPrint('PHOTO TIMING [open_camera]: HARD TIMEOUT at ${stopwatch.elapsedMilliseconds}ms — giving up waiting, telling Gemini to ask for a retry');
          _log_(
            'open_camera: HARD TIMEOUT after ${_openCameraHardTimeout.inSeconds}s (real call still running in '
            'background) — returning status=timeout so Gemini tells the technician to try again',
          );
          unawaited(
            realCall.then(
              (result) async {
                debugPrint(
                  'PHOTO TIMING [open_camera]: late completion after timeout at '
                  '${stopwatch.elapsedMilliseconds}ms — succeeded ($result)',
                );
                // PART K fix (CONFIRMED regression: this used to ALWAYS
                // dispose the now-open controller — throwing away a
                // successfully-opened camera and forcing the technician
                // through a second ~15-70s wait on manual retry, even though
                // the hardware work itself is genuinely done). If the
                // technician is still on the same screen (nothing else
                // happened while we waited — no OTHER screen task took over,
                // and this widget is still alive), hand them the live
                // preview instead: the same screen-task bookkeeping a normal
                // in-time success gets via `_updateScreenTaskForToolCall`,
                // plus a short spoken heads-up since they were already told
                // to retry a moment ago. Only dispose if they've genuinely
                // moved on (a different screen task is active, or the
                // session ended) — that controller really is orphaned then.
                if (!mounted || _teardownStarted || _screenTask != _ScreenTask.none) {
                  _log_(
                    'open_camera: late success after its own timeout, but the screen has moved on '
                    '(screenTask=$_screenTask, mounted=$mounted, teardownStarted=$_teardownStarted) — '
                    'disposing the now-unused controller.',
                  );
                  await _cameraSession.dispose();
                  return;
                }
                _log_(
                  'open_camera: late success after its own timeout — technician still on the same screen, '
                  'handing them the live preview instead of discarding it.',
                );
                if (mounted) setState(() => _screenTask = _ScreenTask.cameraLive);
                _pausedVoiceService?.setScreenTaskActive(true);
                _informGeminiToSpeakVerbatim(
                  "The camera's actually open now — go ahead when you're ready.",
                  reason: 'open_camera_late_success',
                );
              },
              onError: (Object e, StackTrace st) {
                debugPrint(
                  'PHOTO TIMING [open_camera]: late completion after timeout at '
                  '${stopwatch.elapsedMilliseconds}ms — FAILED: $e',
                );
                _log_('open_camera: late failure after its own timeout: $e');
              },
            ),
          );
          return <String, dynamic>{
            'status': 'timeout',
            'job_id': args['job_id'],
            'message': 'Opening the camera timed out after ${_openCameraHardTimeout.inSeconds} seconds — ask the '
                'technician to try again.',
          };
        },
      );
    } finally {
      // PART K — see [_cameraNativeCallInProgress]'s doc comment: resume normal
      // audio processing the instant we're done waiting on this call,
      // whether it finished normally or the hard timeout gave up on it.
      _cameraNativeCallInProgress = false;
      ackTimer.cancel();
    }
  }

  void _onServerMessage(dynamic raw) {
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      final decoded = jsonDecode(text) as Map<String, dynamic>;

      if (decoded.containsKey('setupComplete')) {
        _setupComplete = true;
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
      }
      if (decoded.containsKey('sessionResumptionUpdate')) {
        _log_('sessionResumptionUpdate (informational, harmless — session resumption handle): ${decoded['sessionResumptionUpdate']}');
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
            _log_(
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
        _log_('GEMINI SAID: "$outputTranscriptionText"');
        _logCrossRef('GEMINI SAID', outputTranscriptionText);
        _currentTurnHadAudioOrText = true;
        // BUG 2 backstop (step 3 of the echo-leak fix): rolling record of
        // Gemini's own recently-spoken text, compared against every
        // inputTranscription chunk in [_looksLikeGeminiEcho] before it's
        // allowed anywhere near a trigger buffer. Bounded to the last 600
        // chars so it can't grow unbounded over a long session.
        _recentGeminiOutputText = ('$_recentGeminiOutputText $outputTranscriptionText').trim();
        if (_recentGeminiOutputText.length > 600) {
          _recentGeminiOutputText = _recentGeminiOutputText.substring(_recentGeminiOutputText.length - 600);
        }
      }

      if (serverContent['turnComplete'] == true) {
        _log_('model turn complete');
        _turnComplete = true;
        _maybeResumeOutgoingAudio();
        _clearDeterministicAudioSuppression('turnComplete received');
        _logAndResetTurnShape('turnComplete');
      }
      if (serverContent['interrupted'] == true) {
        _log_('model turn interrupted');
        _turnComplete = true;
        _maybeResumeOutgoingAudio();
        _clearDeterministicAudioSuppression('interrupted received');
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
    _currentTurnHadToolCall = false;
    _currentTurnHadAudioOrText = false;
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
            responsePayload = await _dispatchWithOpenCameraSafeguards(name: name, args: args);
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
      if (_isNavigatingScreenFunction(name) && !responsePayload.containsKey('error')) {
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
      final spokenText = _buildSpokenTextForResult(name: name, result: responsePayload);
      if (spokenText != null) {
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
      unawaited(_stopTest());
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
    // BUG 2 backstop (step 3): checked BEFORE the "inputTranscription
    // chunk:" log line and BEFORE any trigger sees this text at all — see
    // [_looksLikeGeminiEcho]'s doc comment for the thresholds and why they
    // exist.
    if (_looksLikeGeminiEcho(textChunk)) {
      _log_(
        'ECHO BACKSTOP: discarding inputTranscription chunk "$textChunk" — matches Gemini\'s own recent spoken '
        'output ("$_recentGeminiOutputText"), treating as acoustic mic bleed, not technician speech — NOT '
        'passed to any trigger',
      );
      debugPrint('PHOTO TIMING [echo]: discarded likely-echo inputTranscription chunk: "$textChunk"');
      return;
    }
    _log_('inputTranscription chunk: "$textChunk"');

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
    _muteImmediatelyOnFirstChunkOfUtterance();

    // PART D items 1-2: checked FIRST — a plain greeting/presence-check
    // ("can you hear me", "hello") resolves instantly via its own canned
    // response, same as it always has.
    _maybeTriggerAcknowledgePresence(textChunk);

    // BUG FIX: reset on every transcribed chunk of real technician speech,
    // not just the raw-amplitude silence->speech edge in [_trackSpeechLevel]
    // — a genuine transcription is unambiguous evidence the conversation is
    // active right now.
    _resetInactivityTimer(reason: 'technician transcription chunk received');

    _maybeTriggerViewEstimate(textChunk);
    _maybeTriggerGetJobDetails(textChunk);
    _maybeDetectIntentionalGoBack(textChunk);
    _maybeDetectPhotoDecision(textChunk);

    // CONFIRMED via a full real session: Gemini called zero functions
    // natively — every one of these gets the same deterministic backstop
    // proven above for get_job_details, via the shared [_TranscriptTrigger]
    // machinery (see its own doc comment).
    _maybeTriggerDeterministic(
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
    );
    _maybeTriggerDeterministic(
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
    );
    _maybeTriggerDeterministic(
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
    );
    _maybeTriggerDeterministic(
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
    );
    // Guarded to skip while a camera/photo flow is already active (open
    // again mid-flow would be a confusing no-op/duplicate-open at best).
    _maybeTriggerDeterministic(
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
      onGuardFailed: () => _informGeminiToSpeakVerbatim(
        "The camera's already open — say 'ready' or 'capture it' when you want the photo.",
        reason: 'open_camera_guard_failed_already_open',
      ),
    );
    // FIX 2: capture_photo's own backstop, mirroring open_camera's exactly —
    // guarded to ONLY arm while the live camera preview is genuinely showing
    // ([_ScreenTask.cameraLive], set by a successful open_camera/retake_photo
    // — see [_updateScreenTaskForToolCall]), so "ready"/"go ahead" can never
    // misfire at any other point in the conversation.
    _maybeTriggerDeterministic(
      _deterministicTriggers['capture_photo']!,
      textChunk,
      requireJobId: true,
      guard: () => _screenTask == _ScreenTask.cameraLive,
      buildArgs: (_, jobId) => {'job_id': jobId},
      buildSpokenText: (result) => _defaultDeterministicSpokenText(
        name: 'capture_photo',
        humanAction: 'capture the photo',
        appAction: 'took the photo for you',
        result: result,
      ),
    );
    _maybeTriggerDeterministic(
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
    );
    // get_current_screen bypasses dispatchGeminiFunctionCall entirely (see
    // [_describeCurrentScreen]), so it gets its own small hand-rolled
    // detector rather than going through [_maybeTriggerDeterministic] —
    // same reasoning as get_job_details predating the shared engine.
    _maybeTriggerGetCurrentScreen(textChunk);
    // PART A item 3: meta/capability questions ("what can you do") answer
    // from a FIXED, hardcoded description, never dispatchGeminiFunctionCall
    // — same hand-rolled reasoning as get_current_screen just above, not the
    // shared [_TranscriptTrigger] engine (which sends the DISPATCHER's real
    // result to Gemini to speak, not a canned string).
    _maybeTriggerMetaCapability(textChunk);
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

    // PART F items 4-5 / PART I item 1: checked LAST, after every known-
    // command trigger above has already had its synchronous chance to
    // match THIS chunk — the actual mute already happened unconditionally
    // at the top of this method (see [_muteImmediatelyOnFirstChunkOfUtterance]);
    // this only arms the last-resort safety timeout if nothing resolved.
    _maybeArmPreemptiveMuteSafetyTimeout();
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
      guard: () => !_otherSpecificTriggerAlreadyResolvedThisUtterance,
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
    // PART F item 4: by this point every per-chunk AND end-of-utterance
    // trigger above has already had its synchronous chance to match, so
    // this sees the final, settled state of every trigger's
    // resolvedForCurrentUtterance flag.
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
    // PART G item 1 — see [_utteranceAlreadyResolvedByTrigger]'s doc
    // comment: some OTHER trigger already resolved this utterance for real
    // (possibly several chunks ago, after which
    // [_clearAllTriggerBuffersAfterSuccess] wiped every per-trigger
    // `resolvedForCurrentUtterance` flag below back to `false` so a genuine
    // follow-up request could still be detected) — never treat that as
    // "nothing matched" and speak a second, wrong response over it.
    if (_utteranceAlreadyResolvedByTrigger) {
      _clearPreemptiveDefaultMuteSilently('utterance already resolved by another trigger');
      return;
    }
    final kbTrigger = _deterministicTriggers['get_kb_answer']!;
    final siteConditionTrigger = _deterministicTriggers['site_condition']!;
    if (_otherSpecificTriggerAlreadyResolvedThisUtterance ||
        kbTrigger.resolvedForCurrentUtterance ||
        siteConditionTrigger.resolvedForCurrentUtterance) {
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
      _clearPreemptiveDefaultMuteSilently('KB catch-all found nothing worth asking about');
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
    _log_('KB CATCH-ALL: nothing else matched this utterance — routing "$transcript" to get_kb_answer as a last resort.');
    unawaited(
      _executeDeterministic(
        kbTrigger,
        args: {'question': transcript, 'job_id': ?widget.jobId},
        buildSpokenText: _buildKbCatchAllSpokenText,
      ),
    );
  }

  /// PART F item 4 — see [_kbCatchAllBoundaryDeclineText]'s doc comment
  /// for why the catch-all substitutes the boundary phrase instead of the
  /// KB's own raw "not available" decline specifically for THIS path
  /// (nothing else matched at all), while [_buildKbAnswerSpokenText] (used
  /// by get_kb_answer's own EARLY/intentional match — a genuine trade/
  /// how-to question the technician clearly asked) still speaks whatever
  /// the KB itself returned, decline included, unchanged.
  String _buildKbCatchAllSpokenText(Map<String, dynamic> result) {
    final answer = result['answer'] as String?;
    if (answer == null || _kbNoMatchLiteralAnswers.contains(answer)) {
      return _kbCatchAllBoundaryDeclineText;
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
    _log_(
      'PREEMPTIVE MUTE: first chunk of a new utterance — muting Gemini\'s audio immediately and '
      'unconditionally, before any trigger-specific logic (including acknowledge_presence/meta_capability) runs.',
    );
    debugPrint('PHOTO TIMING [preemptive_mute]: new utterance — muting NOW, unconditionally');
    _interruptGeminiForDeterministicTrigger('preemptive_default_mute');
    _preemptiveDefaultMuteActive = true;
  }

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
    if (_deterministicTriggers['site_condition']!.resolvedForCurrentUtterance) return;
    if (_preemptiveDefaultMuteSafetyTimer != null) return; // already armed for this utterance
    _log_(
      'PREEMPTIVE DEFAULT MUTE: nothing matches a known command pattern yet — arming the '
      '${_preemptiveDefaultMuteSafetyDelay.inSeconds}s safety-net timeout.',
    );
    _preemptiveDefaultMuteSafetyTimer = Timer(_preemptiveDefaultMuteSafetyDelay, () {
      if (!_preemptiveDefaultMuteActive) return;
      _log_(
        'PREEMPTIVE DEFAULT MUTE: safety timeout (${_preemptiveDefaultMuteSafetyDelay.inSeconds}s) — nothing '
        'ever resolved this, not even a KB catch-all dispatch — inviting a retry as a last resort so the '
        'session doesn\'t stay silently muted.',
      );
      _informGeminiToSpeakVerbatim(_unrecognizedUtteranceRetryText, reason: 'preemptive_default_mute_timeout');
    });
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
    final normalized = text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ');
    final words = normalized.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final padded = ' ${words.join(' ')} ';
    if (_viewEstimateIndicatorPhrases.any((phrase) => padded.contains(' $phrase '))) return true;
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
  void _clearAllTriggerBuffersAfterSuccess(String reason) {
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
    if (_preemptiveDefaultMuteActive) {
      _log_('PREEMPTIVE DEFAULT MUTE: cleared — "$reason" resolved this utterance for real.');
    }
    _preemptiveDefaultMuteActive = false;
    _preemptiveDefaultMuteSafetyTimer?.cancel();
    _preemptiveDefaultMuteSafetyTimer = null;
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
    if (_viewEstimateDetectionResolvedForCurrentUtterance) return;
    _viewEstimateDetectionBuffer = '$_viewEstimateDetectionBuffer $textChunk'.trim();

    if (!_looksLikeViewEstimateRequest(_viewEstimateDetectionBuffer)) return;

    final transcript = _viewEstimateDetectionBuffer;
    final now = DateTime.now();
    final lastActivity = _lastViewEstimateActivityAt;
    if (lastActivity != null && now.difference(lastActivity) < _viewEstimateDebounce) {
      _viewEstimateDetectionResolvedForCurrentUtterance = true;
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
    Map<String, dynamic> result;
    _beginFunctionCallInFlight('deterministic view_estimate');
    try {
      result = await dispatchGeminiFunctionCall(
        ref: ref,
        cameraSession: _cameraSession,
        navigationSession: _navigationSession,
        name: 'view_estimate',
        args: {'job_id': jobId},
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
    _updateScreenTaskForToolCall('view_estimate', result);

    _lastViewFunctionSucceededAt = DateTime.now();
    _intentionalGoBackHeardSinceLastView = false;
    _currentViewScreenName = 'view_estimate';

    _informGeminiOfDeterministicViewEstimate(result: result);
  }

  /// Sends Gemini a `clientContent` turn describing what the deterministic
  /// view_estimate trigger just did. Hands Gemini the real estimate data
  /// from [result] so its own conversation can speak the estimate details,
  /// since the navigation (and the data lookup) already happened whether or
  /// not Gemini itself decided to call view_estimate.
  void _informGeminiOfDeterministicViewEstimate({required Map<String, dynamic> result}) {
    _informGeminiToSpeakVerbatim(_buildViewEstimateSpokenText(result), reason: 'deterministic view_estimate');
  }

  /// CONFIRMED ghost-call bug: broad, NOT exact-phrase, whole-word/phrase
  /// pattern match for "the technician wants to know about this job" — same
  /// normalization/padding approach as [_looksLikeViewEstimateRequest]. A
  /// false positive here only costs an extra read-only lookup + an
  /// informational clientContent message, never a write.
  bool _looksLikeGetJobDetailsRequest(String text) {
    final normalized = text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ');
    final words = normalized.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final padded = ' ${words.join(' ')} ';
    return _getJobDetailsIndicatorPhrases.any((phrase) => padded.contains(' $phrase '));
  }

  /// Called from [_onInputTranscription] on EVERY transcript chunk — same
  /// accumulate/resolve/debounce shape as [_maybeTriggerViewEstimate], just
  /// applied to [_getJobDetailsIndicatorPhrases]/[_getJobDetailsDebounce].
  void _maybeTriggerGetJobDetails(String textChunk) {
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
    Map<String, dynamic> result;
    _beginFunctionCallInFlight('deterministic get_job_details');
    try {
      result = await dispatchGeminiFunctionCall(
        ref: ref,
        cameraSession: _cameraSession,
        navigationSession: _navigationSession,
        name: 'get_job_details',
        args: {'job_id': jobId},
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
    final normalized = text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ');
    final words = normalized.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final padded = ' ${words.join(' ')} ';
    return _getCurrentScreenIndicatorPhrases.any((phrase) => padded.contains(' $phrase '));
  }

  /// Hand-rolled deterministic trigger for get_current_screen — NOT routed
  /// through [_maybeTriggerDeterministic]/[_TranscriptTrigger] since
  /// answering doesn't call [dispatchGeminiFunctionCall] at all (see
  /// [_describeCurrentScreen]); no job_id gating either, since describing
  /// the current screen works the same in standalone mode. Same
  /// accumulate/resolve/debounce shape as [_maybeTriggerGetJobDetails]
  /// otherwise.
  void _maybeTriggerGetCurrentScreen(String textChunk) {
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
    if (_metaCapabilityIndicatorPhrases.any((phrase) => padded.contains(' $phrase '))) return true;
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
    final normalized = text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ');
    final words = normalized.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final padded = ' ${words.join(' ')} ';
    return _acknowledgePresenceIndicatorPhrases.any((phrase) => padded.contains(' $phrase '));
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
    _informGeminiToSpeakVerbatim(_acknowledgePresenceCannedResponse, reason: 'acknowledge_presence');
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
      result = await _dispatchWithOpenCameraSafeguards(name: trigger.name, args: args);
      debugPrint('PHOTO TIMING [_executeDeterministic]: _dispatchWithOpenCameraSafeguards RETURNED for "${trigger.name}": $result');
    } catch (e, stackTrace) {
      debugPrint('PHOTO TIMING [_executeDeterministic]: EXCEPTION for "${trigger.name}": $e');
      debugPrint('GEMINI DETERMINISTIC TRIGGER ERROR (${trigger.name}): $e\n$stackTrace');
      _log_('DETERMINISTIC ${trigger.name.toUpperCase()} TRIGGER: ${trigger.name} FAILED: $e');
      return;
    } finally {
      _endFunctionCallInFlight('deterministic ${trigger.name}');
    }

    _log_('DETERMINISTIC ${trigger.name.toUpperCase()} TRIGGER: ${trigger.name} succeeded: $result');
    debugPrint('GEMINI DETERMINISTIC TRIGGER: ${trigger.name} succeeded');
    if (!result.containsKey('error')) {
      _clearAllTriggerBuffersAfterSuccess('deterministic ${trigger.name}');
    }

    _updateScreenTaskForToolCall(trigger.name, result);
    if (_isNavigatingScreenFunction(trigger.name) && !result.containsKey('error')) {
      _lastViewFunctionSucceededAt = DateTime.now();
      _intentionalGoBackHeardSinceLastView = false;
      _currentViewScreenName = trigger.name;
      _log_(
        'GO BACK COOLDOWN: "${trigger.name}" succeeded (deterministic) — go_back cooldown armed for '
        '${_goBackCooldownDuration.inSeconds}s unless an intentional go-back phrase is heard first.',
      );
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
      return "Sorry, something went wrong doing that — please try again.";
    }
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
        return result['status'] == 'queued_offline'
            ? "I've saved that photo — it'll upload once you're back online."
            : "I've uploaded the photo.";
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
  String _buildKbAnswerSpokenText(Map<String, dynamic> result) {
    return (result['answer'] as String?) ?? "Sorry, I don't have that information — check with your supervisor.";
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
    if (trigger.resolvedForCurrentUtterance) {
      debugPrint('DETERMINISTIC SKIP: trigger=${trigger.name} already resolved for this utterance');
      return;
    }
    trigger.buffer = '${trigger.buffer} $textChunk'.trim();

    if (!trigger.matches(trigger.buffer)) {
      debugPrint(
        'DETERMINISTIC NO MATCH: trigger=${trigger.name} pattern=${trigger.phrases} against '
        "text='${trigger.buffer}'",
      );
      return;
    }
    if (guard != null && !guard()) {
      debugPrint('DETERMINISTIC SKIP: trigger=${trigger.name} matched but guard() returned false');
      if (onGuardFailed != null) {
        trigger.resolvedForCurrentUtterance = true;
        trigger.lastActivityAt = DateTime.now();
        onGuardFailed();
      }
      return;
    }

    final transcript = trigger.buffer;
    final now = DateTime.now();
    final lastActivity = trigger.lastActivityAt;
    if (lastActivity != null && now.difference(lastActivity) < _deterministicTriggerDebounce) {
      trigger.resolvedForCurrentUtterance = true;
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
      _log_(
        'DETERMINISTIC ${trigger.name.toUpperCase()} TRIGGER: pattern matched ("$transcript") but no job_id '
        'known (standalone mode) — skipping.',
      );
      return;
    }

    trigger.resolvedForCurrentUtterance = true;
    trigger.lastActivityAt = now;
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

  /// FIX 2: whole-word/phrase match against [_intentionalGoBackPhrases] —
  /// same normalization/padding approach as [_looksLikeViewEstimateRequest]
  /// (lowercased, stripped to letters/spaces, space-padded substring
  /// checks), so "backpack" never matches "back" and "gone" never matches
  /// "go".
  bool _looksLikeIntentionalGoBack(String text) {
    final normalized = text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ');
    final words = normalized.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final padded = ' ${words.join(' ')} ';
    return _intentionalGoBackPhrases.any((phrase) => padded.contains(' $phrase '));
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
    if (_screenTask == _ScreenTask.cameraCaptured) {
      return "You're looking at the photo you just took, waiting for you to say keep it or retake it.";
    }
    if (_screenTask == _ScreenTask.cameraLive) {
      return "You're in the camera, ready to take a photo.";
    }
    if (_viewScreenActive) {
      final label = switch (_currentViewScreenName) {
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

    Map<String, dynamic> result;
    _beginFunctionCallInFlight('deterministic go_back');
    try {
      result = await dispatchGeminiFunctionCall(
        ref: ref,
        cameraSession: _cameraSession,
        navigationSession: _navigationSession,
        name: 'go_back',
        args: {'job_id': jobId},
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
  Future<Map<String, dynamic>> _maybeCloseCameraFlowForGoBack(
    Map<String, dynamic> responsePayload, {
    required String jobId,
  }) async {
    if (responsePayload.containsKey('error')) return responsePayload;
    if (responsePayload['status'] == 'navigated_back') return responsePayload;
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
    await _cameraSession.dispose();
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

  /// Reliability audit finding (CHECK 4): broad, NOT exact-phrase,
  /// whole-word/phrase pattern match for "the technician wants to keep
  /// this photo" — see [_photoConfirmIndicatorPhrases]'s doc comment. Same
  /// normalization/padding approach as [_looksLikeViewEstimateRequest].
  bool _looksLikePhotoConfirmRequest(String text) {
    final normalized = text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ');
    final words = normalized.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final padded = ' ${words.join(' ')} ';
    return _photoConfirmIndicatorPhrases.any((phrase) => padded.contains(' $phrase '));
  }

  /// See [_looksLikePhotoConfirmRequest]'s doc comment — same approach,
  /// against [_photoRetakeIndicatorPhrases].
  bool _looksLikePhotoRetakeRequest(String text) {
    final normalized = text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ');
    final words = normalized.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final padded = ' ${words.join(' ')} ';
    return _photoRetakeIndicatorPhrases.any((phrase) => padded.contains(' $phrase '));
  }

  /// Reliability audit finding (CHECK 4): `capture_photo`'s required
  /// follow-up — confirm_photo_upload or retake_photo — had NO
  /// deterministic backstop at all, the same under-triggered-function gap
  /// already proven for view_estimate/go_back. Armed ONLY while
  /// [_screenTask] is [_ScreenTask.cameraCaptured] (a captured-but-
  /// undecided photo actually exists to act on); resolves at most once per
  /// utterance. If the accumulated buffer matches BOTH confirm and retake
  /// phrasing (a genuinely ambiguous utterance), this deliberately does
  /// NOT fire either — safer to let Gemini's own conversational judgment
  /// (or a later, clearer utterance) resolve the ambiguity than to guess.
  void _maybeDetectPhotoDecision(String textChunk) {
    if (_screenTask != _ScreenTask.cameraCaptured || _photoDecisionResolvedForCurrentUtterance) return;
    _photoDecisionDetectionBuffer = '$_photoDecisionDetectionBuffer $textChunk'.trim();

    final wantsConfirm = _looksLikePhotoConfirmRequest(_photoDecisionDetectionBuffer);
    final wantsRetake = _looksLikePhotoRetakeRequest(_photoDecisionDetectionBuffer);
    if (wantsConfirm == wantsRetake) return; // neither matched yet, or both did (ambiguous) — keep waiting.

    final action = wantsConfirm ? 'confirm_photo_upload' : 'retake_photo';
    _photoDecisionResolvedForCurrentUtterance = true;
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

    Map<String, dynamic> result;
    _beginFunctionCallInFlight('deterministic $action');
    try {
      result = await dispatchGeminiFunctionCall(
        ref: ref,
        cameraSession: _cameraSession,
        navigationSession: _navigationSession,
        name: action,
        args: {'job_id': jobId},
      );
    } catch (e, stackTrace) {
      debugPrint('GEMINI DETERMINISTIC TRIGGER ERROR ($action): $e\n$stackTrace');
      _log_('DETERMINISTIC PHOTO DECISION TRIGGER: $action FAILED: $e');
      return;
    } finally {
      _endFunctionCallInFlight('deterministic $action');
    }

    _log_('DETERMINISTIC PHOTO DECISION TRIGGER: $action succeeded: $result');
    debugPrint('GEMINI DETERMINISTIC TRIGGER: $action succeeded');
    _clearAllTriggerBuffersAfterSuccess('deterministic $action');
    _updateScreenTaskForToolCall(action, result);
    _informGeminiOfDeterministicPhotoDecision(action: action, result: result);
  }

  /// Sends Gemini a `clientContent` turn describing what the deterministic
  /// photo-decision trigger just did — same mechanism
  /// [_informGeminiOfDeterministicViewEstimate]/[_informGeminiOfDeterministicGoBack]
  /// use.
  void _informGeminiOfDeterministicPhotoDecision({required String action, required Map<String, dynamic> result}) {
    final text = _buildSpokenTextForResult(name: action, result: result);
    if (text != null) _informGeminiToSpeakVerbatim(text, reason: 'deterministic $action');
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
    if (responsePayload['status'] == 'timeout') {
      _log_('screen task: "$name" TIMED OUT -> ${_ScreenTask.none} (nothing was confirmed open)');
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
      _log_(
        'screen task: "$name" FAILED -> $nextTask '
        '(${name == "open_camera" ? "nothing was ever opened" : "resource state left unchanged"})',
      );
      if (nextTask != _screenTask && mounted) setState(() => _screenTask = nextTask);
      _pausedVoiceService?.setScreenTaskActive(nextTask != _ScreenTask.none);
      return;
    }

    final nextTask = switch (name) {
      'open_camera' || 'retake_photo' => _ScreenTask.cameraLive,
      'capture_photo' => _ScreenTask.cameraCaptured,
      _ => _ScreenTask.none, // confirm_photo_upload — task done, back to pure conversation.
    };

    _log_('screen task: "$name" succeeded -> $nextTask');
    if (mounted) setState(() => _screenTask = nextTask);
    _pausedVoiceService?.setScreenTaskActive(nextTask != _ScreenTask.none);
  }

  /// BUG 2 backstop (step 3): rolling record of Gemini's own recently-spoken
  /// text, built from `serverContent.outputTranscription` chunks (see
  /// [_onServerMessage]) — bounded to the last 600 characters. Compared
  /// against every `inputTranscription` chunk in [_looksLikeGeminiEcho]
  /// BEFORE it reaches any trigger buffer.
  String _recentGeminiOutputText = '';

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
  ///    [_recentGeminiOutputText].
  /// CONFIRMED real leaked examples this is sized to catch: "Is that
  /// correct?" (3 words), "What would you like to do next?" (7 words) — both
  /// comfortably clear these thresholds.
  ///
  /// HONEST LIMITATION: a substring check requires a near-verbatim match.
  /// Gemini's own synthesized speech, once played through a real speaker
  /// and re-captured by the mic under real acoustic conditions, may be
  /// re-transcribed slightly differently than the original — a genuine
  /// echo with enough ASR drift between the two transcriptions could slip
  /// past this backstop. That's why this is a backstop, not the primary
  /// fix; the primary fix is closing the actual mic-timing gap (see
  /// [_lastAudioChunkFedAt]/[_resumeGraceDelay] and the MIC SEND logging
  /// in [_onMicChunk]).
  static const int _echoBackstopMinWords = 3;
  static const int _echoBackstopMinChars = 12;

  bool _looksLikeGeminiEcho(String chunk) {
    final normalizedChunk = _normalizeForEchoCompare(chunk);
    if (normalizedChunk.length < _echoBackstopMinChars) return false;
    if (normalizedChunk.split(' ').where((w) => w.isNotEmpty).length < _echoBackstopMinWords) return false;
    final normalizedRecent = _normalizeForEchoCompare(_recentGeminiOutputText);
    if (normalizedRecent.isEmpty) return false;
    return normalizedRecent.contains(normalizedChunk);
  }

  String _normalizeForEchoCompare(String text) {
    return text.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
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
  // BUG 2 fix (CONFIRMED: full Gemini sentences leaking into
  // inputTranscription, e.g. "I'm showing the preview now, can you confirm
  // you can see the picture?"): 250ms was sized only for the DOCUMENTED
  // native-buffering lag ("tens to a couple hundred ms"). Raised to a more
  // conservative real-device margin — cheap to widen, and a genuinely
  // truncated sentence leaking through is a worse failure than the mic
  // resuming an extra 150ms later than strictly necessary.
  //
  // PART L item 1: 4127d46d-flutter_run_log.txt's "I see you good egg."
  // corruption is CONSISTENT with this exact overlap (a real command
  // starting while trailing playback was still draining), but not
  // confirmed — that specific run log isn't available in this environment
  // to check whether an ECHO BACKSTOP discard fired immediately before this
  // failure, which would be the direct evidence. Raised defensively anyway
  // (400ms -> 600ms): cheap to widen further, same reasoning as the
  // 250ms -> 400ms raise above, pending confirmation from the next real run
  // log that this was (or wasn't) the actual mechanism here.
  static const Duration _resumeGraceDelay = Duration(milliseconds: 600);

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
  void _maybeResumeOutgoingAudio() {
    if (!_outgoingAudioPaused) return;
    if (!_turnComplete) return;
    if (_pcmRemainingFrames > 0) return;
    if (_resumeGraceTimer != null) return;
    _log_(
      'outgoing mic audio: playback appears drained — waiting ${_resumeGraceDelay.inMilliseconds}ms grace '
      'period before resuming (STEP 3 audio-echo fix: absorbs native audio buffering lag beyond what '
      'FlutterPcmSound self-reports, so trailing speaker output has time to actually finish before the mic '
      'sends again)',
    );
    _resumeGraceTimer = Timer(_resumeGraceDelay, () {
      _resumeGraceTimer = null;
      // Re-check: more audio may have arrived (a new response chunk, or the
      // turn was un-completed) during the grace period itself.
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
            '${_resumeGraceDelay.inMilliseconds}ms grace) — waiting ${remaining.inMilliseconds}ms more before '
            'resuming',
          );
          _resumeGraceTimer = Timer(remaining, _maybeResumeOutgoingAudio);
          return;
        }
      }
      _outgoingAudioPaused = false;
      _log_('outgoing mic audio RESUMED (response playback finished + grace period elapsed)');
      _pausedVoiceService?.setExternalSessionPhase(VoicePhase.listening);
      // BUG FIX: a response finishing playback is itself a genuine "the
      // conversation is active" signal — reset here too, not just on
      // technician speech/toolCalls, so a session kept alive purely by long
      // back-and-forth turns (little raw silence, but long stretches where
      // only Gemini's own audio is playing) never times out while genuinely
      // active.
      _resetInactivityTimer(reason: 'outgoing mic audio resumed (response playback finished)');
    });
  }

  /// [FlutterPcmSound.setFeedCallback] fires with how many sample frames are
  /// still buffered for playback — used only to detect "playback has fully
  /// drained" for [_maybeResumeOutgoingAudio]; nothing here needs feeding on
  /// demand since chunks are pushed in directly as they arrive over the
  /// WebSocket (see [_onResponseAudioChunk]).
  void _onPcmFeedCallback(int remainingFrames) {
    _pcmRemainingFrames = remainingFrames;
    _maybeResumeOutgoingAudio();
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
    _suppressResponseAudioForDeterministic = true;
    _pcmRemainingFrames = 0;
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
      _suppressResponseAudioSafetyTimer?.cancel();
      _suppressResponseAudioSafetyTimer = Timer(_suppressResponseAudioSafetyDelay, () {
        if (!_suppressResponseAudioForDeterministic) return;
        _log_(
          'DETERMINISTIC INTERRUPT: safety timeout (${_suppressResponseAudioSafetyDelay.inSeconds}s) — no '
          'interrupted/turnComplete seen for the stale turn, un-muting anyway',
        );
        _suppressResponseAudioForDeterministic = false;
      });
      return;
    }
    _pcmReinitIssuedForCurrentUtterance = true;

    _pcmReady = false;
    final myGeneration = ++_pcmReinitGeneration;
    // Chains onto whatever reinit (if any) is already in flight, rather than
    // firing a second concurrent release()/setup() pair at the native side —
    // see [_pcmReinitChain]'s doc comment.
    _pcmReinitChain = _pcmReinitChain.then((_) async {
      try {
        await FlutterPcmSound.release();
        await FlutterPcmSound.setup(sampleRate: _outputSampleRateHz, channelCount: 1);
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
    _suppressResponseAudioSafetyTimer?.cancel();
    _suppressResponseAudioSafetyTimer = Timer(_suppressResponseAudioSafetyDelay, () {
      if (!_suppressResponseAudioForDeterministic) return;
      _log_(
        'DETERMINISTIC INTERRUPT: safety timeout (${_suppressResponseAudioSafetyDelay.inSeconds}s) — no '
        'interrupted/turnComplete seen for the stale turn, un-muting anyway',
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
  void _informGeminiToSpeakVerbatim(String text, {required String reason}) {
    final channel = _channel;
    if (channel == null) {
      _log_('$reason: WebSocket already closed — cannot inform Gemini');
      return;
    }
    _interruptGeminiForDeterministicTrigger(reason);
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
    _log_('$reason: informed Gemini via clientContent (constrained verbatim instruction)');
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
    // PART K — see [_cameraNativeCallInProgress]'s doc comment: no legitimate NEW
    // response is expected while the camera is mid-open (its own
    // acknowledgment is sent only after this flag clears), so this is a
    // hard drop, not a queue — nothing worth preserving arrives here.
    if (_cameraNativeCallInProgress) {
      _log_(
        'CAMERA OPEN IN PROGRESS: dropping ${pcmBytes.length}-byte response chunk — all audio feed processing '
        'is hard-paused until the camera controller reports back',
      );
      return;
    }
    if (_suppressResponseAudioForDeterministic) {
      _log_('DETERMINISTIC INTERRUPT: dropping ${pcmBytes.length}-byte response chunk (stale/superseded turn)');
      return;
    }
    // PART F items 4-5: SEPARATE gate from the one above — see
    // [_preemptiveDefaultMuteActive]'s doc comment for why this can't
    // share [_suppressResponseAudioForDeterministic]'s own 1.2s
    // safety-unmute (which would wrongly let Gemini's free answer through
    // before a real resolution exists). Never lets an utterance that
    // hasn't yet matched a known command get raw Gemini speech.
    if (_preemptiveDefaultMuteActive) {
      _log_(
        'PREEMPTIVE DEFAULT MUTE: dropping ${pcmBytes.length}-byte response chunk — not yet resolved by a known '
        'trigger or the KB catch-all',
      );
      return;
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
      _pendingPcmChunksAwaitingReinit.add((bytes: pcmBytes, mimeType: mimeType));
      _log_(
        'PCM QUEUE: queuing ${pcmBytes.length}-byte response chunk (generation $_pcmReinitGeneration, '
        '${_pendingPcmChunksAwaitingReinit.length} now queued) — PCM reinit still in flight, will flush in order '
        'once ready, NOT dropped',
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
      _turnComplete = false;
      _log_('outgoing mic audio PAUSED (response playback starting — avoids the mic picking up the speaker and Gemini self-interrupting)');
      _pausedVoiceService?.setExternalSessionPhase(VoicePhase.speaking);
      // BUG FIX (confirmed via log evidence): a warning fired mid-response
      // because nothing reset the timer while Gemini was actively talking —
      // a response starting to play IS the conversation being active, so
      // this must count as a turn exactly like technician speech does.
      _resetInactivityTimer(reason: 'outgoing mic audio paused (response playback starting)');
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
      final latency = DateTime.now().difference(stoppedAt);
      _speechStoppedAt = null;
      _lastLatency = latency;
      _log_('LATENCY (stopped speaking -> first response byte): ${latency.inMilliseconds}ms');
      if (mounted) setState(() {});
    }

    _lastAudioChunkFedAt = DateTime.now();
    unawaited(FlutterPcmSound.feed(PcmArrayInt16.fromList(_pcm16BytesToSamples(pcmBytes))));
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
    _log_(
      'PCM QUEUE: flushing ${queued.length} queued response chunk(s) (generation $generation) now that the PCM '
      'reinit has completed — feeding them in order, none dropped.',
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
    debugPrint('GEMINI LIVE TEST ERROR (WebSocket): $error\n$stackTrace');
    _log_('ERROR (WebSocket): $error');
    if (!mounted) return;
    setState(() {
      _phase = _TestPhase.error;
      _errorMessage = error.toString();
    });
  }

  void _onWsDone() {
    _log_('WebSocket closed by server (closeCode=${_channel?.closeCode}, closeReason=${_channel?.closeReason})');
    if (!mounted) return;
    setState(() => _phase = _TestPhase.closed);
  }

  Future<void> _stopTest() async {
    _log_('Stop Test tapped');
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
    // PART M — see the late-completion `open_camera` handler's use of this
    // (`_teardownStarted`): teardown resets `_screenTask` back to `none`
    // unconditionally, right below — the SAME value that handler already
    // treats as "nothing else happened, safe to hand over the live
    // preview." Without a signal that's specifically "teardown itself is
    // why `_screenTask` reads `none` right now," a camera call resolving
    // late WHILE teardown is running (or has already run) could wrongly
    // read that as "still on the same screen" and try to revive a session
    // that's ending. Set unconditionally, idempotently, the instant
    // teardown starts — safe to set true twice (this function runs twice
    // per session end; see the doc comment just below) and never reset,
    // since a torn-down session never un-tears-down.
    _teardownStarted = true;
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
    _screenTask = _ScreenTask.none;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _resumeGraceTimer?.cancel();
    _resumeGraceTimer = null;
    _suppressResponseAudioSafetyTimer?.cancel();
    _suppressResponseAudioSafetyTimer = null;
    _suppressResponseAudioForDeterministic = false;
    _cancelInactivityTimer();
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
    if (_viewScreenActive) return const SizedBox.shrink();
    return _screenTask == _ScreenTask.none
        ? _buildAmbientPureConversationUi(context)
        : _buildAmbientScreenTaskUi(context);
  }

  /// Opaque, full-screen presentation for [_ScreenTask.cameraLive]/
  /// [_ScreenTask.cameraCaptured] — the exact same `Scaffold` shape this
  /// screen used for ALL of ambient mode before this fix, now scoped to
  /// only the moments there's real content that needs a solid background.
  /// The close button is the tap-fallback for "Loop Off"/"FieldLoop stop",
  /// matching this app's voice+tap parity convention everywhere else.
  Widget _buildAmbientScreenTaskUi(BuildContext context) {
    final canEnd = _phase == _TestPhase.connecting ||
        _phase == _TestPhase.connected ||
        _phase == _TestPhase.requestingToken;
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
          IconButton(
            icon: const Icon(Icons.close_rounded),
            tooltip: 'End session',
            onPressed: canEnd ? _stopTest : null,
          ),
        ],
      ),
      body: SafeArea(child: _buildCameraTaskBody()),
    );
  }

  String get _screenTaskTitle => switch (_screenTask) {
    _ScreenTask.cameraLive => 'Camera',
    _ScreenTask.cameraCaptured => 'Review Photo',
    _ScreenTask.none => 'Voice Assistant',
  };

  /// Pure-conversation ambient body — CHANGED (was: a full opaque `Scaffold`
  /// with a big centered [VoicePhaseIndicator]/title/close button, blocking
  /// whatever screen was open when the wake word was heard for the ENTIRE
  /// conversation). Now paints ONLY a small corner status cluster — the
  /// same [VoicePhaseIndicator] pill every other job-scoped screen's AppBar
  /// already uses, plus the "End session" tap-fallback next to it — and
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
    final canEnd = _phase == _TestPhase.connecting ||
        _phase == _TestPhase.connected ||
        _phase == _TestPhase.requestingToken;
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
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'End session',
                    onPressed: canEnd ? _stopTest : null,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
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
  Widget _buildCameraTaskBody() {
    if (_screenTask == _ScreenTask.cameraCaptured) {
      final capturedFile = _cameraSession.capturedFile;
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
            child: Image.file(File(capturedFile.path), fit: BoxFit.contain),
          ),
        ),
      );
    }

    final controller = _cameraSession.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
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
