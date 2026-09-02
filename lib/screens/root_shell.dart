import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/global_notification_service.dart';
import '../providers/global_voice_service_provider.dart';
import '../providers/jobs_provider.dart';
import '../providers/offline_upload_queue_provider.dart';
import '../providers/permission_providers.dart';
import '../providers/visit_tracking_service.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'profile_screen.dart';

/// Persistent bottom navigation shell shown after login. Job detail, voice,
/// and capture screens push on top of this (full screen, with a back
/// button) rather than living inside a tab.
///
/// This is also the single place the app-wide voice engine is started —
/// `RootShell` wraps the entire authenticated app and persists across every
/// screen navigation, so starting it here (once, the moment microphone
/// permission is confirmed granted) guarantees exactly one
/// `SpeechToText`/`FlutterTts` pair exists for the whole session. Screens
/// pushed on top never start/stop it themselves — see
/// `VoiceCommandRegistrarMixin`.
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  int _selectedIndex = 0;
  bool _voiceInitialized = false;
  bool _offlineQueueStarted = false;
  bool _notificationsStarted = false;
  bool _visitEventQueueStarted = false;

  static const _tabs = [HomeScreen(), HistoryScreen(), ProfileScreen()];
  static const _historyTabIndex = 1;

  @override
  Widget build(BuildContext context) {
    final cameraMic = ref.watch(cameraMicProvider);
    // Only known-granted mic permission is safe to initialize the recognizer
    // on — doing it earlier would re-trigger the OS permission flow. This
    // only readies the recognizer so there's no first-job delay; it does
    // NOT start listening — voice is never active on Home/History/Profile,
    // only once a job is open (see JobDetailScreen.initState/dispose, which
    // call GlobalVoiceService.enterJobScope/exitJobScope).
    if (cameraMic.checked && cameraMic.micGranted && !_voiceInitialized) {
      _voiceInitialized = true;
      // Deferred to a post-frame callback — CONFIRMED via a real device
      // logcat capture that calling this directly here blocked the first
      // frame(s) of RootShell right after login with a 3.4s Davey/frozen-
      // frame warning. GlobalVoiceService.initialize() -> _configureTts()
      // chains several sequential platform-channel round trips
      // (_speech.initialize, awaitSpeakCompletion, setSpeechRate,
      // getVoices, setVoice), and getVoices() in particular can tie up the
      // shared Android platform thread for multiple seconds on a cold TTS
      // engine bind — competing with this exact frame's build/layout/
      // raster work. Starting it only once the first frame has actually
      // been rendered means the login -> RootShell transition is never
      // blocked by it; voice still becomes available moments later, same
      // as before.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(globalVoiceServiceProvider.notifier).initialize();
      });
    }

    // No permission gate needed here (unlike voice) — starting the offline
    // queue only opens a local DB and listens for connectivity, so it's
    // started unconditionally the moment RootShell first builds, covering
    // both "fresh login" and "app relaunch while already logged in" (see
    // OfflineUploadQueueService's doc comment).
    if (!_offlineQueueStarted) {
      _offlineQueueStarted = true;
      ref.read(offlineUploadQueueProvider.notifier).start();
    }

    // Same unconditional-on-first-build reasoning as the offline queue
    // above — no permission gate needed here either, since the realtime
    // subscriptions themselves don't touch the OS notification permission
    // at all (that's requested separately, in Permissions Setup); this just
    // means a notification silently won't be seen if that permission was
    // declined, exactly like a declined mic/camera permission degrades the
    // rest of the app instead of blocking it.
    if (!_notificationsStarted) {
      _notificationsStarted = true;
      ref.read(globalNotificationServiceProvider).start();
    }

    // Same unconditional-on-first-build reasoning as the offline queue
    // above — this only opens a (separate) local DB and listens for
    // connectivity, to retry any gps_arrive/gps_depart writes that
    // couldn't be sent directly (see `visit_provider.dart`'s
    // `_insertVisitEventResilient`/`drainPendingVisitEvents`). Independent
    // of whether any job is currently "entered" — a queued event can
    // belong to a job the technician isn't even looking at anymore.
    if (!_visitEventQueueStarted) {
      _visitEventQueueStarted = true;
      ref.read(visitTrackingServiceProvider).startQueueDrain();
    }

    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
          // HistoryScreen stays mounted the whole session (it's one of
          // this IndexedStack's children, never rebuilt from scratch), so
          // without this its job list would only ever reflect whatever was
          // true the first time the tab happened to build — a job marked
          // complete elsewhere this session wouldn't show up here until an
          // app restart. Re-querying every time the tab is selected keeps
          // it live instead.
          if (index == _historyTabIndex) {
            ref.invalidate(historyJobsQueryProvider);
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history_rounded),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
