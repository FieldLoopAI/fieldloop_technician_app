import 'dart:io';
import 'dart:typed_data';

import 'package:fielloop/models/job_estimate.dart';
import 'package:fielloop/services/job_fact_clip_cache.dart';
import 'package:fielloop/services/job_facts.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 177 Step 3 — job-fact clips kept across wake sessions for the same
/// job. Each "session" below does what the screen does: `bindJob(jobId)` at
/// open, a look-up by the answer text computed from the job data at ask time,
/// and (flag on) NO clear at session end.

/// Mono int16 PCM at 24kHz of [ms] length.
Uint8List _pcm(int ms) => Uint8List(24 * ms * 2);

JobEstimate _estimate(double total) => JobEstimate(
  id: 'e1',
  jobId: 'job-A',
  sourceDictationId: null,
  lineItems: [EstimateLineItem(description: 'Replace water heater', amount: total)],
  totalAmount: total,
  status: 'draft',
);

void main() {
  const jobA = 'job-A';
  const jobB = 'job-B';
  final address = addressReply('401, SETU SQUARE, SONA CROSS ROAD, New CG Rd, Nigam Nagar, Ahmedabad, Gujarat 382424');
  final name = customerNameReply('hariom');

  late JobFactClipCache appLifetime;
  setUp(() => appLifetime = JobFactClipCache());

  /// One wake session on [jobId]: open, ask, close (no clear).
  Uint8List? session(String jobId, JobFactKind kind, String answerNow) {
    appLifetime.bindJob(jobId);
    return appLifetime.pcmFor(jobId, kind, answerNow);
  }

  test('same job, next session: the address and customer name clips hit', () {
    appLifetime.bindJob(jobA);
    expect(appLifetime.store(jobA, JobFactKind.address, address, _pcm(10400)), isNull);
    expect(appLifetime.store(jobA, JobFactKind.customerName, name, _pcm(900)), isNull);
    // session end: nothing cleared (flag on)
    expect(session(jobA, JobFactKind.address, address), isNotNull);
    expect(session(jobA, JobFactKind.customerName, name), isNotNull);
  });

  test('changed data never replays the old audio (exact answer text key)', () {
    appLifetime.bindJob(jobA);
    appLifetime.store(jobA, JobFactKind.customerName, name, _pcm(900));
    appLifetime.store(
      jobA,
      JobFactKind.estimateSummary,
      estimateSummaryReply(loaded: true, estimate: _estimate(1400)),
      _pcm(4000),
    );
    // Between sessions the customer was renamed and the estimate re-priced.
    expect(session(jobA, JobFactKind.customerName, customerNameReply('Hariom Patel')), isNull);
    expect(
      session(jobA, JobFactKind.estimateSummary, estimateSummaryReply(loaded: true, estimate: _estimate(1550))),
      isNull,
    );
    // A "not loaded" line is its own text — it never plays the real total.
    expect(session(jobA, JobFactKind.estimateSummary, estimateNotLoadedReply), isNull);
  });

  test('a new value for a kind replaces the old clip (the old one can never come back)', () {
    appLifetime.bindJob(jobA);
    appLifetime.store(jobA, JobFactKind.customerName, name, _pcm(900));
    final renamed = customerNameReply('Hariom Patel');
    appLifetime.store(jobA, JobFactKind.customerName, renamed, _pcm(1200));
    expect(session(jobA, JobFactKind.customerName, name), isNull);
    expect(session(jobA, JobFactKind.customerName, renamed), isNotNull);
  });

  test('time on site is never cached (a different time can never replay)', () {
    appLifetime.bindJob(jobA);
    final t1 = timeOnSiteReply(
      now: DateTime(2026, 10, 9, 14, 30),
      loaded: true,
      openVisitArrivedAt: DateTime(2026, 10, 9, 14, 5),
    );
    expect(appLifetime.store(jobA, JobFactKind.timeOnSite, t1, _pcm(1500)), isNotNull);
    expect(session(jobA, JobFactKind.timeOnSite, t1), isNull);
  });

  test('job change clears every clip; coming back to the first job starts empty', () {
    appLifetime.bindJob(jobA);
    appLifetime.store(jobA, JobFactKind.address, address, _pcm(10400));
    expect(session(jobB, JobFactKind.address, address), isNull);
    expect(appLifetime.count, 0);
    expect(session(jobA, JobFactKind.address, address), isNull);
  });

  test('a session with no job (standalone) clears too', () {
    appLifetime.bindJob(jobA);
    appLifetime.store(jobA, JobFactKind.address, address, _pcm(10400));
    appLifetime.bindJob(null);
    expect(appLifetime.count, 0);
  });

  test('app restart = a new cache instance = empty (memory only, never on disk)', () {
    appLifetime.bindJob(jobA);
    appLifetime.store(jobA, JobFactKind.address, address, _pcm(10400));
    final afterRestart = JobFactClipCache()..bindJob(jobA);
    expect(afterRestart.pcmFor(jobA, JobFactKind.address, address), isNull);
  });

  test('still bounded by the 3MB cap across sessions', () {
    final small = JobFactClipCache(maxBytes: 600000);
    small.bindJob(jobA);
    small.store(jobA, JobFactKind.address, address, _pcm(10400)); // 499200 bytes
    small.store(jobA, JobFactKind.customerName, name, _pcm(3000)); // 144000 bytes -> over the cap
    expect(small.bytes, lessThanOrEqualTo(600000));
    expect(small.pcmFor(jobA, JobFactKind.address, address), isNull, reason: 'oldest dropped first');
    expect(JobFactClipCache().maxBytes, 3 * 1024 * 1024);
    expect(JobFactClipCache().maxEntries, 8);
  });

  test('screen wiring: app-lifetime cache, no clear at session end when the flag is on', () {
    final src = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();
    expect(src, contains('const bool _jobFactClipKeepAcrossSessions = true;'));
    expect(src, contains('if (!_jobFactClipKeepAcrossSessions) _jobFactClips.clear();'));
    expect(src, contains('_jobFactClipKeepAcrossSessions\n      ? _appLifetimeJobFactClips'));
    // bindJob at session open is still there (the job-change clear).
    expect(src, contains('    _jobFactClips.bindJob(prefetchJobId);'));
  });
}
