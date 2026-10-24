import 'dart:io';

import 'package:fielloop/models/invoice_payment.dart';
import 'package:fielloop/models/invoice_preview.dart';
import 'package:fielloop/models/job_estimate.dart';
import 'package:fielloop/providers/global_voice_service_provider.dart';
import 'package:fielloop/providers/invoice_provider.dart';
import 'package:fielloop/providers/job_estimate_provider.dart';
import 'package:fielloop/providers/jobs_provider.dart';
import 'package:fielloop/providers/payment_lock.dart';
import 'package:fielloop/screens/estimate_screen.dart';
import 'package:fielloop/screens/invoice_review_screen.dart';
import 'package:fielloop/screens/manual_change_order_screen.dart';
import 'package:fielloop/services/server_error_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Failed Lambda calls (estimate send, invoice send-sms, change-order
/// create) show the technician a plain sentence — the JSON `message`, a
/// short plain `error`, the "texting isn't set up" line, or the generic
/// sentence — never the raw response body.

const _jobId = 'job-1';

const _secretsRaw =
    '{"error":"Secrets Manager can\'t find the specified secret. (Service: SecretsManager, Status Code: 400)"}';

class _FakeVoice extends GlobalVoiceService {
  _FakeVoice(super.ref);

  @override
  Future<void> speak(String text) async {}

  @override
  void exitJobScope() {}

  @override
  Future<void> enterJobScope() async {}
}

String _read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  group('friendlyServerError', () {
    test('JSON with message -> the message', () {
      expect(
        friendlyServerError(
          '{"error":"This technician is not assigned to this job",'
          '"message":"You can only send estimates for jobs assigned to you."}',
          sms: true,
        ),
        'You can only send estimates for jobs assigned to you.',
      );
      // message wins even when the error mentions Secrets Manager
      expect(
        friendlyServerError('{"error":"Twilio credentials are not configured","message":"Texting is off."}', sms: true),
        'Texting is off.',
      );
    });

    test('JSON without message: a short plain error is shown as is', () {
      expect(friendlyServerError('{"error":"Payment started - invoice is locked"}'), kPaymentLockedMessage);
      expect(friendlyServerError('{"error":"No customer phone number on file"}', sms: true),
          'No customer phone number on file');
    });

    test('JSON without message: a long, JSON-looking or technical error -> generic', () {
      for (final body in [
        '{"error":"${'x' * 130}"}',
        '{"error":"{\\"code\\":\\"PGRST116\\"}"}',
        '{"error":"bad [thing]"}',
        '{"error":"duplicate key value violates unique constraint \\"x\\""}',
        '{"error":"TypeError: Cannot read properties of undefined (reading \'toFixed\')"}',
        '{"error":"boom at handler (/var/task/index.js:41:7)"}',
        '{"other":"no error field"}',
        '{"error":42}',
      ]) {
        expect(friendlyServerError(body), kGenericErrorMessage, reason: body);
      }
    });

    test('non-JSON and empty bodies -> generic, never the raw text', () {
      expect(friendlyServerError('<html>502 Bad Gateway</html>'), kGenericErrorMessage);
      expect(friendlyServerError('Internal Server Error'), kGenericErrorMessage);
      expect(friendlyServerError(''), kGenericErrorMessage);
      expect(friendlyServerError('[]'), kGenericErrorMessage);
    });

    test('SMS send: Secrets Manager / not configured -> the not-set-up sentence', () {
      expect(friendlyServerError(_secretsRaw, sms: true), kSmsNotConfiguredMessage);
      expect(friendlyServerError('{"error":"Twilio credentials are not configured"}', sms: true),
          kSmsNotConfiguredMessage);
      expect(friendlyServerError('SecretsManager timeout', sms: true), kSmsNotConfiguredMessage);
      expect(kSmsNotConfiguredMessage, "Texting isn't set up yet. Please contact support.");
    });

    test('not an SMS send: a Secrets Manager error is never shown, it is the generic sentence', () {
      expect(friendlyServerError(_secretsRaw), kGenericErrorMessage);
      expect(friendlyServerError('{"error":"Secrets Manager down"}'), kGenericErrorMessage);
    });
  });

  group('friendlyErrorText', () {
    test('StateError message as is; a plain database error; anything else generic', () {
      expect(friendlyErrorText(StateError('This customer has no phone number on file.')),
          'This customer has no phone number on file.');
      expect(friendlyErrorText(const PostgrestException(message: 'Payment started - invoice is locked')),
          kPaymentLockedMessage);
      expect(
        friendlyErrorText(const PostgrestException(message: 'new row violates row-level security policy for table')),
        kGenericErrorMessage,
      );
      expect(friendlyErrorText(Exception('{"error":"raw"}')), kGenericErrorMessage);
      expect(friendlyErrorText(const SocketException('Failed host lookup')), kGenericErrorMessage);
    });
  });

  group('callers', () {
    test('send/create errors are built with the helper; the log lines are unchanged', () {
      final estimate = _read('lib/providers/job_estimate_provider.dart');
      expect(estimate, contains("debugPrint('ESTIMATE ERROR (send): \${response.statusCode} \${response.body}');\n"
          '      throw StateError(friendlyServerError(response.body, sms: true));'));
      expect(estimate, contains('throw StateError(friendlyServerError(pdfResponse.body));'));
      expect(estimate, isNot(contains("'Sending the estimate failed (")));

      final invoice = _read('lib/providers/invoice_provider.dart');
      expect(invoice, contains("debugPrint('INVOICE ERROR (send-sms): \${response.statusCode} \${response.body}');\n"
          '    throw StateError(friendlyServerError(response.body, sms: true));'));
      expect(invoice, isNot(contains("'Sending the invoice failed (")));

      final changeOrder = _read('lib/providers/change_order_provider.dart');
      expect(changeOrder, contains("debugPrint('CHANGE ORDER ERROR (create): "
          "\${response.statusCode} \${response.body}');\n"
          '    throw StateError(friendlyServerError(response.body));'));
      expect(changeOrder, isNot(contains("'Saving the change order failed (")));

      final estimateScreen = _read('lib/screens/estimate_screen.dart');
      expect(estimateScreen, isNot(contains('_sendError = e is StateError ? e.message : e.toString();')));
      expect('_sendError = friendlyErrorText(e);'.allMatches(estimateScreen).length, 2);
      expect(_read('lib/screens/manual_change_order_screen.dart'), isNot(contains('e.toString()')));
    });
  });

  group('screens show the friendly text, not the raw body', () {
    testWidgets('Estimate screen: a 403 from send-estimate-sms shows its message', (tester) async {
      await _pumpEstimate(
        tester,
        sendError: StateError(friendlyServerError(
          '{"error":"This technician is not assigned to this job",'
          '"message":"You can only send estimates for jobs assigned to you."}',
          sms: true,
        )),
      );
      await _send(tester);
      expect(find.text('You can only send estimates for jobs assigned to you.'), findsOneWidget);
      expect(find.textContaining('{'), findsNothing);
      expect(find.textContaining('Sending the estimate failed'), findsNothing);
    });

    testWidgets('Estimate screen: missing Twilio secret shows the not-set-up sentence', (tester) async {
      await _pumpEstimate(tester, sendError: StateError(friendlyServerError(_secretsRaw, sms: true)));
      await _send(tester);
      expect(find.text(kSmsNotConfiguredMessage), findsOneWidget);
      expect(find.textContaining('Secrets Manager'), findsNothing);
    });

    testWidgets('Estimate screen: an unexpected exception shows the generic sentence', (tester) async {
      await _pumpEstimate(tester, sendError: Exception('{"error":"raw body"}'));
      await _send(tester);
      expect(find.text(kGenericErrorMessage), findsOneWidget);
      expect(find.textContaining('raw body'), findsNothing);
    });

    testWidgets('Invoice review: Secrets Manager failure shows the not-set-up sentence', (tester) async {
      await _pumpInvoice(tester, sms: () async => throw StateError(friendlyServerError(_secretsRaw, sms: true)));
      await tester.tap(find.text('Generate & Send Invoice'));
      await tester.pumpAndSettle();
      expect(find.text(kSmsNotConfiguredMessage), findsOneWidget);
      expect(find.textContaining('Secrets Manager'), findsNothing);
      expect(find.textContaining('Sending the invoice failed'), findsNothing);
      expect(find.text('Collect Payment'), findsOneWidget);
    });

    testWidgets('Invoice review: no phone on file shows that plain sentence', (tester) async {
      await _pumpInvoice(
        tester,
        sms: () async =>
            throw StateError(friendlyServerError('{"error":"No customer phone number on file"}', sms: true)),
      );
      await tester.tap(find.text('Generate & Send Invoice'));
      await tester.pumpAndSettle();
      expect(find.text('No customer phone number on file'), findsOneWidget);
      expect(find.textContaining('{'), findsNothing);
    });

    testWidgets('Manual change order: a failure that is not a StateError shows the generic sentence', (tester) async {
      // Unlocked, so the save goes past the lock check and fails on the
      // uninitialised Supabase client (not a StateError) in tests.
      paymentLockStatusFetch = (jobId) async => _latest('unpaid');
      addTearDown(() => paymentLockStatusFetch = fetchLatestInvoicePayment);
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            latestInvoicePaymentProvider.overrideWith((ref, jobId) => Future.value(_latest('unpaid'))),
            jobByIdProvider.overrideWith((ref, id) => null),
          ],
          child: const MaterialApp(home: ManualChangeOrderScreen(jobId: _jobId)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Description of the additional work'), 'New valve');
      await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '120');
      await tester.pump();
      await tester.tap(find.text('Save & Request Approval'));
      await tester.pump();
      await tester.pump();
      expect(find.text(kGenericErrorMessage), findsOneWidget);
    });
  });
}

LatestInvoicePayment _latest(String paymentStatus) => LatestInvoicePayment.fromResponse({
  'invoice': {'id': 'inv-1', 'invoice_number': 'INV-1', 'payment_status': paymentStatus, 'paid_at': null, 'total': 100},
})!;

class _FakeEstimate extends StateNotifier<AsyncValue<JobEstimate?>> implements JobEstimateController {
  _FakeEstimate(this.sendError)
    : super(
        AsyncData(
          JobEstimate.fromJson({
            'id': 'est-1',
            'job_id': _jobId,
            'status': 'draft',
            'total_amount': 80,
            'line_items': [
              {'description': 'Labor', 'amount': 80},
            ],
          }),
        ),
      );

  final Object sendError;

  @override
  Future<void> saveLineItems({
    required String estimateId,
    required List<EstimateLineItem> lineItems,
    required double totalAmount,
  }) async {}

  @override
  Future<String> sendToCustomer(String estimateId, {void Function(String status)? onStatus}) async => throw sendError;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _pumpEstimate(WidgetTester tester, {required Object sendError}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        globalVoiceServiceProvider.overrideWith(_FakeVoice.new),
        jobByIdProvider.overrideWith((ref, id) => null),
        latestInvoicePaymentProvider.overrideWith((ref, jobId) => Future.value(_latest('unpaid'))),
        jobEstimateProvider.overrideWith((ref, jobId) => _FakeEstimate(sendError)),
      ],
      child: const MaterialApp(home: EstimateScreen(jobId: _jobId)),
    ),
  );
  // EstimateScreen's voice indicator animates forever: no pumpAndSettle.
  await _settle(tester);
}

Future<void> _send(WidgetTester tester) async {
  await tester.tap(find.text('Looks good, send to customer'));
  await _settle(tester);
  await tester.tap(find.text('Send'));
  await _settle(tester);
}

InvoicePreview _preview() => InvoicePreview.fromJson({
  'estimate': {
    'id': 'est-1',
    'job_id': _jobId,
    'status': 'approved',
    'total_amount': 100,
    'line_items': [
      {'description': 'Work', 'amount': 100},
    ],
  },
  'approvedChangeOrders': <Object>[],
  'pendingChangeOrders': <Object>[],
  'voidedChangeOrders': <Object>[],
  'declinedChangeOrders': <Object>[],
  'adjustments': <Object>[],
  'estimateApproved': true,
  'grossTotal': 100,
  'feeRate': 0.0195,
  'feeAmount': 1.95,
  'netToContractor': 98.05,
});

Future<void> _pumpInvoice(WidgetTester tester, {required Future<void> Function() sms}) async {
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
          generateInvoice: ({required String jobId}) async =>
              const GeneratedInvoice(id: 'inv-1', pdfUrl: 'https://example.test/invoice.pdf'),
          sendSms: ({required String invoiceId, required String pdfUrl}) => sms(),
          fetchPaymentStatus: (jobId) async => null,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
