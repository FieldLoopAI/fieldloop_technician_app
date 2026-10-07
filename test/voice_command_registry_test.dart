import 'package:fielloop/providers/safe_ref_disposal.dart';
import 'package:fielloop/providers/voice_command_registry_provider.dart';
import 'package:fielloop/routing/voice_route_observer.dart';
import 'package:fielloop/screens/voice_command_registrar_mixin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

VoiceCommand _cmd(String id, List<String> log, String who) =>
    VoiceCommand(id: id, matches: (t) => t.contains(id), handler: (_) async => log.add('$who:$id'));

void main() {
  group('atomic handoff with owner tokens (build 174)', () {
    late VoiceCommandRegistry registry;
    late int flushes;
    late List<String> ran;

    setUp(() {
      flushes = 0;
      ran = [];
      registry = VoiceCommandRegistry(scheduleFlush: (_) => flushes++);
    });
    tearDown(() => registry.dispose());

    test('leave + arrive in one frame = one state change, never an empty registry', () {
      final job = registry.newOwnerToken();
      registry.requestRegister(job, 'JobDetail', [_cmd('arrived', ran, 'job'), _cmd('estimate', ran, 'job')],
          kbFallbackEnabled: true);
      registry.flushPending();
      final states = <Map<String, VoiceCommand>>[];
      final remove = registry.addListener(states.add, fireImmediately: false);

      final cam = registry.newOwnerToken();
      registry.requestUnregister(job, 'JobDetail');
      registry.requestRegister(cam, 'Camera', [_cmd('capture', ran, 'cam')], kbFallbackEnabled: false);
      expect(flushes, 2, reason: 'one flush scheduled per frame, not per request');
      registry.flushPending();

      expect(states, hasLength(1));
      expect(states.single.keys, ['capture']);
      expect(registry.activeScreen, 'Camera');
      expect(registry.activeScreenKbFallbackEnabled, isFalse);
      remove();
    });

    test('stale unregister is ignored once a newer screen owns the id', () {
      final a = registry.newOwnerToken();
      final b = registry.newOwnerToken();
      registry.requestRegister(a, 'JobDetailA', [_cmd('arrived', ran, 'a')], kbFallbackEnabled: true);
      registry.flushPending();
      registry.requestRegister(b, 'JobDetailB', [_cmd('arrived', ran, 'b')], kbFallbackEnabled: true);
      registry.flushPending();
      // A's dispose lands late.
      registry.requestUnregister(a, 'JobDetailA');
      registry.flushPending();
      expect(registry.state.keys, ['arrived']);
      expect(registry.ownerOf('arrived'), b);
      expect(registry.activeScreen, 'JobDetailB');
      registry.state['arrived']!.handler('arrived');
      expect(ran, ['b:arrived']);
    });

    test('new register wins over the same id in the same flush', () {
      final a = registry.newOwnerToken();
      final b = registry.newOwnerToken();
      registry.requestRegister(a, 'A', [_cmd('go back', ran, 'a')], kbFallbackEnabled: false);
      registry.requestRegister(b, 'B', [_cmd('go back', ran, 'b')], kbFallbackEnabled: false);
      registry.requestUnregister(a, 'A');
      registry.flushPending();
      expect(registry.ownerOf('go back'), b);
    });

    test('rapid back-and-forth ends on the last screen, each frame one change', () {
      final job = registry.newOwnerToken();
      final est = registry.newOwnerToken();
      registry.requestRegister(job, 'Job', [_cmd('estimate', ran, 'job')], kbFallbackEnabled: true);
      registry.flushPending();
      for (var i = 0; i < 5; i++) {
        registry.requestUnregister(job, 'Job');
        registry.requestRegister(est, 'Estimate', [_cmd('back', ran, 'est')], kbFallbackEnabled: false);
        registry.flushPending();
        expect(registry.state.keys, ['back']);
        registry.requestUnregister(est, 'Estimate');
        registry.requestRegister(job, 'Job', [_cmd('estimate', ran, 'job')], kbFallbackEnabled: true);
        registry.flushPending();
        expect(registry.state.keys, ['estimate']);
        expect(registry.activeScreen, 'Job');
      }
      // Covered and uncovered inside one frame: still registered.
      registry.requestUnregister(job, 'Job');
      registry.requestRegister(job, 'Job', [_cmd('estimate', ran, 'job')], kbFallbackEnabled: true);
      registry.flushPending();
      expect(registry.ownerOf('estimate'), job);
    });

    test('double dispose is harmless; double register keeps only the latest set', () {
      final a = registry.newOwnerToken();
      registry.requestRegister(a, 'A', [_cmd('one', ran, 'a'), _cmd('two', ran, 'a')], kbFallbackEnabled: false);
      registry.flushPending();
      registry.requestRegister(a, 'A', [_cmd('two', ran, 'a')], kbFallbackEnabled: false);
      registry.flushPending();
      expect(registry.state.keys, ['two']);
      registry.requestUnregister(a, 'A');
      registry.requestUnregister(a, 'A');
      registry.flushPending();
      registry.requestUnregister(a, 'A');
      registry.flushPending();
      expect(registry.state, isEmpty);
      expect(registry.activeScreen, isNull);
    });

    test('a leaving screen stops matching at once, before the flush, and its handler is a no-op', () async {
      final a = registry.newOwnerToken();
      registry.requestRegister(a, 'A', [_cmd('capture', ran, 'a')], kbFallbackEnabled: false);
      registry.flushPending();
      final cmd = registry.state['capture']!;
      registry.requestUnregister(a, 'A');
      expect(cmd.matches('capture'), isFalse);
      await cmd.handler('capture');
      expect(ran, isEmpty);
      registry.flushPending();
      await cmd.handler('capture');
      expect(ran, isEmpty, reason: 'no handler leaks after dispose');
    });
  });

  group('widget level: push / pop between registrar screens', () {
    testWidgets('each navigation is one registry change; Go Back restores the first screen', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final registry = container.read(voiceCommandRegistryProvider.notifier);
      var changes = 0;
      final remove = registry.addListener((_) => changes++, fireImmediately: false);
      addTearDown(remove);
      final navKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navKey,
            navigatorObservers: [voiceRouteObserver],
            home: const _Screen(name: 'job', commandId: 'estimate'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(registry.state.keys, ['estimate']);
      final afterFirst = changes;

      for (final (name, id) in [('camera', 'capture'), ('notes', 'note'), ('estimate', 'back'), ('dashboard', 'home')]) {
        navKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => _Screen(name: name, commandId: id)));
        await tester.pumpAndSettle();
        expect(registry.state.keys, [id], reason: name);
        navKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(registry.state.keys, ['estimate'], reason: 'back from $name');
        expect(registry.activeScreen, '_Screen');
      }
      expect(changes - afterFirst, 8, reason: 'one change per push and per pop, no separate unregister step');
    });
  });
}

class _Screen extends ConsumerStatefulWidget {
  const _Screen({required this.name, required this.commandId});
  final String name;
  final String commandId;

  @override
  ConsumerState<_Screen> createState() => _ScreenState();
}

class _ScreenState extends ConsumerState<_Screen> with SafeRefDisposal<_Screen>, VoiceCommandRegistrarMixin<_Screen> {
  @override
  List<VoiceCommand> buildVoiceCommands() =>
      [VoiceCommand(id: widget.commandId, matches: (t) => t.contains(widget.commandId), handler: (_) async {})];

  @override
  Widget build(BuildContext context) => Scaffold(body: Text(widget.name));
}
