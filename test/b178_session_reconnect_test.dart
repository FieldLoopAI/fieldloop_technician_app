import 'dart:async';
import 'dart:io';

import 'package:fielloop/build_identity.dart';
import 'package:fielloop/screens/gemini_live_test_screen.dart' show kBuildLineFlags, kVoiceFlagsSummary;
import 'package:fielloop/services/session_reconnect.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Build 178 — session recovery rules (`session_reconnect.dart`), driven by
/// a fake clock/scheduler: no real socket, timer or network.
void main() {
  group('Step 1 — who closed the socket, and the SOCKET DEAD line', () {
    test('a close while the app was ending the session is app-initiated (never reconnects)', () {
      expect(classifySocketClose(closedByApp: true), SocketCloseInitiator.app);
      expect(classifySocketClose(closedByApp: true, error: const SocketException('x')), SocketCloseInitiator.app);
    });

    test('onDone without the app closing is the server; socket/handshake/channel errors are the network', () {
      expect(classifySocketClose(closedByApp: false), SocketCloseInitiator.server);
      expect(classifySocketClose(closedByApp: false, error: const SocketException('x')), SocketCloseInitiator.network);
      expect(classifySocketClose(closedByApp: false, error: const HandshakeException('x')), SocketCloseInitiator.network);
      expect(classifySocketClose(closedByApp: false, error: WebSocketChannelException('x')), SocketCloseInitiator.network);
      expect(classifySocketClose(closedByApp: false, error: StateError('x')), SocketCloseInitiator.server);
    });

    test('a server 1011 logs every field and reconnects with reason=1011', () {
      final line = describeSocketDead(
        closeCode: 1011,
        closeReason: 'Internal error encountered.',
        initiatedBy: SocketCloseInitiator.server,
        sessionAgeMs: 91234,
        utterancesSinceSetup: 7,
        transcriptsSinceSetup: 5,
        lastServerMessageAgoMs: 88000,
      );
      expect(
        line,
        'SOCKET DEAD: code=1011 reason="Internal error encountered." initiatedBy=server sessionAgeMs=91234 '
        'utterancesSinceSetup=7 transcriptsSinceSetup=5 lastServerMessageAgoMs=88000',
      );
      expect(reconnectReasonFor(closeCode: 1011, initiatedBy: SocketCloseInitiator.server), '1011');
      expect(reconnectReasonFor(closeCode: null, initiatedBy: SocketCloseInitiator.network), 'network');
    });
  });

  group('Step 2 — the dead session waits 2s, and for an idle photo flow', () {
    test('(a) idle flow: hands off at exactly 2000ms, once', () {
      final clock = _FakeClock();
      var ready = 0;
      ReconnectWaiter(isReady: () => true, onReady: () => ready++, onGiveUp: (_) => fail('gave up'), scheduler: clock.schedule)
          .start();
      clock.elapse(const Duration(milliseconds: 1999));
      expect(ready, 0);
      clock.elapse(const Duration(milliseconds: 1));
      expect(ready, 1);
      clock.elapse(const Duration(seconds: 60));
      expect(ready, 1);
    });

    test('(g) photo flow in progress: nothing happens until it is idle, then the hand-off', () {
      final clock = _FakeClock();
      var flowBusy = true;
      var readyAt = Duration.zero;
      ReconnectWaiter(
        isReady: () => !flowBusy,
        onReady: () => readyAt = clock.elapsed,
        onGiveUp: (_) => fail('gave up'),
        scheduler: clock.schedule,
      ).start();
      clock.elapse(const Duration(seconds: 7));
      expect(readyAt, Duration.zero, reason: 'flow state kept while busy');
      flowBusy = false;
      clock.elapse(const Duration(milliseconds: 500));
      expect(readyAt, const Duration(milliseconds: 7500));
    });

    test('(g) a flow that never goes idle gives up cleanly after 30s of polling', () {
      final clock = _FakeClock();
      Duration? gaveUpAfter;
      var ready = false;
      ReconnectWaiter(
        isReady: () => false,
        onReady: () => ready = true,
        onGiveUp: (w) => gaveUpAfter = w,
        scheduler: clock.schedule,
      ).start();
      clock.elapse(const Duration(seconds: 120));
      expect(ready, isFalse);
      expect(gaveUpAfter, reconnectFlowWaitMax);
      expect(clock.elapsed >= const Duration(seconds: 32), isTrue);
      expect(clock.pending, 0, reason: 'no timer left running');
    });

    test('(b) the app ending the session during the wait cancels it — no hand-off', () {
      final clock = _FakeClock();
      var ready = false;
      final waiter = ReconnectWaiter(
        isReady: () => true,
        onReady: () => ready = true,
        onGiveUp: (_) {},
        scheduler: clock.schedule,
      )..start();
      clock.elapse(const Duration(milliseconds: 800));
      waiter.cancel();
      clock.elapse(const Duration(seconds: 5));
      expect(ready, isFalse);
    });
  });

  group('Step 2 — GlobalVoiceService side: attempts, backoff, give-up', () {
    late _FakeClock clock;
    late SessionReconnectCoordinator c;
    late List<(int, Duration)> started;

    setUp(() {
      clock = _FakeClock();
      c = SessionReconnectCoordinator(scheduler: clock.schedule, now: clock.now);
      started = [];
    });

    void startAttempt(int a) => started.add((a, clock.elapsed));

    test('(a) the dead session ends -> attempt 1 starts at once; setupComplete -> ok with the downtime', () {
      final deadAt = clock.now();
      expect(c.begin(jobId: 'job1', reason: '1011', socketDeadAt: deadAt), isNull);
      clock.elapse(const Duration(milliseconds: 2300)); // 2s wait + teardown
      expect(c.onSessionEnded(startAttempt), ReconnectNext.startAttempt);
      expect(started, [(1, const Duration(milliseconds: 2300))]);
      clock.elapse(const Duration(milliseconds: 1200)); // token + handshake + setup
      expect(c.onSetupComplete(), 3500);
      expect(c.inFlight, isFalse);
      expect(
        describeReconnectResult(attempt: 1, reason: '1011', delayMs: 2000, ok: true, totalDowntimeMs: 3500),
        'RECONNECT: attempt=1 reason=1011 delayMs=2000 result=ok totalDowntimeMs=3500',
      );
    });

    test('(c) three failed attempts at 2s/4s/8s, then a clean give-up and no 4th attempt', () {
      c.begin(jobId: 'job1', reason: '1011', socketDeadAt: clock.now());
      expect(c.onSessionEnded(startAttempt), ReconnectNext.startAttempt); // attempt 1
      expect(c.currentDelay, const Duration(seconds: 2));
      c.onAttemptFailed();
      expect(c.onSessionEnded(startAttempt), ReconnectNext.scheduled);
      expect(c.currentDelay, const Duration(seconds: 4));
      clock.elapse(const Duration(milliseconds: 3999));
      expect(started.length, 1);
      clock.elapse(const Duration(milliseconds: 1));
      expect(started.last, (2, const Duration(seconds: 4)));
      c.onAttemptFailed();
      expect(c.onSessionEnded(startAttempt), ReconnectNext.scheduled);
      expect(c.currentDelay, const Duration(seconds: 8));
      clock.elapse(const Duration(seconds: 8));
      expect(started.last, (3, const Duration(seconds: 12)));
      c.onAttemptFailed();
      expect(c.onSessionEnded(startAttempt), ReconnectNext.gaveUp);
      expect(c.inFlight, isFalse);
      clock.elapse(const Duration(minutes: 5));
      expect(started.map((s) => s.$1), [1, 2, 3], reason: 'never a 4th attempt');
    });

    test('an attempt session that just ends (no report, no setupComplete) counts as a failure', () {
      c.begin(jobId: 'job1', reason: '1011', socketDeadAt: clock.now());
      c.onSessionEnded(startAttempt);
      expect(c.onSessionEnded(startAttempt), ReconnectNext.scheduled);
    });

    test('only one reconnect in flight at a time', () {
      expect(c.begin(jobId: 'job1', reason: '1011', socketDeadAt: clock.now()), isNull);
      expect(c.begin(jobId: 'job1', reason: 'network', socketDeadAt: clock.now()), contains('already in flight'));
    });

    test('(b) cancel (wake word / stop / left job) during the backoff: the scheduled attempt never starts', () {
      c.begin(jobId: 'job1', reason: '1011', socketDeadAt: clock.now());
      c.onSessionEnded(startAttempt);
      c.onAttemptFailed();
      c.onSessionEnded(startAttempt);
      expect(c.cancel(), isTrue);
      clock.elapse(const Duration(seconds: 30));
      expect(started.length, 1);
      expect(c.cancel(), isFalse);
    });

    test('a server that 1011s right after every setup: at most 3 sequences per 2 minutes (no endless loop)', () {
      for (var i = 0; i < reconnectMaxSequences; i++) {
        expect(c.begin(jobId: 'job1', reason: '1011', socketDeadAt: clock.now()), isNull);
        c.onSessionEnded(startAttempt);
        c.onSetupComplete();
        clock.elapse(const Duration(seconds: 5));
      }
      expect(c.begin(jobId: 'job1', reason: '1011', socketDeadAt: clock.now()), contains('sequences already'));
      clock.elapse(reconnectSequenceWindow);
      expect(c.begin(jobId: 'job1', reason: '1011', socketDeadAt: clock.now()), isNull);
    });

    test('(h) a reconnect only ever starts a NEW session: the coordinator carries the job and reason, nothing to replay',
        () {
      c.begin(jobId: 'job1', reason: '1011', socketDeadAt: clock.now());
      c.onSessionEnded(startAttempt);
      expect(c.jobId, 'job1');
      expect(c.reason, '1011');
      expect(started.single.$1, 1, reason: 'the only thing started is a session attempt number');
    });
  });

  group('Step 3 — network drop / return', () {
    late _FakeClock clock;
    late bool socketDead;
    DateTime? lastMessage;
    late List<String> events;
    late NetworkReconnectMonitor m;

    setUp(() {
      clock = _FakeClock();
      socketDead = false;
      lastMessage = null;
      events = [];
      m = NetworkReconnectMonitor(
        isSocketDead: () => socketDead,
        lastServerMessageAt: () => lastMessage,
        onOffline: () => events.add('pause'),
        onOnlineResume: () => events.add('resume'),
        onReconnect: (r) => events.add('reconnect:$r@${clock.elapsed.inMilliseconds}'),
        log: (l) => events.add(l),
        scheduler: clock.schedule,
        now: clock.now,
      );
    });

    test('(d) offline then online within 1s, socket dead -> exactly one reconnect ~2s after online', () {
      m.onConnectivity(online: false);
      clock.elapse(const Duration(milliseconds: 400));
      m.onConnectivity(online: true);
      clock.elapse(const Duration(milliseconds: 100));
      m.onConnectivity(online: true); // duplicate event
      socketDead = true;
      clock.elapse(const Duration(seconds: 10));
      final reconnects = events.where((e) => e.startsWith('reconnect')).toList();
      expect(reconnects, ['reconnect:network_socket_dead@3000']);
      expect(events.first, 'NETWORK: state=offline');
      expect(events, contains('pause'));
      expect(events, contains('NETWORK: state=online'));
    });

    test('(d) a second flap right after still gives at most one reconnect', () {
      socketDead = true;
      m.onConnectivity(online: false);
      m.onConnectivity(online: true);
      clock.elapse(const Duration(milliseconds: 600));
      m.onConnectivity(online: false);
      m.onConnectivity(online: true);
      clock.elapse(const Duration(seconds: 10));
      m.onConnectivity(online: false);
      m.onConnectivity(online: true);
      clock.elapse(const Duration(seconds: 10));
      expect(events.where((e) => e.startsWith('reconnect')).length, 1);
    });

    test('(e) socket alive and the server talking after the network returns -> resume, no reconnect', () {
      m.onConnectivity(online: false);
      m.onConnectivity(online: true);
      clock.elapse(const Duration(milliseconds: 1500));
      lastMessage = clock.now(); // sessionResumptionUpdate etc.
      clock.elapse(const Duration(seconds: 10));
      expect(events.where((e) => e.startsWith('reconnect')), isEmpty);
      expect(events, contains('resume'));
      expect(m.isDown, isFalse);
    });

    test('socket alive but the server silent for more than 4s after the network returned -> one reconnect', () {
      m.onConnectivity(online: false);
      m.onConnectivity(online: true);
      clock.elapse(const Duration(seconds: 10));
      expect(events.where((e) => e.startsWith('reconnect')), ['reconnect:network_no_server_message@4501']);
    });

    test('online events while never offline do nothing (the first event after subscribing)', () {
      m.onConnectivity(online: true);
      clock.elapse(const Duration(seconds: 10));
      expect(events, isEmpty);
    });
  });

  group('Step 4 — no-transcript watchdog', () {
    test('(f) fires only with 0 transcripts this session and 2 empty utterances in a row', () {
      expect(
        watchdogShouldRestart(consecutiveEmptyUtterances: 2, transcriptsSinceSetup: 0, ownAudioPlaying: false, micPaused: false),
        isTrue,
      );
      expect(
        watchdogShouldRestart(consecutiveEmptyUtterances: 1, transcriptsSinceSetup: 0, ownAudioPlaying: false, micPaused: false),
        isFalse,
      );
    });

    test('(f) one transcript this session (the quiet-voice case) -> never', () {
      expect(
        watchdogShouldRestart(consecutiveEmptyUtterances: 5, transcriptsSinceSetup: 1, ownAudioPlaying: false, micPaused: false),
        isFalse,
      );
    });

    test('(f) our own audio playing or the mic paused -> never', () {
      expect(
        watchdogShouldRestart(consecutiveEmptyUtterances: 3, transcriptsSinceSetup: 0, ownAudioPlaying: true, micPaused: false),
        isFalse,
      );
      expect(
        watchdogShouldRestart(consecutiveEmptyUtterances: 3, transcriptsSinceSetup: 0, ownAudioPlaying: false, micPaused: true),
        isFalse,
      );
    });

    test('(f) capped at 2 restarts per 60s, process-wide', () {
      final clock = _FakeClock();
      final cap = WatchdogRestartCap(now: clock.now);
      expect(cap.tryTake(), isTrue);
      clock.elapse(const Duration(seconds: 10));
      expect(cap.tryTake(), isTrue);
      clock.elapse(const Duration(seconds: 10));
      expect(cap.tryTake(), isFalse);
      clock.elapse(const Duration(seconds: 40));
      expect(cap.tryTake(), isTrue, reason: 'the first restart is 60s old now');
    });
  });

  group('Step 6a — TURN TIMING: none', () {
    test('reason: the hint where known, else app turn / superseded / no reply audio', () {
      expect(turnTimingNoneReason(hint: 'no_estimate', replyAudioPlayed: true, replyOwed: true), 'no_estimate');
      expect(turnTimingNoneReason(hint: null, replyAudioPlayed: true, replyOwed: false), 'excluded_app_turn');
      expect(turnTimingNoneReason(hint: null, replyAudioPlayed: false, replyOwed: true), 'superseded');
      expect(turnTimingNoneReason(hint: null, replyAudioPlayed: false, replyOwed: false), 'no_reply_audio');
      expect(describeTurnTimingNone(12, 'no_reply_audio'), 'TURN TIMING: none utterance=12 reason=no_reply_audio');
    });
  });

  group('Steps 6b/6c/7 — BUILD and SETUP lines, switches at their defaults', () {
    test('the four new switches default ON; the 1011 switches default to build 177 behaviour', () {
      expect(kAutoReconnect, isTrue);
      expect(kNetworkReconnect, isTrue);
      expect(kNoTranscriptWatchdog, isTrue);
      expect(kSnapItFix, isTrue);
      expect(kGeminiToolConfigAny, isTrue);
      expect(kGeminiCompressionTriggerTokens, 6000);
    });

    test('BUILD line: every build 177 flag unchanged, then the build 178 flags last', () {
      expect(kBuildLineFlags, startsWith(kVoiceFlagsSummary));
      expect(
        kBuildLineFlags.substring(kVoiceFlagsSummary.length).trim(),
        'autoReconnect=true networkReconnect=true noTranscriptWatchdog=true snapItFix=true '
        'geminiToolConfigAny=true geminiCompressionTriggerTokens=6000',
      );
      expect(kVoiceFlagsSummary, contains('jobFactClipPrewarm=false'), reason: 'existing defaults unchanged');
      expect(describeFullBuildLine(flags: kBuildLineFlags, when: 'session_open'), endsWith('when=session_open'));
    });

    test('SETUP line reads the facts straight from the setup JSON', () {
      const setup =
          '{"setup":{"model":"m","systemInstruction":{"parts":[{"text":"abcde"}]},'
          '"tools":[{"functionDeclarations":[{"name":"a"},{"name":"b"}]}],'
          '"toolConfig":{"functionCallingConfig":{"mode":"ANY"}},'
          '"contextWindowCompression":{"triggerTokens":"6000","slidingWindow":{"targetTokens":"3000"}}}}';
      expect(
        describeSetupFacts(setup),
        'SETUP: systemInstructionChars=5 tools=2 toolConfigMode=ANY contextCompressionTrigger=6000 vad=default '
        'geminiToolConfigAny=true geminiCompressionTriggerTokens=6000',
      );
      const noToolConfigWithVad =
          '{"setup":{"realtimeInputConfig":{"automaticActivityDetection":{"silenceDurationMs":400}}}}';
      expect(describeSetupFacts(noToolConfigWithVad), contains('toolConfigMode=ABSENT'));
      expect(describeSetupFacts(noToolConfigWithVad), contains('vad=silenceDurationMs=400'));
    });
  });
}

/// Manual clock: [schedule] stands in for `Timer.new`, [elapse] fires due
/// timers in time order.
class _FakeClock {
  final DateTime _start = DateTime(2026, 10, 12, 9);
  Duration elapsed = Duration.zero;
  final List<_FakeTimer> _timers = [];

  DateTime now() => _start.add(elapsed);

  int get pending => _timers.where((t) => t.isActive).length;

  Timer schedule(Duration delay, void Function() callback) {
    final t = _FakeTimer(elapsed + delay, callback);
    _timers.add(t);
    return t;
  }

  void elapse(Duration d) {
    final end = elapsed + d;
    while (true) {
      final due = _timers.where((t) => t.isActive && t.at <= end).toList()..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final t = due.first;
      elapsed = t.at;
      t.fire();
    }
    elapsed = end;
    _timers.removeWhere((t) => !t.isActive);
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.at, this._callback);
  final Duration at;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
