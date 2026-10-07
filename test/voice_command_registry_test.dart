import 'package:fielloop/providers/safe_ref_disposal.dart';
import 'package:fielloop/providers/voice_command_registry_provider.dart';
import 'package:fielloop/routing/voice_route_observer.dart';
import 'package:fielloop/screens/voice_command_registrar_mixin.dart';
import 'package:flutter/foundation.dart';
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

  group('build 175: one navigation over consecutive frames = one handoff (RAPID SWAP residual)', () {
    late List<String> logs;
    late DebugPrintCallback savedDebugPrint;
    late DateTime now;
    late List<void Function()> ticks;
    late List<String> ran;

    setUp(() {
      logs = [];
      ran = [];
      ticks = [];
      now = DateTime(2026, 10, 7, 14, 18);
      savedDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
    });
    tearDown(() => debugPrint = savedDebugPrint);

    VoiceCommandRegistry make({bool coalesce = true}) =>
        VoiceCommandRegistry(scheduleFlush: ticks.add, coalesceNavigation: coalesce, clock: () => now);

    /// One frame of [ms]: time moves on, then the end-of-frame callbacks run.
    void frame([int ms = 16]) {
      now = now.add(Duration(milliseconds: ms));
      final due = List.of(ticks);
      ticks.clear();
      for (final tick in due) {
        tick();
      }
    }

    void settle() {
      for (var i = 0; i < 40 && ticks.isNotEmpty; i++) {
        frame();
      }
    }

    List<String> handoffs() => [for (final l in logs) if (l.contains(': handoff ') && !l.contains('no net change')) l];
    List<String> rapidSwaps() => [for (final l in logs) if (l.contains('RAPID SWAP')) l];

    List<VoiceCommand> jobCmds() => [for (final id in ['arrived', 'open_camera', 'prepare_estimate']) _cmd(id, ran, 'job')];
    List<VoiceCommand> invoiceCmds() => [for (final id in ['generate_invoice', 'arrived']) _cmd(id, ran, 'inv')];

    /// The 14:18:52 sequence: go back to home from Invoice with the camera
    /// prewarmed. Frame A pushes the camera host, frame B pops it and Invoice.
    void replay141852(VoiceCommandRegistry r, {required int job, required int inv, required int cam, int gapFrames = 0}) {
      r.requestUnregister(inv, 'InvoiceScreen'); // .374
      r.requestRegister(cam, '_CameraHostPage', const [], kbFallbackEnabled: false); // .408
      frame(37); // b174 flushed here (.411)
      for (var i = 0; i < gapFrames; i++) {
        frame(); // 14:31:14: ~31ms with no request between the two batches
      }
      r.requestRegister(inv, 'InvoiceScreen', invoiceCmds(), kbFallbackEnabled: false); // .420
      r.requestUnregister(cam, '_CameraHostPage');
      r.requestRegister(job, 'JobDetailScreen', jobCmds(), kbFallbackEnabled: true);
      r.requestUnregister(inv, 'InvoiceScreen');
      r.requestUnregister(cam, '_CameraHostPage'); // .442
      frame(22); // b174 flushed again here: RAPID SWAP 31ms
      settle();
    }

    /// Job Detail, then (7s later) Invoice — the state before each replay.
    (int, int, int) onInvoice(VoiceCommandRegistry r) {
      final job = r.newOwnerToken();
      r.requestRegister(job, 'JobDetailScreen', jobCmds(), kbFallbackEnabled: true);
      settle();
      now = now.add(const Duration(seconds: 7));
      final inv = r.newOwnerToken();
      r.requestUnregister(job, 'JobDetailScreen');
      r.requestRegister(inv, 'InvoiceScreen', invoiceCmds(), kbFallbackEnabled: false);
      settle();
      now = now.add(const Duration(seconds: 8));
      logs.clear();
      return (job, inv, r.newOwnerToken());
    }

    test('14:18:52 replay (Invoice -> camera host -> Job Detail): one handoff, zero RAPID SWAP', () {
      final r = make();
      final (job, inv, cam) = onInvoice(r);
      replay141852(r, job: job, inv: inv, cam: cam);
      expect(rapidSwaps(), isEmpty);
      expect(handoffs(), hasLength(1));
      expect(handoffs().single, contains('-InvoiceScreen#$inv +_CameraHostPage#$cam'));
      expect(handoffs().single, endsWith('since previous change)'));
      expect(r.state.keys.toSet(), {'arrived', 'open_camera', 'prepare_estimate'});
      expect(r.ownerOf('arrived'), job, reason: 'shared id ends with the arriving screen');
      expect(r.activeScreen, 'JobDetailScreen');
      expect(r.activeScreenKbFallbackEnabled, isTrue);
      r.dispose();
    });

    test('14:31:14 replay (Estimate -> camera host -> Job Detail, a quiet frame between): one handoff, zero RAPID SWAP', () {
      final r = make();
      final (job, est, cam) = onInvoice(r);
      replay141852(r, job: job, inv: est, cam: cam, gapFrames: 1);
      expect(rapidSwaps(), isEmpty);
      expect(handoffs(), hasLength(1));
      expect(r.activeScreen, 'JobDetailScreen');
      r.dispose();
    });

    test('regression proof: with coalescing off the same replay is two handoffs and a RAPID SWAP', () {
      final r = make(coalesce: false);
      final (job, inv, cam) = onInvoice(r);
      replay141852(r, job: job, inv: inv, cam: cam);
      expect(handoffs(), hasLength(2));
      expect(rapidSwaps(), hasLength(1));
      expect(rapidSwaps().single, contains('only 22ms'));
      r.dispose();
    });

    test('two separate navigations 200ms apart still warn', () {
      final r = make();
      final (job, inv, _) = onInvoice(r);
      r.requestUnregister(inv, 'InvoiceScreen');
      r.requestRegister(job, 'JobDetailScreen', jobCmds(), kbFallbackEnabled: true);
      settle();
      now = now.add(const Duration(milliseconds: 200));
      final inv2 = r.newOwnerToken();
      r.requestUnregister(job, 'JobDetailScreen');
      r.requestRegister(inv2, 'InvoiceScreen', invoiceCmds(), kbFallbackEnabled: false);
      settle();
      expect(handoffs(), hasLength(2));
      expect(rapidSwaps(), hasLength(1), reason: 'a genuine back-to-back swap is still reported');
      r.dispose();
    });

    test('stale-owner protection holds inside a coalesced flush, and a leaving screen stops matching at once', () {
      final r = make();
      final (job, inv, cam) = onInvoice(r);
      final invCmd = r.state['generate_invoice']!;
      r.requestUnregister(inv, 'InvoiceScreen');
      expect(invCmd.matches('generate_invoice'), isFalse, reason: 'before any flush');
      replay141852(r, job: job, inv: inv, cam: cam);
      // Invoice's late dispose (14:18:53.635) after Job Detail owns "arrived".
      logs.clear();
      r.requestUnregister(inv, 'InvoiceScreen');
      settle();
      expect(r.ownerOf('arrived'), job);
      expect(handoffs(), isEmpty);
      expect(logs.single, contains('no net change'));
      r.dispose();
    });

    test('a request every frame cannot hold the flush past the cap', () {
      final r = make();
      final a = r.newOwnerToken();
      final b = r.newOwnerToken();
      var flushedAt = -1;
      for (var i = 0; i < registryCoalesceMaxFrames + 10 && flushedAt < 0; i++) {
        r.requestRegister(i.isEven ? a : b, 'S$i', [_cmd('x', ran, 's')], kbFallbackEnabled: false);
        frame();
        if (r.state.isNotEmpty) flushedAt = i;
      }
      expect(flushedAt, inInclusiveRange(0, registryCoalesceMaxFrames));
      r.dispose();
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
