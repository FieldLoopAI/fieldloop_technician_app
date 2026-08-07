import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../providers/global_voice_service_provider.dart';
import '../theme/app_theme.dart';

/// The pulsing mic / processing indicator for the global wake-word voice
/// service (see [globalVoiceServiceProvider]). Used full-size as the centerpiece
/// of the Voice Assistant screen (defaults match its original look exactly)
/// and as a small persistent badge on any other screen with voice commands
/// active — pass `showRings: false` with an explicit [coreSize]/[iconSize]
/// for the compact form.
class VoiceListeningIndicator extends StatelessWidget {
  const VoiceListeningIndicator({
    super.key,
    required this.phase,
    this.size = 220,
    this.showRings = true,
    double? coreSize,
    double? iconSize,
  }) : _coreSizeOverride = coreSize,
       _iconSizeOverride = iconSize;

  final VoicePhase phase;

  /// Outer diameter of the pulsing rings and the processing spinner ring —
  /// only used when [showRings] is true.
  final double size;
  final bool showRings;
  final double? _coreSizeOverride;
  final double? _iconSizeOverride;

  double get coreSize => _coreSizeOverride ?? size * (118 / 220);
  double get iconSize => _iconSizeOverride ?? size * (46 / 220);

  @override
  Widget build(BuildContext context) {
    final isProcessing = phase == VoicePhase.processing;
    final boxSize = showRings ? size : coreSize;

    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (showRings && !isProcessing)
            for (var i = 0; i < 3; i++)
              Container(
                    width: size,
                    height: size,
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
          if (showRings && isProcessing)
            SizedBox(
              width: size * (200 / 220),
              height: size * (200 / 220),
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: const AlwaysStoppedAnimation(AppColors.amber),
                backgroundColor: Colors.white.withValues(alpha: 0.08),
              ),
            ),
          Container(
                width: coreSize,
                height: coreSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: isProcessing
                      ? const LinearGradient(colors: [AppColors.amber, Color(0xFFB45309)])
                      : AppColors.headerGradient,
                  boxShadow: [
                    BoxShadow(
                      color: (isProcessing ? AppColors.amber : AppColors.primaryGreen).withValues(alpha: 0.45),
                      blurRadius: coreSize * (32 / 118),
                      spreadRadius: coreSize * (2 / 118),
                    ),
                  ],
                ),
                child: Icon(
                  isProcessing ? Icons.graphic_eq_rounded : Icons.mic_rounded,
                  color: Colors.white,
                  size: iconSize,
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
