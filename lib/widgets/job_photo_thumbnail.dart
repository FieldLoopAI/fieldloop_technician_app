import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/job_photo.dart';
import '../theme/app_theme.dart';

/// Renders a [JobPhoto] as an image — local bytes (captured this session)
/// take priority since they're already in memory; otherwise the signed
/// [JobPhoto.url] from `/photos/for-job` is loaded via `CachedNetworkImage`
/// (with its own loading/error placeholders, e.g. for an expired link);
/// falling back to a generic checkmark if neither is available yet (still
/// loading the very first fetch). Shared by the Job Detail photo strip and
/// the Photo Capture grid so both render photos identically.
class JobPhotoThumbnail extends StatelessWidget {
  const JobPhotoThumbnail({super.key, required this.photo, this.iconSize = 22});

  final JobPhoto photo;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    if (photo.localBytes != null) {
      return Image.memory(photo.localBytes!, fit: BoxFit.cover);
    }

    final url = photo.url;
    if (url != null) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        placeholder: (context, url) => Container(
          color: AppColors.borderGrey,
          alignment: Alignment.center,
          child: SizedBox(
            width: iconSize * 0.7,
            height: iconSize * 0.7,
            child: const CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryGreen),
          ),
        ),
        errorWidget: (context, url, error) => Container(
          color: AppColors.borderGrey,
          alignment: Alignment.center,
          child: Icon(Icons.broken_image_outlined, color: AppColors.neutralGreyLight, size: iconSize),
        ),
      );
    }

    return Container(
      color: AppColors.borderGrey,
      alignment: Alignment.center,
      child: Icon(Icons.check_circle_rounded, color: AppColors.primaryGreen, size: iconSize),
    );
  }
}
