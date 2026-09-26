import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/global_voice_service_provider.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

/// FIX 2 (dictation confirm/redo) — on-screen tap fallback for
/// [GlobalVoiceService.captureConfirmation]'s confirm/redo step, same
/// "voice AND tap always resolve the same way" principle as every other
/// command in this app (see `PhotoPreviewScreen`'s Confirm/Retake buttons).
/// Tapping either button calls
/// [GlobalVoiceService.submitConfirmationTap], which feeds the exact same
/// literal keyword through the exact same matching path a spoken reply
/// would.
///
/// Wired globally via `MaterialApp.builder` in `app.dart` — unlike the
/// photo confirm/retake buttons (a dedicated screen reached by
/// navigation), `prepare_estimate`/`site_condition` can be triggered from
/// several different screens (Job Detail, Photo Capture, Voice Assistant)
/// with no navigation involved, so this has to be visible above whichever
/// one is currently on top rather than living in any one of them.
class DictationConfirmationBar extends ConsumerWidget {
  const DictationConfirmationBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(
      globalVoiceServiceProvider.select((s) => s.pendingConfirmationTranscript),
    );
    if (pending == null) return const SizedBox.shrink();

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        // Same readable-width cap as the screens underneath, so on a
        // tablet this reads as a card, not a full-width banner.
        child: MaxWidthBox(
          child: Material(
            color: Colors.transparent,
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.borderGrey),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Confirm this note?',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.textDark),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '"$pending"',
                    style: const TextStyle(fontSize: 13.5, color: AppColors.neutralGrey, height: 1.4),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            onPressed: () => ref
                                .read(globalVoiceServiceProvider.notifier)
                                .submitConfirmationTap(false),
                            icon: const Icon(Icons.replay_rounded, size: 18),
                            label: const Text('Redo'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.primaryGreenDark,
                              side: const BorderSide(color: AppColors.primaryGreen),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: ElevatedButton.icon(
                            onPressed: () => ref
                                .read(globalVoiceServiceProvider.notifier)
                                .submitConfirmationTap(true),
                            icon: const Icon(Icons.check_rounded, size: 18),
                            label: const Text('Confirm'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primaryGreen,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
