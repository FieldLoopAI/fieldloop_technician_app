import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/global_voice_service_provider.dart';
import '../providers/job_photos_provider.dart';
import '../providers/job_voice_commands.dart';
import '../providers/safe_ref_disposal.dart';
import '../providers/voice_command_registry_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/error_banner.dart';
import '../widgets/primary_button.dart';
import 'voice_command_registrar_mixin.dart';

const int _maxPhotoBytes = 300 * 1024;

/// Result of [_PhotoPreviewScreenState._confirm], and what this screen pops
/// with — `null` means "retaken, no outcome." [queuedOffline] is still a
/// success from the technician's perspective (see [_confirm]): the photo is
/// safely saved locally and will upload automatically, so this screen still
/// navigates back normally, just with a different confirmation message than
/// [uploaded]. Only [failed] leaves this screen open with an on-screen error.
enum PhotoConfirmOutcome { uploaded, queuedOffline, failed }

/// Shown right after the shutter fires, before anything is compressed or
/// uploaded. "Retake" discards the captured file and returns to the live
/// camera with no upload or `field_events` write having happened; "Confirm"
/// runs compression (under [_maxPhotoBytes], EXIF-corrected) then the
/// existing upload flow, and only then pops back to the capture screen.
///
/// Voice "confirm"/"retake" while this screen is showing call the exact
/// same [_confirm]/[_retake] the buttons do — registered via
/// `VoiceCommandRegistrarMixin` exactly while this screen is the active
/// one, same as every other job-scoped screen.
class PhotoPreviewScreen extends ConsumerStatefulWidget {
  const PhotoPreviewScreen({super.key, required this.jobId, required this.imagePath});

  final String jobId;
  final String imagePath;

  @override
  ConsumerState<PhotoPreviewScreen> createState() => _PhotoPreviewScreenState();
}

class _PhotoPreviewScreenState extends ConsumerState<PhotoPreviewScreen>
    with SafeRefDisposal<PhotoPreviewScreen>, VoiceCommandRegistrarMixin<PhotoPreviewScreen> {
  bool _uploading = false;
  String? _error;

  @override
  List<VoiceCommand> buildVoiceCommands() {
    return [
      VoiceCommand(
        id: 'confirm_photo',
        matches: (t) => t.contains('confirm'),
        // Short, single-word vocabulary — finalizes on a much shorter
        // silence window than the shared default (tuned for multi-word
        // phrases like "job complete"), so the technician isn't left
        // waiting ~2s after just saying "confirm". See
        // VoiceCommand.pauseWindow.
        pauseWindow: shortCommandPauseWindow,
        handler: (_) async {
          final service = ref.read(globalVoiceServiceProvider.notifier);
          await service.speak('Uploading photo');
          final outcome = await _confirm();
          switch (outcome) {
            case PhotoConfirmOutcome.uploaded:
              await service.speak('Photo saved');
            case PhotoConfirmOutcome.queuedOffline:
              await service.speak("Saved — will upload when you're back online");
            case PhotoConfirmOutcome.failed:
              await service.speak("Sorry, the photo couldn't be saved");
          }
        },
      ),
      VoiceCommand(
        id: 'retake_photo',
        matches: (t) => t.contains('retake'),
        pauseWindow: shortCommandPauseWindow,
        handler: (_) async {
          await _retake();
          await ref.read(globalVoiceServiceProvider.notifier).speak('Retaking photo');
        },
      ),
      ...jobLifecycleVoiceCommands(ref, widget.jobId),
    ];
  }

  Future<Uint8List> _compressImage(String path) async {
    var quality = 85;
    Uint8List? result;

    while (quality >= 30) {
      final compressed = await FlutterImageCompress.compressWithFile(
        path,
        quality: quality,
        format: CompressFormat.jpeg,
        autoCorrectionAngle: true,
      );
      if (compressed == null) {
        throw StateError('Image compression returned no data.');
      }
      result = compressed;
      debugPrint('PHOTOS: compressed at quality=$quality -> ${compressed.length} bytes');
      if (compressed.length <= _maxPhotoBytes) break;
      quality -= 15;
    }

    if (result == null) throw StateError('Image compression failed.');
    return result;
  }

  Future<PhotoConfirmOutcome> _confirm() async {
    if (_uploading) return PhotoConfirmOutcome.failed;
    setState(() {
      _uploading = true;
      _error = null;
    });

    try {
      Uint8List compressed;
      try {
        compressed = await _compressImage(widget.imagePath);
      } catch (e, stackTrace) {
        debugPrint('PHOTOS ERROR (compression): $e\n$stackTrace');
        rethrow;
      }

      // `uploadPhoto` itself decides whether this is an immediate upload or
      // a network failure that gets queued locally instead — either way it
      // does NOT throw, so from here on this is the success path for both.
      final result = await ref.read(jobPhotosProvider(widget.jobId).notifier).uploadPhoto(compressed);

      unawaited(File(widget.imagePath).delete().catchError((_) => File(widget.imagePath)));

      final outcome = result == PhotoUploadResult.queuedOffline
          ? PhotoConfirmOutcome.queuedOffline
          : PhotoConfirmOutcome.uploaded;

      // The friendly "saved — will upload later" message is shown as a
      // SnackBar on PhotoCaptureScreen (the screen this pops back to) once
      // this route is gone, not here — a SnackBar queued on this screen
      // right before popping it would be torn down with the route before
      // it's visible. See PhotoCaptureScreen._capture.
      if (mounted) Navigator.of(context).pop(outcome);
      return outcome;
    } catch (e, stackTrace) {
      debugPrint('PHOTO CONFIRM ERROR: $e\n$stackTrace');
      if (mounted) setState(() => _error = e.toString());
      return PhotoConfirmOutcome.failed;
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _retake() async {
    if (_uploading) return;
    try {
      await File(widget.imagePath).delete();
    } catch (e) {
      debugPrint('PHOTOS: could not delete discarded photo file: $e');
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_uploading,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: const Text('Review Photo'),
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.textDark,
          elevation: 0,
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Same tablet-aware treatment as the capture screen — on a
              // wide viewport, full-bleed padding stretches the image and
              // buttons uncomfortably wide.
              final isTablet = constraints.maxWidth > 600;
              final horizontalPadding = isTablet ? constraints.maxWidth * 0.12 : 16.0;

              return Padding(
                padding: EdgeInsets.fromLTRB(horizontalPadding, 16, horizontalPadding, 16),
                child: Column(
                  children: [
                Expanded(
                  child:
                      ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Container(
                              width: double.infinity,
                              color: const Color(0xFF15181A),
                              child: Image.file(File(widget.imagePath), fit: BoxFit.contain),
                            ),
                          )
                          .animate()
                          .fadeIn(duration: 250.ms)
                          .scale(
                            begin: const Offset(0.94, 0.94),
                            end: const Offset(1, 1),
                            duration: 250.ms,
                            curve: Curves.easeOut,
                          ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  ErrorBanner(message: _error!, onDismiss: () => setState(() => _error = null)),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 54,
                        child: OutlinedButton.icon(
                          onPressed: _uploading ? null : _retake,
                          icon: const Icon(Icons.replay_rounded),
                          label: const Text('Retake'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.primaryGreenDark,
                            side: const BorderSide(color: AppColors.primaryGreen),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: PrimaryButton(
                        label: 'Confirm',
                        icon: Icons.check_rounded,
                        isLoading: _uploading,
                        onPressed: _uploading ? null : _confirm,
                      ),
                    ),
                  ],
                ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
