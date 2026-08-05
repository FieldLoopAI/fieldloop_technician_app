import 'package:flutter/material.dart';

/// A scale-down-on-press wrapper for custom tappable surfaces that aren't
/// [ElevatedButton]/[OutlinedButton] (e.g. cards, chips, tiles), matching
/// the button press animation used throughout the app.
class TapScale extends StatefulWidget {
  const TapScale({super.key, required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<TapScale> createState() => _TapScaleState();
}

class _TapScaleState extends State<TapScale> {
  double _scale = 1;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.96),
      onTapUp: (_) => setState(() => _scale = 1),
      onTapCancel: () => setState(() => _scale = 1),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: widget.child,
      ),
    );
  }
}
