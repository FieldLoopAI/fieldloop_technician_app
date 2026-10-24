import 'dart:io';

import 'package:fielloop/models/invoice_payment.dart';
import 'package:fielloop/providers/change_order_provider.dart';
import 'package:fielloop/providers/global_voice_service_provider.dart';
import 'package:fielloop/providers/job_dictations_provider.dart';
import 'package:fielloop/providers/job_voice_commands.dart';
import 'package:fielloop/providers/payment_lock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 185 money freeze: once the job's payment is pending or paid, the
/// estimate, change orders and invoice adjustments can't be written. Photos,
/// notes and time on site are untouched.

const _jobId = 'job-1';

String _read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

LatestInvoicePayment? _latest(String? paymentStatus) => paymentStatus == null
    ? null
    : LatestInvoicePayment.fromResponse({
        'invoice': {'id': 'inv-1', 'invoice_number': 'INV-1', 'payment_status': paymentStatus, 'paid_at': null, 'total': 100},
      });

/// Replaces the status read for one test.
void _useStatus(String? paymentStatus) {
  paymentLockStatusFetch = (jobId) async => _latest(paymentStatus);
  addTearDown(() => paymentLockStatusFetch = fetchLatestInvoicePaymentForTests);
}

// The real fetch, restored after each test.
final fetchLatestInvoicePaymentForTests = paymentLockStatusFetch;

Matcher _throwsMessage(String message) =>
    throwsA(isA<StateError>().having((e) => e.message, 'message', message));

class _FakeVoice extends GlobalVoiceService {
  _FakeVoice(super.ref);

  final spoken = <String>[];

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<String> captureDictation({Duration? settleWindow, String handlerTag = 'dictation'}) async =>
      'Replace the valve, 120 dollars';

  @override
  Future<ConfirmationOutcome> captureConfirmation({required String transcriptForDisplay}) async =>
      ConfirmationOutcome.confirmed;

  @override
  void markProcessing() {}
}

/// Runs the voice change_order command with a fake voice service and
/// returns what was spoken plus the VOICE ERROR log line.
Future<({List<String> spoken, String errorLog})> _voiceChangeOrder(WidgetTester tester) async {
  late WidgetRef widgetRef;
  late _FakeVoice voice;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [globalVoiceServiceProvider.overrideWith((ref) => voice = _FakeVoice(ref))],
      child: Consumer(
        builder: (context, ref, _) {
          widgetRef = ref;
          return const SizedBox();
        },
      ),
    ),
  );
  final logs = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
  try {
    await tester.runAsync(() => handleChangeOrderCommand(ref: widgetRef, jobId: _jobId));
  } finally {
    debugPrint = original;
  }
  return (spoken: voice.spoken, errorLog: logs.firstWhere((l) => l.startsWith('VOICE ERROR'), orElse: () => ''));
}

void main() {
  group('the lock rule (mirrors adjustmentsLocked)', () {
    bool locked(String? status, {PaymentStatusLoad load = PaymentStatusLoad.loaded, bool enabled = true}) =>
        jobMoneyLocked(enabled: enabled, load: load, status: _latest(status)?.status);

    test('pending (session open) and paid lock', () {
      expect(locked('pending'), isTrue);
      expect(locked('paid'), isTrue);
    });

    test('pending session expired -> the webhook resets it to unpaid -> unlocked', () {
      expect(locked('unpaid'), isFalse);
    });

    test('unpaid and no invoice at all are unlocked', () {
      expect(locked('unpaid'), isFalse);
      expect(locked(null), isFalse);
    });

    test('any other stored status (invoices have no void column; e.g. "voided") reads as unpaid -> unlocked', () {
      expect(locked('voided'), isFalse);
    });

    test('status still loading or unreadable -> locked, as in adjustmentsLocked', () {
      expect(locked('unpaid', load: PaymentStatusLoad.loading), isTrue);
      expect(locked(null, load: PaymentStatusLoad.failed), isTrue);
      for (final status in ['pending', 'paid', 'unpaid', null]) {
        for (final load in PaymentStatusLoad.values) {
          expect(
            jobMoneyLocked(enabled: true, load: load, status: _latest(status)?.status),
            adjustmentsLocked(
              enabled: true,
              sent: false,
              generating: false,
              updatingAdjustments: false,
              status: _latest(status)?.status,
              load: load,
            ),
            reason: '$status/$load',
          );
        }
      }
    });

    test('flag off: never locked', () {
      expect(locked('paid', enabled: false), isFalse);
      expect(locked(null, load: PaymentStatusLoad.failed, enabled: false), isFalse);
    });
  });

  group('ensureJobMoneyUnlocked', () {
    test('pending or paid -> refused with the plain reason', () async {
      for (final status in ['pending', 'paid']) {
        _useStatus(status);
        await expectLater(ensureJobMoneyUnlocked(_jobId, enabled: true), _throwsMessage(kPaymentLockedMessage));
      }
    });

    test('unpaid or no invoice -> allowed', () async {
      for (final status in ['unpaid', null]) {
        _useStatus(status);
        await ensureJobMoneyUnlocked(_jobId, enabled: true);
      }
    });

    test('status read fails -> refused; a StateError keeps its own message', () async {
      paymentLockStatusFetch = (_) async => throw const SocketException('offline');
      addTearDown(() => paymentLockStatusFetch = fetchLatestInvoicePaymentForTests);
      await expectLater(ensureJobMoneyUnlocked(_jobId, enabled: true), _throwsMessage(kPaymentStatusUncheckedMessage));
      paymentLockStatusFetch = (_) async => throw StateError('No active session — please sign in again.');
      await expectLater(
        ensureJobMoneyUnlocked(_jobId, enabled: true),
        _throwsMessage('No active session — please sign in again.'),
      );
    });

    test('flag off: reads nothing, never refuses', () async {
      var calls = 0;
      paymentLockStatusFetch = (_) async {
        calls++;
        return _latest('paid');
      };
      addTearDown(() => paymentLockStatusFetch = fetchLatestInvoicePaymentForTests);
      await ensureJobMoneyUnlocked(_jobId, enabled: false);
      expect(calls, 0);
    });
  });

  group('blocked app writes', () {
    test('createChangeOrder (voice, Job Detail tap and manual form) is refused before any network call', () async {
      _useStatus('paid');
      await expectLater(createChangeOrder(jobId: _jobId, description: 'x', amount: 10), _throwsMessage(kPaymentLockedMessage));
    });

    test('createChangeOrder passes the lock when unpaid (then reaches its usual network step)', () async {
      _useStatus('unpaid');
      Object? error;
      try {
        await createChangeOrder(jobId: _jobId, description: 'x', amount: 10);
      } catch (e) {
        error = e;
      }
      // No Supabase in tests: it fails at the session lookup, after the lock.
      expect(error, isNotNull);
      expect(error is StateError && error.message == kPaymentLockedMessage, isFalse);
    });

    test('every estimate / change-order write method checks the lock first', () {
      final estimate = _read('lib/providers/job_estimate_provider.dart');
      for (final signature in [
        'Future<void> createManual(List<EstimateLineItem> lineItems) async {\n    await ensureJobMoneyUnlocked(jobId);',
        '    required double totalAmount,\n  }) async {\n    await ensureJobMoneyUnlocked(jobId);',
        'Future<String> sendToCustomer(String estimateId, {void Function(String status)? onStatus}) async {\n'
            '    await ensureJobMoneyUnlocked(jobId);',
        'Future<void> voidEstimate({required String estimateId, required String reason}) async {\n'
            '    await ensureJobMoneyUnlocked(jobId);',
        'final result = await AsyncValue.guard(() async {\n      await ensureJobMoneyUnlocked(jobId);\n'
            '      return _parse(dictationId);',
      ]) {
        expect(estimate.contains(signature), isTrue, reason: signature);
      }
      final changeOrders = _read('lib/providers/job_change_orders_provider.dart');
      for (final signature in [
        '    required double additionalAmount,\n  }) async {\n    await ensureJobMoneyUnlocked(jobId);',
        'Future<void> voidChangeOrder({required String changeOrderId, required String reason}) async {\n'
            '    await ensureJobMoneyUnlocked(jobId);',
      ]) {
        expect(changeOrders.contains(signature), isTrue, reason: signature);
      }
      expect(
        _read('lib/providers/change_order_provider.dart').contains(
          'double? amount}) async {\n  await ensureJobMoneyUnlocked(jobId);',
        ),
        isTrue,
      );
    });

    test('Estimate and Change Orders screens disable their money actions with the plain reason', () {
      expect(kPaymentLockedMessage, 'Payment started - invoice is locked');
      final estimateScreen = _read('lib/screens/estimate_screen.dart');
      for (final guarded in [
        'onAction: editable && !_moneyLocked',
        'onPressed: _moneyLocked ? null : _addLineItem',
        'onPressed: (_savingDraft || _moneyLocked || problem != null)',
        'onPressed: (_sending || _savingDraft || _moneyLocked || problem != null)',
        'onPressed: locked ? null : () => _removeLineItem(item)',
        'onPressed: _moneyLocked ? null : _createNewEstimate',
        'onPressed: _moneyLocked ? null : _startVoiding',
        'onPressed: (_voiding || !canConfirm || _moneyLocked) ? null',
      ]) {
        expect(estimateScreen.contains(guarded), isTrue, reason: guarded);
      }
      final changeOrdersScreen = _read('lib/screens/change_orders_screen.dart');
      for (final guarded in [
        'onAction: editable && !_moneyLocked ? _addChangeOrderManually : null',
        'onPressed: _moneyLocked ? null : _addChangeOrderManually',
        'onPressed: _moneyLocked ? null : () => _saveChangeOrder(changeOrder)',
        'onPressed: (isSaving || _moneyLocked) ? null : () => _startVoiding(changeOrder.id)',
        'onPressed: (isSaving || !canConfirm || _moneyLocked) ? null',
      ]) {
        expect(changeOrdersScreen.contains(guarded), isTrue, reason: guarded);
      }
    });
  });

  group('allowed writes never consult the lock', () {
    test('notes / site conditions (job_dictations) are not gated', () async {
      var calls = 0;
      paymentLockStatusFetch = (_) async {
        calls++;
        return _latest('paid');
      };
      addTearDown(() => paymentLockStatusFetch = fetchLatestInvoicePaymentForTests);
      Object? error;
      try {
        await insertJobDictation(
          jobId: _jobId,
          technicianId: 'tech-1',
          commandType: DictationCommandType.siteCondition,
          transcript: 'Water damage under the sink',
        );
      } catch (e) {
        error = e;
      }
      expect(calls, 0);
      expect(error is StateError && error.message == kPaymentLockedMessage, isFalse);
    });

    test('photos, notes, arrival/time and job completion code has no lock check', () {
      for (final path in [
        'lib/providers/job_dictations_provider.dart',
        'lib/providers/job_photos_provider.dart',
        'lib/providers/arrival_provider.dart',
        'lib/providers/job_complete_provider.dart',
        'lib/providers/job_runtime_provider.dart',
      ]) {
        expect(_read(path).contains('ensureJobMoneyUnlocked'), isFalse, reason: path);
      }
    });
  });

  group('voice change_order', () {
    testWidgets('locked: the existing "couldn\'t save" line, nothing new spoken', (tester) async {
      _useStatus('pending');
      final result = await _voiceChangeOrder(tester);
      expect(result.spoken.last, "Sorry, I couldn't save that change order");
      expect(result.spoken.where((s) => s.contains('locked')), isEmpty);
      expect(result.errorLog, contains(kPaymentLockedMessage));
    });

    testWidgets('unlocked: passes the lock and reaches the save (no network in tests)', (tester) async {
      _useStatus('unpaid');
      final result = await _voiceChangeOrder(tester);
      expect(result.errorLog, isNot(contains(kPaymentLockedMessage)));
      expect(result.spoken.first, 'Go ahead, describe the additional work and price');
    });
  });
}
