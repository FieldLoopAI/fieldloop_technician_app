import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/mock_job.dart';
import '../providers/estimate_invoice_providers.dart';
import '../providers/job_runtime_provider.dart';
import '../providers/permission_providers.dart';
import '../providers/voice_session_provider.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../widgets/permission_card.dart';
import '../widgets/tap_scale.dart';
import 'estimate_screen.dart';
import 'photo_capture_screen.dart';

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
  _QuickAction(
    label: 'Troubleshoot',
    icon: Icons.build_circle_rounded,
    phrase: 'FieldLoop, help me troubleshoot this error code',
  ),
  _QuickAction(
    label: 'Site Condition',
    icon: Icons.notes_rounded,
    phrase: 'FieldLoop, log site condition — attic access is tight',
  ),
  _QuickAction(
    label: 'Job Complete',
    icon: Icons.check_circle_rounded,
    phrase: 'FieldLoop, mark this job complete',
  ),
];

/// Full-screen, immersive voice-interaction UI. Every quick action here is a
/// silent failsafe: tapping a chip runs the exact same command handler a
/// real recognized voice command would, so the whole app stays usable if
/// the wake-word/voice path fails or isn't available — including when
/// microphone permission itself was denied (see [_MicUnavailableBanner]).
class VoiceAssistantScreen extends ConsumerWidget {
  const VoiceAssistantScreen({super.key, required this.jobId});

  final String jobId;

  Future<void> _handleAction(BuildContext context, WidgetRef ref, _QuickAction action) async {
    final controller = ref.read(voiceSessionProvider.notifier);
    await controller.runCommand(action.phrase);
    if (!context.mounted) return;

    switch (action.label) {
      case 'Photos':
        Navigator.of(
          context,
        ).push(FadeSlidePageRoute(builder: (_) => PhotoCaptureScreen(jobId: jobId)));
        break;
      case 'Prepare Estimate':
        Navigator.of(
          context,
        ).push(FadeSlidePageRoute(builder: (_) => EstimateScreen(jobId: jobId)));
        break;
      case 'Troubleshoot':
        _showSnack(context, 'Troubleshooting guide would open here.');
        break;
      case 'Site Condition':
        _showSnack(context, 'Site condition note logged.');
        break;
      case 'Job Complete':
        final runtime = ref.read(jobRuntimeProvider(jobId));
        final estimateStatus = ref.read(estimateStatusProvider(jobId));
        final invoiceStatus = ref.read(invoiceStatusProvider(jobId));
        final ready =
            runtime.status == JobStatus.onSite &&
            estimateStatus == EstimateStatus.signed &&
            invoiceStatus != InvoiceStatus.notYetInvoiced;
        if (ready) {
          ref.read(jobRuntimeProvider(jobId).notifier).markComplete();
          _showSnack(context, 'Job marked complete.');
        } else if (runtime.status != JobStatus.onSite) {
          _showSnack(context, "Can't complete — not yet on site.");
        } else {
          _showSnack(context, 'Complete the estimate and invoice first.');
        }
    }
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF1B2620),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(voiceSessionProvider);
    final cameraMic = ref.watch(cameraMicProvider);
    final askShown = ref.watch(cameraMicAskShownProvider);
    final statusLabel = session.phase == VoicePhase.processing
        ? 'Processing...'
        : (session.transcript.isEmpty ? "Say 'FieldLoop' to begin" : 'Listening...');

    // Show the one-time "soft ask" only once we actually know the current
    // status (avoids a flash of the ask card before the first status check
    // resolves) and only until it's been actioned once, anywhere in the app.
    final showAsk = cameraMic.checked && !cameraMic.allGranted && !askShown;
    final micUnavailable = !showAsk && !cameraMic.micGranted;

    return Scaffold(
      backgroundColor: const Color(0xFF0B120F),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isTablet = constraints.maxWidth > 600;
            final horizontalPadding = isTablet ? constraints.maxWidth * 0.16 : 20.0;

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
                      const SizedBox(width: 48),
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
                    _ListeningIndicator(phase: session.phase),
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
                          onTap: () => _handleAction(context, ref, action),
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

class _ListeningIndicator extends StatelessWidget {
  const _ListeningIndicator({required this.phase});

  final VoicePhase phase;

  @override
  Widget build(BuildContext context) {
    final isProcessing = phase == VoicePhase.processing;

    return SizedBox(
      width: 220,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (!isProcessing)
            for (var i = 0; i < 3; i++)
              Container(
                    width: 220,
                    height: 220,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.primaryGreenLight.withValues(alpha: 0.5)),
                    ),
                  )
                  .animate(onPlay: (c) => c.repeat(), delay: (i * 500).ms)
                  .scale(
                    begin: const Offset(0.45, 0.45),
                    end: const Offset(1, 1),
                    duration: 1800.ms,
                    curve: Curves.easeOut,
                  )
                  .fadeOut(duration: 1800.ms, curve: Curves.easeOut),
          if (isProcessing)
            SizedBox(
              width: 200,
              height: 200,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: const AlwaysStoppedAnimation(AppColors.amber),
                backgroundColor: Colors.white.withValues(alpha: 0.08),
              ),
            ),
          Container(
                width: 118,
                height: 118,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: isProcessing
                      ? const LinearGradient(colors: [AppColors.amber, Color(0xFFB45309)])
                      : AppColors.headerGradient,
                  boxShadow: [
                    BoxShadow(
                      color: (isProcessing ? AppColors.amber : AppColors.primaryGreen).withValues(alpha: 0.45),
                      blurRadius: 32,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Icon(
                  isProcessing ? Icons.graphic_eq_rounded : Icons.mic_rounded,
                  color: Colors.white,
                  size: 46,
                ),
              )
              .animate(
                key: ValueKey(isProcessing),
                onPlay: (c) => isProcessing ? null : c.repeat(reverse: true),
              )
              .scale(
                begin: const Offset(1, 1),
                end: isProcessing ? const Offset(1, 1) : const Offset(1.08, 1.08),
                duration: 900.ms,
                curve: Curves.easeInOut,
              ),
        ],
      ),
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
