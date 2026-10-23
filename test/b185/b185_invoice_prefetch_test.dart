import 'dart:async';

import 'package:fielloop/models/invoice_preview.dart';
import 'package:fielloop/screens/gemini_live_test_screen.dart' show cameraCloseShowsCameraScreen;
import 'package:fielloop/screens/invoice_review_screen.dart';
import 'package:fielloop/screens/invoice_screen.dart';
import 'package:fielloop/services/gemini_function_dispatcher.dart';
import 'package:fielloop/services/invoice_preview_cache.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _jobId = 'job-1';
const _navigated = {'status': 'navigated', 'job_id': _jobId};

InvoicePreview _preview() => InvoicePreview.fromJson({
  'estimate': {
    'id': 'est-1',
    'job_id': _jobId,
    'status': 'approved',
    'total_amount': 3619,
    'line_items': [
      {'description': 'Work', 'amount': 3619},
    ],
  },
  'approvedChangeOrders': <Object>[],
  'pendingChangeOrders': <Object>[],
  'voidedChangeOrders': <Object>[],
  'declinedChangeOrders': <Object>[],
  'adjustments': <Object>[],
  'estimateApproved': true,
  'grossTotal': 3619,
  'feeRate': 0.0195,
  'feeAmount': 70.57,
  'netToContractor': 3548.43,
});

/// Records pushes instead of navigating, so the pushed screen can be
/// inspected without building it.
class _RecordingSession extends GeminiNavigationSession {
  final pushed = <({String name, Widget screen})>[];

  @override
  String? get topScreenName => pushed.isEmpty ? null : pushed.last.name;

  @override
  void push(Widget screen, {required String name}) => pushed.add((name: name, screen: screen));
}

class _Clock {
  DateTime now = DateTime(2026, 10, 23, 12);
  void advance(Duration d) => now = now.add(d);
}

/// Counts the view's own fetches (the prefetch uses a separate function).
class _ViewFetch {
  int calls = 0;
  Future<InvoicePreview> Function({required String jobId}) answering(Future<InvoicePreview> Function() result) =>
      ({required String jobId}) {
        calls++;
        return result();
      };
}

Future<Map<String, dynamic>> _view(
  _RecordingSession session,
  InvoicePreviewCache cache,
  _ViewFetch fetch, {
  bool flag = true,
  Future<InvoicePreview> Function()? result,
  Duration? timeout,
}) => viewInvoiceForTesting(
  navigationSession: session,
  jobId: _jobId,
  stripePayments: flag,
  fetchPreview: fetch.answering(result ?? () async => _preview()),
  fetchTimeout: timeout ?? kViewInvoiceFetchTimeout,
  previewCache: cache,
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('B185 invoice preview prefetch + view_invoice', () {
    test('timeouts: 8 s for the view, 45 s cache TTL', () {
      expect(kViewInvoiceFetchTimeout, const Duration(seconds: 8));
      expect(kInvoicePreviewCacheTtl, const Duration(seconds: 45));
    });

    test('cache hit opens InvoiceReviewScreen with the prefetched preview and no fetch', () async {
      final clock = _Clock();
      final cache = InvoicePreviewCache(now: () => clock.now);
      final prefetched = _preview();
      cache.prefetch(_jobId, ({required String jobId}) async => prefetched);
      await _settle();
      clock.advance(const Duration(seconds: 44));

      final session = _RecordingSession();
      final fetch = _ViewFetch();
      expect(await _view(session, cache, fetch), _navigated);
      expect(fetch.calls, 0);
      expect(session.pushed.single.name, 'view_invoice');
      expect((session.pushed.single.screen as InvoiceReviewScreen).preview, same(prefetched));
    });

    test('a running prefetch is awaited instead of a second fetch', () async {
      final cache = InvoicePreviewCache();
      final gate = Completer<InvoicePreview>();
      cache.prefetch(_jobId, ({required String jobId}) => gate.future);

      final session = _RecordingSession();
      final fetch = _ViewFetch();
      final result = _view(session, cache, fetch);
      await _settle();
      expect(session.pushed, isEmpty);
      final prefetched = _preview();
      gate.complete(prefetched);
      expect(await result, _navigated);
      expect(fetch.calls, 0);
      expect((session.pushed.single.screen as InvoiceReviewScreen).preview, same(prefetched));
    });

    test('the cached preview expires 45 s after the prefetch started', () async {
      final clock = _Clock();
      final cache = InvoicePreviewCache(now: () => clock.now);
      cache.prefetch(_jobId, ({required String jobId}) async => _preview());
      await _settle();
      clock.advance(kInvoicePreviewCacheTtl);

      final session = _RecordingSession();
      final fetch = _ViewFetch();
      expect(await _view(session, cache, fetch), _navigated);
      expect(fetch.calls, 1);
      expect(session.pushed.single.screen, isA<InvoiceReviewScreen>());
    });

    test('the cache is single-use, and only for its own job', () async {
      final cache = InvoicePreviewCache();
      cache.prefetch(_jobId, ({required String jobId}) async => _preview());
      await _settle();
      expect(cache.take('other-job'), isNull);
      expect(cache.take(_jobId)?.value, isNotNull);
      expect(cache.take(_jobId), isNull);

      cache.prefetch(_jobId, ({required String jobId}) async => _preview());
      await _settle();
      final fetch = _ViewFetch();
      await _view(_RecordingSession(), cache, fetch);
      expect(fetch.calls, 0);
      final second = _RecordingSession();
      expect(await _view(second, cache, fetch), _navigated);
      expect(fetch.calls, 1);
    });

    test('a failed prefetch is dropped and the view fetches on its own', () async {
      final cache = InvoicePreviewCache();
      cache.prefetch(_jobId, ({required String jobId}) async => throw StateError('preview failed (500)'));
      await _settle();
      expect(cache.take(_jobId), isNull);

      cache.prefetch(_jobId, ({required String jobId}) async => throw StateError('preview failed (500)'));
      await _settle();
      final session = _RecordingSession();
      final fetch = _ViewFetch();
      expect(await _view(session, cache, fetch), _navigated);
      expect(fetch.calls, 1);
      expect(session.pushed.single.screen, isA<InvoiceReviewScreen>());
    });

    test('an awaited prefetch that fails falls back to the old InvoiceScreen', () async {
      final cache = InvoicePreviewCache();
      final gate = Completer<InvoicePreview>();
      cache.prefetch(_jobId, ({required String jobId}) => gate.future);
      final session = _RecordingSession();
      final result = _view(session, cache, _ViewFetch());
      await _settle();
      gate.completeError(StateError('preview failed (500)'));
      expect(await result, _navigated);
      expect(session.pushed.single.screen, isA<InvoiceScreen>());
    });

    test('an awaited prefetch that times out falls back to the old InvoiceScreen', () async {
      final cache = InvoicePreviewCache();
      cache.prefetch(_jobId, ({required String jobId}) => Completer<InvoicePreview>().future);
      final session = _RecordingSession();
      expect(await _view(session, cache, _ViewFetch(), timeout: const Duration(milliseconds: 20)), _navigated);
      expect(session.pushed.single.screen, isA<InvoiceScreen>());
    });

    test('own fetch failing or timing out falls back to the old InvoiceScreen', () async {
      final failed = _RecordingSession();
      expect(
        await _view(failed, InvoicePreviewCache(), _ViewFetch(), result: () async => throw StateError('x')),
        _navigated,
      );
      expect(failed.pushed.single.screen, isA<InvoiceScreen>());

      final timedOut = _RecordingSession();
      expect(
        await _view(
          timedOut,
          InvoicePreviewCache(),
          _ViewFetch(),
          result: () => Completer<InvoicePreview>().future,
          timeout: const Duration(milliseconds: 20),
        ),
        _navigated,
      );
      expect(timedOut.pushed.single.screen, isA<InvoiceScreen>());
    });

    test('flag off: old InvoiceScreen, no fetch, cache left untouched', () async {
      final cache = InvoicePreviewCache();
      cache.prefetch(_jobId, ({required String jobId}) async => _preview());
      await _settle();
      final session = _RecordingSession();
      final fetch = _ViewFetch();
      expect(await _view(session, cache, fetch, flag: false), _navigated);
      expect(fetch.calls, 0);
      expect(session.pushed.single.screen, isA<InvoiceScreen>());
      expect(cache.take(_jobId)?.value, isNotNull);
    });

    test('already on top: same map, no push, cache not consumed', () async {
      final cache = InvoicePreviewCache();
      cache.prefetch(_jobId, ({required String jobId}) async => _preview());
      await _settle();
      final session = _RecordingSession()..pushed.add((name: 'view_invoice', screen: const SizedBox()));
      expect(await _view(session, cache, _ViewFetch()), {'status': 'already_on_screen', 'job_id': _jobId});
      expect(session.pushed, hasLength(1));
      expect(cache.take(_jobId), isNotNull);
    });

    test('prefetch never throws, sync or async', () async {
      final cache = InvoicePreviewCache();
      expect(() => cache.prefetch(_jobId, ({required String jobId}) => throw StateError('sync')), returnsNormally);
      expect(cache.take(_jobId), isNull);
      cache.prefetch(_jobId, ({required String jobId}) => Future<InvoicePreview>.error(StateError('async')));
      await _settle();
      expect(cache.take(_jobId), isNull);
    });
  });

  group('B185 go_back camera close', () {
    test('a prewarmed-only camera does not show the camera screen (no host page)', () {
      expect(cameraCloseShowsCameraScreen(enabled: true, cameraTaskActive: false, cameraOpenConfirmed: false), isFalse);
    });

    test('a real camera flow still shows it', () {
      expect(cameraCloseShowsCameraScreen(enabled: true, cameraTaskActive: true, cameraOpenConfirmed: false), isTrue);
      expect(cameraCloseShowsCameraScreen(enabled: true, cameraTaskActive: true, cameraOpenConfirmed: true), isTrue);
      expect(cameraCloseShowsCameraScreen(enabled: true, cameraTaskActive: false, cameraOpenConfirmed: true), isTrue);
    });

    test('flag off: always shows it, as before', () {
      expect(cameraCloseShowsCameraScreen(enabled: false, cameraTaskActive: false, cameraOpenConfirmed: false), isTrue);
    });
  });
}
