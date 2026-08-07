import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/job_photo.dart';
import '../providers/global_voice_service_provider.dart';
import '../providers/job_photos_provider.dart';
import '../providers/job_voice_commands.dart';
import '../providers/jobs_provider.dart';
import '../providers/permission_providers.dart';
import '../providers/safe_ref_disposal.dart';
import '../providers/voice_command_registry_provider.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../widgets/error_banner.dart';
import '../widgets/permission_card.dart';
import '../widgets/tap_scale.dart';
import '../widgets/voice_listening_indicator.dart';
import 'estimate_screen.dart';
import 'photo_preview_screen.dart';
import 'voice_command_registrar_mixin.dart';

/// Real camera capture flow. Voice drives "Capture"/"Take Photo"/"Next
/// Picture"/"No More Photos" during a capture session — the capture button
/// and "No More Photos" button here are the tap-equivalent failsafe for
/// that, calling the exact same [_capture] / [_finishCapturing] functions
/// the registered voice commands call (see [buildVoiceCommands]). This
/// screen never touches the recognizer itself — only the shared command
/// registry, via `VoiceCommandRegistrarMixin`.
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

  @override
  List<VoiceCommand> buildVoiceCommands() {
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
      prepareEstimateVoiceCommand(
        ref: ref,
        jobId: widget.jobId,
        navigate: () => Navigator.of(
          context,
        ).push(FadeSlidePageRoute(builder: (_) => EstimateScreen(jobId: widget.jobId))),
      ),
      ...jobLifecycleVoiceCommands(ref, widget.jobId),
    ];
  }

  void _finishCapturing() {
    if (!mounted) return;
    Navigator.of(context).pop();
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
      await Navigator.of(context).push(
        FadeSlidePageRoute(
          builder: (_) => PhotoPreviewScreen(jobId: widget.jobId, imagePath: rawFile.path),
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('CAMERA ERROR (capture): $e\n$stackTrace');
      if (mounted) setState(() => _error = e.toString());
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
    final photosAsync = ref.watch(jobPhotosProvider(widget.jobId));
    final photos = photosAsync.valueOrNull ?? const [];
    final cameraMic = ref.watch(cameraMicProvider);
    final askShown = ref.watch(cameraMicAskShownProvider);

    // The recognizer itself is a single global service, started once at
    // RootShell (see GlobalVoiceService) — this screen only watches its
    // state for the indicator and offers its own commands while active
    // (see buildVoiceCommands).
    final voiceSession = ref.watch(globalVoiceServiceProvider);

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
              child: Center(
                child: VoiceListeningIndicator(
                  phase: voiceSession.phase,
                  showRings: false,
                  coreSize: 34,
                  iconSize: 16,
                ),
              ),
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
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Captured photos (${photos.length})',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textDark,
                      ),
                    ),
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
            return ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (photo.localBytes != null)
                    Image.memory(photo.localBytes!, fit: BoxFit.cover)
                  else
                    Container(
                      color: AppColors.borderGrey,
                      alignment: Alignment.center,
                      child: const Icon(Icons.check_circle_rounded, color: AppColors.primaryGreen, size: 28),
                    ),
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
                ],
              ),
            ).animate(delay: (40 * index).ms).fadeIn(duration: 250.ms).scale(begin: const Offset(0.9, 0.9), end: const Offset(1, 1));
          },
        );
      },
    );
  }
}
