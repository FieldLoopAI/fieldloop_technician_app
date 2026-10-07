import 'dart:typed_data';

import 'package:fielloop/services/job_fact_clip_cache.dart';
import 'package:fielloop/services/job_facts.dart';
import 'package:flutter_test/flutter_test.dart';

/// [ms] of mono int16 PCM at 24kHz, filled with [fill].
Uint8List _pcm(int ms, [int fill = 1]) => Uint8List(24 * ms * 2)..fillRange(0, 24 * ms * 2, fill);

void main() {
  group('JobFactClipCache (build 174, C14-C16)', () {
    test('plays back the clip for the right job, kind and text', () {
      final cache = JobFactClipCache()..bindJob('job-1');
      expect(cache.put('job-1', JobFactKind.address, '12 Oak St.', _pcm(1500, 7)), isTrue);
      expect(cache.pcmFor('job-1', JobFactKind.address, '12 Oak St.')!.first, 7);
      expect(cache.pcmFor('job-1', JobFactKind.customerName, '12 Oak St.'), isNull);
      expect(cache.pcmFor('job-2', JobFactKind.address, '12 Oak St.'), isNull);
    });

    test('a different value misses — never a stale answer', () {
      final cache = JobFactClipCache()..bindJob('job-1');
      cache.put('job-1', JobFactKind.estimateSummary, r'The estimate is $1,200.', _pcm(2000));
      expect(cache.pcmFor('job-1', JobFactKind.estimateSummary, r'The estimate is $1,450.'), isNull);
      // The new value replaces the old one for that kind.
      cache.put('job-1', JobFactKind.estimateSummary, r'The estimate is $1,450.', _pcm(2000));
      expect(cache.count, 1);
      expect(cache.pcmFor('job-1', JobFactKind.estimateSummary, r'The estimate is $1,200.'), isNull);
    });

    test('job change and session end clear everything', () {
      final cache = JobFactClipCache()..bindJob('job-1');
      cache.put('job-1', JobFactKind.address, '12 Oak St.', _pcm(1500));
      cache.bindJob('job-1');
      expect(cache.count, 1, reason: 'same job keeps its clips');
      cache.bindJob('job-2');
      expect(cache.count, 0);
      expect(cache.pcmFor('job-1', JobFactKind.address, '12 Oak St.'), isNull);
      expect(cache.put('job-1', JobFactKind.address, '12 Oak St.', _pcm(1500)), isFalse,
          reason: 'a late recording from the old job is refused');
      cache.put('job-2', JobFactKind.address, '9 Elm Rd.', _pcm(1500));
      cache.clear();
      expect(cache.count, 0);
      expect(cache.bytes, 0);
    });

    test('a miss (nothing recorded yet, or no job bound) returns null', () {
      final cache = JobFactClipCache();
      expect(cache.pcmFor('job-1', JobFactKind.address, 'x'), isNull);
      expect(cache.put('job-1', JobFactKind.address, 'x', _pcm(1500)), isFalse);
    });

    test('time on site is never cached; implausible lengths are refused', () {
      final cache = JobFactClipCache()..bindJob('job-1');
      expect(cache.put('job-1', JobFactKind.timeOnSite, '12 minutes on site.', _pcm(1500)), isFalse);
      expect(cache.put('job-1', JobFactKind.address, 'x', _pcm(200)), isFalse);
      expect(cache.put('job-1', JobFactKind.address, 'x', _pcm(9000)), isFalse);
      expect(isCacheableJobFact(JobFactKind.timeOnSite), isFalse);
    });

    test('size cap: entries and bytes, least recently used out first', () {
      final cache = JobFactClipCache(maxEntries: 2, maxBytes: 24 * 2 * 5000)..bindJob('j');
      cache.put('j', JobFactKind.address, 'a', _pcm(2000));
      cache.put('j', JobFactKind.customerName, 'b', _pcm(2000));
      cache.pcmFor('j', JobFactKind.address, 'a'); // a is now most recent
      cache.put('j', JobFactKind.estimateSummary, 'c', _pcm(2000));
      expect(cache.count, 2);
      expect(cache.pcmFor('j', JobFactKind.customerName, 'b'), isNull);
      expect(cache.pcmFor('j', JobFactKind.address, 'a'), isNotNull);
      expect(cache.bytes, lessThanOrEqualTo(24 * 2 * 5000));
    });

    // Build 175 — the 7 Oct tablet address (277-282 audio tokens ≈ 11.1-11.3s).
    const address = '401, SETU SQUARE, SONA CROSS ROAD, New CG Rd, Nigam Nagar, Ahmedabad, Gujarat 382424.';

    test('build 175: a long (~11.3s) address is stored and a repeat hits', () {
      final cache = JobFactClipCache()..bindJob('job-1');
      cache.put('job-1', JobFactKind.customerName, 'hariom.', _pcm(1200));
      expect(cache.store('job-1', JobFactKind.address, address, _pcm(11300, 5)), isNull);
      expect(cache.count, 2);
      // A later ask in the same session (same cache instance, same job).
      cache.bindJob('job-1');
      expect(cache.pcmFor('job-1', JobFactKind.address, address)!.first, 5);
    });

    test('build 175: the 174 fixed bounds refused that same address (regression proof)', () {
      final cache = JobFactClipCache(sizeLimitFromText: false)..bindJob('job-1');
      expect(cache.store('job-1', JobFactKind.address, address, _pcm(11300)), startsWith('too long: 11300ms > max 8000ms'));
    });

    test('build 175: a different job misses and a late recording for it is refused', () {
      final cache = JobFactClipCache()..bindJob('job-1');
      cache.put('job-1', JobFactKind.address, address, _pcm(11300));
      expect(cache.pcmFor('job-2', JobFactKind.address, address), isNull);
      cache.bindJob('job-2');
      expect(cache.pcmFor('job-1', JobFactKind.address, address), isNull);
      expect(cache.store('job-1', JobFactKind.address, address, _pcm(11300)), startsWith('other job'));
    });

    test('build 175: a cut-off recording (far shorter than the text) is not stored', () {
      final cache = JobFactClipCache()..bindJob('job-1');
      // 21 spoken units → min 3150ms; 1.5s of audio cannot be the whole line.
      expect(spokenUnitsForText(address), 21);
      expect(cache.store('job-1', JobFactKind.address, address, _pcm(1500)), startsWith('too short'));
      expect(cache.count, 0);
    });

    test('build 175: length limits scale with the text but stay bounded', () {
      expect(maxClipForText('hariom.'), const Duration(seconds: 8), reason: 'never below the old cap');
      expect(maxClipForText(address), const Duration(seconds: 23));
      expect(maxClipForText(List.filled(60, 'word').join(' ')), const Duration(seconds: 30), reason: 'hard ceiling');
      expect(minClipForText('hariom.'), const Duration(milliseconds: 600));
      final cache = JobFactClipCache()..bindJob('j');
      expect(cache.store('j', JobFactKind.address, address, _pcm(23500)), startsWith('too long'));
    });

    test('build 175: the byte cap still holds for long clips', () {
      final cache = JobFactClipCache(maxBytes: 24 * 2 * 10000)..bindJob('j');
      expect(cache.store('j', JobFactKind.address, address, _pcm(11300)), startsWith('over the byte cap'));
      final roomy = JobFactClipCache(maxBytes: 24 * 2 * 15000)..bindJob('j');
      roomy.put('j', JobFactKind.customerName, 'hariom.', _pcm(5000));
      expect(roomy.put('j', JobFactKind.address, address, _pcm(11300)), isTrue);
      expect(roomy.bytes, lessThanOrEqualTo(24 * 2 * 15000));
      expect(roomy.pcmFor('j', JobFactKind.customerName, 'hariom.'), isNull, reason: 'oldest evicted to fit');
    });

    test('reason parsing', () {
      expect(jobFactKindForReason('job_fact address'), JobFactKind.address);
      expect(jobFactKindForReason('job_fact timeOnSite'), JobFactKind.timeOnSite);
      expect(jobFactKindForReason('deterministic go_back'), isNull);
    });
  });
}
