import 'dart:async';

import 'package:fielloop/models/invoice_preview.dart';
import 'package:fielloop/screens/invoice_review_screen.dart';
import 'package:fielloop/screens/invoice_screen.dart';
import 'package:fielloop/services/gemini_function_dispatcher.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _jobId = 'job-1';

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

const _navigated = {'status': 'navigated', 'job_id': _jobId};

void main() {
  group('B185 voice view_invoice', () {
    test('flag on + fetch ok opens InvoiceReviewScreen with the fetched preview', () async {
      final session = _RecordingSession();
      final preview = _preview();
      final fetchedFor = <String>[];
      final result = await viewInvoiceForTesting(
        navigationSession: session,
        jobId: _jobId,
        stripePayments: true,
        fetchPreview: ({required String jobId}) async {
          fetchedFor.add(jobId);
          return preview;
        },
      );
      expect(result, _navigated);
      expect(fetchedFor, [_jobId]);
      expect(session.pushed, hasLength(1));
      expect(session.pushed.single.name, 'view_invoice');
      final screen = session.pushed.single.screen as InvoiceReviewScreen;
      expect(screen.jobId, _jobId);
      expect(screen.preview, same(preview));
    });

    test('flag on + fetch throws falls back to the old InvoiceScreen', () async {
      final session = _RecordingSession();
      final result = await viewInvoiceForTesting(
        navigationSession: session,
        jobId: _jobId,
        stripePayments: true,
        fetchPreview: ({required String jobId}) async => throw StateError('Loading the invoice preview failed (500)'),
      );
      expect(result, _navigated);
      expect(session.pushed.single.name, 'view_invoice');
      expect((session.pushed.single.screen as InvoiceScreen).jobId, _jobId);
    });

    test('flag on + fetch times out falls back to the old InvoiceScreen', () async {
      final session = _RecordingSession();
      final never = Completer<InvoicePreview>();
      final result = await viewInvoiceForTesting(
        navigationSession: session,
        jobId: _jobId,
        stripePayments: true,
        fetchPreview: ({required String jobId}) => never.future,
        fetchTimeout: const Duration(milliseconds: 20),
      );
      expect(result, _navigated);
      expect(session.pushed.single.screen, isA<InvoiceScreen>());
    });

    test('default timeout is 3 seconds', () {
      expect(kViewInvoicePreviewTimeout, const Duration(seconds: 3));
    });

    test('flag off opens the old InvoiceScreen with no fetch', () async {
      final session = _RecordingSession();
      var fetches = 0;
      final result = await viewInvoiceForTesting(
        navigationSession: session,
        jobId: _jobId,
        stripePayments: false,
        fetchPreview: ({required String jobId}) async {
          fetches++;
          return _preview();
        },
      );
      expect(result, _navigated);
      expect(fetches, 0);
      expect(session.pushed.single.name, 'view_invoice');
      expect(session.pushed.single.screen, isA<InvoiceScreen>());
    });

    test('a second call while the fetch is in flight does not push twice', () async {
      final session = _RecordingSession();
      final gate = Completer<InvoicePreview>();
      var fetches = 0;
      Future<InvoicePreview> fetch({required String jobId}) {
        fetches++;
        return gate.future;
      }

      final first = viewInvoiceForTesting(
        navigationSession: session,
        jobId: _jobId,
        stripePayments: true,
        fetchPreview: fetch,
      );
      final second = await viewInvoiceForTesting(
        navigationSession: session,
        jobId: _jobId,
        stripePayments: true,
        fetchPreview: fetch,
      );
      expect(second, {'status': 'already_on_screen', 'job_id': _jobId});
      gate.complete(_preview());
      expect(await first, _navigated);
      expect(fetches, 1);
      expect(session.pushed, hasLength(1));
      expect(session.pushed.single.screen, isA<InvoiceReviewScreen>());
    });

    test('already on top: no fetch, no push, same map as before', () async {
      for (final flag in [true, false]) {
        final session = _RecordingSession()..pushed.add((name: 'view_invoice', screen: const SizedBox()));
        var fetches = 0;
        final result = await viewInvoiceForTesting(
          navigationSession: session,
          jobId: _jobId,
          stripePayments: flag,
          fetchPreview: ({required String jobId}) async {
            fetches++;
            return _preview();
          },
        );
        expect(result, {'status': 'already_on_screen', 'job_id': _jobId});
        expect(fetches, 0);
        expect(session.pushed, hasLength(1));
      }
    });
  });
}
