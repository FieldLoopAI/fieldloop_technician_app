import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../providers/global_voice_service_provider.dart';
import '../providers/job_voice_commands.dart';
import '../providers/permission_providers.dart';
import '../providers/safe_ref_disposal.dart';
import '../providers/voice_command_registry_provider.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/permission_card.dart';
import '../widgets/tap_scale.dart';
import '../widgets/voice_listening_indicator.dart';
import 'photo_capture_screen.dart';
import 'voice_command_registrar_mixin.dart';

class _QuickAction {
  const _QuickAction({required this.label, required this.icon, required this.phrase});
  final String label;
  final IconData icon;
  final String phrase;
}

const _quickActions = [
  _QuickAction(label: 'Photos', icon: Icons.photo_camera_rounded, phrase: 'FieldLoop, take a photo'),
  _QuickAction(
    label: 'Prepare Estimate',
    icon: Icons.description_rounded,
    phrase: 'FieldLoop, prepare estimate for compressor replacement',
  ),
  _QuickAction(label: 'Ask a Question', icon: Icons.help_outline_rounded, phrase: 'FieldLoop, help'),
  _QuickAction(
    label: 'Site Condition',
    icon: Icons.notes_rounded,
    phrase: 'FieldLoop, log site condition — attic access is tight',
  ),
  _QuickAction(label: 'Job Complete', icon: Icons.check_circle_rounded, phrase: 'FieldLoop, mark this job complete'),
];

/// Full-screen, immersive voice-interaction UI. Every quick action here is a
/// silent failsafe: tapping a chip runs
/// [GlobalVoiceService.triggerTapCommand] with the exact same phrase a
/// recognized "FieldLoop" wake-word command would speak, matched against
/// whatever this screen currently has registered (see [buildVoiceCommands])
/// — so the whole app stays usable if the wake-word/voice path fails or
/// isn't available, including when microphone permission itself was denied
/// (see [_MicUnavailableBanner]). The recognizer itself is a single global
/// service started once at `RootShell`; this screen never starts, stops, or
/// otherwise touches it — only the shared command registry.
class VoiceAssistantScreen extends ConsumerStatefulWidget {
  const VoiceAssistantScreen({super.key, required this.jobId});

  final String jobId;

  @override
  ConsumerState<VoiceAssistantScreen> createState() => _VoiceAssistantScreenState();
}

class _VoiceAssistantScreenState extends ConsumerState<VoiceAssistantScreen>
    with SafeRefDisposal<VoiceAssistantScreen>, VoiceCommandRegistrarMixin<VoiceAssistantScreen> {
  Future<void> _handleTap(_QuickAction action) {
    return ref.read(globalVoiceServiceProvider.notifier).triggerTapCommand(action.phrase);
  }

  @override
  List<VoiceCommand> buildVoiceCommands() {
    return [
      openCameraVoiceCommand(
        ref: ref,
        jobId: widget.jobId,
        navigate: () => Navigator.of(
          context,
        ).push(FadeSlidePageRoute(builder: (_) => PhotoCaptureScreen(jobId: widget.jobId))),
      ),
      prepareEstimateVoiceCommand(ref: ref, jobId: widget.jobId),
      ...jobLifecycleVoiceCommands(ref, widget.jobId),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(globalVoiceServiceProvider);
    final cameraMic = ref.watch(cameraMicProvider);
    final askShown = ref.watch(cameraMicAskShownProvider);

    // Show the one-time "soft ask" only once we actually know the current
    // status (avoids a flash of the ask card before the first status check
    // resolves) and only until it's been actioned once, anywhere in the app.
    final showAsk = cameraMic.checked && !cameraMic.allGranted && !askShown;
    final micUnavailable = !showAsk && (!cameraMic.micGranted || !session.available);
    final statusLabel = micUnavailable
        ? 'Voice unavailable'
        : session.muted
        ? 'Muted'
        : session.phase == VoicePhase.processing
        ? 'Processing...'
        : (session.transcript.isEmpty ? "Say 'FieldLoop' to begin" : 'Listening...');

    return Scaffold(
      backgroundColor: const Color(0xFF0B120F),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = responsiveGutter(constraints.maxWidth, min: 20);

            return Padding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 8),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white70, size: 18),
                      ),
                      const Expanded(
                        child: Text(
                          'FieldLoop Assistant',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.4),
                        ),
                      ),
                      IconButton(
                        onPressed: () => ref
                            .read(globalVoiceServiceProvider.notifier)
                            .setMuted(!session.muted),
                        icon: Icon(
                          session.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                          color: Colors.white70,
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                  if (micUnavailable) ...[
                    const SizedBox(height: 12),
                    _MicUnavailableBanner(
                      permanentlyDenied: cameraMic.microphone.isPermanentlyDenied,
                      onEnable: () => ref.read(cameraMicProvider.notifier).request(),
                    ),
                  ],
                  if (showAsk) ...[
                    const Spacer(),
                    Builder(
                      builder: (context) {
                        final copy = cameraMicAskCopy(cameraMic);
                        return PermissionCard(
                          icons: copy.icons,
                          title: copy.title,
                          message: copy.message,
                          actionLabel: 'Continue',
                          actionIcon: Icons.arrow_forward_rounded,
                          onAction: () async {
                            await ref.read(cameraMicProvider.notifier).request();
                            // The permission request is async — this widget
                            // (and its `ref`) can be gone by the time it
                            // resolves.
                            if (!mounted) return;
                            ref.read(cameraMicAskShownProvider.notifier).state = true;
                          },
                        );
                      },
                    ),
                    const Spacer(),
                  ] else ...[
                    const Spacer(),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Text(
                        statusLabel,
                        key: ValueKey(statusLabel),
                        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(height: 32),
                    VoiceListeningIndicator(phase: session.phase),
                    const SizedBox(height: 32),
                    _TranscriptCard(text: session.transcript),
                    const Spacer(),
                  ],
                  Text(
                    'Tap a command — voice works the same way',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11.5, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final action in _quickActions)
                        TapScale(
                          onTap: () => _handleTap(action),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(action.icon, color: AppColors.primaryGreenLight, size: 16),
                                const SizedBox(width: 8),
                                Text(
                                  action.label,
                                  style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Shown when microphone permission is denied — voice input won't work, but
/// per the fallback requirement the screen stays fully usable via the
/// quick-action buttons below, so this is a banner, never a block.
class _MicUnavailableBanner extends StatelessWidget {
  const _MicUnavailableBanner({required this.permanentlyDenied, required this.onEnable});

  final bool permanentlyDenied;
  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) {
    return PermissionCard(
      compact: true,
      icons: const [Icons.mic_off_rounded],
      title: 'Voice input unavailable',
      message: permanentlyDenied
          ? "Microphone access is off. Use the buttons below, or enable it in Settings."
          : 'Microphone access was declined. Use the buttons below, or enable it to use voice commands.',
      actionLabel: permanentlyDenied ? 'Open Settings' : 'Enable Microphone',
      onAction: permanentlyDenied ? openAppSettings : onEnable,
    );
  }
}

class _TranscriptCard extends StatelessWidget {
  const _TranscriptCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 76),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border(left: BorderSide(color: AppColors.primaryGreenLight.withValues(alpha: 0.6), width: 3)),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Text(
          text.isEmpty ? 'Your voice commands will appear here…' : '"$text"',
          key: ValueKey(text),
          style: TextStyle(
            color: text.isEmpty ? Colors.white38 : Colors.white,
            fontSize: 14.5,
            fontStyle: text.isEmpty ? FontStyle.italic : FontStyle.normal,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
