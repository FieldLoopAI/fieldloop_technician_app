import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';

/// Change-order approval state as a [StatusChip] — used everywhere change
/// orders are listed (Job Details' Change Orders tab and the Change Orders
/// screen), with the shared [StatusTone] colors: amber = pending, green =
/// approved, red = declined, grey = voided.
class ApprovalStatusPill extends StatelessWidget {
  const ApprovalStatusPill({super.key, required this.status, this.voided = false});

  /// Raw `change_orders.status`.
  final String status;
  final bool voided;

  @override
  Widget build(BuildContext context) {
    if (voided) return const StatusChip(tone: StatusTone.neutral, label: 'Voided', icon: Icons.block_rounded);
    return switch (status) {
      'pending' => const StatusChip(tone: StatusTone.pending, label: 'Pending approval'),
      'approved' => const StatusChip(tone: StatusTone.approved, label: 'Approved'),
      'declined' => const StatusChip(tone: StatusTone.declined, label: 'Declined'),
      _ => StatusChip(tone: StatusTone.neutral, label: status, icon: Icons.help_outline_rounded),
    };
  }
}
