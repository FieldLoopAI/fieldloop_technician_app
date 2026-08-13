import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/env.dart';

const int _sampleRateHz = 16000;

Uri _deepgramListenUri() {
  return Uri.parse(
    'wss://api.deepgram.com/v1/listen'
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

      _log('opening Deepgram WebSocket...');
      // Deepgram authenticates via the Sec-WebSocket-Protocol header, NOT a
      // query param — `protocols: ['token', token]` is what
      // WebSocketChannel.connect turns into that header. A query-param
      // token silently fails against Deepgram's endpoint (confirmed by the
      // dashboard team's existing working implementation).
      final channel = WebSocketChannel.connect(_deepgramListenUri(), protocols: ['token', token]);
      _channel = channel;
      await channel.ready;
      _log('Deepgram WebSocket opened');
      _logLatency('deepgram-ws-opened');

      _wsSub = channel.stream.listen(_onWsMessage, onError: _onWsError, onDone: _onWsDone);

      _log('starting mic stream (pcm16, ${_sampleRateHz}hz, mono)...');
      final audioStream = await _recorder.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _sampleRateHz, numChannels: 1),
      );
      _audioSub = audioStream.listen(
        (chunk) => channel.sink.add(chunk),
        onError: (Object e, StackTrace stackTrace) {
          debugPrint('VOICE ERROR (Deepgram mic stream): $e\n$stackTrace');
          _finish(null);
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
      _log('silence window elapsed with no speech_final, finalizing: "$_pendingTranscript"');
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
