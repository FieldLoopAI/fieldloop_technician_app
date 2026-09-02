import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/global_voice_service_provider.dart';
import '../theme/app_theme.dart';

/// Persistent, always-visible voice status pill — the single reusable
/// small-format indicator for [VoicePhase] (idle/awaitingWakeWord/
/// listening/processing/speaking), shown in the same AppBar slot every
/// job-scoped screen already reserves for voice UI (see JobDetailScreen/
/// PhotoCaptureScreen's `actions:`, where this replaces the old two-state
/// [VoiceListeningIndicator] badge).
///
/// This widget holds no state of its own — what it shows is entirely a
/// function of `globalVoiceServiceProvider`'s existing `phase`, read via
/// `ref.watch` exactly once below. It is never a second source of truth:
/// if `phase` is ever wrong, this reads wrong in exactly the same way, by
/// design. Nothing here can delay or block the real voice pipeline — it
/// never touches `GlobalVoiceService`'s `_tts`/`_speech` instances, only
/// reads its already-published state.
///
/// Deliberately STAYS small and stays put — the full-screen, large-format
/// "genuine active interaction" experience lives entirely in
/// [VoiceInteractionOverlay] now (a single global overlay, not a
/// per-screen grow-in-place animation on this widget). This widget's only
/// job is the quiet, permanent corner pill.
class VoicePhaseIndicator extends ConsumerWidget {
  const VoicePhaseIndicator({super.key, this.size = 34});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(globalVoiceServiceProvider.select((s) => s.phase));

    // One short, subtle tone at the exact processing -> speaking edge (a
    // backend answer just arrived and TTS is about to start) — a system
    // UI click, not a bundled audio asset, so it can never touch the
    // shared `_tts` instance real speech plays through. `ref.listen`'s own
    // previous/next pair is what detects the edge; nothing here keeps its
    // own copy of "was it processing a moment ago."
    ref.listen<VoicePhase>(globalVoiceServiceProvider.select((s) => s.phase), (previous, next) {
      if (previous == VoicePhase.processing && next == VoicePhase.speaking) {
        SystemSound.play(SystemSoundType.click);
      }
    });

    return SizedBox(
      width: size,
      height: size,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: KeyedSubtree(key: ValueKey(phase), child: _phaseVisual(phase)),
      ),
    );
  }

  Widget _phaseVisual(VoicePhase phase) {
    switch (phase) {
      case VoicePhase.idle:
      // Passive baseline loop, waiting to hear "FieldLoop" — deliberately
      // the same subtle, low-motion resting visual as idle (see
      // [VoicePhase]'s doc comment): nothing worth calling out until a
      // real interaction actually starts (that's [VoiceInteractionOverlay]'s
      // job).
      case VoicePhase.awaitingWakeWord:
        return _IdleDot(size: size);
      case VoicePhase.listening:
        return _ListeningPulse(size: size);
      case VoicePhase.processing:
        return _ProcessingSpinner(size: size);
      case VoicePhase.speaking:
        return _SpeakingBars(size: size);
    }
  }
}

/// idle — a subtle, low-motion resting dot. Deliberately the least active
/// visual of the four: low opacity, slow, no directional motion.
class _IdleDot extends StatelessWidget {
  const _IdleDot({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    final dotSize = size * 0.26;
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child:
            Container(
                  width: dotSize,
                  height: dotSize,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.neutralGreyLight),
                )
                .animate(onPlay: (c) => c.repeat(reverse: true))
                .scale(
                  begin: const Offset(0.85, 0.85),
                  end: const Offset(1, 1),
                  duration: 1800.ms,
                  curve: Curves.easeInOut,
                )
                .fade(begin: 0.35, end: 0.75, duration: 1800.ms, curve: Curves.easeInOut),
      ),
    );
  }
}

/// listening — a clearly active, immediately-responsive pulse: quick
/// expanding rings around a mic core, tuned faster than the idle/processing
/// motions so it reads as "on" the instant the mic opens.
class _ListeningPulse extends StatelessWidget {
  const _ListeningPulse({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (var i = 0; i < 2; i++)
            Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.primaryGreenLight.withValues(alpha: 0.65), width: 1.5),
                  ),
                )
                .animate(onPlay: (c) => c.repeat(), delay: (i * 450).ms)
                .scale(begin: const Offset(0.4, 0.4), end: const Offset(1, 1), duration: 1100.ms, curve: Curves.easeOut)
                .fadeOut(duration: 1100.ms, curve: Curves.easeOut),
          Container(
                width: size * 0.55,
                height: size * 0.55,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.primaryGreen),
                child: Icon(Icons.mic_rounded, color: Colors.white, size: size * 0.32),
              )
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .scale(begin: const Offset(1, 1), end: const Offset(1.1, 1.1), duration: 500.ms, curve: Curves.easeInOut),
        ],
      ),
    );
  }
}

/// processing — a rotating indeterminate ring: a fundamentally different
/// motion (rotation, not radiating pulses) so it never reads as "still
/// listening." Amber, matching this app's existing processing color
/// language (see VoiceListeningIndicator).
class _ProcessingSpinner extends StatelessWidget {
  const _ProcessingSpinner({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: const AlwaysStoppedAnimation(AppColors.amber),
              backgroundColor: AppColors.amber.withValues(alpha: 0.15),
            ),
          ),
          Icon(Icons.graphic_eq_rounded, color: AppColors.amber, size: size * 0.4),
        ],
      ),
    );
  }
}

/// speaking — small bars pulsing out of phase, reading as "audio playing"
/// rather than "listening" or "working." Blue, the one color none of the
/// other three phases use, and a rhythmic (not radiating, not rotating)
/// motion — the third distinct shape in the set.
class _SpeakingBars extends StatelessWidget {
  const _SpeakingBars({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    final barWidth = size * 0.12;
    final barHeight = size * 0.42;
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) SizedBox(width: barWidth * 0.7),
              Container(
                    width: barWidth,
                    height: barHeight,
                    decoration: BoxDecoration(color: AppColors.blue, borderRadius: BorderRadius.circular(barWidth / 2)),
                  )
                  .animate(onPlay: (c) => c.repeat(reverse: true), delay: (i * 140).ms)
                  .scale(
                    begin: const Offset(1, 0.4),
                    end: const Offset(1, 1),
                    duration: 420.ms,
                    curve: Curves.easeInOut,
                  ),
            ],
          ],
        ),
      ),
    );
  }
}
