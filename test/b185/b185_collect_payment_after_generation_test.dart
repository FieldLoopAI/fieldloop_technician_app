import 'package:fielloop/models/invoice_payment.dart';
import 'package:fielloop/models/invoice_preview.dart';
import 'package:fielloop/providers/global_voice_service_provider.dart';
import 'package:fielloop/providers/invoice_provider.dart';
import 'package:fielloop/providers/jobs_provider.dart';
import 'package:fielloop/screens/invoice_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 185 follow-up FIX 1 — Collect Payment shows as soon as the invoice
/// is generated, whatever happens to the SMS that follows.

class _FakeVoice extends GlobalVoiceService {
  _FakeVoice(super.ref);

  final spoken = <String>[];

  @override
  Future<void> speak(String text) async => spoken.add(text);

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

class _Calls {
  final generated = <String>[];
  final smsFor = <String>[];
}

Future<_FakeVoice> _pump(
  WidgetTester tester, {
  required _Calls calls,
  required Future<void> Function() sms,
}) async {
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late _FakeVoice voice;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        globalVoiceServiceProvider.overrideWith((ref) => voice = _FakeVoice(ref)),
        jobByIdProvider.overrideWith((ref, id) => null),
      ],
      child: MaterialApp(
        home: InvoiceReviewScreen(
          jobId: _jobId,
          preview: _preview(),
          generateInvoice: ({required String jobId}) async {
            calls.generated.add(jobId);
            return const GeneratedInvoice(id: 'inv-1', pdfUrl: 'https://example.test/invoice.pdf');
          },
          sendSms: ({required String invoiceId, required String pdfUrl}) async {
            calls.smsFor.add(invoiceId);
            await sms();
          },
          fetchPaymentStatus: (jobId) async => null,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return voice;
}

Future<void> _generate(WidgetTester tester) async {
  expect(find.text('Collect Payment'), findsNothing);
  await tester.tap(find.text('Generate & Send Invoice'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('SMS success: sent confirmation, then Collect Payment', (tester) async {
    final calls = _Calls();
    final voice = await _pump(tester, calls: calls, sms: () async {});
    await _generate(tester);

    expect(calls.generated, [_jobId]);
    expect(calls.smsFor, ['inv-1']);
    expect(find.text('Invoice sent to the customer'), findsOneWidget);
    expect(voice.spoken, ['Invoice sent to the customer']);
    expect(find.text('Collect Payment'), findsOneWidget);
    expect(find.text(invoicePaymentStatusLabel(InvoicePaymentStatus.unpaid)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SMS failure: the existing error shows, and Collect Payment still shows', (tester) async {
    final calls = _Calls();
    final voice = await _pump(
      tester,
      calls: calls,
      sms: () async => throw StateError('Sending the invoice failed (400): Twilio error'),
    );
    await _generate(tester);

    expect(calls.smsFor, ['inv-1']);
    expect(find.text('Sending the invoice failed (400): Twilio error'), findsOneWidget);
    expect(find.text('Invoice sent to the customer'), findsNothing);
    expect(voice.spoken, isEmpty);
    expect(find.text('Collect Payment'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no phone on file: the existing error shows, and Collect Payment still shows', (tester) async {
    final calls = _Calls();
    await _pump(
      tester,
      calls: calls,
      sms: () async => throw StateError(
        'Sending the invoice failed (400): {"error":"No customer phone number on file"}',
      ),
    );
    await _generate(tester);

    expect(
      find.text('Sending the invoice failed (400): {"error":"No customer phone number on file"}'),
      findsOneWidget,
    );
    expect(find.text('Collect Payment'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('generation failure: no invoice, so no Collect Payment', (tester) async {
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
          home: InvoiceReviewScreen(
            jobId: _jobId,
            preview: _preview(),
            generateInvoice: ({required String jobId}) async => throw StateError('Generating the invoice failed (409)'),
            sendSms: ({required String invoiceId, required String pdfUrl}) async => fail('SMS must not run'),
            fetchPaymentStatus: (jobId) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _generate(tester);
    expect(find.text('Generating the invoice failed (409)'), findsOneWidget);
    expect(find.text('Collect Payment'), findsNothing);
  });
}
