import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Shown when a failed call gives nothing safe to show the technician.
const kGenericErrorMessage = 'Something went wrong. Please try again.';

/// Shown when an SMS send fails because texting (Twilio / Secrets Manager)
/// isn't configured.
const kSmsNotConfiguredMessage = "Texting isn't set up yet. Please contact support.";

/// The text to show the technician for a failed Lambda call's [body] — never
/// the raw body (callers log that themselves, under their own tags):
///  1. the JSON `message` field, when present (the Lambdas' plain sentence);
///  2. for an SMS send ([sms]), [kSmsNotConfiguredMessage] when the body
///     mentions Secrets Manager or "not configured";
///  3. the JSON `error` field, only when it is a short plain sentence (see
///     [isPlainErrorSentence]);
///  4. otherwise [kGenericErrorMessage].
String friendlyServerError(String body, {bool sms = false}) {
  Map<dynamic, dynamic>? decoded;
  try {
    final value = jsonDecode(body);
    if (value is Map) decoded = value;
  } catch (_) {}

  final message = decoded?['message'];
  if (message is String && message.trim().isNotEmpty) return message.trim();
  if (sms && _notConfigured.hasMatch(body)) return kSmsNotConfiguredMessage;
  final error = decoded?['error'];
  if (error is String && isPlainErrorSentence(error)) return error.trim();
  return kGenericErrorMessage;
}

/// The text to show for an exception caught around one of those calls: a
/// [StateError]'s message is already written for the technician; a
/// database error's message only if it is a plain sentence (e.g. the
/// payment-lock trigger's "Payment started - invoice is locked"); anything
/// else is [kGenericErrorMessage].
String friendlyErrorText(Object error) {
  if (error is StateError) return error.message;
  if (error is PostgrestException && isPlainErrorSentence(error.message)) return error.message.trim();
  return kGenericErrorMessage;
}

/// A short, one-line sentence with nothing technical in it: under 120
/// characters, no braces/brackets, no stack-trace or SQL words, and no
/// mention of Secrets Manager or missing configuration.
bool isPlainErrorSentence(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.length >= 120) return false;
  if (trimmed.contains(RegExp(r'[{}\[\]\n\r]'))) return false;
  if (_technical.hasMatch(trimmed) || _notConfigured.hasMatch(trimmed)) return false;
  return true;
}

final _notConfigured = RegExp(r'secrets\s*manager|not configured', caseSensitive: false);

final _technical = RegExp(
  r'\b(stack|trace|traceback|exception|typeerror|referenceerror|syntaxerror|undefined|unexpected token|'
  r'select|insert into|violates|constraint|relation|column|sqlstate|pgrst\w*|duplicate key|syntax)\b'
  r'|\bat\s+\S+\s*\(|\.js:\d|\.dart:\d',
  caseSensitive: false,
);
