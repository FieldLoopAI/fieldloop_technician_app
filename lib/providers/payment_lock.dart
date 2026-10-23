import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/invoice_payment.dart';
import '../services/b185_flags.dart';
import 'invoice_provider.dart';

/// Build 185 money freeze — once a job's payment is pending or paid, the
/// estimate, its change orders and invoice adjustments can't be created,
/// changed or removed (see [jobMoneyLocked]). Photos, notes, time on site and
/// job status steps never come through here.
///
/// The status source is the one Invoice Review already reads,
/// `/invoices/payment-status` ([fetchLatestInvoicePayment] /
/// [latestInvoicePaymentProvider]); nothing here polls.

/// The status read [ensureJobMoneyUnlocked] uses; replaceable only by tests.
@visibleForTesting
Future<LatestInvoicePayment?> Function(String jobId) paymentLockStatusFetch = fetchLatestInvoicePayment;

/// Throws a [StateError] (the message is shown/handled by each caller's
/// existing error path) when a money write must not run: the payment is
/// pending or paid, or its status couldn't be read. Flag off: never throws
/// and reads nothing.
Future<void> ensureJobMoneyUnlocked(String jobId, {bool enabled = kStripePayments}) async {
  if (!enabled) return;
  final LatestInvoicePayment? latest;
  try {
    latest = await paymentLockStatusFetch(jobId);
  } on StateError {
    // Already written for the technician (e.g. "No active session — please
    // sign in again.").
    rethrow;
  } catch (e) {
    debugPrint('PAYMENT LOCK: status read failed for job $jobId — money write refused ($e)');
    throw StateError(kPaymentStatusUncheckedMessage);
  }
  if (isInvoicePaymentFrozen(latest?.status)) {
    debugPrint('PAYMENT LOCK: job $jobId payment is ${latest?.status.name} — money write refused');
    throw StateError(kPaymentLockedMessage);
  }
}

/// [latestInvoicePaymentProvider]'s state -> [jobMoneyLocked], for screens
/// that disable their money actions.
bool watchJobMoneyLocked(WidgetRef ref, String jobId, {bool enabled = kStripePayments}) {
  if (!enabled) return false;
  final async = ref.watch(latestInvoicePaymentProvider(jobId));
  return jobMoneyLocked(
    enabled: true,
    load: async.hasError
        ? PaymentStatusLoad.failed
        : async.hasValue
        ? PaymentStatusLoad.loaded
        : PaymentStatusLoad.loading,
    status: async.valueOrNull?.status,
  );
}

/// The plain reason shown under the disabled actions, or null while the
/// status is still loading.
String? jobMoneyLockReason(WidgetRef ref, String jobId) {
  final async = ref.watch(latestInvoicePaymentProvider(jobId));
  if (async.hasError) return kPaymentStatusUncheckedMessage;
  if (isInvoicePaymentFrozen(async.valueOrNull?.status)) return kPaymentLockedMessage;
  return null;
}
