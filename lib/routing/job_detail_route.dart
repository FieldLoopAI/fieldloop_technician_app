import 'package:flutter/widgets.dart';

/// The route the open job's `JobDetailScreen` lives on — set by that screen
/// while it's mounted, so the voice "go to Job Details" command can pop
/// straight back to it (`GeminiNavigationSession.goToJobDetails`) no matter
/// how many screens sit on top, or whether they were opened by voice or by
/// tapping. Routes in this app are pushed unnamed, so the route object
/// itself is the only reliable handle.
ModalRoute<Object?>? _activeJobDetailRoute;

ModalRoute<Object?>? get activeJobDetailRoute => _activeJobDetailRoute;

void setActiveJobDetailRoute(ModalRoute<Object?> route) => _activeJobDetailRoute = route;

/// Only clears if [route] is still the one recorded — a newer Job Detail's
/// registration must not be wiped by an older one's late dispose.
void clearActiveJobDetailRoute(ModalRoute<Object?>? route) {
  if (identical(_activeJobDetailRoute, route)) _activeJobDetailRoute = null;
}
