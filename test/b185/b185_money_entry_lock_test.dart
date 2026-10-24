import 'dart:async';

import 'package:fielloop/models/change_order.dart';
import 'package:fielloop/models/invoice_payment.dart';
import 'package:fielloop/models/job_estimate.dart';
import 'package:fielloop/models/mock_job.dart';
import 'package:fielloop/providers/invoice_provider.dart';
import 'package:fielloop/providers/job_change_orders_provider.dart';
import 'package:fielloop/providers/job_estimate_provider.dart';
import 'package:fielloop/providers/jobs_provider.dart';
import 'package:fielloop/providers/payment_lock.dart';
import 'package:fielloop/screens/job_detail_screen.dart';
import 'package:fielloop/screens/manual_change_order_screen.dart';
import 'package:fielloop/screens/manual_estimate_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 185 money freeze, entry points: Job Details' "Create Estimate" /
/// "Add Change Order" and the two manual forms are disabled while the job's
/// payment is pending or paid (no message while the status is loading).
/// "View Change Orders" / "View Full Estimate" stay available.

const _jobId = 'job-1';

final _job = MockJob(
  id: _jobId,
  jobIdPublic: 'FL-1',
  customerName: 'Test Customer',
  serviceAddress: '1 Main St',
  description: 'Leak',
  tradeCategory: 'plumbing',
  status: JobStatus.onSite,
  scheduledStart: DateTime(2026, 10, 24, 9),
);

const _changeOrder = ChangeOrder(
  id: 'co-1',
  jobId: _jobId,
  description: 'Replace the valve',
  additionalAmount: 120,
  status: 'approved',
);

LatestInvoicePayment _latest(String paymentStatus) => LatestInvoicePayment.fromResponse({
  'invoice': {'id': 'inv-1', 'invoice_number': 'INV-1', 'payment_status': paymentStatus, 'paid_at': null, 'total': 100},
})!;

/// The status the screens watch: 'paid'/'unpaid', or null for still loading.
Future<LatestInvoicePayment?> _status(String? paymentStatus) =>
    paymentStatus == null ? Completer<LatestInvoicePayment?>().future : Future.value(_latest(paymentStatus));

class _FakeChangeOrders extends StateNotifier<AsyncValue<List<ChangeOrder>>> implements JobChangeOrdersController {
  _FakeChangeOrders(List<ChangeOrder> rows) : super(AsyncData(rows));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeEstimate extends StateNotifier<AsyncValue<JobEstimate?>> implements JobEstimateController {
  _FakeEstimate() : super(const AsyncData(null));

  final created = <List<EstimateLineItem>>[];

  @override
  Future<void> createManual(List<EstimateLineItem> lineItems) async => created.add(lineItems);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester, {
  required String? paymentStatus,
  required Widget child,
  List<Override> extra = const [],
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        latestInvoicePaymentProvider.overrideWith((ref, jobId) => _status(paymentStatus)),
        jobByIdProvider.overrideWith((ref, id) => null),
        ...extra,
      ],
      child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _pumpTab(
  WidgetTester tester, {
  required String? paymentStatus,
  required bool changeOrders,
  List<ChangeOrder> rows = const [_changeOrder],
}) => _pump(
      tester,
      paymentStatus: paymentStatus,
      child: jobDetailMoneyTabForTesting(job: _job, changeOrders: changeOrders, voiceEligible: true),
      extra: [
        jobChangeOrdersProvider.overrideWith((ref, jobId) => _FakeChangeOrders(rows)),
        jobEstimateProvider.overrideWith((ref, jobId) => _FakeEstimate()),
      ],
    );

ButtonStyleButton _button(WidgetTester tester, String label) => tester.widget<ButtonStyleButton>(
  find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)),
);

/// A host route that opens [screen], so the form's own pop after a save
/// lands back on it.
Widget _host(Widget screen) => Builder(
  builder: (context) => TextButton(
    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen)),
    child: const Text('open'),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

const _saveCo = 'Save & Request Approval';
const _saveEstimate = 'Save Estimate';

void main() {
  group('Job Details, Change Orders tab', () {
    testWidgets('paid: Add Change Order disabled, message shown, View Change Orders enabled', (tester) async {
      await _pumpTab(tester, paymentStatus: 'paid', changeOrders: true);
      expect(_button(tester, 'Add Change Order').enabled, isFalse);
      expect(find.text(kPaymentLockedMessage), findsOneWidget);
      expect(_button(tester, 'View Change Orders').enabled, isTrue);
    });

    testWidgets('unpaid: Add Change Order enabled, no message', (tester) async {
      await _pumpTab(tester, paymentStatus: 'unpaid', changeOrders: true);
      expect(_button(tester, 'Add Change Order').enabled, isTrue);
      expect(find.text(kPaymentLockedMessage), findsNothing);
      expect(_button(tester, 'View Change Orders').enabled, isTrue);
    });

    testWidgets('loading: Add Change Order disabled, no message', (tester) async {
      await _pumpTab(tester, paymentStatus: null, changeOrders: true);
      expect(_button(tester, 'Add Change Order').enabled, isFalse);
      expect(find.text(kPaymentLockedMessage), findsNothing);
      expect(_button(tester, 'View Change Orders').enabled, isTrue);
    });

    testWidgets('paid, no change orders yet: no add action, message shown', (tester) async {
      await _pumpTab(tester, paymentStatus: 'paid', changeOrders: true, rows: const []);
      // EmptyStateActions drops its button when the action is null.
      expect(find.text('Add Change Order'), findsNothing);
      expect(find.text(kPaymentLockedMessage), findsOneWidget);
    });

    testWidgets('unpaid, no change orders yet: add action offered, no message', (tester) async {
      await _pumpTab(tester, paymentStatus: 'unpaid', changeOrders: true, rows: const []);
      expect(_button(tester, 'Add Change Order').enabled, isTrue);
      expect(find.text(kPaymentLockedMessage), findsNothing);
    });
  });

  group('Job Details, Estimate tab', () {
    testWidgets('paid: no Create Estimate action, message shown', (tester) async {
      await _pumpTab(tester, paymentStatus: 'paid', changeOrders: false);
      expect(find.text('Create Estimate'), findsNothing);
      expect(find.text(kPaymentLockedMessage), findsOneWidget);
    });

    testWidgets('unpaid: Create Estimate enabled, no message', (tester) async {
      await _pumpTab(tester, paymentStatus: 'unpaid', changeOrders: false);
      expect(_button(tester, 'Create Estimate').enabled, isTrue);
      expect(find.text(kPaymentLockedMessage), findsNothing);
    });

    testWidgets('loading: no Create Estimate action, no message', (tester) async {
      await _pumpTab(tester, paymentStatus: null, changeOrders: false);
      expect(find.text('Create Estimate'), findsNothing);
      expect(find.text(kPaymentLockedMessage), findsNothing);
    });
  });

  group('ManualChangeOrderScreen', () {
    Future<List<String>> fillAndCountReads(WidgetTester tester, String paymentStatus) async {
      final reads = <String>[];
      paymentLockStatusFetch = (jobId) async {
        reads.add(jobId);
        return _latest(paymentStatus);
      };
      addTearDown(() => paymentLockStatusFetch = fetchLatestInvoicePayment);
      await _pump(tester, paymentStatus: paymentStatus, child: _host(const ManualChangeOrderScreen(jobId: _jobId)));
      await _open(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'Description of the additional work'), 'New valve');
      await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '120');
      await tester.pump();
      return reads;
    }

    testWidgets('paid: message at the top, Save disabled, nothing written', (tester) async {
      final reads = await fillAndCountReads(tester, 'paid');
      expect(find.text(kPaymentLockedMessage), findsOneWidget);
      expect(_button(tester, _saveCo).enabled, isFalse);
      await tester.tap(find.text(_saveCo), warnIfMissed: false);
      await tester.pump();
      expect(reads, isEmpty);
    });

    testWidgets('unpaid: Save enabled and runs the existing save (lock check, then its error line)', (tester) async {
      final reads = await fillAndCountReads(tester, 'unpaid');
      expect(find.text(kPaymentLockedMessage), findsNothing);
      expect(_button(tester, _saveCo).enabled, isTrue);
      await tester.tap(find.text(_saveCo));
      await tester.pump();
      await tester.pump();
      // The write-step check ran and passed; with no Supabase in tests the
      // save then fails into the form's existing error text.
      expect(reads, [_jobId]);
      expect(find.text(kPaymentLockedMessage), findsNothing);
      expect(_button(tester, _saveCo).enabled, isTrue);
    });
  });

  group('ManualEstimateScreen', () {
    Future<_FakeEstimate> fill(WidgetTester tester, String paymentStatus) async {
      final estimate = _FakeEstimate();
      await _pump(
        tester,
        paymentStatus: paymentStatus,
        child: _host(const ManualEstimateScreen(jobId: _jobId)),
        extra: [jobEstimateProvider.overrideWith((ref, jobId) => estimate)],
      );
      await _open(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'Description'), 'Replace the valve');
      await tester.enterText(find.widgetWithText(TextFormField, 'Unit price'), '120');
      await tester.pump();
      return estimate;
    }

    testWidgets('paid: message at the top, Save disabled, nothing written', (tester) async {
      final estimate = await fill(tester, 'paid');
      expect(find.text(kPaymentLockedMessage), findsOneWidget);
      expect(_button(tester, _saveEstimate).enabled, isFalse);
      await tester.tap(find.text(_saveEstimate), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(estimate.created, isEmpty);
    });

    testWidgets('unpaid: Save enabled and saves as before', (tester) async {
      final estimate = await fill(tester, 'unpaid');
      expect(find.text(kPaymentLockedMessage), findsNothing);
      expect(_button(tester, _saveEstimate).enabled, isTrue);
      await tester.tap(find.text(_saveEstimate));
      await tester.pumpAndSettle();
      expect(estimate.created.single.single.description, 'Replace the valve');
      expect(find.text('Estimate saved'), findsOneWidget);
      expect(find.text('open'), findsOneWidget);
    });
  });
}
