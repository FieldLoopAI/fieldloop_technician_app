import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../models/invoice_adjustment.dart';
import '../models/invoice_payment.dart';
import '../models/invoice_preview.dart';

/// Fetches a read-only preview of what a job's invoice would look like via
/// the `/invoices/preview` Lambda — the estimate, every change order (split
/// by status), and the computed gross/fee/net totals. Never writes anything
/// (see `InvoicePreview`'s doc comment); only [generateInvoicePdf] actually
/// saves an `invoices` row. Throws — with a message written to be spoken/
/// shown directly to the technician — if there's no active session or the
/// Lambda call fails (including "no estimate found for this job", the
/// backend's own gate for a job with zero `job_estimates` rows).
Future<InvoicePreview> fetchInvoicePreview({required String jobId}) async {
  final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
  if (accessToken == null) {
    throw StateError('No active session — please sign in again.');
  }

  debugPrint('INVOICE: requesting /invoices/preview for job $jobId...');
  final response = await http.post(
    Uri.parse('$apiBaseUrl/invoices/preview'),
    headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
    body: jsonEncode({'jobId': jobId}),
  );
  if (response.statusCode != 200) {
    debugPrint('INVOICE ERROR (preview): ${response.statusCode} ${response.body}');
    throw StateError('Loading the invoice preview failed (${response.statusCode}): ${response.body}');
  }

  final decoded = jsonDecode(response.body) as Map<String, dynamic>;
  final preview = InvoicePreview.fromJson(decoded);
  debugPrint(
    'INVOICE: preview received for job $jobId (grossTotal=${preview.grossTotal}, '
    'pending=${preview.pendingChangeOrders.length})',
  );
  return preview;
}

/// A just-generated, saved invoice — the `invoices` row `/invoices/generate-pdf`
/// inserts, plus the branded PDF's signed URL. Only [id] and [pdfUrl] are
/// needed downstream (by [sendInvoiceSms]), so that's all this captures —
/// see `backend/functions/generate-invoice-pdf` for the full row shape.
class GeneratedInvoice {
  const GeneratedInvoice({required this.id, required this.pdfUrl});

  final String id;
  final String pdfUrl;
}

/// Actually saves the invoice (`invoices` row, `status = 'draft'`) and
/// generates the branded customer-facing PDF via the `/invoices/generate-pdf`
/// Lambda — unlike [fetchInvoicePreview], this is NOT idempotent: calling it
/// twice for the same job creates two separate `invoices` rows. Only ever
/// called once the technician has confirmed on `InvoiceReviewScreen`.
Future<GeneratedInvoice> generateInvoicePdf({required String jobId}) async {
  final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
  if (accessToken == null) {
    throw StateError('No active session — please sign in again.');
  }

  debugPrint('INVOICE: requesting /invoices/generate-pdf for job $jobId...');
  final response = await http.post(
    Uri.parse('$apiBaseUrl/invoices/generate-pdf'),
    headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
    body: jsonEncode({'jobId': jobId}),
  );
  if (response.statusCode != 200) {
    debugPrint('INVOICE ERROR (generate-pdf): ${response.statusCode} ${response.body}');
    throw StateError('Generating the invoice failed (${response.statusCode}): ${response.body}');
  }

  final decoded = jsonDecode(response.body) as Map<String, dynamic>;
  final invoice = decoded['invoice'] as Map<String, dynamic>?;
  final pdfUrl = decoded['pdfUrl'] as String?;
  final invoiceId = invoice?['id']?.toString();
  if (invoiceId == null || pdfUrl == null || pdfUrl.isEmpty) {
    throw StateError('Generating the invoice failed: response missing "invoice.id" or "pdfUrl".');
  }
  debugPrint('INVOICE: invoice $invoiceId generated for job $jobId');
  return GeneratedInvoice(id: invoiceId, pdfUrl: pdfUrl);
}

/// Texts the customer their invoice PDF and marks it `'sent'`, via the
/// `/invoices/send-sms` Lambda — same call shape as
/// `JobEstimateController.sendToCustomer`'s SMS step. Throws (including "no
/// customer phone number on file", the backend's own check) rather than
/// silently leaving the invoice un-sent.
Future<void> sendInvoiceSms({required String invoiceId, required String pdfUrl}) async {
  final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
  if (accessToken == null) {
    throw StateError('No active session — please sign in again.');
  }

  debugPrint('INVOICE: requesting /invoices/send-sms for invoice $invoiceId...');
  final response = await http.post(
    Uri.parse('$apiBaseUrl/invoices/send-sms'),
    headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
    body: jsonEncode({'invoiceId': invoiceId, 'pdfUrl': pdfUrl}),
  );
  if (response.statusCode != 200) {
    debugPrint('INVOICE ERROR (send-sms): ${response.statusCode} ${response.body}');
    throw StateError('Sending the invoice failed (${response.statusCode}): ${response.body}');
  }
  debugPrint('INVOICE: SMS send succeeded for invoice $invoiceId');
}

/// Adds a manual invoice line (a fee, or a discount when [amount] is
/// negative) — a direct `invoice_adjustments` insert, allowed for the job's
/// lead technician by RLS (see
/// `supabase/migrations/20260924000000_invoice_adjustments.sql`). The caller
/// re-fetches [fetchInvoicePreview] afterward, which is where the new line
/// and the updated totals come from.
Future<InvoiceAdjustment> addInvoiceAdjustment({
  required String jobId,
  required String description,
  required double amount,
}) async {
  debugPrint('INVOICE: adding manual adjustment for job $jobId ($description, $amount)...');
  final row = await Supabase.instance.client
      .from('invoice_adjustments')
      .insert({'job_id': jobId, 'description': description, 'amount': amount})
      .select()
      .single();
  return InvoiceAdjustment.fromJson(row);
}

/// Removes a manual invoice line added by [addInvoiceAdjustment].
Future<void> deleteInvoiceAdjustment(String adjustmentId) async {
  debugPrint('INVOICE: deleting manual adjustment $adjustmentId...');
  await Supabase.instance.client.from('invoice_adjustments').delete().eq('id', adjustmentId);
}

/// A job's manual invoice lines, for surfaces that don't hold a full
/// [InvoicePreview] (Job Detail's Invoice tab total). Invalidated by the
/// Invoice Review screen after every add/remove. Falls back to an empty list
/// if the read fails — e.g. before the `invoice_adjustments` migration is
/// applied — so the tab never breaks over an optional extra.
final jobInvoiceAdjustmentsProvider = FutureProvider.autoDispose.family<List<InvoiceAdjustment>, String>((
  ref,
  jobId,
) async {
  try {
    final rows = await Supabase.instance.client
        .from('invoice_adjustments')
        .select()
        .eq('job_id', jobId)
        .order('created_at', ascending: true);
    return rows.map(InvoiceAdjustment.fromJson).toList();
  } catch (e) {
    debugPrint('INVOICE: could not load manual adjustments for job $jobId ($e) — treating as none');
    return const [];
  }
});

// ===========================================================================
// BUILD 185 — Stripe test-mode payments (see `services/b185_flags.dart` and
// `backend/functions/invoice-payment`). The real counterpart of the mock
// `invoiceStatusProvider` in `estimate_invoice_providers.dart`, which stays
// as it is for the flag-off path and the mock InvoiceScreen.
// ===========================================================================

/// Creates (or reuses the open) Stripe Checkout session for [invoiceId] via
/// `/invoices/checkout`. The server freezes the invoice ('pending') before
/// replying. Throws with the server's message on any refusal.
Future<CheckoutSession> createCheckoutSession(String invoiceId) async {
  final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
  if (accessToken == null) {
    throw StateError('No active session — please sign in again.');
  }

  debugPrint('PAYMENT: requesting /invoices/checkout for invoice $invoiceId...');
  final response = await http.post(
    Uri.parse('$apiBaseUrl/invoices/checkout'),
    headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
    body: jsonEncode({'invoiceId': invoiceId}),
  );
  if (response.statusCode != 200) {
    debugPrint('PAYMENT ERROR (checkout): ${response.statusCode} ${response.body}');
    throw StateError('Starting the payment failed (${response.statusCode}): ${_serverError(response.body)}');
  }

  final decoded = jsonDecode(response.body) as Map<String, dynamic>;
  final url = decoded['url'] as String?;
  final sessionId = decoded['sessionId'] as String?;
  if (url == null || url.isEmpty || sessionId == null) {
    throw StateError('Starting the payment failed: response missing "url" or "sessionId".');
  }
  final amountCents = (decoded['amountCents'] as num?)?.toInt();
  final feeCents = (decoded['feeCents'] as num?)?.toInt();
  debugPrint(
    'PAYMENT: checkout ready for invoice $invoiceId amountCents=$amountCents feeCents=$feeCents '
    'session=…${sessionId.length > 6 ? sessionId.substring(sessionId.length - 6) : sessionId}',
  );
  return CheckoutSession(url: url, sessionId: sessionId, amountCents: amountCents, feeCents: feeCents);
}

/// The job's latest invoice and its payment status via
/// `/invoices/payment-status` (server-side ownership check, so no new RLS
/// is needed for the app). Null when the job has no invoice yet.
Future<LatestInvoicePayment?> fetchLatestInvoicePayment(String jobId) async {
  final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
  if (accessToken == null) {
    throw StateError('No active session — please sign in again.');
  }

  final response = await http.get(
    Uri.parse('$apiBaseUrl/invoices/payment-status').replace(queryParameters: {'jobId': jobId}),
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (response.statusCode != 200) {
    debugPrint('PAYMENT ERROR (payment-status): ${response.statusCode} ${response.body}');
    throw StateError('Loading the payment status failed (${response.statusCode}): ${_serverError(response.body)}');
  }
  final latest = LatestInvoicePayment.fromResponse(jsonDecode(response.body) as Map<String, dynamic>);
  debugPrint('PAYMENT: status for job $jobId -> invoice=${latest?.id} status=${latest?.status.name}');
  return latest;
}

/// Real latest-invoice payment status for a job. Invalidated by Invoice
/// Review whenever it re-reads the status.
final latestInvoicePaymentProvider = FutureProvider.autoDispose.family<LatestInvoicePayment?, String>(
  (ref, jobId) => fetchLatestInvoicePayment(jobId),
);

/// `{"error": "..."}` -> the message; anything else -> the raw body.
String _serverError(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['error'] is String) return decoded['error'] as String;
  } catch (_) {}
  return body;
}
