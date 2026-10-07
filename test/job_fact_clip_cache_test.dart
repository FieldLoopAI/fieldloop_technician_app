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

    test('reason parsing', () {
      expect(jobFactKindForReason('job_fact address'), JobFactKind.address);
      expect(jobFactKindForReason('job_fact timeOnSite'), JobFactKind.timeOnSite);
      expect(jobFactKindForReason('deterministic go_back'), isNull);
    });
  });
}
