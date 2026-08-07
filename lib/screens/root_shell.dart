import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/global_voice_service_provider.dart';
import '../providers/permission_providers.dart';
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
  bool _voiceStarted = false;

  static const _tabs = [HomeScreen(), HistoryScreen(), ProfileScreen()];

  @override
  Widget build(BuildContext context) {
    final cameraMic = ref.watch(cameraMicProvider);
    // Only known-granted mic permission is safe to start the recognizer on
    // — starting it earlier would re-trigger the OS permission flow.
    if (cameraMic.checked && cameraMic.micGranted && !_voiceStarted) {
      _voiceStarted = true;
      ref.read(globalVoiceServiceProvider.notifier).start();
    }

    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
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
