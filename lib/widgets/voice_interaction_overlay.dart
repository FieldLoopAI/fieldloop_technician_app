import 'dart:async';
import 'dart:math' show pi, sin;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/global_voice_service_provider.dart';
import '../theme/app_theme.dart';

/// Full-screen modal voice experience â€” shown only BRIEFLY, once per Gemini
/// session (see [_briefSessionIntroDuration]/[GlobalVoiceState.sessionEpoch]),
/// as a short "here's Gemini" intro right when a session starts, then
/// auto-shrinks to the small corner indicator for the rest of that session
/// regardless of how many more times [_isActive]'s phases (listening/
/// processing/speaking) toggle on and off. REPLACES the old per-screen
/// "grow the corner pill in place" animation entirely (see
/// `VoicePhaseIndicator`, now a plain small pill that never moves or resizes
/// itself, and the one thing left visible for the rest of the session).
///
/// CHANGED (was: full-screen for the ENTIRE active interaction, every time)
/// â€” the technician needs to see and interact with the real app underneath
/// for essentially the whole session (dictation readbacks, photo capture,
/// navigating to review a screen, ...), not just the moments a function call
/// happens to trigger real screen content ([GlobalVoiceState.screenTaskActive]
/// still independently forces an early shrink for those, same as before â€”
/// see that field's doc comment). A few seconds of full-screen at the very
/// start is enough to establish "Gemini is listening now" without blocking
/// the rest of the conversation.
///
/// A single global instance, wired once at the `MaterialApp.builder` level
/// (see `app.dart`), same root-Stack pattern as `DictationConfirmationBar`
/// â€” renders above whichever screen is currently on top without needing to
/// be added to each of the 5 voice-active screens individually. The real
/// screen underneath is never touched, rebuilt, or disposed by this: it's
/// a purely additive visual layer in the same root Stack, not a route push.
///
/// Pure observer, same rule as every other piece of this feature: it only
/// watches `globalVoiceServiceProvider`'s already-published state â€” it
/// can never delay or block the real voice pipeline, which runs
/// identically whether or not this is even on screen. It renders nothing
/// (`SizedBox.shrink()`, no ticker running) whenever fully at rest. The
/// [Timer] that ends the brief intro window is purely local UI state (when
/// to animate this widget back to the corner) â€” it never gates or delays
/// anything the real voice pipeline does.
///
/// IS a real modal while shown: the scrim visually and functionally sits
/// above the current screen, absorbing taps meant for it â€” but that's a
/// touch-layer UI choice, unrelated to (and never affecting) the mic/voice
/// pipeline's own timing.
class VoiceInteractionOverlay extends ConsumerStatefulWidget {
  const VoiceInteractionOverlay({super.key});

  @override
  ConsumerState<VoiceInteractionOverlay> createState() => _VoiceInteractionOverlayState();
}

class _VoiceInteractionOverlayState extends ConsumerState<VoiceInteractionOverlay>
    with SingleTickerProviderStateMixin {
  static const Duration _transitionDuration = Duration(milliseconds: 350);
  // A true dramatic dim, not a grey wash â€” CONFIRMED from a real screen
  // recording that 0.7 read as weak.
  static const double _scrimOpacity = 0.82;
  // Matches VoicePhaseIndicator's default `size` and the same corner-slot
  // approximation earlier rounds of this feature already used (right:14
  // padding around the indicator, centered in a standard 56px AppBar below
  // the status bar/notch) â€” the travel animation below starts from here.
  static const double _cornerSize = 34;
  // Genuinely large â€” a meaningful fraction of screen width on a typical
  // phone, not a small icon (CONFIRMED too small at 240).
  static const double _largeSize = 300;

  /// How long the full-screen intro stays up once a session starts, before
  /// auto-shrinking to the corner for the rest of that session (see
  /// [_armAutoShrinkTimer]) â€” "a few seconds", per the brief-intro spec this
  /// replaced the old every-time-active behavior with.
  static const Duration _briefSessionIntroDuration = Duration(seconds: 3);

  late final AnimationController _controller;

  /// The [GlobalVoiceState.sessionEpoch] this widget has already accounted
  /// for â€” a change from this value is what "a new session just started"
  /// means (see that field's doc comment). Initialized from whatever epoch
  /// is current on mount so a same-epoch rebuild never mistakes itself for a
  /// new session.
  int _lastSeenSessionEpoch = 0;

  /// True once this session's one-time brief full-screen intro has been
  /// shown and shrunk away â€” by the timer elapsing, OR by
  /// `screenTaskActive`/an inactive phase cutting it short before the timer
  /// even fires (see the shrink branch in [_applyVoiceState]). Latches for
  /// the rest of the session either way: the intro is spent once, it's
  /// never "refunded" by a later screenTaskActive dip ending. Reset to
  /// `false` only when [_lastSeenSessionEpoch] changes.
  bool _hasShownIntroThisSession = false;

  /// Live only while the full-screen intro is up and hasn't yet been cut
  /// short some other way â€” fires [_briefSessionIntroDuration] after the
  /// intro first appears and shrinks it to the corner. Purely local UI
  /// timing; never gates the real voice pipeline (see the class doc
  /// comment).
  Timer? _autoShrinkTimer;

  /// Genuine active interaction â€” NOT `phase != VoicePhase.idle`.
  /// `VoicePhase.awaitingWakeWord` (the passive, always-on baseline loop
  /// waiting to hear "FieldLoop") is also non-idle, and the baseline loop
  /// restarts via an `idle -> awaitingWakeWord` edge after every
  /// interaction â€” a naive `!= idle` check would re-trigger this overlay
  /// the instant each interaction ends. Only these three phases represent
  /// real, user-visible activity worth ever going full-screen for.
  static bool _isActive(VoicePhase phase) =>
      phase == VoicePhase.listening || phase == VoicePhase.processing || phase == VoicePhase.speaking;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _transitionDuration);
    // Defensive only â€” this is a single app-root instance, so it should
    // never actually mount mid-interaction, but snap straight to the
    // right state (full-screen + timer armed, exactly as if [_applyVoiceState]
    // had just run) rather than replaying the entry animation just in case.
    final initial = ref.read(globalVoiceServiceProvider);
    _lastSeenSessionEpoch = initial.sessionEpoch;
    _applyVoiceState(
      phase: initial.phase,
      screenTaskActive: initial.screenTaskActive,
      sessionEpoch: initial.sessionEpoch,
      instant: true,
    );
  }

  @override
  void dispose() {
    _autoShrinkTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _armAutoShrinkTimer() {
    _autoShrinkTimer ??= Timer(_briefSessionIntroDuration, () {
      if (!mounted) return;
      debugPrint('VOICE OVERLAY: brief session intro elapsed - shrinking to corner for the rest of the session');
      _hasShownIntroThisSession = true;
      _autoShrinkTimer = null;
      _controller.reverse();
    });
  }

  /// The one place that decides whether the full-screen intro should be up
  /// right now, and reacts to it â€” called both from [initState] (with
  /// [instant]: true, no timer bookkeeping needed since nothing was showing
  /// yet) and from [build]'s `ref.listen` (with [instant]: false) whenever
  /// phase/screenTaskActive/sessionEpoch change.
  void _applyVoiceState({
    required VoicePhase phase,
    required bool screenTaskActive,
    required int sessionEpoch,
    required bool instant,
  }) {
    if (sessionEpoch != _lastSeenSessionEpoch) {
      debugPrint('VOICE OVERLAY: new session (epoch $_lastSeenSessionEpoch -> $sessionEpoch) - intro available again');
      _lastSeenSessionEpoch = sessionEpoch;
      _hasShownIntroThisSession = false;
      _autoShrinkTimer?.cancel();
      _autoShrinkTimer = null;
    }

    final shouldShowFullScreen = _isActive(phase) && !screenTaskActive && !_hasShownIntroThisSession;

    if (shouldShowFullScreen) {
      if (_controller.value == 0) {
        debugPrint('VOICE OVERLAY: activating full-screen (brief session intro) - phase=$phase');
        if (instant) {
          _controller.value = 1;
        } else {
          _controller.forward();
        }
      }
      _armAutoShrinkTimer();
      return;
    }

    // Not showing full-screen (or shouldn't be) — cutting the intro short
    // (screenTaskActive, or phase went inactive) counts as "spent," exactly
    // like the timer elapsing, so it never re-expands later this session.
    if (_autoShrinkTimer != null) {
      _autoShrinkTimer!.cancel();
      _autoShrinkTimer = null;
      _hasShownIntroThisSession = true;
    }
    if (_controller.value != 0) {
      debugPrint(
        'VOICE OVERLAY: deactivating - returning to corner (phase=$phase, screenTaskActive=$screenTaskActive, '
        'introAlreadyShown=$_hasShownIntroThisSession)',
      );
      if (instant) {
        _controller.value = 0;
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final voiceState = ref.watch(
      globalVoiceServiceProvider.select(
        (s) => (phase: s.phase, screenTaskActive: s.screenTaskActive, sessionEpoch: s.sessionEpoch),
      ),
    );
    final phase = voiceState.phase;

    ref.listen(
      globalVoiceServiceProvider.select(
        (s) => (phase: s.phase, screenTaskActive: s.screenTaskActive, sessionEpoch: s.sessionEpoch),
      ),
      (previous, next) {
        _applyVoiceState(
          phase: next.phase,
          screenTaskActive: next.screenTaskActive,
          sessionEpoch: next.sessionEpoch,
          instant: false,
        );
      },
    );

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        if (_controller.value == 0) return const SizedBox.shrink();
        return Positioned.fill(child: _buildContent(context, phase));
      },
    );
  }

  Widget _buildContent(BuildContext context, VoicePhase phase) {
    // Scrim, position, and size are all driven off this SAME eased value â€”
    // one continuous, synchronized motion rather than separately-timed
    // pieces that merely happen to overlap.
    final t = Curves.easeInOut.transform(_controller.value);
    final media = MediaQuery.of(context);
    final screenSize = media.size;
    final topInset = media.padding.top;

    final cornerCenter = Offset(screenSize.width - 14 - _cornerSize / 2, topInset + 28);
    final centeredCenter = Offset(screenSize.width / 2, screenSize.height / 2 - 20);
    final currentSize = _cornerSize + (_largeSize - _cornerSize) * t;
    final currentCenter = Offset.lerp(cornerCenter, centeredCenter, t)!;
    // The label only makes sense once the indicator has mostly arrived â€”
    // fading it in over the transition's back half avoids a label
    // floating in space while the indicator is still mid-flight.
    final labelOpacity = ((t - 0.55) / 0.45).clamp(0.0, 1.0);

    return Stack(
      children: [
        // The scrim itself absorbs taps (a decorated Container is opaque to
        // hit-testing by default) â€” the one deliberately-interactive part
        // of this overlay, making it a genuine modal while shown.
        Positioned.fill(child: Container(color: Colors.black.withValues(alpha: _scrimOpacity * t))),
        Positioned(
          left: currentCenter.dx - currentSize / 2,
          top: currentCenter.dy - currentSize / 2,
          width: currentSize,
          height: currentSize,
          child: IgnorePointer(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: KeyedSubtree(key: ValueKey(phase), child: _phaseVisual(phase, currentSize)),
            ),
          ),
        ),
        if (labelOpacity > 0)
          Positioned(
            left: 0,
            right: 0,
            top: centeredCenter.dy + _largeSize / 2 + 32,
            child: IgnorePointer(
              child: Opacity(
                opacity: labelOpacity,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      _labelFor(phase),
                      key: ValueKey(phase),
                      // Plain Text, not TextField/TextFormField/SelectableText
                      // â€” CONFIRMED this was already the case; the yellow
                      // squiggly reported from a real device was Android's
                      // spell-check decoration, which only ever renders on an
                      // editable widget. `decoration: TextDecoration.none` is
                      // set explicitly below purely as defense-in-depth
                      // against any ambient `DefaultTextStyle` supplying one,
                      // not because this Text was ever actually editable.
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _labelFor(VoicePhase phase) => switch (phase) {
    VoicePhase.listening => 'Listening...',
    VoicePhase.processing => 'Thinking...',
    VoicePhase.speaking => 'Speaking...',
    VoicePhase.idle || VoicePhase.awaitingWakeWord => '',
  };

  /// Full-format visual â€” ONE technique (the morphing gradient blob below)
  /// reused for all three active phases, only its speed/palette/energy
  /// varying per phase â€” NOT three unrelated widgets, and NOT a resized
  /// copy of `VoicePhaseIndicator`'s small pill visuals. Reads correctly
  /// across the whole size range this travels through (the small corner
  /// size up to [_largeSize]), so there's no jarring swap mid-flight â€” the
  /// same widget just keeps scaling as `size` grows.
  Widget _phaseVisual(VoicePhase phase, double size) {
    switch (phase) {
      case VoicePhase.listening:
        return _MorphingBlob(size: size, config: _BlobConfig.listening);
      case VoicePhase.processing:
        return _MorphingBlob(size: size, config: _BlobConfig.processing);
      case VoicePhase.speaking:
        return _MorphingBlob(size: size, config: _BlobConfig.speaking);
      case VoicePhase.idle:
      case VoicePhase.awaitingWakeWord:
        // Never actually reached â€” the overlay is hidden for both â€” but
        // exhaustiveness requires a case, and this deliberately reuses
        // nothing from the small pill (no shared dependency to keep in
        // sync) since it can never render.
        return const SizedBox.shrink();
    }
  }
}

/// Complementary accents alongside the app's green palette (see
/// `AppColors`, which has no teal/violet of its own) â€” used only for this
/// blob effect's gradient blending, not promoted to the shared theme.
const _tealAccent = Color(0xFF17B8A6);
const _violetAccent = Color(0xFF7C6FF0);

/// Per-phase tuning for [_MorphingBlob] â€” same technique throughout
/// ([_MorphingBlob] itself never branches on phase), only these values
/// differ.
class _BlobConfig {
  const _BlobConfig({
    required this.palette,
    required this.loopDuration,
    required this.moveEnergy,
    required this.pulseEnergy,
    required this.sizeMultiplier,
    this.beatsPerLoop,
  });

  /// Circle fill colors, cycled if there are more circles than colors.
  final List<Color> palette;

  /// One full drift/pulse cycle â€” shorter = faster, more energetic motion.
  final Duration loopDuration;

  /// How far (as a fraction of [_MorphingBlob.size]) each circle drifts
  /// from its base position.
  final double moveEnergy;

  /// Per-circle radius pulse amplitude (fraction of that circle's base
  /// radius).
  final double pulseEnergy;

  /// Overall blob scale relative to the indicator's current size.
  final double sizeMultiplier;

  /// If set, layers one additional whole-group scale pulse at this many
  /// beats per [loopDuration] on top of the individual circle motion â€”
  /// speaking's "rhythmic pulsing synced to a steady beat," distinct from
  /// listening/processing's purely organic (unsynced) drift.
  final int? beatsPerLoop;

  // listening â€” faster, more energetic, brighter/saturated, largest.
  static const listening = _BlobConfig(
    palette: [AppColors.primaryGreen, _tealAccent, AppColors.primaryGreenLight, AppColors.blue],
    loopDuration: Duration(seconds: 5),
    moveEnergy: 0.16,
    pulseEnergy: 0.22,
    sizeMultiplier: 1.06,
  );

  // processing â€” slower, hypnotic/swirling, desaturated & cooler, no beat.
  static const processing = _BlobConfig(
    palette: [Color(0xFF3D6B63), Color(0xFF48587F), Color(0xFF5C6B8C), _violetAccent],
    loopDuration: Duration(seconds: 12),
    moveEnergy: 0.1,
    pulseEnergy: 0.12,
    sizeMultiplier: 0.9,
  );

  // speaking â€” moderate organic drift PLUS a steady synced beat pulse
  // layered on top â€” reads as rhythmic/"alive" without needing real audio
  // amplitude.
  static const speaking = _BlobConfig(
    palette: [AppColors.blue, _violetAccent, _tealAccent, AppColors.primaryGreenLight],
    loopDuration: Duration(seconds: 7),
    moveEnergy: 0.12,
    pulseEnergy: 0.16,
    sizeMultiplier: 0.98,
    beatsPerLoop: 7,
  );
}

/// Fixed motion signature for one circle within the blob â€” distinct
/// integer frequencies and phase offsets per circle (computed once, not
/// per frame) so no two circles ever drift in sync, whatever [_BlobConfig]
/// is applied. Integer frequencies keep every full [_BlobConfig.
/// loopDuration] cycle seamless (`AnimationController.repeat()` wraps
/// 1 -> 0 with no jump only when every sine term completes a whole number
/// of periods over that span).
class _CircleSpec {
  const _CircleSpec({
    required this.baseRadiusFraction,
    required this.baseCenterFraction,
    required this.freqX,
    required this.freqY,
    required this.phaseX,
    required this.phaseY,
    required this.pulseFreq,
  });

  final double baseRadiusFraction;
  final Offset baseCenterFraction;
  final int freqX;
  final int freqY;
  final double phaseX;
  final double phaseY;
  final int pulseFreq;
}

const _circleSpecs = [
  _CircleSpec(
    baseRadiusFraction: 0.5,
    baseCenterFraction: Offset(-0.09, -0.04),
    freqX: 2,
    freqY: 3,
    phaseX: 0,
    phaseY: 1.4,
    pulseFreq: 3,
  ),
  _CircleSpec(
    baseRadiusFraction: 0.4,
    baseCenterFraction: Offset(0.11, 0.07),
    freqX: 3,
    freqY: 2,
    phaseX: 2.3,
    phaseY: 0.5,
    pulseFreq: 4,
  ),
  _CircleSpec(
    baseRadiusFraction: 0.44,
    baseCenterFraction: Offset(0.03, -0.13),
    freqX: 5,
    freqY: 4,
    phaseX: 3.6,
    phaseY: 2.7,
    pulseFreq: 2,
  ),
  _CircleSpec(
    baseRadiusFraction: 0.32,
    baseCenterFraction: Offset(-0.12, 0.11),
    freqX: 4,
    freqY: 5,
    phaseX: 1.2,
    phaseY: 4.3,
    pulseFreq: 5,
  ),
];

/// The Siri-style "morphing gradient blob": [_circleSpecs].length
/// overlapping radial-gradient circles, each drifting/pulsing on its own
/// continuous sine-wave signature (never synced to the others), melted
/// together into one soft liquid shape by a single [ImageFiltered] blur
/// over the whole group. ONE [AnimationController] (not one per circle)
/// drives every circle's position/scale, all derived from that single
/// `t` value each frame â€” the same "one controller, computed values"
/// shape already proven safe/performant elsewhere in this feature (see
/// `VoicePhaseIndicator`/this file's transition controller). The blur is
/// applied once over the composited group, never per-circle, to keep the
/// GPU cost to a single blur pass regardless of circle count.
class _MorphingBlob extends StatefulWidget {
  const _MorphingBlob({required this.size, required this.config});

  final double size;
  final _BlobConfig config;

  @override
  State<_MorphingBlob> createState() => _MorphingBlobState();
}

class _MorphingBlobState extends State<_MorphingBlob> with SingleTickerProviderStateMixin {
  // Strong, constant blur â€” CONFIRMED range (20-40) for the circles to
  // read as one liquid blob rather than distinct shapes, regardless of
  // the indicator's current size during the corner<->center transition.
  static const double _blurSigma = 26;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.config.loopDuration)..repeat();
  }

  @override
  void didUpdateWidget(covariant _MorphingBlob oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Phase changes mid-flight are handled by AnimatedSwitcher building a
    // fresh instance (new State, new controller) â€” this only covers a
    // same-phase config swap, which never actually happens today, kept
    // for correctness rather than assuming it can't.
    if (oldWidget.config.loopDuration != widget.config.loopDuration) {
      _controller.duration = widget.config.loopDuration;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    final blobSize = widget.size * config.sizeMultiplier;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;
            final beatScale = config.beatsPerLoop == null
                ? 1.0
                : 1.0 + 0.06 * sin(2 * pi * config.beatsPerLoop! * t);
            return Transform.scale(
              scale: beatScale,
              child: SizedBox(
                width: blobSize,
                height: blobSize,
                // ONE blur over the whole composited group â€” never wrapped
                // around individual circles below.
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      for (var i = 0; i < _circleSpecs.length; i++)
                        _buildCircle(
                          spec: _circleSpecs[i],
                          color: config.palette[i % config.palette.length],
                          blobSize: blobSize,
                          t: t,
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCircle({required _CircleSpec spec, required Color color, required double blobSize, required double t}) {
    final config = widget.config;
    final driftX = blobSize * config.moveEnergy * sin(2 * pi * spec.freqX * t + spec.phaseX);
    final driftY = blobSize * config.moveEnergy * sin(2 * pi * spec.freqY * t + spec.phaseY);
    final pulse = 1.0 + config.pulseEnergy * sin(2 * pi * spec.pulseFreq * t + spec.phaseX);
    final radius = spec.baseRadiusFraction * blobSize * 0.5 * pulse;
    final center = Offset(
      blobSize / 2 + spec.baseCenterFraction.dx * blobSize + driftX,
      blobSize / 2 + spec.baseCenterFraction.dy * blobSize + driftY,
    );

    return Positioned(
      left: center.dx - radius,
      top: center.dy - radius,
      width: radius * 2,
      height: radius * 2,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
  }
}

