import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/job_photos_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/error_banner.dart';
import '../widgets/primary_button.dart';

const int _maxPhotoBytes = 300 * 1024;

/// Shown right after the shutter fires, before anything is compressed or
/// uploaded. "Retake" discards the captured file and returns to the live
/// camera with no upload or `field_events` write having happened; "Confirm"
/// runs compression (under [_maxPhotoBytes], EXIF-corrected) then the
/// existing upload flow, and only then pops back to the capture screen.
class PhotoPreviewScreen extends ConsumerStatefulWidget {
  const PhotoPreviewScreen({super.key, required this.jobId, required this.imagePath});

  final String jobId;
  final String imagePath;

  @override
  ConsumerState<PhotoPreviewScreen> createState() => _PhotoPreviewScreenState();
}

class _PhotoPreviewScreenState extends ConsumerState<PhotoPreviewScreen> {
  bool _uploading = false;
  String? _error;

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

  Future<void> _confirm() async {
    if (_uploading) return;
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

      await ref.read(jobPhotosProvider(widget.jobId).notifier).uploadPhoto(compressed);

      unawaited(File(widget.imagePath).delete().catchError((_) => File(widget.imagePath)));

      if (mounted) Navigator.of(context).pop(true);
    } catch (e, stackTrace) {
      debugPrint('PHOTO CONFIRM ERROR: $e\n$stackTrace');
      if (mounted) setState(() => _error = e.toString());
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
    if (mounted) Navigator.of(context).pop(false);
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
          child: Padding(
            padding: const EdgeInsets.all(16),
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
          ),
        ),
      ),
    );
  }
}
