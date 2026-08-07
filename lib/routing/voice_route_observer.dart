import 'package:flutter/material.dart';

/// Global route observer so voice-command-registering screens (see
/// `VoiceCommandRegistrarMixin`) know exactly when they become the
/// active/visible screen (`didPush`/`didPopNext`) versus get covered by
/// another screen pushed on top (`didPushNext`) or popped themselves
/// (`didPop`) — registered once on the app's single `MaterialApp` in
/// `app.dart`.
final voiceRouteObserver = RouteObserver<PageRoute<void>>();
