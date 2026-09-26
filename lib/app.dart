import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/global_voice_service_provider.dart';
import 'providers/permission_providers.dart';
import 'routing/app_navigator_key.dart';
import 'routing/voice_route_observer.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';
import 'widgets/dictation_confirmation_bar.dart';
import 'widgets/voice_interaction_overlay.dart';

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
    // Drops the pre-fetched Gemini token while backgrounded, re-fetches on
    // return — see GlobalVoiceService.onAppLifecycleChanged.
    ref.read(globalVoiceServiceProvider.notifier).onAppLifecycleChanged(state);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FieldLoop AI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [voiceRouteObserver],
      // FIX 2 (dictation confirm/redo) — the tap fallback for the
      // confirm/redo step is stacked above the navigator here, not inside
      // any one screen, since prepare_estimate/site_condition can be
      // triggered from several different screens with no navigation
      // involved. Renders nothing (SizedBox.shrink) whenever no
      // confirmation is pending, so this is a no-op everywhere else in the
      // app, including before login.
      builder: (context, child) => Stack(
        children: [
          ?child,
          // Below DictationConfirmationBar so its Confirm/Redo tap
          // fallback stays reachable even while this modal's scrim is up
          // (captureConfirmation()'s `listening` phase is exactly when
          // both are simultaneously active).
          const VoiceInteractionOverlay(),
          const DictationConfirmationBar(),
        ],
      ),
      home: const SplashScreen(),
    );
  }
}
