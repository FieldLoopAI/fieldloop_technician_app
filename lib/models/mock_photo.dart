import 'package:flutter/material.dart';

/// A job-site photo. Since there's no camera/storage wired up yet, [color]
/// stands in for the actual image as a placeholder swatch.
class MockPhoto {
  const MockPhoto({
    required this.id,
    required this.caption,
    required this.timestamp,
    required this.color,
  });

  final String id;
  final String caption;
  final DateTime timestamp;
  final Color color;
}
