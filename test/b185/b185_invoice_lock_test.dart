import 'dart:async';

import 'package:fielloop/models/invoice_adjustment.dart';
import 'package:fielloop/models/invoice_payment.dart';
import 'package:fielloop/models/invoice_preview.dart';
import 'package:fielloop/providers/global_voice_service_provider.dart';
import 'package:fielloop/providers/invoice_provider.dart';
import 'package:fielloop/providers/jobs_provider.dart';
import 'package:fielloop/screens/invoice_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 185 follow-up — Invoice Review adjustments are read-only while the
/// latest invoice is pending or paid (or its status hasn't loaded), the
/// handlers refuse on their own, and "Fix something first" hides once frozen.

class _FakeVoice extends GlobalVoiceService {
  _FakeVoice(super.ref);

  @override
  Future<void> speak(String text) async {}

  @override
  void exitJobScope() {}

  @override
  Future<void> enterJobScope() async {}
}

const _jobId = '13be2358-5296-4d94-9a58-9d1662ac4902';

const _tripFee = InvoiceAdjustment(id: 'adj-1', jobId: _jobId, description: 'Trip fee', amount: 25);

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
  'adjustments': [
    {'id': _tripFee.id, 'job_id': _jobId, 'description': _tripFee.description, 'amount': _tripFee.amount},
  ],
  'estimateApproved': true,
  'grossTotal': 3644,
  'feeRate': 0.0195,
  'feeAmount': 71.06,
  'netToContractor': 3572.94,
});

LatestInvoicePayment _latest(InvoicePaymentStatus status) => LatestInvoicePayment(
  id: 'inv-1',
  invoiceNumber: 'FL-TEST01',
  status: status,
  paidAt: null,
  total: 3644,
);

class _Writes {
  final added = <String>[];
  final deleted = <String>[];
  var statusReads = 0;
}

Future<_Writes> _pump(
  WidgetTester tester, {
  required Future<LatestInvoicePayment?> Function() status,
  _Writes? writes,
}) async {
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final calls = writes ?? _Writes();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        globalVoiceServiceProvider.overrideWith(_FakeVoice.new),
        jobByIdProvider.overrideWith((ref, id) => null),
      ],
      child: MaterialApp(
        home: InvoiceReviewScreen(
          jobId: _jobId,
          preview: _preview(),
          generateInvoice: ({required String jobId}) async => fail('generate must not run'),
          sendSms: ({required String invoiceId, required String pdfUrl}) async => fail('SMS must not run'),
          fetchPaymentStatus: (jobId) {
            calls.statusReads++;
            return status();
          },
          addAdjustmentRow: ({required String jobId, required String description, required double amount}) async {
            calls.added.add(description);
            return null;
          },
          deleteAdjustmentRow: (adjustmentId) async => calls.deleted.add(adjustmentId),
          fetchPreview: ({required String jobId}) async => _preview(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return calls;
}

ButtonStyleButton _addButton(WidgetTester tester) => tester.widget<ButtonStyleButton>(
  find.ancestor(of: find.text('Add Line Item'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)),
);

IconButton _removeButton(WidgetTester tester) =>
    tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close_rounded));

void _expectEditable(WidgetTester tester) {
  expect(_addButton(tester).enabled, isTrue);
  expect(_removeButton(tester).onPressed, isNotNull);
}

void _expectReadOnly(WidgetTester tester) {
  expect(_addButton(tester).enabled, isFalse);
  expect(_removeButton(tester).onPressed, isNull);
}

/// Taps the (disabled) controls: no sheet opens and nothing is written.
Future<void> _tapControls(WidgetTester tester, _Writes writes) async {
  await tester.tap(find.text('Add Line Item'), warnIfMissed: false);
  await tester.pumpAndSettle();
  expect(find.text('Add to Invoice'), findsNothing);
  await tester.tap(find.widgetWithIcon(IconButton, Icons.close_rounded), warnIfMissed: false);
  await tester.pumpAndSettle();
  expect(writes.added, isEmpty);
  expect(writes.deleted, isEmpty);
}

Future<void> _fillAndSubmitSheet(WidgetTester tester) async {
  await tester.tap(find.text('Add Line Item'));
  await tester.pumpAndSettle();
  expect(find.text('Add to Invoice'), findsOneWidget);
  await tester.enterText(find.byType(TextFormField).at(0), 'Extra part');
  await tester.enterText(find.byType(TextFormField).at(1), '10');
  await tester.pump();
  await tester.tap(find.text('Add to Invoice'));
  await tester.pumpAndSettle();
}

InvoiceAdjustmentActions _actions(WidgetTester tester) =>
    tester.state(find.byType(InvoiceReviewScreen)) as InvoiceAdjustmentActions;

void main() {
  group('pure rules', () {
    test('adjustmentsLocked: anything but a loaded unpaid status locks (flag on)', () {
      bool locked(PaymentStatusLoad load, InvoicePaymentStatus? status, {bool enabled = true}) => adjustmentsLocked(
        enabled: enabled,
        sent: false,
        generating: false,
        updatingAdjustments: false,
        status: status,
        load: load,
      );
      expect(locked(PaymentStatusLoad.loaded, InvoicePaymentStatus.unpaid), isFalse);
      expect(locked(PaymentStatusLoad.loaded, null), isFalse);
      expect(locked(PaymentStatusLoad.loading, null), isTrue);
      expect(locked(PaymentStatusLoad.failed, null), isTrue);
      expect(locked(PaymentStatusLoad.loaded, InvoicePaymentStatus.pending), isTrue);
      expect(locked(PaymentStatusLoad.loaded, InvoicePaymentStatus.paid), isTrue);
      expect(locked(PaymentStatusLoad.loading, InvoicePaymentStatus.paid, enabled: false), isFalse);
    });

    test('showFixSomethingFirst: hidden only for pending/paid with the flag on', () {
      expect(showFixSomethingFirst(enabled: true, status: null), isTrue);
      expect(showFixSomethingFirst(enabled: true, status: InvoicePaymentStatus.unpaid), isTrue);
      expect(showFixSomethingFirst(enabled: true, status: InvoicePaymentStatus.pending), isFalse);
      expect(showFixSomethingFirst(enabled: true, status: InvoicePaymentStatus.paid), isFalse);
      expect(showFixSomethingFirst(enabled: false, status: InvoicePaymentStatus.paid), isTrue);
    });
  });

  group('adjustments card', () {
    testWidgets('unpaid: editable, add and delete write, Fix something first shows', (tester) async {
      final writes = await _pump(tester, status: () async => _latest(InvoicePaymentStatus.unpaid));
      _expectEditable(tester);
      expect(find.text('Fix something first'), findsOneWidget);
      expect(find.text(kInvoiceLockedMessage), findsNothing);

      await _fillAndSubmitSheet(tester);
      expect(writes.added, ['Extra part']);

      await tester.tap(find.widgetWithIcon(IconButton, Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(writes.deleted, [_tripFee.id]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no invoice yet counts as unpaid: editable', (tester) async {
      await _pump(tester, status: () async => null);
      _expectEditable(tester);
      expect(find.text('Fix something first'), findsOneWidget);
    });

    testWidgets('status still loading: controls disabled, no sheet, then editable once unpaid loads', (tester) async {
      final pending = Completer<LatestInvoicePayment?>();
      final writes = await _pump(tester, status: () => pending.future);
      _expectReadOnly(tester);
      expect(find.text('Checking payment status…'), findsOneWidget);
      await _tapControls(tester, writes);

      pending.complete(_latest(InvoicePaymentStatus.unpaid));
      await tester.pumpAndSettle();
      _expectEditable(tester);
      expect(find.text('Checking payment status…'), findsNothing);
    });

    testWidgets('status read failed: controls disabled until a retry succeeds', (tester) async {
      var fail = true;
      final writes = await _pump(
        tester,
        status: () async {
          if (fail) throw StateError('network down');
          return _latest(InvoicePaymentStatus.unpaid);
        },
      );
      _expectReadOnly(tester);
      expect(find.text("Couldn't check the payment status."), findsOneWidget);
      await _tapControls(tester, writes);

      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      _expectEditable(tester);
    });

    testWidgets('pending: locked, Fix something first hidden', (tester) async {
      final writes = await _pump(tester, status: () async => _latest(InvoicePaymentStatus.pending));
      _expectReadOnly(tester);
      expect(find.text(kInvoiceLockedMessage), findsOneWidget);
      expect(find.text('Fix something first'), findsNothing);
      expect(find.text('Pending'), findsOneWidget);
      await _tapControls(tester, writes);
    });

    testWidgets('opened directly on a paid invoice: locked, Fix something first hidden, no Collect Payment', (
      tester,
    ) async {
      final writes = await _pump(tester, status: () async => _latest(InvoicePaymentStatus.paid));
      _expectReadOnly(tester);
      expect(find.text(kInvoiceLockedMessage), findsOneWidget);
      expect(find.text('Fix something first'), findsNothing);
      expect(find.text('Paid'), findsOneWidget);
      expect(find.text('Collect Payment'), findsNothing);
      expect(find.text('Generate & Send Invoice'), findsNothing);
      await _tapControls(tester, writes);
      expect(tester.takeException(), isNull);
    });
  });

  group('handlers refuse on their own', () {
    testWidgets('paid: addAdjustment called directly shows the lock message, no sheet, no write', (tester) async {
      final writes = await _pump(tester, status: () async => _latest(InvoicePaymentStatus.paid));
      unawaited(_actions(tester).addAdjustment());
      await tester.pumpAndSettle();
      expect(find.text('Add to Invoice'), findsNothing);
      expect(find.text(kInvoiceLockedMessage), findsNWidgets(2)); // card note + snackbar
      expect(writes.added, isEmpty);
    });

    testWidgets('pending: removeAdjustment called directly refuses, no delete', (tester) async {
      final writes = await _pump(tester, status: () async => _latest(InvoicePaymentStatus.pending));
      await _actions(tester).removeAdjustment(_tripFee);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(writes.deleted, isEmpty);
    });

    testWidgets('still loading: handlers called directly refuse', (tester) async {
      final pending = Completer<LatestInvoicePayment?>();
      final writes = await _pump(tester, status: () => pending.future);
      unawaited(_actions(tester).addAdjustment());
      await tester.pumpAndSettle();
      expect(find.text('Add to Invoice'), findsNothing);
      await _actions(tester).removeAdjustment(_tripFee);
      await tester.pumpAndSettle();
      expect(writes.added, isEmpty);
      expect(writes.deleted, isEmpty);
      pending.complete(null);
      await tester.pumpAndSettle();
    });

    testWidgets('paid while the sheet was open: the save is refused after the server re-check', (tester) async {
      var status = InvoicePaymentStatus.unpaid;
      final writes = await _pump(tester, status: () async => _latest(status));
      _expectEditable(tester);

      status = InvoicePaymentStatus.paid;
      await _fillAndSubmitSheet(tester);
      expect(writes.added, isEmpty);
      expect(find.byType(SnackBar), findsOneWidget);
      _expectReadOnly(tester);
      expect(find.text('Fix something first'), findsNothing);
    });

    testWidgets('paid since open: delete is refused after the server re-check', (tester) async {
      var status = InvoicePaymentStatus.unpaid;
      final writes = await _pump(tester, status: () async => _latest(status));
      status = InvoicePaymentStatus.paid;
      await tester.tap(find.widgetWithIcon(IconButton, Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(writes.deleted, isEmpty);
      expect(writes.statusReads, 2);
      _expectReadOnly(tester);
    });

    testWidgets('re-check failure refuses the write', (tester) async {
      var fail = false;
      final writes = await _pump(
        tester,
        status: () async {
          if (fail) throw StateError('network down');
          return _latest(InvoicePaymentStatus.unpaid);
        },
      );
      fail = true;
      await _actions(tester).removeAdjustment(_tripFee);
      await tester.pumpAndSettle();
      expect(writes.deleted, isEmpty);
      expect(find.text("Couldn't confirm the payment status - try again"), findsOneWidget);
    });
  });
}
