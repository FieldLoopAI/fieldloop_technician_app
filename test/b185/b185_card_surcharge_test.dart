import 'package:fielloop/models/invoice_payment.dart';
import 'package:fielloop/models/invoice_preview.dart';
import 'package:fielloop/providers/global_voice_service_provider.dart';
import 'package:fielloop/providers/jobs_provider.dart';
import 'package:fielloop/screens/invoice_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 185 card-fee surcharge — Invoice Review's Payment panel shows
/// "Card processing fee" and "Customer pays" only when the server reports a
/// processing fee above zero.

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

InvoicePreview _preview() => InvoicePreview.fromJson({
  'estimate': {
    'id': 'est-1',
    'job_id': _jobId,
    'status': 'approved',
    'total_amount': 4287.35,
    'line_items': [
      {'description': 'Work', 'amount': 4287.35},
    ],
  },
  'approvedChangeOrders': <Object>[],
  'pendingChangeOrders': <Object>[],
  'voidedChangeOrders': <Object>[],
  'declinedChangeOrders': <Object>[],
  'adjustments': <Object>[],
  'estimateApproved': true,
  'grossTotal': 4287.35,
  'feeRate': 0.0195,
  'feeAmount': 83.60,
  'netToContractor': 4203.75,
});

LatestInvoicePayment? _latest(Map<String, Object?> extra) => LatestInvoicePayment.fromResponse({
  'invoice': {
    'id': 'inv-1',
    'invoice_number': 'INV-1',
    'payment_status': 'pending',
    'paid_at': null,
    'total': 4287.35,
    ...extra,
  },
});

Future<void> _pump(WidgetTester tester, LatestInvoicePayment? latest) async {
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        globalVoiceServiceProvider.overrideWith(_FakeVoice.new),
        jobByIdProvider.overrideWith((ref, id) => null),
      ],
      child: MaterialApp(
        home: InvoiceReviewScreen(jobId: _jobId, preview: _preview(), fetchPaymentStatus: (jobId) async => latest),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('cardSurcharge / formatCents', () {
    test('present only when the processing fee and total are above zero', () {
      expect(
        cardSurcharge(processingFeeCents: 12836, chargeTotalCents: 441571),
        (processingFeeCents: 12836, chargeTotalCents: 441571),
      );
      expect(cardSurcharge(processingFeeCents: null, chargeTotalCents: null), isNull);
      expect(cardSurcharge(processingFeeCents: 0, chargeTotalCents: 428735), isNull);
      expect(cardSurcharge(processingFeeCents: 12836, chargeTotalCents: null), isNull);
    });

    test('formats integer cents', () {
      expect(formatCents(441571), r'$4415.71');
      expect(formatCents(12836), r'$128.36');
      expect(formatCents(5), r'$0.05');
    });

    test('payment-status parsing reads the new fields, absent -> null', () {
      final withFee = _latest({'processing_fee_cents': 12836, 'charge_total_cents': 441571})!;
      expect(withFee.processingFeeCents, 12836);
      expect(withFee.chargeTotalCents, 441571);
      final without = _latest({})!;
      expect(without.processingFeeCents, isNull);
      expect(without.chargeTotalCents, isNull);
    });
  });

  group('Invoice Review Payment panel', () {
    testWidgets('processing fee reported: shows the fee and what the customer pays', (tester) async {
      await _pump(tester, _latest({'processing_fee_cents': 12836, 'charge_total_cents': 441571}));
      expect(find.text('Card processing fee'), findsOneWidget);
      expect(find.text(r'$128.36'), findsOneWidget);
      expect(find.text('Customer pays'), findsOneWidget);
      expect(find.text(r'$4415.71'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no processing fee in the reply: no extra lines', (tester) async {
      await _pump(tester, _latest({}));
      expect(find.text('Pending'), findsWidgets);
      expect(find.text('Card processing fee'), findsNothing);
      expect(find.text('Customer pays'), findsNothing);
    });

    testWidgets('processing fee of 0: no extra lines', (tester) async {
      await _pump(tester, _latest({'processing_fee_cents': 0, 'charge_total_cents': 428735}));
      expect(find.text('Card processing fee'), findsNothing);
      expect(find.text('Customer pays'), findsNothing);
    });
  });
}
