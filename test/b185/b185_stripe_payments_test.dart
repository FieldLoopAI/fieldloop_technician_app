import 'dart:io';

import 'package:fielloop/models/invoice_payment.dart';
import 'package:fielloop/services/b184_flags.dart';
import 'package:fielloop/services/b185_flags.dart';
import 'package:fielloop/services/checkout_voice_hold.dart';
import 'package:fielloop/widgets/invoice_payment_status_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  group('B185 flag', () {
    test('defaults ON and prints its own B185 FLAGS line', () {
      expect(kStripePayments, isTrue);
      expect(describeB185Flags(), 'B185 FLAGS: stripePayments=true');
    });

    test('B184 FLAGS line is unchanged', () {
      expect(
        describeB184Flags(),
        'B184 FLAGS: remarkQuickReply=true anotherOneCapture=true yesCaptureRouting=true localCloseConfirm5s=true',
      );
    });

    test('logged at app start right after the B184 line', () {
      expect(
        _read('lib/main.dart').contains('  debugPrint(describeB184Flags());\n  debugPrint(describeB185Flags());\n'),
        isTrue,
      );
    });

    test('logged at every session open right after the B184 line', () {
      expect(
        _read('lib/screens/gemini_live_test_screen.dart')
            .contains('      _log_(describeB184Flags());\n      _log_(describeB185Flags());\n'),
        isTrue,
      );
    });
  });

  group('payment status mapping', () {
    test('raw payment_status -> enum; unknown or missing is never paid', () {
      expect(parseInvoicePaymentStatus('unpaid'), InvoicePaymentStatus.unpaid);
      expect(parseInvoicePaymentStatus('pending'), InvoicePaymentStatus.pending);
      expect(parseInvoicePaymentStatus('paid'), InvoicePaymentStatus.paid);
      expect(parseInvoicePaymentStatus(null), InvoicePaymentStatus.unpaid);
      expect(parseInvoicePaymentStatus('PAID'), InvoicePaymentStatus.unpaid);
      expect(parseInvoicePaymentStatus('sent'), InvoicePaymentStatus.unpaid);
    });

    test('labels', () {
      expect(invoicePaymentStatusLabel(InvoicePaymentStatus.unpaid), 'Unpaid');
      expect(invoicePaymentStatusLabel(InvoicePaymentStatus.pending), 'Pending');
      expect(invoicePaymentStatusLabel(InvoicePaymentStatus.paid), 'Paid');
    });

    test('/invoices/payment-status response parsing', () {
      final latest = LatestInvoicePayment.fromResponse({
        'invoice': {
          'id': 'inv-1',
          'invoice_number': 'INV-12345678',
          'payment_status': 'paid',
          'paid_at': '2026-10-22T10:00:00.000Z',
          'total': '3619.00',
        },
      })!;
      expect(latest.id, 'inv-1');
      expect(latest.invoiceNumber, 'INV-12345678');
      expect(latest.status, InvoicePaymentStatus.paid);
      expect(latest.paidAt, DateTime.utc(2026, 10, 22, 10));
      expect(latest.total, 3619.0);
      expect(LatestInvoicePayment.fromResponse({'invoice': null}), isNull);
      expect(
        LatestInvoicePayment.fromResponse({
          'invoice': {'id': 'inv-2', 'invoice_number': null, 'payment_status': null, 'paid_at': null, 'total': 10},
        })!.status,
        InvoicePaymentStatus.unpaid,
      );
    });

    test('frozen = pending or paid', () {
      expect(isInvoicePaymentFrozen(null), isFalse);
      expect(isInvoicePaymentFrozen(InvoicePaymentStatus.unpaid), isFalse);
      expect(isInvoicePaymentFrozen(InvoicePaymentStatus.pending), isTrue);
      expect(isInvoicePaymentFrozen(InvoicePaymentStatus.paid), isTrue);
    });
  });

  group('Invoice Review visibility', () {
    test('Collect Payment: needs the flag and an invoice id; hidden once paid', () {
      for (final status in [null, InvoicePaymentStatus.unpaid, InvoicePaymentStatus.pending]) {
        expect(showCollectPaymentButton(enabled: true, invoiceId: 'inv-1', status: status), isTrue, reason: '$status');
      }
      expect(showCollectPaymentButton(enabled: true, invoiceId: 'inv-1', status: InvoicePaymentStatus.paid), isFalse);
      expect(showCollectPaymentButton(enabled: true, invoiceId: null, status: InvoicePaymentStatus.unpaid), isFalse);
      expect(showCollectPaymentButton(enabled: false, invoiceId: 'inv-1', status: InvoicePaymentStatus.unpaid), isFalse);
    });

    test('adjustments locked: existing rules kept, plus pending/paid', () {
      bool locked({bool enabled = true, bool sent = false, bool generating = false, bool updating = false, InvoicePaymentStatus? status}) =>
          adjustmentsLocked(enabled: enabled, sent: sent, generating: generating, updatingAdjustments: updating, status: status);
      expect(locked(), isFalse);
      expect(locked(sent: true), isTrue);
      expect(locked(generating: true), isTrue);
      expect(locked(updating: true), isTrue);
      expect(locked(status: InvoicePaymentStatus.unpaid), isFalse);
      expect(locked(status: InvoicePaymentStatus.pending), isTrue);
      expect(locked(status: InvoicePaymentStatus.paid), isTrue);
      // Flag off: build 184 behavior.
      expect(locked(enabled: false, status: InvoicePaymentStatus.paid), isFalse);
      expect(locked(enabled: false, sent: true), isTrue);
    });

    test('internal fee/net section hidden only while pending or paid', () {
      expect(showInternalFeeSection(enabled: true, status: null), isTrue);
      expect(showInternalFeeSection(enabled: true, status: InvoicePaymentStatus.unpaid), isTrue);
      expect(showInternalFeeSection(enabled: true, status: InvoicePaymentStatus.pending), isFalse);
      expect(showInternalFeeSection(enabled: true, status: InvoicePaymentStatus.paid), isFalse);
      expect(showInternalFeeSection(enabled: false, status: InvoicePaymentStatus.paid), isTrue);
    });

    test('Generate & Send hidden once payment started', () {
      expect(showGenerateButton(enabled: true, status: null), isTrue);
      expect(showGenerateButton(enabled: true, status: InvoicePaymentStatus.unpaid), isTrue);
      expect(showGenerateButton(enabled: true, status: InvoicePaymentStatus.pending), isFalse);
      expect(showGenerateButton(enabled: true, status: InvoicePaymentStatus.paid), isFalse);
      expect(showGenerateButton(enabled: false, status: InvoicePaymentStatus.paid), isTrue);
    });
  });

  group('status chip', () {
    for (final status in InvoicePaymentStatus.values) {
      testWidgets('renders ${status.name}', (tester) async {
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: InvoicePaymentStatusChip(status: status))));
        expect(find.text(invoicePaymentStatusLabel(status)), findsOneWidget);
      });
    }
  });

  group('checkout voice hold', () {
    late List<String> calls;
    CheckoutVoiceHold make() => CheckoutVoiceHold(
      stopVoice: () => calls.add('exitJobScope'),
      resumeVoice: () async => calls.add('enterJobScope'),
      log: (_) {},
    );
    setUp(() => calls = []);

    test('hold always stops voice; release resumes an eligible job', () async {
      final hold = make();
      hold.hold(jobId: 'j', voiceEligible: true);
      expect(hold.isHeld, isTrue);
      expect(calls, ['exitJobScope']);
      await hold.release(jobId: 'j', reason: 'app_resumed', stillEligible: true);
      expect(hold.isHeld, isFalse);
      expect(calls, ['exitJobScope', 'enterJobScope']);
    });

    test('a read-only (completed) job stays silent after release', () async {
      final hold = make();
      hold.hold(jobId: 'j', voiceEligible: false);
      await hold.release(jobId: 'j', reason: 'app_resumed', stillEligible: true);
      expect(calls, ['exitJobScope']);
    });

    test('a job that went read-only while held stays silent', () async {
      final hold = make();
      hold.hold(jobId: 'j', voiceEligible: true);
      await hold.release(jobId: 'j', reason: 'app_resumed', stillEligible: false);
      expect(calls, ['exitJobScope']);
    });

    test('hold and release are idempotent', () async {
      final hold = make();
      hold.hold(jobId: 'j', voiceEligible: true);
      hold.hold(jobId: 'j', voiceEligible: true);
      await hold.release(jobId: 'j', reason: 'a', stillEligible: true);
      await hold.release(jobId: 'j', reason: 'b', stillEligible: true);
      expect(calls, ['exitJobScope', 'enterJobScope']);
    });

    test('Invoice Review holds with the existing voice-scope pair, before launching Checkout', () {
      final src = _read('lib/screens/invoice_review_screen.dart');
      expect(src.contains('stopVoice: _voiceService.exitJobScope,'), isTrue);
      expect(src.contains('resumeVoice: _voiceService.enterJobScope,'), isTrue);
      final holdAt = src.indexOf('_voiceHold.hold(');
      final launchAt = src.indexOf('await launchUrl(');
      expect(holdAt, greaterThan(0));
      expect(launchAt, greaterThan(holdAt));
    });
  });

  group('untouched surfaces', () {
    test('mock InvoiceScreen and its simulate button are left as they were', () {
      final src = _read('lib/screens/invoice_screen.dart');
      expect(src.contains("TextButton(onPressed: _simulatePayment, child: const Text('Simulate payment received (demo)'))"), isTrue);
      expect(src.contains('b185'), isFalse);
    });

    test('Job Detail keeps the mock badge for the flag-off path', () {
      final src = _read('lib/screens/job_detail_screen.dart');
      expect(src.contains('final invoiceStatus = ref.watch(invoiceStatusProvider(widget.jobId));'), isTrue);
      expect(src.contains(': _InvoiceStatusBadge(status: invoiceStatus),'), isTrue);
      expect(src.contains('? _RealPaymentStatusBadge(jobId: job.id)'), isTrue);
    });
  });
}
