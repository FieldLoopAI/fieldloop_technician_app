import 'package:flutter/material.dart';

class _StatusStyle {
  const _StatusStyle(this.foreground, this.background);
  final Color foreground;
  final Color background;
}

/// A small colored badge for a job's status (e.g. "scheduled", "en_route").
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status});

  final String status;

  static const Map<String, _StatusStyle> _styles = {
    'draft': _StatusStyle(Color(0xFF6B7280), Color(0xFFF3F4F6)),
    'scheduled': _StatusStyle(Color(0xFF6B7280), Color(0xFFF3F4F6)),
    'en_route': _StatusStyle(Color(0xFF2563EB), Color(0xFFDBEAFE)),
    'on_site': _StatusStyle(Color(0xFFD97706), Color(0xFFFEF3C7)),
    'complete': _StatusStyle(Color(0xFF0F9D58), Color(0xFFE3F5E9)),
    'invoiced': _StatusStyle(Color(0xFF7C3AED), Color(0xFFEDE3FB)),
    'paid': _StatusStyle(Color(0xFF0F9D58), Color(0xFFE3F5E9)),
    'closed': _StatusStyle(Color(0xFF374151), Color(0xFFE5E7EB)),
  };

  String get _label => status
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  @override
  Widget build(BuildContext context) {
    final style =
        _styles[status] ?? const _StatusStyle(Color(0xFF6B7280), Color(0xFFF3F4F6));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _label.isEmpty ? 'Unknown' : _label,
        style: TextStyle(color: style.foreground, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}
