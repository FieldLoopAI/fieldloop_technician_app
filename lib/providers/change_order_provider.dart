import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';

/// Saves a change order via the `/change-orders/create` Lambda: the Lambda
/// itself extracts the dollar amount from the verbatim [description] (same
/// Groq extraction that used to be a separate `/change-orders/parse` call —
/// that route was never actually deployed, so this now happens server-side
/// in one round trip) and writes a `change_orders` row with status
/// `'pending'`. If Twilio is configured and the customer has a phone on
/// file, it also texts them an approval request (see
/// `backend/functions/create-change-order`). Returns whether that SMS
/// actually went out (`smsSent`) so the caller can speak an accurate
/// confirmation either way — the change order is saved successfully
/// regardless of `smsSent`. Throws on failure — callers decide what to tell
/// the technician (see `handleChangeOrderCommand` in
/// `job_voice_commands.dart`, and the manual change order form).
///
/// [amount] — set by the manual form only: a typed amount the Lambda uses
/// as-is instead of extracting one from [description] with Groq. Everything
/// else (pending status, customer approval SMS) is identical either way.
Future<bool> createChangeOrder({required String jobId, required String description, double? amount}) async {
  final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
  if (accessToken == null) {
    throw StateError('No active session — please sign in again.');
  }

  debugPrint('CHANGE ORDER: requesting /change-orders/create for job $jobId...');
  final response = await http.post(
    Uri.parse('$apiBaseUrl/change-orders/create'),
    headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
    body: jsonEncode({'jobId': jobId, 'description': description, 'amount': ?amount}),
  );
  if (response.statusCode != 200) {
    throw StateError('Saving the change order failed (${response.statusCode}): ${response.body}');
  }

  final decoded = jsonDecode(response.body) as Map<String, dynamic>;
  final smsSent = decoded['smsSent'] as bool? ?? false;
  debugPrint('CHANGE ORDER: change_orders insert succeeded for job $jobId (smsSent=$smsSent)');
  return smsSent;
}
