import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/job_photo.dart';

String _formatCapturedAt(DateTime dt) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  final suffix = dt.hour >= 12 ? 'PM' : 'AM';
  return '${months[dt.month - 1]} ${dt.day}, ${dt.year} · $hour12:$minute $suffix';
}

/// Full-screen, read-only view of a job photo — reachable by tapping any
/// thumbnail in the photo strip/grid (Job Detail, Photo Capture). Distinct
/// from [PhotoPreviewScreen]: that one is the confirm/retake flow for a
/// photo JUST captured and not yet uploaded; this one is for browsing a
/// photo that already exists, whether from this session ([JobPhoto.
/// localBytes]) or a previous one (loaded via [JobPhoto.url], a temporary
/// signed S3 link from `/photos/for-job`).
class PhotoViewerScreen extends StatelessWidget {
  const PhotoViewerScreen({super.key, required this.photo});

  final JobPhoto photo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          _formatCapturedAt(photo.timestamp),
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          Expanded(child: Center(child: _PhotoViewerImage(photo: photo))),
          if (photo.hasNote) _PhotoNotePanel(note: photo.transcript!.trim()),
        ],
      ),
    );
  }
}

/// The technician's spoken description of this photo (its
/// `field_events.transcript`), shown under the image.
class _PhotoNotePanel extends StatelessWidget {
  const _PhotoNotePanel({required this.note});

  final String note;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.3),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        color: Colors.white.withValues(alpha: 0.08),
        child: SingleChildScrollView(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.sticky_note_2_outlined, color: Colors.white70, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(note, style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.35)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoViewerImage extends StatelessWidget {
  const _PhotoViewerImage({required this.photo});

  final JobPhoto photo;

  @override
  Widget build(BuildContext context) {
    // Same priority as the thumbnail tiles: local bytes (this session) are
    // already in memory and always take precedence over a network fetch.
    if (photo.localBytes != null) {
      return Image.memory(photo.localBytes!, fit: BoxFit.contain);
    }

    final url = photo.url;
    if (url != null) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.contain,
        placeholder: (context, url) => const Padding(
          padding: EdgeInsets.all(40),
          child: CircularProgressIndicator(color: Colors.white70),
        ),
        errorWidget: (context, url, error) => const Padding(
          padding: EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
              SizedBox(height: 12),
              Text(
                "This photo couldn't be loaded — its link may have expired",
                style: TextStyle(color: Colors.white70, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return const Icon(Icons.image_not_supported_outlined, color: Colors.white38, size: 64);
  }
}
