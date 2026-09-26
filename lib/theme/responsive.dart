import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'design_tokens.dart';

/// The app's one breakpoint system, shared by every screen so phones,
/// Android tablets, iPads and landscape phones all switch layout at the same
/// widths. Values follow Material 3's window size classes.
///
/// Prefer the width a widget is actually given (a [LayoutBuilder]'s
/// `constraints.maxWidth`) over the window width — it is the same thing for
/// a full-screen page, and still right if the page is ever shown in a split
/// view or a side pane.
abstract final class Breakpoints {
  /// 7-8" tablets in portrait, large phones in landscape.
  static const double medium = 600;

  /// Large tablets / iPads in landscape, iPad Pro in portrait.
  static const double expanded = 840;
}

enum WindowSize {
  compact,
  medium,
  expanded;

  static WindowSize ofWidth(double width) {
    if (width >= Breakpoints.expanded) return expanded;
    if (width >= Breakpoints.medium) return medium;
    return compact;
  }

  bool get isCompact => this == compact;
  bool get isExpanded => this == expanded;
}

/// Widest content is allowed to grow before it is centered with side
/// gutters — so a tablet shows a readable column instead of phone cards
/// stretched edge to edge.
abstract final class ContentWidth {
  /// Sign-in / setup forms.
  static const double form = 440;

  /// Lists, detail pages, settings, documents.
  static const double reading = 720;

  /// Multi-column layouts (two job cards side by side).
  static const double wide = 1120;
}

/// Horizontal padding that keeps content at most [maxContentWidth] wide and
/// centered in [width], never less than [min] per side.
double responsiveGutter(double width, {double maxContentWidth = ContentWidth.reading, double min = AppSpacing.md}) =>
    math.max(min, (width - maxContentWidth) / 2);

extension ResponsiveContext on BuildContext {
  WindowSize get windowSize => WindowSize.ofWidth(MediaQuery.sizeOf(this).width);
}

/// Centers [child] and caps its width at [maxWidth].
class MaxWidthBox extends StatelessWidget {
  const MaxWidthBox({super.key, required this.child, this.maxWidth = ContentWidth.reading});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
