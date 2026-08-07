import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../config/env.dart';

final completeSetupControllerProvider =
    AsyncNotifierProvider<CompleteSetupController, bool>(CompleteSetupController.new);

/// Redeems a technician's first-time setup token and sets their password.
///
/// This is the one unauthenticated backend call in the app — the technician
/// has no session yet at this point, so no `Authorization` header is sent.
/// Every failure case (invalid, expired, already-used, or deactivated token)
/// comes back from the backend as the same generic error message, which is
/// surfaced to the UI as-is rather than being reinterpreted here.
class CompleteSetupController extends AsyncNotifier<bool> {
  @override
  FutureOr<bool> build() => false;

  Future<void> completeSetup({required String token, required String newPassword}) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      debugPrint('SETUP: submitting complete-setup request');
      final response = await http.post(
        Uri.parse('$apiBaseUrl/technicians/complete-setup'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': token, 'new_password': newPassword}),
      );

      Map<String, dynamic> decoded;
      try {
        decoded = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        decoded = const {};
      }

      if (response.statusCode != 200 || decoded['success'] != true) {
        final message =
            (decoded['error'] as String?) ?? 'This setup link is invalid or has expired.';
        throw StateError(message);
      }

      debugPrint('SETUP: complete-setup succeeded');
      return true;
    });
  }
}
