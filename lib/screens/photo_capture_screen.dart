import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
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

  Widget _buildPreviewArea(CameraMicState cameraMic, bool askShown, double maxPreviewHeight) {
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

    _ensureCameraInitialized();

    return _CameraPreview(
      controller: _cameraController,
      flash: _flash,
      busy: _capturing,
      onCapture: _capture,
      maxHeight: maxPreviewHeight,
    );
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

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(job != null ? 'Add Photos · ${job.jobIdPublic}' : 'Add Photos'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
        actions: [
          if (cameraMic.micGranted)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(child: VoicePhaseIndicator()),
            ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isTablet = constraints.maxWidth > 600;
            final horizontalPadding = isTablet ? constraints.maxWidth * 0.12 : 16.0;
            // Bounds the preview by available height as well as width so a
            // wide/short viewport (tablets especially — a 4:3 preview at
            // full tablet width can be taller than the whole screen) can
            // never push the rest of the column into overflow.
            final maxPreviewHeight = (constraints.maxHeight * 0.42).clamp(180.0, 520.0).toDouble();

            return Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(horizontalPadding, 16, horizontalPadding, 0),
                  child: _buildPreviewArea(cameraMic, askShown, maxPreviewHeight),
                ),
                if (_error != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(horizontalPadding, 12, horizontalPadding, 0),
                    child: ErrorBanner(message: _error!, onDismiss: () => setState(() => _error = null)),
                  ),
                const SizedBox(height: 20),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                  child: Row(
                    children: [
                      Text(
                        'Captured photos (${photos.length})',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textDark,
                        ),
                      ),
                      const Spacer(),
                      PendingUploadBadge(jobId: widget.jobId),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: photos.isEmpty
                      ? (photosAsync.isLoading
                            ? const Center(child: CircularProgressIndicator())
                            : const _EmptyGridState())
                      : _PhotoGrid(photos: photos, horizontalPadding: horizontalPadding),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(horizontalPadding, 8, horizontalPadding, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _finishCapturing,
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('No More Photos'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primaryGreenDark,
                        side: const BorderSide(color: AppColors.primaryGreen),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CameraPreview extends StatelessWidget {
  const _CameraPreview({
    required this.controller,
    required this.flash,
    required this.busy,
    required this.onCapture,
    required this.maxHeight,
  });

  final CameraController? controller;
  final bool flash;
  final bool busy;
  final VoidCallback onCapture;

  /// Height budget handed down from the screen's own [LayoutBuilder] — the
  /// preview must never grow taller than this, even on a wide tablet where
  /// a 4:3 preview at full available width would otherwise be taller than
  /// the screen itself.
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final ready = controller != null && controller!.value.isInitialized;

    // previewSize is reported in the sensor's native (landscape) orientation
    // even when displaying portrait, so the on-screen ratio is height/width.
    // Falls back to a 3:4 portrait ratio (the 4:3 capture preset, rotated)
    // until the controller reports a real size.
    double previewRatio = 3 / 4;
    if (ready) {
      final size = controller!.value.previewSize;
      if (size != null && size.width > 0 && size.height > 0) {
        previewRatio = size.height / size.width;
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Size from the available width first, then clamp to the height
        // budget — whichever is tighter wins, and the other dimension is
        // derived from it so the aspect ratio is always preserved.
        final heightFromWidth = constraints.maxWidth * previewRatio;
        final previewHeight = heightFromWidth > maxHeight ? maxHeight : heightFromWidth;
        final previewWidth = previewHeight / previewRatio;

        return Center(
          child: SizedBox(
            width: previewWidth,
            height: previewHeight,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF2B2F33), Color(0xFF15181A)],
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  alignment: Alignment.center,
                  children: [
                    if (ready)
                      FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: controller!.value.previewSize?.height ?? 1,
                          height: controller!.value.previewSize?.width ?? 1,
                          child: CameraPreview(controller!),
                        ),
                      )
                    else
                      const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white54),
                      ),
                    AnimatedOpacity(
                      opacity: flash ? 1 : 0,
                      duration: const Duration(milliseconds: 80),
                      child: Container(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: -28,
              child: TapScale(
                onTap: ready && !busy ? onCapture : () {},
                child: Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.surface,
                    border: Border.all(color: AppColors.primaryGreen, width: 4),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 14, offset: const Offset(0, 6)),
                    ],
                  ),
                  child: busy
                      ? const Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.primaryGreen),
                        )
                      : const Icon(Icons.camera_alt_rounded, color: AppColors.primaryGreen, size: 28),
                ),
              ),
            ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EmptyGridState extends StatelessWidget {
  const _EmptyGridState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.photo_library_outlined, size: 44, color: AppColors.neutralGreyLight),
          const SizedBox(height: 10),
          const Text(
            'No photos yet — tap the shutter to capture one',
            style: TextStyle(color: AppColors.neutralGrey, fontSize: 13.5),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _PhotoGrid extends StatelessWidget {
  const _PhotoGrid({required this.photos, required this.horizontalPadding});

  final List<JobPhoto> photos;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth > 700 ? 4 : 3;
        return GridView.builder(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 4),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.9,
          ),
          itemCount: photos.length,
          itemBuilder: (context, index) {
            final photo = photos[index];
            return TapScale(
              onTap: () => Navigator.of(
                context,
              ).push(FadeSlidePageRoute(builder: (_) => PhotoViewerScreen(photo: photo))),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    JobPhotoThumbnail(photo: photo, iconSize: 28),
                    if (photo.status == JobPhotoStatus.uploading)
                      Container(
                        color: Colors.black.withValues(alpha: 0.35),
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(strokeWidth: 2.6, color: Colors.white),
                        ),
                      ),
                    if (photo.status == JobPhotoStatus.failed)
                      Container(
                        color: Colors.black.withValues(alpha: 0.45),
                        alignment: Alignment.center,
                        child: const Icon(Icons.error_outline_rounded, color: Colors.white, size: 28),
                      ),
                    if (photo.status == JobPhotoStatus.queuedOffline)
                      Container(
                        color: Colors.black.withValues(alpha: 0.35),
                        alignment: Alignment.center,
                        child: const Icon(Icons.cloud_upload_outlined, color: Colors.white, size: 26),
                      ),
                  ],
                ),
              ),
            ).animate(delay: (40 * index).ms).fadeIn(duration: 250.ms).scale(begin: const Offset(0.9, 0.9), end: const Offset(1, 1));
          },
        );
      },
    );
  }
}
