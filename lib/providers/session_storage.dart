import 'package:shared_preferences/shared_preferences.dart';

/// How long a persisted Supabase session may be reused without forcing a
/// fresh login — see [getLastLoginAt].
const sessionReloginInterval = Duration(days: 3);

const _lastLoginAtKey = 'last_login_at';

/// Records "now" as the last successful login time. Called whenever
/// [AuthController.login] produces a session, so the startup gate can later
/// decide whether that session is still within the 3-day re-login window.
Future<void> saveLastLoginAt() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_lastLoginAtKey, DateTime.now().toIso8601String());
}

/// Returns null if the technician has never logged in on this device, or if
/// the stored value is unreadable — both are treated as "re-login required"
/// by the startup gate.
Future<DateTime?> getLastLoginAt() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_lastLoginAtKey);
  if (raw == null) return null;
  return DateTime.tryParse(raw);
}

/// Cleared on manual logout so a signed-out technician always hits
/// LoginScreen next launch, independent of the 3-day window.
Future<void> clearLastLoginAt() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_lastLoginAtKey);
}
