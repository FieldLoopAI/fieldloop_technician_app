import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/env.dart';

const int _sampleRateHz = 16000;

/// FIX (WebSocket connect failure — confirmed from logs as
/// `https://api.deepgram.com:0/v1/listen?...`) — root cause is NOT a wrong
/// scheme in this URL (it was already `wss://`, correctly): it's a Dart
/// `Uri` quirk. `Uri`'s built-in default-port table only knows `http`
/// (80) and `https` (443) — it has no entry for `ws`/`wss` — so
/// `Uri.parse('wss://host/path').port` returns `0`, NOT 443, whenever the
/// port is left implicit (verified directly: `Uri.parse('wss://api.
/// deepgram.com/v1/listen').port == 0`). `dart:io`'s `WebSocket.connect`
/// (however it's reached — this used to go through `WebSocketChannel.
/// connect` -> `package:web_socket`'s `IOWebSocket.connect`; now goes
/// through [IOWebSocketChannel.connect] directly, see below, but both
/// paths bottom out in the exact same `dart:io` call) converts a `wss://`
/// URL to `https://` internally to drive the HTTP upgrade handshake, and
/// does so by reconstructing a new `Uri` that carries the original Uri's
/// `port` straight through — so the `0` above lands verbatim in the
/// reconstructed URI as a literal, invalid `:0`, producing exactly the
/// broken URL seen in the log. Adding the port EXPLICITLY here (`:443`)
/// sidesteps the quirk entirely: an explicit port in the source string is
/// stored as a real 443, not looked up via the (wss-blind) default-port
/// table, so it survives the wss-\>https reconstruction as 443 — which
/// `Uri`'s constructor then correctly omits from the printed URL anyway,
/// since 443 IS https's known default.
///
/// FIX (auth: subprotocol -> direct header) — previously carried a
/// short-lived JWT via `Sec-WebSocket-Protocol` (and, briefly, ALSO an
/// `access_token` query param as a workaround for that method's header-
/// length limits — see the git history on this file). Both were working
/// around a constraint that doesn't actually apply here: the
/// `Sec-WebSocket-Protocol` trick exists because BROWSER JavaScript's
/// `WebSocket` API has no way to set an arbitrary `Authorization` header on
/// the handshake — this app is a native Dart client (via `dart:io`'s own
/// `WebSocket`, reached through [IOWebSocketChannel] — see
/// [DeepgramCommandCapture.capture]), which CAN set one directly, the same
/// as any other HTTP request. Doing that instead is both simpler and
/// avoids the JWT-length problem entirely, since an `Authorization` header
/// has no comparable practical size limit the way a subprotocol list does.
/// This function now builds the plain `wss://` URL with ONLY the actual
/// Deepgram query parameters — no token of any kind belongs in the URL
/// anymore.
Uri _deepgramListenUri() {
  return Uri.parse(
    'wss://api.deepgram.com:443/v1/listen'
    '?model=nova-2'
    '&language=en-US'
    '&encoding=linear16'
    '&sample_rate=$_sampleRateHz'
    '&channels=1'
    '&interim_results=true'
    '&punctuate=false'
    '&endpointing=300',
  );
}

/// Redacts [token] for logging — enough of it (prefix/suffix/length) to
/// eyeball-verify at a glance that a real, non-empty, plausible-looking
/// token is actually present at connect time, without ever writing the
/// live credential itself into the log.
String _redactToken(String token) {
  if (token.length <= 8) return '<redacted, len=${token.length}>';
  return '${token.substring(0, 4)}...${token.substring(token.length - 4)} (len=${token.length})';
}

/// Requests a short-lived (30s) Deepgram access token via the FieldLoop
/// backend (`POST /voice/deepgram-token`) — the long-lived Deepgram API key
/// lives only in the backend's secret store and never reaches the client.
Future<String> _requestDeepgramToken(String supabaseAccessToken) async {
  // BUG B2: logged explicitly (not just implied by the request) so a 404 or
  // any other unexpected status can be checked directly against the
  // deployed API Gateway route for POST /voice/deepgram-token, rather than
  // inferred from apiBaseUrl + a string literal elsewhere in the code. This
  // concatenation is identical in form to the already-working
  // '$apiBaseUrl/voice/troubleshoot' (job_voice_commands.dart) and
  // '$apiBaseUrl/photos/upload-url' (job_photos_provider.dart) calls — no
  // trailing slash on apiBaseUrl, no leading slash duplicated — so a 404
  // here points at the API Gateway route itself never having been
  // deployed/wired to the get-deepgram-token Lambda, not a client-side
  // path bug.
  final uri = Uri.parse('$apiBaseUrl/voice/deepgram-token');
  debugPrint('VOICE DEEPGRAM: requesting token from $uri');
  final response = await http.post(uri, headers: {'Authorization': 'Bearer $supabaseAccessToken'});
  debugPrint('VOICE DEEPGRAM: token request to $uri returned status ${response.statusCode}');
  if (response.statusCode != 200) {
    throw StateError('Deepgram token request failed (${response.statusCode}): ${response.body}');
  }
  final decoded = jsonDecode(response.body) as Map<String, dynamic>;
  final token = decoded['token'] as String?;
  if (token == null || token.isEmpty) {
    throw StateError('Deepgram token response missing "token": ${response.body}');
  }
  return token;
}

/// Result of a single, successful [DeepgramCommandCapture.capture] attempt.
class DeepgramCaptureResult {
  const DeepgramCaptureResult({required this.transcript});
  final String transcript;
}

/// Low-latency command capture over Deepgram's streaming API — used ONLY
/// for the short window right after the on-device wake word fires (see
/// `GlobalVoiceService._tryDeepgramCommandCapture`), never for wake-word
/// detection itself, which stays on-device (free, always-on — see
/// `GlobalVoiceService._matchWakeWord`).
///
/// One instance is used per capture attempt (wake word -> command) rather
/// than being long-lived, mirroring how `speech_to_text` sessions are
/// similarly one-shot per command in `GlobalVoiceService`.
///
/// [capture] never throws — any failure (token request, WebSocket connect,
/// mic stream, a parse error) resolves with `null` instead, so the caller
/// can fall back to on-device recognition for that single command attempt
/// rather than leaving the technician stuck with no response.
class DeepgramCommandCapture {
  DeepgramCommandCapture({required this.wakeWordDetectedAt, required this.onPartialTranscript});

  /// Same reference point `GlobalVoiceService._logLatency` uses — passed in
  /// (rather than this class calling `DateTime.now()` at construction)
  /// so latency logging here lines up exactly with the on-device wake-word
  /// timing already logged before this capture starts.
  final DateTime wakeWordDetectedAt;

  /// Called with each partial transcript as it streams in, purely so the
  /// caller can mirror it into `GlobalVoiceState.transcript` for the UI —
  /// final command routing only happens once [capture] resolves.
  final void Function(String partial) onPartialTranscript;

  final AudioRecorder _recorder = AudioRecorder();
  WebSocketChannel? _channel;
  StreamSubscription<Uint8List>? _audioSub;
  StreamSubscription? _wsSub;
  Timer? _silenceTimer;
  final Completer<DeepgramCaptureResult?> _resultCompleter = Completer<DeepgramCaptureResult?>();
  String _pendingTranscript = '';
  bool _finished = false;

  /// DIAGNOSTIC (empty-transcript investigation) — running total of audio
  /// bytes actually handed to `channel.sink.add` this session, logged
  /// alongside every chunk (see [capture]) so a real device log can answer
  /// definitively whether mic audio is flowing into the WebSocket at all,
  /// rather than inferring it indirectly from Deepgram's response (or lack
  /// thereof).
  int _audioBytesSent = 0;

  /// App-level backstop, same philosophy as `GlobalVoiceService.
  /// _commandSettleWindow`: don't only trust the vendor's own end-of-speech
  /// signal (`speech_final`) — finalize on our own clock if nothing new
  /// arrives for this long, so a dropped/late `speech_final` can't hang the
  /// capture indefinitely.
  static const Duration _silenceFinalizeWindow = Duration(milliseconds: 900);

  void _log(String message) => debugPrint('VOICE DEEPGRAM: $message');

  /// Same format as `GlobalVoiceService._logLatency` ("VOICE LATENCY:
  /// wake-to-$stage: ${elapsedMs}ms") so both halves of a wake-word ->
  /// command cycle show up in one consistent, greppable timeline.
  void _logLatency(String stage) {
    final elapsedMs = DateTime.now().difference(wakeWordDetectedAt).inMilliseconds;
    debugPrint('VOICE LATENCY: wake-to-$stage: ${elapsedMs}ms');
  }

  Future<DeepgramCaptureResult?> capture({required String supabaseAccessToken}) async {
    try {
      _log('requesting Deepgram token...');
      _logLatency('deepgram-token-requested');
      final token = await _requestDeepgramToken(supabaseAccessToken);
      _log('Deepgram token received');
      _logLatency('deepgram-token-received');

      // Logged immediately before connecting — the EXACT Uri that gets
      // handed to the connect call (scheme, host, port, query params) so a
      // broken scheme/port is visible directly in the log without having
      // to parse it back out of a WebSocketException message after the
      // fact. No token lives in this Uri anymore (see _deepgramListenUri's
      // doc comment), so it's already safe to log as-is.
      final listenUri = _deepgramListenUri();
      _log('opening Deepgram WebSocket at: $listenUri');
      // FIX (auth: subprotocol -> direct header) — IOWebSocketChannel
      // (dart:io's real WebSocket under the hood, NOT the generic/
      // browser-compatible WebSocketChannel.connect this used to go
      // through) can set an actual Authorization header on the WebSocket
      // handshake, the same as any other native HTTP request — no
      // Sec-WebSocket-Protocol workaround needed. `protocols` is
      // deliberately omitted entirely: Deepgram authenticates off this
      // header now, and sending a stale/irrelevant subprotocol list
      // alongside it would only be misleading in a future log.
      //
      // FIX (auth scheme: Token -> Bearer) — `token` here is a short-lived
      // scoped JWT from Deepgram's `/v1/auth/grant` endpoint (see
      // _requestDeepgramToken), NOT a permanent project API key. Deepgram
      // distinguishes the two schemes: `Token <key>` is for permanent,
      // non-JWT API keys; a granted temporary JWT requires `Bearer <jwt>`
      // instead. Using `Token` against a JWT is what was producing the 401.
      final headers = <String, dynamic>{'Authorization': 'Bearer $token'};
      _log(
        'connecting with headers: {Authorization: Bearer ${_redactToken(token)}} '
        '(direct header auth, no Sec-WebSocket-Protocol)',
      );
      final channel = IOWebSocketChannel.connect(listenUri, headers: headers);
      _channel = channel;
      await channel.ready;
      _log('Deepgram WebSocket opened');
      _logLatency('deepgram-ws-opened');

      _wsSub = channel.stream.listen(_onWsMessage, onError: _onWsError, onDone: _onWsDone);

      // DIAGNOSTIC (empty-transcript investigation) — `record`'s
      // startStream() does NOT check/request permission itself (confirmed
      // against the package source: permission is entirely the caller's
      // responsibility). This app already gates the whole voice feature
      // behind mic permission being granted (see `cameraMicProvider` /
      // `GlobalVoiceService.initialize`, which is what lets the on-device
      // wake-word listener work in the first place) — the same OS-level
      // mic grant covers `record` too, there's no separate prompt for it —
      // but logging the actual result here, rather than assuming that,
      // turns "is this the blocker" from a guess into a verifiable fact in
      // the next log.
      final hasPermission = await _recorder.hasPermission();
      _log('AudioRecorder.hasPermission() = $hasPermission');
      if (!hasPermission) {
        _log('no mic permission for AudioRecorder — cannot start the audio stream, aborting capture');
        _finish(null);
        return await _resultCompleter.future;
      }

      _log('starting mic stream (pcm16, ${_sampleRateHz}hz, mono)...');
      final audioStream = await _recorder.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _sampleRateHz, numChannels: 1),
      );
      _log('mic stream obtained, subscribing now');
      _audioSub = audioStream.listen(
        (chunk) {
          _audioBytesSent += chunk.length;
          _log(
            'sent audio chunk, ${chunk.length} bytes, total $_audioBytesSent bytes this session',
          );
          channel.sink.add(chunk);
        },
        onError: (Object e, StackTrace stackTrace) {
          debugPrint('VOICE ERROR (Deepgram mic stream): $e\n$stackTrace');
          _finish(null);
        },
        onDone: () {
          _log('mic stream closed by recorder (total sent this session: $_audioBytesSent bytes)');
        },
      );
      _armSilenceTimer();

      return await _resultCompleter.future;
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (Deepgram capture): $e\n$stackTrace');
      _finish(null);
      return null;
    } finally {
      // Awaited here (not fire-and-forget) so the mic is guaranteed fully
      // released — recorder stopped, WebSocket closed — before this
      // function returns control to GlobalVoiceService, which resumes
      // on-device listening right after. Both recognizers holding the mic
      // at once is exactly the "fighting over the mic" failure mode this
      // capture is required to avoid.
      await _teardown();
    }
  }

  /// Lets the owner (`GlobalVoiceService`) cut this capture short — e.g.
  /// the technician backs out of the job, mutes, or logs out mid-capture.
  /// Unblocks [capture]'s `await _resultCompleter.future` with `null`; the
  /// `finally` block there still runs [_teardown] as normal.
  void cancel() {
    _log('capture cancelled');
    _finish(null);
  }

  void _onWsMessage(dynamic raw) {
    try {
      final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
      if (decoded['type'] != 'Results') return;

      final alternatives = (decoded['channel'] as Map<String, dynamic>?)?['alternatives'] as List<dynamic>?;
      final transcript = (alternatives != null && alternatives.isNotEmpty)
          ? (alternatives.first as Map<String, dynamic>)['transcript'] as String? ?? ''
          : '';
      final speechFinal = decoded['speech_final'] == true;

      if (transcript.isNotEmpty) {
        _pendingTranscript = transcript;
        _log('partial transcript received: "$transcript" (speech_final=$speechFinal)');
        _logLatency('deepgram-partial-transcript');
        onPartialTranscript(transcript);
        _armSilenceTimer();
      }

      if (speechFinal) {
        _log('Deepgram reported speech_final, finalizing: "$_pendingTranscript"');
        _logLatency('deepgram-final-transcript');
        _finish(_pendingTranscript.isEmpty ? null : DeepgramCaptureResult(transcript: _pendingTranscript));
      }
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (Deepgram message parse): $e\n$stackTrace');
    }
  }

  void _onWsError(Object error, StackTrace stackTrace) {
    debugPrint('VOICE ERROR (Deepgram WebSocket): $error\n$stackTrace');
    _finish(null);
  }

  void _onWsDone() {
    _log('Deepgram WebSocket closed by server');
    _finish(_pendingTranscript.isEmpty ? null : DeepgramCaptureResult(transcript: _pendingTranscript));
  }

  void _armSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(_silenceFinalizeWindow, () {
      // DIAGNOSTIC — _audioBytesSent alongside the empty-transcript
      // finalize is the direct answer to "was any mic audio ever actually
      // sent this session": 0 here means the mic pipeline itself never
      // delivered anything (see the chunk-level logging in capture());
      // a large nonzero number here instead points at a Deepgram-side or
      // format problem, not a missing-audio one.
      _log(
        'silence window elapsed with no speech_final, finalizing: "$_pendingTranscript" '
        '(audio bytes sent this session: $_audioBytesSent)',
      );
      _logLatency('deepgram-final-transcript');
      _finish(_pendingTranscript.isEmpty ? null : DeepgramCaptureResult(transcript: _pendingTranscript));
    });
  }

  void _finish(DeepgramCaptureResult? result) {
    if (_finished) return;
    _finished = true;
    _silenceTimer?.cancel();
    if (!_resultCompleter.isCompleted) _resultCompleter.complete(result);
  }

  Future<void> _teardown() async {
    _log('stopping mic stream, closing Deepgram WebSocket');
    await _audioSub?.cancel();
    await _wsSub?.cancel();
    try {
      await _recorder.stop();
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (Deepgram recorder stop): $e\n$stackTrace');
    }
    await _recorder.dispose();
    try {
      await _channel?.sink.close();
    } catch (e, stackTrace) {
      debugPrint('VOICE ERROR (Deepgram WebSocket close): $e\n$stackTrace');
    }
    _logLatency('deepgram-ws-closed');
  }
}
