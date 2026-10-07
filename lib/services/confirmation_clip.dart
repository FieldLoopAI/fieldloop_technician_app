/// Change 3 (Module B latency) — cached audio for the app's FIXED spoken
/// confirmations, played locally instead of asking Gemini to say them.
///
/// MEASURED (acceptance logs, 5 Oct, SM-T837V): after a deterministic action
/// the scripted line's first audio byte came 700–970ms after the transcript
/// on almost every turn (Gemini generating a "say exactly …" turn), and
/// 2–3s when a stale free-text turn or a one-word TURN IDENTITY hold was in
/// the way. The wake greeting already solves the same problem with a saved
/// clip (`wake_greeting_clip.dart`, 188–334ms); this is that mechanism for
/// confirmations:
///  - the first time Gemini speaks a cacheable line all the way through,
///    exactly as scripted, its audio is saved (see [confirmationTranscriptMatches]);
///  - from then on that line plays from the clip, through the SAME playback
///    path as Gemini audio (mic pause, drain, interrupt, latency metrics);
///  - a line with no clip yet goes through Gemini exactly as before.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'wake_greeting_clip.dart';

/// The `_informGeminiToSpeakVerbatim` reasons whose lines are fixed
/// navigation/camera confirmations — the only lines ever cached. Anything
/// built from job data (job details, KB answers, timelines) is never cached.
const Set<String> cacheableConfirmationReasons = {
  'deterministic go_back',
  'deterministic view_invoice',
  'deterministic view_change_orders',
  'deterministic view_job_history',
  'deterministic view_estimate',
  'deterministic view_job_details',
  'deterministic open_camera',
  // Build 174 — the fixed "Okay." a blocked negated camera request gets.
  'negation_guard',
};

bool isCacheableConfirmation(String reason) => cacheableConfirmationReasons.contains(reason);

String _normalize(String text) =>
    text.toLowerCase().replaceAll(RegExp(r"[^a-z0-9' ]"), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Whether a finished turn's transcript is exactly the scripted line —
/// punctuation/case/spacing aside. Only such a turn is ever saved as a clip,
/// so a clip can never contain a free-text addition or a truncated line.
bool confirmationTranscriptMatches(String transcript, String script) {
  final heard = _normalize(transcript);
  return heard.isNotEmpty && heard == _normalize(script);
}

/// Whether [transcript] is the start of [script] but not all of it — the
/// server's transcript stopped early. Diagnostic only: such a turn is still
/// never saved (its audio can't be checked word for word).
bool confirmationTranscriptTruncated(String transcript, String script) {
  final heard = _normalize(transcript);
  final full = _normalize(script);
  return heard.isNotEmpty && heard != full && full.startsWith(heard);
}

/// Build 175 — Job Details confirmation ("go back to main/home screen").
///
/// MEASURED (b174, 7 Oct, 7 of 7 turns at 14:18:55, 14:31:17, 14:31:52,
/// 14:32:37, 14:33:29, 14:42:40): Gemini spoke the whole of
/// [jobDetailsNavigatedReplyOld] (64 audio tokens ≈ 2.6s) but its output
/// transcript was only ever "Okay —" (once "Okay — you're"), so
/// [confirmationTranscriptMatches] never passed and the clip was never
/// saved; the one-word transcript also kept TURN IDENTITY holding the audio
/// until turnComplete (first audio 3.0–3.5s). go_back's "Okay, I've taken
/// you back." — same opening word, a comma instead of the dash — was
/// transcribed in full and saved on its first clean turn (14:18:23).
const String jobDetailsNavigatedReplyOld = "Okay — you're on the job details screen.";
const String jobDetailsNavigatedReplyCacheable = "Okay, you're on the job details screen.";

/// The Job Details confirmation; [cacheableWording] = build 175's.
String jobDetailsNavigatedReply({required bool cacheableWording}) =>
    cacheableWording ? jobDetailsNavigatedReplyCacheable : jobDetailsNavigatedReplyOld;

/// Splits [pcm] (mono int16) into playback-sized chunks, each a whole number
/// of samples — the same ~100ms granularity Gemini's own chunks arrive in.
List<Uint8List> splitPcmForPlayback(Uint8List pcm, {int chunkBytes = 4800}) {
  final size = chunkBytes.isEven ? chunkBytes : chunkBytes + 1;
  return [
    for (var start = 0; start < pcm.length; start += size)
      Uint8List.sublistView(pcm, start, start + size > pcm.length ? pcm.length : start + size),
  ];
}

/// Saved confirmation clips: one WAV per line in the app-support directory,
/// ALL preloaded into memory at session start ([preload]) so a lookup at
/// reply time is synchronous and never waits on disk.
class ConfirmationClipStore {
  ConfirmationClipStore({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  static const String filePrefix = 'confirmation_clip_';
  static const Duration minClip = Duration(milliseconds: 600);
  static const Duration maxClip = Duration(seconds: 8);
  static const int _wavHeaderBytes = 44;

  final Map<String, Uint8List> _pcmByKey = {};

  int get count => _pcmByKey.length;

  Future<File> _file(String text) async {
    final dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}$filePrefix${clipFileKey(text)}.wav');
  }

  /// Loads every saved clip into memory. Safe to call more than once.
  Future<int> preload() async {
    try {
      final dir = await _directory();
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(filePrefix) || !name.endsWith('.wav')) continue;
        final key = name.substring(filePrefix.length, name.length - 4);
        if (_pcmByKey.containsKey(key)) continue;
        final bytes = await entity.readAsBytes();
        if (bytes.length <= _wavHeaderBytes) continue;
        _pcmByKey[key] = Uint8List.sublistView(bytes, _wavHeaderBytes);
      }
    } catch (e) {
      debugPrint('CONFIRMATION CLIP: could not preload saved clips ($e) — those lines go through Gemini');
    }
    return _pcmByKey.length;
  }

  /// The saved PCM for [text], or null — synchronous (see [preload]).
  Uint8List? pcmFor(String text) => _pcmByKey[clipFileKey(text)];

  /// Saves [pcm] (mono int16 at [kWakeGreetingSampleRateHz]) as the clip for
  /// [text]. Returns false — saving nothing — if the length is implausible.
  Future<bool> save(String text, Uint8List pcm) async {
    final duration = Duration(microseconds: (pcm.length ~/ 2) * 1000000 ~/ kWakeGreetingSampleRateHz);
    if (duration < minClip || duration > maxClip) {
      debugPrint('CONFIRMATION CLIP: not saving a ${duration.inMilliseconds}ms clip for "$text" (outside the plausible range)');
      return false;
    }
    try {
      final file = await _file(text);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(pcm16ToWav(pcm), flush: true);
      await tmp.rename(file.path);
      _pcmByKey[clipFileKey(text)] = Uint8List.fromList(pcm);
      debugPrint('CONFIRMATION CLIP: saved "$text" (${duration.inMilliseconds}ms) — played locally from now on');
      return true;
    } catch (e) {
      debugPrint('CONFIRMATION CLIP: could not save "$text" ($e) — it keeps going through Gemini');
      return false;
    }
  }
}

/// App-wide store: the session screen records into it and plays from it.
final ConfirmationClipStore confirmationClips = ConfirmationClipStore();
