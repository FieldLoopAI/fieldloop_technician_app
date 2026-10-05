import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';

/// A minted Gemini Live ephemeral token and the last moment it can still
/// START a new session. Single-use (`uses: 1`, see
/// `backend/functions/get-gemini-token`). The value itself is never logged.
class GeminiToken {
  const GeminiToken(this.value, this.usableUntil);

  final String value;
  final DateTime usableUntil;
}

/// Assumed start window when the endpoint doesn't report one (a backend
/// deployed before `newSessionExpiresInSeconds` existed): Google's default
/// is 1 minute, so stay under it.
const Duration _fallbackStartWindow = Duration(seconds: 50);

/// `POST $apiBaseUrl/voice/gemini-token`, authenticated with the signed-in
/// technician's Supabase session exactly as before — only WHEN this is
/// called changed (see [GeminiTokenCache]), not how.
Future<GeminiToken> fetchGeminiToken() async {
  final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
  if (accessToken == null) {
    throw StateError('No Supabase session — log in before running this test.');
  }
  // Measured from before the request, so network time only ever makes the
  // local estimate more conservative than the server's real window.
  final requestedAt = DateTime.now();
  final response = await http.post(
    Uri.parse('$apiBaseUrl/voice/gemini-token'),
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (response.statusCode != 200) {
    throw StateError('gemini-token request failed (${response.statusCode}): ${response.body}');
  }
  final decoded = jsonDecode(response.body) as Map<String, dynamic>;
  final token = decoded['token'] as String?;
  if (token == null || token.isEmpty) {
    throw StateError('gemini-token response missing "token"');
  }
  final seconds = decoded['newSessionExpiresInSeconds'] as num?;
  final window = seconds != null ? Duration(seconds: seconds.toInt()) : _fallbackStartWindow;
  return GeminiToken(token, requestedAt.add(window));
}

/// Holds at most ONE unused Gemini token in memory so a wake word doesn't
/// have to wait on a cold `/voice/gemini-token` round trip.
///
/// - [activate] (a job is open and voice can hear the wake word) fetches a
///   spare in the background; [deactivate] (job closed, muted, logout, app
///   backgrounded) drops it and stops refreshing. Nothing is fetched while
///   inactive, and nothing is ever written to disk.
/// - A spare counts as usable only while it has at least [minRemaining] of
///   its start window left. [refreshLead] before that window closes it is
///   replaced in the background, so an idle job screen always holds a
///   usable one.
/// - [take] hands a token to a session that is starting now: the spare if
///   usable, else the fetch already in flight, else a fresh fetch — the
///   last two are exactly today's behavior, so a missing/stale cache only
///   ever degrades to the old latency, never fails differently. Tokens are
///   single-use, so a taken token is never handed out again.
/// - Overlapping requests share one in-flight fetch.
class GeminiTokenCache {
  GeminiTokenCache({
    Future<GeminiToken> Function()? fetch,
    DateTime Function()? now,
    this.minRemaining = const Duration(seconds: 20),
    this.refreshLead = const Duration(seconds: 60),
  }) : _fetch = fetch ?? fetchGeminiToken,
       _now = now ?? DateTime.now;

  final Future<GeminiToken> Function() _fetch;
  final DateTime Function() _now;
  final Duration minRemaining;
  final Duration refreshLead;

  /// Refreshes closer together than this are skipped: a token with a start
  /// window this short (the pre-`newSessionExpiresInSeconds` fallback) is
  /// prefetched once and not kept alive with a timer.
  static const Duration _minRefreshDelay = Duration(seconds: 30);

  bool _active = false;
  GeminiToken? _spare;
  Future<GeminiToken>? _inFlight;

  /// True once a [take] is waiting on [_inFlight] — its result then goes to
  /// that session instead of becoming the spare.
  bool _inFlightClaimed = false;

  /// Bumped by [clear]; a fetch that completes for an older generation is
  /// discarded instead of repopulating a cache that was just cleared.
  int _generation = 0;
  Timer? _refreshTimer;

  bool get isActive => _active;

  @visibleForTesting
  bool get hasUsableSpare => _isUsable(_spare);

  @visibleForTesting
  bool get hasFetchInFlight => _inFlight != null;

  void activate() {
    _active = true;
    prefetch();
  }

  void deactivate() {
    _active = false;
    clear();
  }

  /// Drops the spare and any pending refresh from memory.
  void clear() {
    _generation++;
    _spare = null;
    _inFlight = null;
    _inFlightClaimed = false;
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  /// Fetches a spare in the background unless inactive, one is already
  /// usable, or a fetch is already in flight. Failures are logged and left
  /// for [take] to retry on demand.
  void prefetch() {
    if (!_active || _isUsable(_spare) || _inFlight != null) return;
    _startFetch();
  }

  /// [wakeAt] (the wake word that started this session, if any) is only
  /// logged: one `GEMINI TOKEN: wakeAt=… takenAt=… gapMs=… source=…` line
  /// per take, plus a `readyAt` line when the token had to be waited for.
  Future<String> take({DateTime? wakeAt}) async {
    final takenAt = _now();
    final spare = _spare;
    _spare = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (_isUsable(spare)) {
      debugPrint('GEMINI TOKEN: using pre-fetched token (${_secondsLeft(spare!)}s of start window left)');
      _logTake(wakeAt, takenAt, 'spare');
      return spare.value;
    }
    final inFlight = _inFlight;
    if (inFlight != null && !_inFlightClaimed) {
      debugPrint('GEMINI TOKEN: no usable spare — joining the fetch already in flight');
      _inFlightClaimed = true;
      _logTake(wakeAt, takenAt, 'inflight');
      final token = await inFlight;
      _logReady(wakeAt, 'inflight');
      return token.value;
    }
    debugPrint('GEMINI TOKEN: no usable spare — fetching on demand');
    _logTake(wakeAt, takenAt, 'fetch');
    final token = await _fetch();
    _logReady(wakeAt, 'fetch');
    return token.value;
  }

  static String _ts(DateTime t) => t.toIso8601String().substring(11, 23);

  void _logTake(DateTime? wakeAt, DateTime takenAt, String source) {
    debugPrint(
      'GEMINI TOKEN: wakeAt=${wakeAt == null ? 'n/a' : _ts(wakeAt)} takenAt=${_ts(takenAt)} '
      'gapMs=${wakeAt == null ? 'n/a' : takenAt.difference(wakeAt).inMilliseconds} source=$source',
    );
  }

  void _logReady(DateTime? wakeAt, String source) {
    final readyAt = _now();
    debugPrint(
      'GEMINI TOKEN: source=$source readyAt=${_ts(readyAt)} '
      'wakeToReadyMs=${wakeAt == null ? 'n/a' : readyAt.difference(wakeAt).inMilliseconds}',
    );
  }

  void _startFetch() {
    final generation = _generation;
    final future = _fetch();
    _inFlight = future;
    _inFlightClaimed = false;
    future.then(
      (token) {
        if (generation != _generation || !identical(_inFlight, future)) return;
        _inFlight = null;
        if (_inFlightClaimed) {
          _inFlightClaimed = false;
          return;
        }
        if (!_active) return;
        _spare = token;
        debugPrint('GEMINI TOKEN: spare acquired, start window ${_secondsLeft(token)}s');
        _scheduleRefresh(token);
      },
      onError: (Object e) {
        if (generation != _generation || !identical(_inFlight, future)) return;
        _inFlight = null;
        // A claimed fetch's error reaches its take() caller through its own
        // await; only unclaimed background failures are reported here.
        if (_inFlightClaimed) {
          _inFlightClaimed = false;
          return;
        }
        debugPrint('GEMINI TOKEN: background prefetch failed — will fetch on demand at wake word ($e)');
      },
    );
  }

  void _scheduleRefresh(GeminiToken token) {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    final delay = token.usableUntil.subtract(refreshLead).difference(_now());
    if (delay < _minRefreshDelay) return;
    _refreshTimer = Timer(delay, () {
      _refreshTimer = null;
      // The current spare stays in place (still usable for refreshLead)
      // until its replacement arrives.
      if (_active && _inFlight == null) _startFetch();
    });
  }

  bool _isUsable(GeminiToken? token) => token != null && token.usableUntil.difference(_now()) >= minRemaining;

  int _secondsLeft(GeminiToken token) => token.usableUntil.difference(_now()).inSeconds;
}
