import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'build_identity.dart';
import 'providers/local_notifications_service.dart';
import 'screens/gemini_live_test_screen.dart' show kBuildLineFlags;
import 'services/b179_flags.dart';
import 'services/b180_flags.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  logBuildIdentity(flags: kBuildLineFlags);
  debugPrint(describeB179Flags());
  debugPrint(describeB180Flags());

  await Supabase.initialize(
    url: 'https://glpzohfzldvztseriwky.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdscHpvaGZ6bGR2enRzZXJpd2t5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ1Mjc2NDcsImV4cCI6MjEwMDEwMzY0N30.Pm5mXGAHvf7A-3FO1z4MIK8E-pj3YqAYenRUS64jPpA',
  );

  // Initialized here (before login even) rather than only when
  // GlobalNotificationService.start() runs, so a notification tap that
  // cold-launches the app — the app process was fully terminated — can
  // still be read back via LocalNotificationsService.consumeLaunchJobId()
  // (see SplashScreen) before the technician's session has even been
  // resolved. Safe to call this early: it only wires up the Android
  // channel + tap callback, it does not request any permission itself.
  await LocalNotificationsService.instance.initialize();

  runApp(const ProviderScope(child: FieldLoopApp()));
}
