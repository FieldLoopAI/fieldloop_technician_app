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

class JobFactClipCache {
  JobFactClipCache({this.maxEntries = 8, this.maxBytes = 3 * 1024 * 1024});

  final int maxEntries;
  final int maxBytes;

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
  bool put(String jobId, JobFactKind kind, String text, Uint8List pcm) {
    if (jobId != _jobId || !isCacheableJobFact(kind)) return false;
    final duration = Duration(microseconds: (pcm.length ~/ 2) * 1000000 ~/ kWakeGreetingSampleRateHz);
    if (duration < ConfirmationClipStore.minClip || duration > ConfirmationClipStore.maxClip) return false;
    if (pcm.length > maxBytes) return false;
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
    return true;
  }
}
