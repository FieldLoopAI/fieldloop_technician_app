import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/permission_providers.dart';
import 'screens/login_screen.dart';
import 'theme/app_theme.dart';

class FieldLoopApp extends ConsumerStatefulWidget {
  const FieldLoopApp({super.key});

  @override
  ConsumerState<FieldLoopApp> createState() => _FieldLoopAppState();
}

class _FieldLoopAppState extends ConsumerState<FieldLoopApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check permission status whenever the app resumes — most commonly
    // after the technician has been sent to the OS Settings app to flip a
    // permanently-denied permission on, so the UI unblocks itself without
    // needing a manual retry tap.
    if (state == AppLifecycleState.resumed) {
      ref.read(cameraMicProvider.notifier).refresh();
      ref.read(locationProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FieldLoop AI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const LoginScreen(),
    );
  }
}
