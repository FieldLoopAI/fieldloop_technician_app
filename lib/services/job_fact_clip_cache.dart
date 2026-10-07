/// Build 174 (C14–C16) — per-job audio for job-fact answers.
///
/// The answer text is already computed locally in ~12ms (`job_facts.dart`);
/// what was slow (1.3–2.3s) is Gemini speaking it. This reuses the
/// confirmation-clip mechanism (`confirmation_clip.dart`): the first time
/// Gemini speaks a job-fact line cleanly for this job, its audio is kept,
/// and a repeat of the same question plays it at once.
///
/// There is no TTS in that mechanism — a clip only exists after Gemini has
/// spoken the line once — so the FIRST ask of each fact per job still goes
/// through Gemini.
///
/// Safety:
///  - memory only, bounded ([maxEntries], [maxBytes], least recently used
///    out first), never written to disk;
///  - bound to one job: [bindJob] with a different job, or [clear] at
///    session end, drops everything;
///  - keyed by the exact answer text, so a changed value (a new estimate
///    total) simply misses — a clip can never speak a stale value;
///  - time on site changes every minute and is never cached.
///
/// Build 175: the per-clip length bound is sized from the answer text
/// ([maxClipForText]/[minClipForText]). Build 174's fixed 8s cap (shared
/// with confirmation clips) refused every address: "401, SETU SQUARE, …
/// Gujarat 382424." was 277–282 audio tokens ≈ 11.1–11.3s ≈ 532–541KB
/// (tablet log 7 Oct 14:50:48 / 14:51:14), so a repeat never hit.
library;

import 'dart:collection';
import 'dart:typed_data';

import 'confirmation_clip.dart';
import 'job_facts.dart';
import 'wake_greeting_clip.dart';

/// Whether [kind]'s answer is fixed for the visit (cacheable).
bool isCacheableJobFact(JobFactKind kind) => kind != JobFactKind.timeOnSite;

/// The [JobFactKind] a `_informGeminiToSpeakVerbatim` reason names
/// (`job_fact address`), or null for any other reason.
JobFactKind? jobFactKindForReason(String reason) {
  if (!reason.startsWith('job_fact ')) return null;
  final name = reason.substring('job_fact '.length);
  for (final kind in JobFactKind.values) {
    if (kind.name == name) return kind;
  }
  return null;
}

/// Words the answer will be spoken as, counting each digit on its own
/// ("382424" is read digit by digit) — the unit [maxClipForText] and
/// [minClipForText] scale with.
int spokenUnitsForText(String text) {
  var units = 0;
  for (final token in text.split(RegExp(r'[^A-Za-z0-9]+'))) {
    if (token.isEmpty) continue;
    final digits = token.replaceAll(RegExp(r'[^0-9]'), '').length;
    units += digits + (token.length > digits ? 1 : 0);
  }
  return units;
}

/// Longest plausible clip for [text]: 2s + 1s per spoken unit, never below
/// the confirmation-clip cap (8s) and never above 30s. The 7 Oct address
/// (21 units, spoken in ~11.3s) gets 23s — about twice what it took.
Duration maxClipForText(String text) {
  final ms = 2000 + 1000 * spokenUnitsForText(text);
  final floor = ConfirmationClipStore.maxClip.inMilliseconds;
  return Duration(milliseconds: ms.clamp(floor, 30000));
}

/// Shortest plausible clip for [text]: 150ms per spoken unit (twice the
/// pace of fast speech), never below the confirmation-clip floor (600ms).
/// A recording well short of this lost audio somewhere and is refused even
/// though its transcript matched.
Duration minClipForText(String text) {
  final ms = 150 * spokenUnitsForText(text);
  final floor = ConfirmationClipStore.minClip.inMilliseconds;
  return Duration(milliseconds: ms < floor ? floor : ms);
}

/// PCM length (mono int16 at 24kHz) as a duration.
Duration jobFactClipDuration(Uint8List pcm) =>
    Duration(microseconds: (pcm.length ~/ 2) * 1000000 ~/ kWakeGreetingSampleRateHz);

class JobFactClipCache {
  JobFactClipCache({this.maxEntries = 8, this.maxBytes = 3 * 1024 * 1024, this.sizeLimitFromText = true});

  final int maxEntries;
  final int maxBytes;

  /// true (build 175) = the per-clip length bound comes from the answer
  /// text ([maxClipForText]/[minClipForText]); false = build 174's fixed
  /// confirmation-clip bounds (600ms–8s).
  final bool sizeLimitFromText;

  String? _jobId;
  final LinkedHashMap<String, Uint8List> _pcmByKey = LinkedHashMap();
  int _bytes = 0;

  String? get jobId => _jobId;
  int get count => _pcmByKey.length;
  int get bytes => _bytes;

  static String _key(JobFactKind kind, String text) => '${kind.name}|${text.trim()}';

  /// Scopes the cache to [jobId]; a different job clears it first.
  void bindJob(String? jobId) {
    if (jobId == _jobId) return;
    clear();
    _jobId = jobId;
  }

  void clear() {
    _pcmByKey.clear();
    _bytes = 0;
  }

  /// The clip for exactly [text] as [kind]'s answer for [jobId], or null.
  Uint8List? pcmFor(String jobId, JobFactKind kind, String text) {
    if (jobId != _jobId || !isCacheableJobFact(kind)) return null;
    final key = _key(kind, text);
    final pcm = _pcmByKey.remove(key);
    if (pcm == null) return null;
    _pcmByKey[key] = pcm; // most recently used
    return pcm;
  }

  /// Keeps [pcm] (mono int16 at 24kHz) as [kind]'s answer [text] for
  /// [jobId]. False — nothing kept — for another job, an uncacheable kind,
  /// or an implausible length (same bounds as confirmation clips).
  bool put(String jobId, JobFactKind kind, String text, Uint8List pcm) => store(jobId, kind, text, pcm) == null;

  /// The per-clip length bounds [put] applies to [text].
  ({Duration min, Duration max}) boundsFor(String text) => sizeLimitFromText
      ? (min: minClipForText(text), max: maxClipForText(text))
      : (min: ConfirmationClipStore.minClip, max: ConfirmationClipStore.maxClip);

  /// [put], but says why nothing was kept: null = stored, otherwise the
  /// exact check that refused it (for the `JOB FACT CACHED not stored` line).
  String? store(String jobId, JobFactKind kind, String text, Uint8List pcm) {
    if (jobId != _jobId) return 'other job (cache bound to ${_jobId ?? 'none'})';
    if (!isCacheableJobFact(kind)) return 'kind ${kind.name} is never cached';
    final duration = jobFactClipDuration(pcm);
    final bounds = boundsFor(text);
    if (duration < bounds.min) {
      return 'too short: ${duration.inMilliseconds}ms < min ${bounds.min.inMilliseconds}ms for this text';
    }
    if (duration > bounds.max) {
      return 'too long: ${duration.inMilliseconds}ms > max ${bounds.max.inMilliseconds}ms for this text';
    }
    if (pcm.length > maxBytes) return 'over the byte cap: ${pcm.length} > $maxBytes bytes';
    final key = _key(kind, text);
    final old = _pcmByKey.remove(key);
    if (old != null) _bytes -= old.length;
    // One answer per kind: a new value replaces the old one for that kind.
    final sameKind = [for (final k in _pcmByKey.keys) if (k.startsWith('${kind.name}|')) k];
    for (final k in sameKind) {
      _bytes -= _pcmByKey.remove(k)!.length;
    }
    _pcmByKey[key] = Uint8List.fromList(pcm);
    _bytes += pcm.length;
    while (_pcmByKey.length > maxEntries || _bytes > maxBytes) {
      final oldest = _pcmByKey.keys.first;
      _bytes -= _pcmByKey.remove(oldest)!.length;
    }
    return null;
  }
}
