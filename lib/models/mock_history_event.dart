import 'package:flutter/material.dart';

enum HistoryEventType { arrival, photo, voiceNote, estimate, changeOrder, invoice, payment }

extension HistoryEventTypeX on HistoryEventType {
  IconData get icon {
    switch (this) {
      case HistoryEventType.arrival:
        return Icons.location_on_rounded;
      case HistoryEventType.photo:
        return Icons.photo_camera_rounded;
      case HistoryEventType.voiceNote:
        return Icons.mic_rounded;
      case HistoryEventType.estimate:
        return Icons.description_rounded;
      case HistoryEventType.changeOrder:
        return Icons.edit_note_rounded;
      case HistoryEventType.invoice:
        return Icons.receipt_long_rounded;
      case HistoryEventType.payment:
        return Icons.payments_rounded;
    }
  }
}

/// A single entry in a job's activity timeline.
class MockHistoryEvent {
  const MockHistoryEvent({
    required this.type,
    required this.description,
    required this.timestamp,
  });

  final HistoryEventType type;
  final String description;
  final DateTime timestamp;
}
