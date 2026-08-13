import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/safe_ref_disposal.dart';
import '../providers/voice_command_registry_provider.dart';
import '../routing/voice_route_observer.dart';

/// Mix into any job-scoped screen that has voice commands available.
/// Registers [buildVoiceCommands] into the shared `voiceCommandRegistryProvider`
/// exactly while this screen is the active/visible one, and removes them
/// otherwise — not just on mount/unmount, but on every route transition
/// (`didPush`/`didPopNext` = became active, `didPushNext`/`didPop` = no
/// longer active), via [RouteAware]/`voiceRouteObserver`. That's what makes
/// "Job Detail underneath a pushed Photo Capture screen" correctly stop
/// offering Job Detail's commands while it's covered, then resume offering
/// them the moment Photo Capture pops back.
///
/// Screens using this mixin never start, stop, or otherwise touch the
/// recognizer itself (see `GlobalVoiceService`) — only this command list.
mixin VoiceCommandRegistrarMixin<T extends ConsumerStatefulWidget> on SafeRefDisposal<T>
    implements RouteAware {
  late final VoiceCommandRegistry _voiceRegistry;
  List<String> _registeredCommandIds = const [];
  bool _routeSubscribed = false;

  // Bumped by every register/unregister call. A scheduled registration
  // checks this before applying, so a fast register-then-immediately-
  // unregister (e.g. this screen gets covered before its own postFrame
  // callback has even fired) can't have the deferred callback re-apply a
  // now-stale registration after the unregister already ran.
  int _registrationGeneration = 0;

  /// This screen's currently-available voice commands — called fresh every
  /// time the screen becomes the active/visible one, so closures always
  /// capture the current `BuildContext`/job state, never a stale one from
  /// before the screen was covered.
  List<VoiceCommand> buildVoiceCommands();

  @override
  void initState() {
    super.initState();
    _voiceRegistry = capture((ref) => ref.read(voiceCommandRegistryProvider.notifier));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_routeSubscribed) {
      final route = ModalRoute.of(context);
      if (route is PageRoute) {
        _routeSubscribed = true;
        voiceRouteObserver.subscribe(this, route);
      }
    }
  }

  /// `didPush`/`didPopNext` (which call this) can fire while Flutter is
  /// still in the middle of building this screen's widget tree for the
  /// first time (synchronously, from `didChangeDependencies`) — a provider
  /// write at that point is unsafe regardless of `mounted`, since the
  /// "cannot modify a provider while the widget tree is building" hazard is
  /// about the BUILD PHASE, not this widget's lifecycle. Deferring the
  /// actual write to a post-frame callback avoids that; the `safeWrite`
  /// (mounted-guarded) check inside still matters separately, since the
  /// deferred callback itself can fire after this widget was disposed in a
  /// fast-navigation scenario — this needs both, not one or the other.
  ///
  /// DIAGNOSTIC (voice-going-stale investigation) — this deferral means
  /// the TRIGGER (this RouteAware callback firing) and the APPLY (the
  /// registry actually being mutated, a frame later) can land in a
  /// different order than the raw sequence of navigation events would
  /// suggest, e.g. Photo Preview's didPop() (unregister, applied
  /// immediately) racing Job Detail's didPopNext() (register, deferred a
  /// full frame) — logging both points with millisecond timestamps is
  /// what makes that visible instead of assumed.
  void _registerCommands() {
    debugPrint('VOICE REGISTRY [t=${DateTime.now().millisecondsSinceEpoch}]: $T register TRIGGERED (didPush/didPopNext)');
    final commands = buildVoiceCommands();
    final ids = commands.map((c) => c.id).toList(growable: false);
    final generation = ++_registrationGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Superseded by a later register/unregister that happened before
      // this frame's callbacks ran (e.g. covered again immediately) — that
      // call already left the registry in the state it wants; applying
      // this older snapshot on top would be wrong.
      if (generation != _registrationGeneration) {
        debugPrint(
          'VOICE REGISTRY [t=${DateTime.now().millisecondsSinceEpoch}]: $T register APPLY skipped — '
          'superseded by a later trigger before this frame ran',
        );
        return;
      }
      safeWrite(() {
        debugPrint('VOICE REGISTRY [t=${DateTime.now().millisecondsSinceEpoch}]: $T register APPLYING [${ids.join(', ')}]');
        _registeredCommandIds = ids;
        _voiceRegistry.registerAll(commands);
      });
    });
  }

  void _unregisterCommands() {
    debugPrint('VOICE REGISTRY [t=${DateTime.now().millisecondsSinceEpoch}]: $T unregister TRIGGERED (didPushNext/didPop/dispose)');
    _registrationGeneration++;
    if (_registeredCommandIds.isEmpty) return;
    final ids = _registeredCommandIds;
    _registeredCommandIds = const [];
    debugPrint('VOICE REGISTRY [t=${DateTime.now().millisecondsSinceEpoch}]: $T unregister APPLYING [${ids.join(', ')}]');
    // `_voiceRegistry` was captured once in initState (see SafeRefDisposal)
    // — never re-read via `ref` here, including from dispose().
    _voiceRegistry.unregisterAll(ids);
  }

  @override
  void didPush() => _registerCommands();

  @override
  void didPopNext() => _registerCommands();

  @override
  void didPushNext() => _unregisterCommands();

  @override
  void didPop() => _unregisterCommands();

  @override
  void dispose() {
    if (_routeSubscribed) voiceRouteObserver.unsubscribe(this);
    _unregisterCommands();
    super.dispose();
  }
}
