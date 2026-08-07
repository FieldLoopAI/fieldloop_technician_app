import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/mock_technician.dart';

final authControllerProvider = AsyncNotifierProvider<AuthController, MockTechnician?>(
  AuthController.new,
);

/// Holds the currently signed-in technician (or `null` when signed out).
///
/// Signs in with Supabase Auth, then looks up the matching row in the
/// `technicians` table (by `auth_user_id`). If the authenticated user has no
/// technician row, they're signed back out and treated as a login failure.
class AuthController extends AsyncNotifier<MockTechnician?> {
  @override
  FutureOr<MockTechnician?> build() => null;

  /// [identifier] may be either a phone number or an email address — both
  /// are valid technician sign-in identifiers against the same backend.
  Future<void> login({required String identifier, required String password}) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final supabase = Supabase.instance.client;

      final isEmail = identifier.contains('@');
      debugPrint('LOGIN: calling auth.signInWithPassword (identifier is ${isEmail ? 'email' : 'phone'})...');
      final authResponse = await supabase.auth.signInWithPassword(
        email: isEmail ? identifier : null,
        phone: isEmail ? null : identifier,
        password: password,
      );
      debugPrint('LOGIN: auth.signInWithPassword succeeded (user id: ${authResponse.user?.id})');
      final userId = authResponse.user!.id;

      debugPrint('LOGIN: querying technicians table for auth_user_id=$userId...');
      final row = await supabase
          .from('technicians')
          .select()
          .eq('auth_user_id', userId)
          .maybeSingle();
      debugPrint(
        'LOGIN: technicians query finished (${row == null ? 'no matching row' : 'found a row'})',
      );

      if (row == null) {
        await supabase.auth.signOut();
        throw StateError('This account is not registered as a technician.');
      }

      return MockTechnician.fromMap(row);
    });
  }

  void logout() {
    Supabase.instance.client.auth.signOut();
    state = const AsyncData(null);
  }
}
