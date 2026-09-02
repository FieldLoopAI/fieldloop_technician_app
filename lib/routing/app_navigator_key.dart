import 'package:flutter/material.dart';

/// The single root [NavigatorState] key for the whole app — assigned to
/// `MaterialApp.navigatorKey` in `app.dart`. Needed so a tapped system
/// notification (see `local_notifications_service.dart`) can push straight
/// to `JobDetailScreen` from the plugin's tap callback, which fires outside
/// any widget's `build` and so has no `BuildContext` of its own to call
/// `Navigator.of(context)` with.
final rootNavigatorKey = GlobalKey<NavigatorState>();
