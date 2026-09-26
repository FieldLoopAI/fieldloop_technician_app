import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/job_photo.dart';
import '../providers/global_voice_service_provider.dart';
import '../providers/job_photos_provider.dart';
import '../providers/job_runtime_provider.dart';
import '../providers/job_voice_commands.dart';
import '../providers/jobs_provider.dart';
import '../providers/permission_providers.dart';
import '../providers/safe_ref_disposal.dart';
import '../providers/voice_command_registry_provider.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';
import '../theme/responsive.dart';
import '../widgets/error_banner.dart';
import '../widgets/job_photo_thumbnail.dart';
import '../widgets/permission_card.dart';
import '../widgets/pending_upload_badge.dart';
import '../widgets/tap_scale.dart';
import '../widgets/voice_phase_indicator.dart';
import 'photo_preview_screen.dart';
import 'photo_viewer_screen.dart';
import 'voice_command_registrar_mixin.dart';

/// Real camera capture flow. Voice drives "Capture"/"Take Photo"/"Next
/// Picture"/"No More Photos" during a capture session — the capture button
/// and "No More Photos" button here are the tap-equivalent failsafe for
/// that, calling the exact same [_capture] / [_finishCapturing] functions
/// the registered voice commands call (see [buildVoiceCommands]). This
/// screen never touches the recognizer itself — only the shared command
/// registry, via `VoiceCommandRegistrarMixin`.
///
/// A finished job (complete/invoiced/paid/closed) never gets here under
/// normal navigation — `JobDetailScreen`'s "Add Photos" tile is hidden for
/// one (see `_PhotoStrip.canAddPhotos`) — but [build] independently checks
/// the same [activeJobStatuses] itself and refuses to initialize the
/// camera (or register any voice command — see [_jobFinished]) if it's
/// ever reached anyway, showing a plain read-only message instead. Two
/// independent layers, not one relying on the other.
class PhotoCaptureScreen extends ConsumerStatefulWidget {
  const PhotoCaptureScreen({super.key, required this.jobId});

  final String jobId;

  @override
  ConsumerState<PhotoCaptureScreen> createState() => _PhotoCaptureScreenState();
}

class _PhotoCaptureScreenState extends ConsumerState<PhotoCaptureScreen>
    with
        WidgetsBindingObserver,
        SafeRefDisposal<PhotoCaptureScreen>,
        VoiceCommandRegistrarMixin<PhotoCaptureScreen> {
  bool _flash = false;
  bool _capturing = false;
  String? _error;

  CameraController? _cameraController;
  Future<void>? _cameraInitFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    super.dispose();
  }

  /// DEFENSE IN DEPTH — Job Detail's "Add Photos" entry point is already
  /// hidden for a finished job (see `_PhotoStrip.canAddPhotos` in
  /// `job_detail_screen.dart`), so under normal navigation this screen is
  /// never reached for one at all. This is the second, independent layer:
  /// even if reached some other way (a stale button, a deep link, future
  /// code that forgets the check), [build] never initializes the camera
  /// for a finished job (see its early-return), and this makes sure voice
  /// is equally off here — a finished job is read-only for ANY new data,
  /// not just photos, matching `JobDetailScreen._voiceEligible`'s exact
  /// same [activeJobStatuses] check.
  bool get _jobFinished {
    final job = ref.read(jobByIdProvider(widget.jobId));
    return job != null && !activeJobStatuses.contains(job.status);
  }

  @override
  List<VoiceCommand> buildVoiceCommands() {
    if (_jobFinished) return const [];
    return [
      VoiceCommand(
        id: 'next_picture',
        matches: (t) => t.contains('next picture') || t.contains('next photo'),
        handler: (_) => _capture(),
      ),
      VoiceCommand(
        id: 'capture_photo',
        matches: (t) => t.contains('capture') || t.contains('take photo'),
        handler: (_) async {
          await _capture();
          await ref
              .read(globalVoiceServiceProvider.notifier)
              .speak('Photo captured, say confirm or retake');
        },
      ),
      VoiceCommand(
        id: 'no_more_photos',
        matches: (t) => t.contains('no more photo'),
        handler: (_) async {
          _finishCapturing();
          await ref.read(globalVoiceServiceProvider.notifier).speak('Finishing photos');
        },
      ),
      prepareEstimateVoiceCommand(ref: ref, jobId: widget.jobId),
      ...jobLifecycleVoiceCommands(ref, widget.jobId),
    ];
  }

  void _finishCapturing() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// `didPopNext` (from `VoiceCommandRegistrarMixin`'s `RouteAware`
  /// conformance, already subscribed for voice-command registration) also
  /// fires the moment this screen becomes visible again after whatever was
  /// covering it (Photo Preview, Estimate, ...) gets popped — used here to
  /// check whether this job's photo URLs (signed for 1 hour, see
  /// `/photos/for-job`) might have gone stale while the technician was
  /// elsewhere. `super.didPopNext()` still runs the mixin's own
  /// voice-command re-registration; this only adds the photo refresh
  /// alongside it.
  @override
  void didPopNext() {
    super.didPopNext();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(jobPhotosProvider(widget.jobId).notifier).refreshIfStale();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      controller.dispose();
      setState(() {
        _cameraController = null;
        _cameraInitFuture = null;
      });
    } else if (state == AppLifecycleState.resumed) {
      _ensureCameraInitialized();
    }
  }

  void _ensureCameraInitialized() {
    _cameraInitFuture ??= _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      debugPrint('CAMERA: enumerating available cameras...');
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('No camera found on this device.');
      final rearCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(rearCamera, ResolutionPreset.high, enableAudio: false);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      debugPrint('CAMERA: initialized rear camera successfully');
      setState(() => _cameraController = controller);
    } catch (e, stackTrace) {
      debugPrint('CAMERA ERROR (init): $e\n$stackTrace');
      if (mounted) setState(() => _error = 'Could not start the camera: $e');
    }
  }

  /// Takes the photo and hands off to [PhotoPreviewScreen] — compression and
  /// upload only happen if the technician taps Confirm there. "Capturing"
  /// stays true (keeping the shutter button's busy state, hidden behind the
  /// pushed route) until that screen is popped, so a second tap can't sneak
  /// in mid-review.
  ///
  /// Deliberately returns as soon as the photo is taken and navigation to
  /// Photo Preview is TRIGGERED — it does NOT await that screen's eventual
  /// confirm/retake outcome. This used to be one straight-line `await`
  /// chain all the way through the pop, which meant the `capture_photo`
  /// voice command handler (the only caller that `await`s this from
  /// [buildVoiceCommands]) never reported itself "finished" to
  /// `GlobalVoiceService` until the technician backed all the way out of
  /// Photo Preview — up to 28+ seconds later in the field. Since the voice
  /// service only starts listening again once the current handler's Future
  /// completes (see `_dispatchCommand` in global_voice_service_provider.dart),
  /// the recognizer sat dead the entire time Photo Preview was on screen,
  /// so its own registered commands (`confirm_photo`/`retake_photo`) never
  /// got a chance to be heard. The push + outcome-handling now runs in
  /// [_awaitPreviewOutcome], fired-and-forgotten from here, so it keeps
  /// running (and still owns resetting `_capturing`) without blocking
  /// whichever caller — voice handler or tap — is awaiting this method.
  Future<void> _capture() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || _capturing) return;

    setState(() {
      _capturing = true;
      _flash = true;
      _error = null;
    });

    try {
      debugPrint('CAMERA: taking picture...');
      final rawFile = await controller.takePicture();
      if (mounted) {
        await Future.delayed(const Duration(milliseconds: 100));
        // Re-check: the 100ms delay above is itself an async gap, and the
        // `mounted` check that gated entry into this block is now stale —
        // `setState` after real disposal throws.
        if (mounted) setState(() => _flash = false);
      }

      if (!mounted) return;
      debugPrint(
        'CAMERA: photo captured, navigating to Photo Preview — capture_photo handler (if any) '
        'is done as of here, NOT waiting for the confirm/retake outcome',
      );
      unawaited(
        _awaitPreviewOutcome(
          Navigator.of(context).push<PhotoConfirmOutcome>(
            FadeSlidePageRoute(
              builder: (_) => PhotoPreviewScreen(jobId: widget.jobId, imagePath: rawFile.path),
            ),
          ),
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('CAMERA ERROR (capture): $e\n$stackTrace');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _capturing = false;
          _flash = false;
        });
      }
    }
  }

  /// The rest of the capture flow that used to block [_capture] itself:
  /// waits for Photo Preview to actually be popped (confirm, retake, or the
  /// technician backing out) and only then resets `_capturing`/`_flash` and
  /// shows the queued-offline SnackBar. Split out so [_capture] can return
  /// — and let the voice handler that called it report "finished" — the
  /// moment navigation is triggered, while this keeps running underneath.
  Future<void> _awaitPreviewOutcome(Future<PhotoConfirmOutcome?> outcomeFuture) async {
    try {
      final outcome = await outcomeFuture;
      debugPrint(
        'CAMERA: Photo Preview flow actually completed (outcome=$outcome) — this is the real '
        'end of the work capture_photo kicked off, separate from (and later than) the voice '
        'handler already having reported itself finished',
      );
      // Shown here (after the pop), not on PhotoPreviewScreen itself — a
      // SnackBar queued right before that screen pops would be torn down
      // with the route before it's ever visible.
      if (outcome == PhotoConfirmOutcome.queuedOffline && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Saved — will upload when you're back online")));
      }
    } finally {
      if (mounted) {
        setState(() {
          _capturing = false;
          _flash = false;
        });
      }
    }
  }

  /// The camera/mic permission card to show in place of the live preview,
  /// or null when the camera may run.
  Widget? _buildPermissionGate(CameraMicState cameraMic, bool askShown) {
    final showCombinedAsk = cameraMic.checked && !cameraMic.allGranted && !askShown;
    if (showCombinedAsk) {
      final copy = cameraMicAskCopy(cameraMic);
      return PermissionCard(
        icons: copy.icons,
        title: copy.title,
        message: copy.message,
        actionLabel: 'Continue',
        actionIcon: Icons.arrow_forward_rounded,
        onAction: () async {
          await ref.read(cameraMicProvider.notifier).request();
          // The permission request is async — this widget (and its `ref`)
          // can be gone by the time it resolves.
          if (!mounted) return;
          ref.read(cameraMicAskShownProvider.notifier).state = true;
        },
      );
    }

    final showCameraGate = cameraMic.checked && !cameraMic.cameraGranted;
    if (showCameraGate) {
      final permanentlyDenied = cameraMic.camera.isPermanentlyDenied;
      debugPrint('CAMERA: permission not granted (permanentlyDenied=$permanentlyDenied)');
      return PermissionCard(
        icons: const [Icons.camera_alt_rounded],
        title: 'Camera Access Needed',
        message: permanentlyDenied
            ? 'Camera access is turned off for FieldLoop. Enable it in Settings to take job photos.'
            : 'FieldLoop needs camera access to take job site photos.',
        actionLabel: permanentlyDenied ? 'Open Settings' : 'Enable Camera',
        actionIcon: permanentlyDenied ? Icons.settings_rounded : Icons.arrow_forward_rounded,
        onAction: permanentlyDenied
            ? openAppSettings
            : () => ref.read(cameraMicProvider.notifier).request(),
      );
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(jobByIdProvider(widget.jobId));

    // DEFENSE IN DEPTH — see [_jobFinished]'s doc comment. Checked here,
    // reactively (ref.watch, not a one-time initState snapshot), before
    // anything else in this build touches the camera: no
    // `_ensureCameraInitialized()` call, no `CameraController` ever
    // created, for a finished job. Existing photos are deliberately NOT
    // shown here — Job Detail's own photo strip already shows them in
    // view-only mode; this screen's only reason to exist at all is
    // capturing NEW ones, which a finished job can never do.
    if (job != null && !activeJobStatuses.contains(job.status)) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text('Add Photos · ${job.jobIdPublic}'),
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.textDark,
          elevation: 0,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline_rounded, size: 40, color: AppColors.neutralGreyLight),
                const SizedBox(height: 14),
                const Text(
                  'This job is complete — no further photos can be added.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textDark),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: const Text('Go Back'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final photosAsync = ref.watch(jobPhotosProvider(widget.jobId));
    final photos = photosAsync.valueOrNull ?? const [];
    final cameraMic = ref.watch(cameraMicProvider);
    final askShown = ref.watch(cameraMicAskShownProvider);

    final gate = _buildPermissionGate(cameraMic, askShown);
    if (gate == null) _ensureCameraInitialized();

    // Full-screen capture: the live preview fills the whole screen (under
    // the status bar and home indicator too) and every control floats on
    // top of it, so nothing ever shrinks the viewfinder. Only the controls
    // respect the safe area.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: CaptureLayout(
          title: 'Add Photos',
          subtitle: job?.jobIdPublic,
          preview: gate == null ? _FullBleedCameraPreview(controller: _cameraController) : null,
          permissionGate: gate,
          flash: _flash,
          busy: _capturing,
          cameraReady: _cameraController?.value.isInitialized ?? false,
          showVoiceIndicator: cameraMic.micGranted,
          error: _error,
          onDismissError: () => setState(() => _error = null),
          jobId: widget.jobId,
          photos: photos,
          photosLoading: photosAsync.isLoading,
          onCapture: _capture,
          onFinish: _finishCapturing,
          onClose: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}

/// Live camera feed scaled to COVER its parent (edge to edge, cropping
/// whatever overhangs) rather than letterboxed into a small box. The box
/// handed to [CameraPreview] uses the same orientation [CameraPreview]
/// itself uses to pick its aspect ratio, so the feed is never stretched —
/// portrait or landscape.
class _FullBleedCameraPreview extends StatelessWidget {
  const _FullBleedCameraPreview({required this.controller});

  final CameraController? controller;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white54),
        ),
      );
    }

    return ValueListenableBuilder<CameraValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        // previewSize is reported in the sensor's native landscape
        // orientation; swap it for a portrait device.
        final sensor = value.previewSize ?? const Size(4, 3);
        final orientation =
            value.previewPauseOrientation ?? value.lockedCaptureOrientation ?? value.deviceOrientation;
        final landscape =
            orientation == DeviceOrientation.landscapeLeft || orientation == DeviceOrientation.landscapeRight;
        final box = landscape ? sensor : Size(sensor.height, sensor.width);

        return FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(width: box.width, height: box.height, child: CameraPreview(controller)),
        );
      },
    );
  }
}

/// The capture screen's presentation, separate from the camera/voice
/// plumbing in [PhotoCaptureScreen] so it can be laid out and tested at
/// every screen size without a real camera.
///
/// Portrait: top bar, then the captured-photos strip and a shutter /
/// "No More Photos" row along the bottom. Landscape (any device wider than
/// it is tall): the shutter and "No More Photos" move to a rail on the
/// right, like a native camera, so the controls don't eat the little
/// vertical space a landscape phone has.
class CaptureLayout extends StatelessWidget {
  const CaptureLayout({
    super.key,
    required this.title,
    required this.subtitle,
    required this.preview,
    required this.permissionGate,
    required this.flash,
    required this.busy,
    required this.cameraReady,
    required this.showVoiceIndicator,
    required this.error,
    required this.onDismissError,
    required this.jobId,
    required this.photos,
    required this.photosLoading,
    required this.onCapture,
    required this.onFinish,
    required this.onClose,
  });

  final String title;
  final String? subtitle;

  /// The live feed; null while [permissionGate] is shown instead.
  final Widget? preview;
  final Widget? permissionGate;
  final bool flash;
  final bool busy;
  final bool cameraReady;
  final bool showVoiceIndicator;
  final String? error;
  final VoidCallback onDismissError;
  final String jobId;
  final List<JobPhoto> photos;
  final bool photosLoading;
  final VoidCallback onCapture;
  final VoidCallback onFinish;
  final VoidCallback onClose;

  static const double _railWidth = 132;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final sideRail = constraints.maxWidth > constraints.maxHeight;
        final showShutter = permissionGate == null;
        final shutter = _ShutterButton(enabled: cameraReady && !busy, busy: busy, onTap: onCapture);
        final strip = _CapturedStrip(
          jobId: jobId,
          photos: photos,
          loading: photosLoading,
          showEmptyHint: showShutter,
        );

        return Stack(
          children: [
            Positioned.fill(child: preview ?? const SizedBox.shrink()),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: flash ? 0.85 : 0,
                  duration: const Duration(milliseconds: 80),
                  child: const ColoredBox(color: Colors.white),
                ),
              ),
            ),
            if (permissionGate != null)
              Positioned.fill(
                child: SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        _TopBar.height + AppSpacing.md,
                        sideRail ? _railWidth : AppSpacing.lg,
                        sideRail ? AppSpacing.lg : 160,
                      ),
                      child: MaxWidthBox(maxWidth: ContentWidth.form, child: permissionGate!),
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _Scrim(
                begin: Alignment.topCenter,
                child: SafeArea(
                  bottom: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TopBar(
                        title: title,
                        subtitle: subtitle,
                        showVoiceIndicator: showVoiceIndicator,
                        onClose: onClose,
                      ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
                          child: MaxWidthBox(
                            child: ErrorBanner(message: error!, onDismiss: onDismissError),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (sideRail) ...[
              Positioned(
                left: 0,
                right: _railWidth,
                bottom: 0,
                child: _Scrim(
                  begin: Alignment.bottomCenter,
                  child: SafeArea(
                    top: false,
                    right: false,
                    minimum: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.lg, AppSpacing.md, 0),
                      child: strip,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                child: _Scrim(
                  begin: Alignment.centerRight,
                  child: SafeArea(
                    left: false,
                    minimum: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                    child: SizedBox(
                      width: _railWidth,
                      child: Column(
                        children: [
                          const Spacer(),
                          if (showShutter) shutter,
                          const Spacer(),
                          _FinishButton(onPressed: onFinish, stacked: true),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ] else
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _Scrim(
                  begin: Alignment.bottomCenter,
                  child: SafeArea(
                    top: false,
                    minimum: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: MaxWidthBox(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xl, AppSpacing.md, 0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            strip,
                            const SizedBox(height: AppSpacing.md),
                            // Shutter dead center; "No More Photos" in the
                            // right-hand slot. Equal Expanded slots on both
                            // sides keep the shutter centered.
                            Row(
                              children: [
                                const Expanded(child: SizedBox.shrink()),
                                if (showShutter) shutter else const SizedBox(height: _ShutterButton.size),
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: _FinishButton(onPressed: onFinish, stacked: false),
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
              ),
          ],
        );
      },
    );
  }
}

/// Dark gradient behind overlaid controls so white text and icons stay
/// legible over a bright scene, fading out toward the middle of the frame.
class _Scrim extends StatelessWidget {
  const _Scrim({required this.begin, required this.child});

  final Alignment begin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: begin,
          end: -begin,
          colors: [Colors.black.withValues(alpha: 0.6), Colors.black.withValues(alpha: 0)],
        ),
      ),
      child: child,
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.showVoiceIndicator,
    required this.onClose,
  });

  static const double height = 64;

  final String title;
  final String? subtitle;
  final bool showVoiceIndicator;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: height),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xs),
        child: Row(
          children: [
            IconButton(
              onPressed: onClose,
              tooltip: 'Close camera',
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: 0.35),
                foregroundColor: Colors.white,
                minimumSize: const Size(48, 48),
              ),
              icon: const Icon(Icons.close_rounded),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                ],
              ),
            ),
            if (showVoiceIndicator)
              Container(
                margin: const EdgeInsets.only(left: AppSpacing.xs, right: AppSpacing.xxs),
                padding: const EdgeInsets.all(AppSpacing.xxs),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), shape: BoxShape.circle),
                child: const VoicePhaseIndicator(),
              ),
          ],
        ),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.enabled, required this.busy, required this.onTap});

  static const double size = 78;

  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Take photo',
      child: TapScale(
        onTap: enabled ? onTap : () {},
        child: AnimatedOpacity(
          opacity: enabled || busy ? 1 : 0.5,
          duration: const Duration(milliseconds: 150),
          child: Container(
            width: size,
            height: size,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 14)],
            ),
            child: Container(
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(strokeWidth: 2.6, color: AppColors.primaryGreen),
                    )
                  : const Icon(Icons.camera_alt_rounded, color: AppColors.primaryGreenDark, size: 28),
            ),
          ),
        ),
      ),
    );
  }
}

/// "No More Photos" — the tap equivalent of the voice command, always
/// reachable. [stacked] puts the icon over a two-line label for the narrow
/// landscape rail.
class _FinishButton extends StatelessWidget {
  const _FinishButton({required this.onPressed, required this.stacked});

  final VoidCallback onPressed;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: Colors.white.withValues(alpha: 0.92),
      foregroundColor: AppColors.primaryGreenDark,
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    );

    if (stacked) {
      return FilledButton(
        onPressed: onPressed,
        style: style,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_rounded),
            SizedBox(height: AppSpacing.xxs),
            Text('No More\nPhotos', textAlign: TextAlign.center),
          ],
        ),
      );
    }

    // FittedBox only ever shrinks the label, and only when the slot beside
    // the shutter is narrower than it (a ~320dp phone at a large
    // accessibility text size) — so it can never overflow.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: FilledButton.icon(
        onPressed: onPressed,
        style: style,
        icon: const Icon(Icons.check_rounded, size: 20),
        label: const Text('No More Photos'),
      ),
    );
  }
}

/// Captured photos for this job as one compact row of thumbnails, newest
/// first, overlaid on the preview instead of taking screen space from it.
class _CapturedStrip extends StatelessWidget {
  const _CapturedStrip({
    required this.jobId,
    required this.photos,
    required this.loading,
    required this.showEmptyHint,
  });

  static const double _thumbSize = 60;

  final String jobId;
  final List<JobPhoto> photos;
  final bool loading;
  final bool showEmptyHint;

  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty) {
      if (loading || !showEmptyHint) return const SizedBox.shrink();
      return const Text(
        'No photos yet — tap the shutter to capture one',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600),
      );
    }

    final newestFirst = photos.reversed.toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                'Captured photos (${photos.length})',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Flexible(child: PendingUploadBadge(jobId: jobId)),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          height: _thumbSize,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: newestFirst.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.xs),
            itemBuilder: (context, index) {
              final photo = newestFirst[index];
              return TapScale(
                onTap: () => Navigator.of(
                  context,
                ).push(FadeSlidePageRoute(builder: (_) => PhotoViewerScreen(photo: photo))),
                child: Container(
                  width: _thumbSize,
                  decoration: BoxDecoration(
                    borderRadius: AppRadius.tile,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.md - 2),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        JobPhotoThumbnail(photo: photo),
                        if (photo.status == JobPhotoStatus.uploading)
                          Container(
                            color: Colors.black.withValues(alpha: 0.35),
                            alignment: Alignment.center,
                            child: const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                            ),
                          ),
                        if (photo.status == JobPhotoStatus.failed)
                          Container(
                            color: Colors.black.withValues(alpha: 0.45),
                            alignment: Alignment.center,
                            child: const Icon(Icons.error_outline_rounded, color: Colors.white, size: 22),
                          ),
                        if (photo.status == JobPhotoStatus.queuedOffline)
                          Container(
                            color: Colors.black.withValues(alpha: 0.35),
                            alignment: Alignment.center,
                            child: const Icon(Icons.cloud_upload_outlined, color: Colors.white, size: 20),
                          ),
                      ],
                    ),
                  ),
                ),
              ).animate().fadeIn(duration: 250.ms).scale(begin: const Offset(0.85, 0.85), end: const Offset(1, 1));
            },
          ),
        ),
      ],
    );
  }
}
