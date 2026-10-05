/// The wake-word greeting, played locally the instant "FieldLoop" is heard
/// instead of waiting on a live Gemini round trip.
///
/// Every spoken line in a session normally goes through Gemini's own voice
/// (`_informGeminiToSpeakVerbatim` in `gemini_live_test_screen.dart`), and the
/// greeting used to as well — which meant it could only start after the
/// token, the WebSocket handshake, `setupComplete` AND a model turn, often
/// several seconds after the wake word. Now:
///
///  - The first time Gemini speaks the greeting cleanly (whole line, not
///    interrupted, transcript matches), the screen saves the exact audio it
///    played ([WakeGreetingClipStore.save]) — same voice, same words.
///  - Every later wake word plays that saved clip at once
///    ([WakeGreetingPlayback.start]) on its own small player, while the
///    session keeps connecting in the background. The screen then skips
///    asking Gemini for the greeting.
///  - With no saved clip yet (first wake after install, or the greeting text
///    changed) nothing changes: Gemini speaks it at `setupComplete` exactly
///    as before, and that rendition becomes the clip.
///
/// [WakeGreetingMicGate] keeps the clip from ever talking over a command:
/// mic audio captured while it plays is held back (so Gemini never hears
/// the greeting as if the technician said it), and the moment the
/// technician is heard speaking the clip is stopped and their speech is
/// released to the normal command pipeline instead of being dropped.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';

/// The ONE opening line of a wake-word session.
const String kWakeGreetingText = "Hey, I'm here to help — what do you need?";

/// Gemini Live's output rate — the rate the saved clip is recorded at.
const int kWakeGreetingSampleRateHz = 24000;

/// `HH:mm:ss.SSS`, the same timestamp shape the session screen's own log
/// lines use.
String wakeGreetingTs(DateTime t) => t.toIso8601String().substring(11, 23);

/// Root-mean-square amplitude of little-endian int16 PCM.
double pcm16Rms(Uint8List chunk) {
  final sampleCount = chunk.length ~/ 2;
  if (sampleCount == 0) return 0;
  final samples = ByteData.sublistView(chunk);
  double sumSquares = 0;
  for (var i = 0; i < sampleCount; i++) {
    final sample = samples.getInt16(i * 2, Endian.little);
    sumSquares += sample * sample;
  }
  return math.sqrt(sumSquares / sampleCount);
}

/// Letters and digits only, lowercased, single-spaced — how a played turn's
/// transcript is compared against [kWakeGreetingText] before it is saved.
String normalizeGreetingText(String text) =>
    text.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]+"), ' ').trim();

/// Whether Gemini's transcript of a played turn is the greeting itself —
/// nothing missing, nothing added — so only a clean rendition is saved.
bool isCleanGreetingTranscript(String transcript, {String greeting = kWakeGreetingText}) {
  final heard = normalizeGreetingText(transcript);
  return heard.isNotEmpty && heard == normalizeGreetingText(greeting);
}

/// Wraps raw mono int16 PCM in a 44-byte WAV header.
Uint8List pcm16ToWav(Uint8List pcm, {int sampleRate = kWakeGreetingSampleRateHz}) {
  final header = ByteData(44);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, 1, Endian.little); // mono
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(pcm))
      .takeBytes();
}

/// Stable across runs (unlike `String.hashCode`) — names the cache file
/// after the greeting text, so changing [kWakeGreetingText] simply misses
/// the old clip and records a new one.
String _fnv1a32Hex(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// The saved greeting clip: one WAV file in the app-support directory,
/// mirrored in memory after first use so a wake word never waits on disk.
class WakeGreetingClipStore {
  WakeGreetingClipStore({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  /// Shortest/longest audio accepted as a real rendition of the greeting.
  static const Duration minClip = Duration(milliseconds: 800);
  static const Duration maxClip = Duration(seconds: 8);

  final Map<String, Uint8List> _memory = {};

  Future<File> _file(String text) async {
    final dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}wake_greeting_${_fnv1a32Hex(text)}.wav');
  }

  /// The saved clip for [text] as WAV bytes, or null if none is saved.
  Future<Uint8List?> load(String text) async {
    final cached = _memory[text];
    if (cached != null) return cached;
    try {
      final file = await _file(text);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length <= 44) return null;
      _memory[text] = bytes;
      return bytes;
    } catch (e) {
      debugPrint('WAKE GREETING: could not read the saved clip ($e) — Gemini will speak the greeting instead');
      return null;
    }
  }

  /// Saves [pcm] (mono int16 at [kWakeGreetingSampleRateHz]) as the clip for
  /// [text]. Returns false — saving nothing — if the length is implausible.
  Future<bool> save(String text, Uint8List pcm) async {
    final duration = Duration(microseconds: (pcm.length ~/ 2) * 1000000 ~/ kWakeGreetingSampleRateHz);
    if (duration < minClip || duration > maxClip) {
      debugPrint('WAKE GREETING: not saving a ${duration.inMilliseconds}ms clip (outside the plausible range)');
      return false;
    }
    final wav = pcm16ToWav(pcm);
    try {
      final file = await _file(text);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(wav, flush: true);
      await tmp.rename(file.path);
      _memory[text] = wav;
      debugPrint('WAKE GREETING: saved Gemini\'s greeting as the local clip (${duration.inMilliseconds}ms) — '
          'played instantly on the next wake word');
      return true;
    } catch (e) {
      debugPrint('WAKE GREETING: could not save the clip ($e) — next wake word uses Gemini\'s greeting again');
      return false;
    }
  }
}

/// App-wide store: the voice service plays from it, the session screen
/// records into it.
final WakeGreetingClipStore wakeGreetingClips = WakeGreetingClipStore();

enum WakeGreetingOutcome {
  /// Played to the end.
  played,

  /// Stopped part-way (or before it started) because the technician was
  /// speaking.
  interrupted,

  /// Stopped because the session went away (job left, wake word aborted).
  cancelled,

  /// No saved clip yet — the screen falls back to Gemini's greeting.
  unavailable,

  /// The player failed — the screen falls back to Gemini's greeting.
  failed,
}

/// One wake word's greeting clip, from the moment it was requested.
class WakeGreetingPlayback {
  WakeGreetingPlayback._(this.detectedAt);

  /// When the wake word was recognized.
  final DateTime detectedAt;

  /// When the player confirmed the clip started; null until then (and
  /// forever, if it never started).
  DateTime? startedAt;

  /// When it stopped, for any reason.
  DateTime? endedAt;

  WakeGreetingOutcome? _outcome;
  final Completer<WakeGreetingOutcome> _done = Completer<WakeGreetingOutcome>();
  FlutterSoundPlayer? _player;

  /// Null while the clip is still loading or playing.
  WakeGreetingOutcome? get outcome => _outcome;

  /// Loading or playing — mic audio must still be held back.
  bool get isActive => _outcome == null;

  /// Whether the clip took (or is taking) the greeting's place, so Gemini
  /// must not be asked to speak it.
  bool get replacesGeminiGreeting =>
      _outcome != WakeGreetingOutcome.unavailable && _outcome != WakeGreetingOutcome.failed;

  Future<WakeGreetingOutcome> get done => _done.future;

  /// The clip's own loudness, one RMS value per [_envelopeFrame] — what the
  /// mic gate needs to know WHEN the clip could be leaking back into the
  /// mic (see [clipAudibleAt]). Null until the clip is loaded.
  List<double>? _envelope;

  static const Duration _envelopeFrame = Duration(milliseconds: 20);

  /// Clip frames quieter than this are pauses (between words, around the
  /// dash) — no echo can come out of them.
  static const double clipQuietRms = 400;

  /// When the speaker's output can reach the mic relative to when it was
  /// played: output latency plus room reverb. A mic chunk arriving at `t` can
  /// carry echo of anything the clip played in `[t - echoReach, t - echoDelayMin]`.
  static const Duration echoReach = Duration(milliseconds: 400);
  static const Duration echoDelayMin = Duration(milliseconds: 40);

  /// Whether mic audio captured at [at] could contain the clip's own echo —
  /// i.e. the clip had sound (not a pause) in the window that could still be
  /// reaching the mic. ec736a7a log: the clip's echo, 154ms after it started,
  /// was loud enough (peakRms 15925) and long enough to pass the old
  /// level-and-duration test as "the technician talking"; only loudness the
  /// clip CAN'T have produced now counts as speech. Unknown envelope -> true
  /// (assume echo; never barge in on a guess).
  bool clipAudibleAt(DateTime at) {
    final started = startedAt;
    if (started == null) return false;
    final envelope = _envelope;
    if (envelope == null) return true;
    final ended = endedAt;
    final frameMs = _envelopeFrame.inMilliseconds;
    final fromMs = at.difference(started).inMilliseconds - echoReach.inMilliseconds;
    final toMs = at.difference(started).inMilliseconds - echoDelayMin.inMilliseconds;
    for (var ms = fromMs; ms <= toMs; ms += frameMs) {
      if (ms < 0) continue;
      if (ended != null && !started.add(Duration(milliseconds: ms)).isBefore(ended)) break;
      final i = ms ~/ frameMs;
      if (i >= envelope.length) break;
      if (envelope[i] >= clipQuietRms) return true;
    }
    return false;
  }

  @visibleForTesting
  static WakeGreetingPlayback forTesting({required DateTime startedAt, required List<double> envelope}) =>
      WakeGreetingPlayback._(startedAt)
        ..startedAt = startedAt
        .._envelope = envelope;

  static List<double> _envelopeOf(Uint8List wav) {
    final frameBytes = kWakeGreetingSampleRateHz * 2 * _envelopeFrame.inMilliseconds ~/ 1000;
    final pcm = Uint8List.sublistView(wav, 44);
    return [
      for (var offset = 0; offset + 2 <= pcm.length; offset += frameBytes)
        pcm16Rms(Uint8List.sublistView(pcm, offset, (offset + frameBytes).clamp(0, pcm.length))),
    ];
  }

  /// Starts playing the saved clip for [text] right away. Never throws:
  /// every failure resolves [done] to `unavailable`/`failed`.
  static WakeGreetingPlayback start({
    required DateTime detectedAt,
    String text = kWakeGreetingText,
    WakeGreetingClipStore? store,
  }) {
    final playback = WakeGreetingPlayback._(detectedAt);
    unawaited(playback._run(store ?? wakeGreetingClips, text));
    return playback;
  }

  Future<void> _run(WakeGreetingClipStore store, String text) async {
    final wav = await store.load(text);
    if (!isActive) return;
    if (wav == null) {
      debugPrint('WAKE GREETING: no saved clip yet — Gemini will speak the greeting once the session is ready '
          '(and that rendition is saved for next time)');
      _finish(WakeGreetingOutcome.unavailable);
      return;
    }
    _envelope = _envelopeOf(wav);
    final player = FlutterSoundPlayer();
    _player = player;
    // Safety nets so a stuck native player can never leave the session's
    // mic held back: not started in time -> Gemini greets instead; started
    // but no "finished" callback well past the clip's length -> treat it
    // as played.
    final startTimeout = Timer(startDeadline, () {
      if (isActive && startedAt == null) {
        debugPrint('WAKE GREETING: clip did not start within ${startDeadline.inMilliseconds}ms — '
            'Gemini will speak the greeting instead');
        _finish(WakeGreetingOutcome.failed);
      }
    });
    try {
      await player.openPlayer();
      if (!isActive) return;
      await player.startPlayer(
        fromDataBuffer: wav,
        codec: Codec.pcm16WAV,
        sampleRate: kWakeGreetingSampleRateHz,
        numChannels: 1,
        whenFinished: () => _finish(WakeGreetingOutcome.played),
      );
      startTimeout.cancel();
      if (!isActive) return;
      final clipLength = Duration(microseconds: ((wav.length - 44) ~/ 2) * 1000000 ~/ kWakeGreetingSampleRateHz);
      Timer(clipLength + const Duration(seconds: 2), () {
        if (isActive) {
          debugPrint('WAKE GREETING: no finished callback from the player — treating the clip as played');
          _finish(WakeGreetingOutcome.played);
        }
      });
      final spokenAt = DateTime.now();
      startedAt = spokenAt;
      debugPrint(
        'WAKE GREETING: detectedAt=${wakeGreetingTs(detectedAt)} spokenAt=${wakeGreetingTs(spokenAt)} '
        'elapsedMs=${spokenAt.difference(detectedAt).inMilliseconds} source=cached_clip',
      );
    } catch (e) {
      startTimeout.cancel();
      debugPrint('WAKE GREETING: local clip playback failed ($e) — Gemini will speak the greeting instead');
      _finish(WakeGreetingOutcome.failed);
    }
  }

  /// Longest the player may take to start before the clip is given up on
  /// — well inside the 2s target, so a slow start still beats the old path.
  static const Duration startDeadline = Duration(milliseconds: 1500);

  /// Stops the clip now (a no-op once it has finished).
  void stop(WakeGreetingOutcome outcome, String reason) {
    if (!isActive) return;
    debugPrint('WAKE GREETING: stopped (${outcome.name}: $reason)'
        '${startedAt == null ? ' before it started playing' : ' after ${DateTime.now().difference(startedAt!).inMilliseconds}ms'}');
    _finish(outcome);
  }

  void _finish(WakeGreetingOutcome outcome) {
    if (_outcome != null) return;
    _outcome = outcome;
    endedAt = DateTime.now();
    if (outcome == WakeGreetingOutcome.played) {
      final started = startedAt;
      debugPrint('WAKE GREETING: finished playing'
          '${started == null ? '' : ' (${endedAt!.difference(started).inMilliseconds}ms)'}');
    }
    final player = _player;
    _player = null;
    if (player != null) {
      unawaited(() async {
        try {
          if (!player.isStopped) await player.stopPlayer();
          await player.closePlayer();
        } catch (e) {
          debugPrint('WAKE GREETING: player cleanup error ($e)');
        }
      }());
    }
    _done.complete(outcome);
  }
}

/// What the screen does with one mic chunk while a greeting clip is in play.
enum WakeGreetingMicAction {
  /// Held back — the clip is (or may soon be) audible.
  hold,

  /// The technician is speaking: stop the clip, then send
  /// [WakeGreetingMicGate.takeReleased] on, in order.
  bargeIn,

  /// A loud run just ended WITHOUT qualifying as speech — see
  /// [WakeGreetingMicGate.lastRejectedRun]. Still held; logged by the
  /// screen as `BARGE-IN REQUIRES SUSTAINED SPEECH`.
  rejectedLoudRun,
}

/// Sits in front of the session's mic stream for as long as the wake
/// greeting clip is loading, playing, or its echo is dying away. Pure (no
/// plugins, no clock of its own) so its decisions are unit-tested.
///
/// ec736a7a log: the first version took any run above [bargeInRms] lasting
/// 240ms as the technician — and the clip's OWN echo, 154ms after it
/// started (peakRms 15925: both players are plain media-stream audio, which
/// the voice-communication mic's echo cancellation doesn't reliably remove),
/// passed exactly that test, stopping the greeting 390ms in. Now a run must
/// be BOTH:
///  - sustained: [bargeInSustain] of loud audio (a single spike — a click,
///    a camera transient — never is), and
///  - speech the clip can't have made: at least [speechEvidence] of that
///    loudness captured while the clip had nothing audible in its echo
///    window (`clipAudible == false` — a pause in the clip, before it
///    started, or after it ended; see [WakeGreetingPlayback.clipAudibleAt]).
/// Someone talking over the greeting is still loud through its pauses and
/// past its end; an echo goes quiet with the clip.
class WakeGreetingMicGate {
  WakeGreetingMicGate({
    this.bargeInRms = 1500,
    this.bargeInSustain = const Duration(milliseconds: 300),
    this.speechEvidence = const Duration(milliseconds: 120),
    this.maxQuietGap = const Duration(milliseconds: 120),
    this.preRoll = const Duration(milliseconds: 300),
    this.echoTail = const Duration(milliseconds: 300),
  });

  /// 3x the session's own "someone is speaking" level (500).
  final double bargeInRms;
  final Duration bargeInSustain;

  /// How much of a run's loudness must fall outside the clip's echo window.
  final Duration speechEvidence;

  /// Quiet this short inside a run doesn't end it (gaps between syllables).
  final Duration maxQuietGap;

  /// Audio kept from just before the detected onset, so the first syllable
  /// isn't clipped.
  final Duration preRoll;

  /// After the clip ends, its echo can still reach the mic this long.
  final Duration echoTail;

  final List<({Uint8List bytes, DateTime at})> _held = [];
  final List<Uint8List> _released = [];

  DateTime? _runStartedAt;
  DateTime? _lastLoudAt;
  Duration _runLoud = Duration.zero;
  Duration _runOutsideEcho = Duration.zero;
  double _runPeak = 0;

  /// When the technician's speech began, once barge-in is confirmed.
  DateTime? bargeInOnset;

  /// The most recent loud run that ended without qualifying as speech.
  ({DateTime startedAt, Duration loud, Duration outsideEcho, double peakRms})? lastRejectedRun;

  double peakRms = 0;
  double _rmsSum = 0;
  int _rmsCount = 0;

  double get averageRms => _rmsCount == 0 ? 0 : _rmsSum / _rmsCount;
  int get heldChunks => _held.length;

  /// A loud run is still open (not yet confirmed or rejected) — the screen
  /// keeps evaluating past the clip's end until it resolves.
  bool get runInProgress => _runStartedAt != null && bargeInOnset == null;

  /// Feeds one chunk captured at [at], lasting [chunkDuration]. Every chunk
  /// is held; the return says whether this one confirmed barge-in or ended
  /// a loud run that didn't qualify. [clipAudible]: whether the clip's own
  /// echo could be in this chunk (see [WakeGreetingPlayback.clipAudibleAt]).
  WakeGreetingMicAction add(Uint8List bytes, DateTime at, Duration chunkDuration, {bool clipAudible = false}) {
    _held.add((bytes: bytes, at: at));
    final rms = pcm16Rms(bytes);
    if (rms > peakRms) peakRms = rms;
    _rmsSum += rms;
    _rmsCount++;
    if (bargeInOnset != null) return WakeGreetingMicAction.bargeIn;

    if (rms > bargeInRms) {
      final lastLoud = _lastLoudAt;
      if (_runStartedAt == null || lastLoud == null || at.difference(lastLoud) > maxQuietGap + chunkDuration) {
        _runStartedAt = at;
        _runLoud = Duration.zero;
        _runOutsideEcho = Duration.zero;
        _runPeak = 0;
      }
      _runLoud += chunkDuration;
      if (!clipAudible) _runOutsideEcho += chunkDuration;
      if (rms > _runPeak) _runPeak = rms;
      _lastLoudAt = at;
      if (_runLoud >= bargeInSustain && _runOutsideEcho >= speechEvidence) {
        bargeInOnset = _runStartedAt;
        return WakeGreetingMicAction.bargeIn;
      }
    } else {
      final lastLoud = _lastLoudAt;
      final runStart = _runStartedAt;
      if (runStart != null && lastLoud != null && at.difference(lastLoud) > maxQuietGap) {
        lastRejectedRun = (startedAt: runStart, loud: _runLoud, outsideEcho: _runOutsideEcho, peakRms: _runPeak);
        _runStartedAt = null;
        _runLoud = Duration.zero;
        _runOutsideEcho = Duration.zero;
        _runPeak = 0;
        return WakeGreetingMicAction.rejectedLoudRun;
      }
    }
    return WakeGreetingMicAction.hold;
  }

  /// The clip played out (or was stopped for an unrelated reason) and
  /// [endedAt] + [echoTail] has passed: audio captured before the clip
  /// became audible is the technician's and goes on; everything captured
  /// while it played is its echo and is dropped.
  void resolvePlayed({required DateTime? startedAt}) {
    for (final chunk in _held) {
      if (startedAt == null || chunk.at.isBefore(startedAt)) _released.add(chunk.bytes);
    }
    _held.clear();
  }

  /// Barge-in: keep everything captured before the clip was audible, plus
  /// everything from [preRoll] before the speech onset on.
  void resolveBargeIn({required DateTime? startedAt}) {
    final from = (bargeInOnset ?? DateTime.now()).subtract(preRoll);
    for (final chunk in _held) {
      final beforeClip = startedAt == null || chunk.at.isBefore(startedAt);
      if (beforeClip || !chunk.at.isBefore(from)) _released.add(chunk.bytes);
    }
    _held.clear();
  }

  /// The clip never played (no saved clip, or the player failed): every
  /// held chunk is the technician's.
  void resolveUnused() {
    for (final chunk in _held) {
      _released.add(chunk.bytes);
    }
    _held.clear();
  }

  /// Chunks to forward, oldest first. Empties the list.
  List<Uint8List> takeReleased() {
    final out = List<Uint8List>.of(_released);
    _released.clear();
    return out;
  }

  /// Whether audio at [at] could still be the clip's echo.
  bool withinEchoTail({required DateTime endedAt, required DateTime at}) => at.isBefore(endedAt.add(echoTail));
}
