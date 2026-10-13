// Build 179 item A — idle wake-word beep mute: the decision logic of
// IdleBeepMute against a fake platform channel, plus source checks that the
// native helper only touches STREAM_NOTIFICATION and that every restore
// point is wired. Offline; no device.
import 'dart:io';

import 'package:fielloop/services/idle_beep_mute.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeChannel {
  final calls = <String>[];
  Object? muteResult = {'status': 'muted', 'prev': 7};
  Object? restoreResult = {'status': 'restored', 'vol': 7};
  Object? muteThrows;
  Object? restoreThrows;

  Future<Object?> invoke(String method) async {
    calls.add(method);
    if (method == 'muteRecognizerBeep') {
      if (muteThrows != null) throw muteThrows!;
      return muteResult;
    }
    if (restoreThrows != null) throw restoreThrows!;
    return restoreResult;
  }
}

void main() {
  late _FakeChannel channel;
  late List<String> logs;
  IdleBeepMute make({bool enabled = true}) =>
      IdleBeepMute(invoke: channel.invoke, log: logs.add, enabled: enabled);

  setUp(() {
    channel = _FakeChannel();
    logs = [];
  });

  Future<void> idle(IdleBeepMute m, {bool gemini = false, bool fg = true, bool listener = true}) =>
      m.muteForIdleListener(idleListenerActive: listener, geminiSessionActive: gemini, appForeground: fg);

  test('flag defaults ON', () => expect(kIdleBeepMute, isTrue));

  group('shouldMute — only the idle listener, foreground, no Gemini session', () {
    test('all conditions met', () {
      expect(
        IdleBeepMute.shouldMute(
          enabled: true,
          unavailable: false,
          idleListenerActive: true,
          geminiSessionActive: false,
          appForeground: true,
        ),
        isTrue,
      );
    });
    for (final (label, enabled, unavailable, listener, gemini, fg) in [
      ('flag off', false, false, true, false, true),
      ('unavailable', true, true, true, false, true),
      ('listener not active', true, false, false, false, true),
      ('Gemini session running', true, false, true, true, true),
      ('app in background', true, false, true, false, false),
    ]) {
      test('no mute: $label', () {
        expect(
          IdleBeepMute.shouldMute(
            enabled: enabled,
            unavailable: unavailable,
            idleListenerActive: listener,
            geminiSessionActive: gemini,
            appForeground: fg,
          ),
          isFalse,
        );
      });
    }
  });

  test('mutes once for the idle listener and logs the saved volume', () async {
    final m = make();
    await idle(m);
    expect(channel.calls, ['muteRecognizerBeep']);
    expect(m.isMuted, isTrue);
    expect(logs, ['IDLE BEEP MUTE: muted prev=7']);
  });

  test('the ~10 s restarts do not mute again (volume saved only once)', () async {
    final m = make();
    await idle(m);
    await idle(m);
    await idle(m);
    expect(channel.calls, ['muteRecognizerBeep']);
  });

  test('never mutes while a Gemini session runs, in the background, or with the flag off', () async {
    await idle(make(), gemini: true);
    await idle(make(), fg: false);
    await idle(make(), listener: false);
    await idle(make(enabled: false));
    expect(channel.calls, isEmpty);
  });

  test('session start: restore goes out before the session (and its greeting) plays', () async {
    final m = make();
    await idle(m);
    await m.restore('gemini_session_start');
    expect(channel.calls, ['muteRecognizerBeep', 'restoreRecognizerBeep']);
    expect(m.isMuted, isFalse);
    expect(logs.last, 'IDLE BEEP MUTE: restored vol=7 reason=gemini_session_start');
  });

  test('after the session ends the idle listener mutes again', () async {
    final m = make();
    await idle(m);
    await m.restore('wake_word');
    await idle(m);
    expect(channel.calls, ['muteRecognizerBeep', 'restoreRecognizerBeep', 'muteRecognizerBeep']);
  });

  test('restore without a mute does nothing', () async {
    final m = make();
    await m.restore('exit_job_scope');
    expect(channel.calls, isEmpty);
  });

  for (final reason in ['app_paused', 'app_detached', 'exit_job_scope', 'dispose', 'voice_muted', 'logout']) {
    test('restore reason=$reason', () async {
      final m = make();
      await idle(m);
      await m.restore(reason);
      expect(logs.last, 'IDLE BEEP MUTE: restored vol=7 reason=$reason');
    });
  }

  test('a restore issued while the mute call is in flight is still sent', () async {
    final m = make();
    final muting = idle(m);
    final restoring = m.restore('wake_word');
    await Future.wait([muting, restoring]);
    expect(channel.calls, ['muteRecognizerBeep', 'restoreRecognizerBeep']);
  });

  test('notification stream already silent: nothing saved, nothing restored', () async {
    channel.muteResult = {'status': 'already_silent', 'prev': 0};
    final m = make();
    await idle(m);
    expect(m.isMuted, isFalse);
    await m.restore('wake_word');
    expect(channel.calls, ['muteRecognizerBeep']);
  });

  group('platform failure: logged once, never thrown, no retry loop', () {
    test('mute throws (e.g. SecurityException) -> UNAVAILABLE once, restore attempted in finally', () async {
      channel.muteThrows = PlatformException(code: 'IDLE_BEEP_MUTE', message: 'SecurityException: Not allowed');
      final m = make();
      await idle(m);
      expect(m.isUnavailable, isTrue);
      expect(m.isMuted, isFalse);
      expect(channel.calls, ['muteRecognizerBeep', 'restoreRecognizerBeep']);
      expect(logs.where((l) => l.startsWith('IDLE BEEP MUTE UNAVAILABLE:')).length, 1);
      await idle(m);
      await idle(m);
      expect(channel.calls.length, 2, reason: 'no retry after the first failure');
    });

    test('native reports the ringer mode changed -> UNAVAILABLE, stream restored', () async {
      channel.muteResult = {'status': 'unavailable', 'reason': 'ringer mode changed'};
      final m = make();
      await idle(m);
      expect(logs, contains('IDLE BEEP MUTE UNAVAILABLE: ringer mode changed'));
      expect(channel.calls, ['muteRecognizerBeep', 'restoreRecognizerBeep']);
    });

    test('missing plugin (no Android) -> UNAVAILABLE, no throw', () async {
      channel.muteThrows = MissingPluginException('no handler');
      final m = make();
      await expectLater(idle(m), completes);
      expect(m.isUnavailable, isTrue);
    });

    test('restore throws -> no throw, UNAVAILABLE logged once', () async {
      final m = make();
      await idle(m);
      channel.restoreThrows = PlatformException(code: 'X');
      await expectLater(m.restore('wake_word'), completes);
      await expectLater(m.restore('wake_word'), completes);
      expect(logs.where((l) => l.startsWith('IDLE BEEP MUTE UNAVAILABLE:')).length, 1);
    });
  });

  group('app start: a stream left muted by a killed process is restored', () {
    test('restored -> logged', () async {
      await make().restoreLeftoverAtStart();
      expect(channel.calls, ['restoreRecognizerBeep']);
      expect(logs, ['IDLE BEEP MUTE: restored vol=7 reason=app_start_leftover']);
    });
    test('nothing left muted -> silent', () async {
      channel.restoreResult = {'status': 'not_muted'};
      await make().restoreLeftoverAtStart();
      expect(logs, isEmpty);
    });
    test('flag off -> no call', () async {
      await make(enabled: false).restoreLeftoverAtStart();
      expect(channel.calls, isEmpty);
    });
  });

  group('source: native helper and wiring', () {
    final kotlin = File('android/app/src/main/kotlin/com/fieldloop/fielloop/MainActivity.kt').readAsStringSync();
    final start = kotlin.indexOf('Build 179 item A — silence the speech recognizer');
    final end = kotlin.indexOf('override fun onDestroy');
    // Code only — the doc comment names the streams it must NOT touch.
    final helper = kotlin
        .substring(start, end)
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    test('touches only STREAM_NOTIFICATION — no media/voice stream, no DND', () {
      expect(start, greaterThan(0));
      expect(helper, contains('AudioManager.STREAM_NOTIFICATION'));
      for (final forbidden in ['STREAM_MUSIC', 'STREAM_VOICE_CALL', 'STREAM_RING', 'setInterruptionFilter', 'STREAM_ALARM']) {
        expect(helper, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test('saves the original volume and mute state before muting, restores at start', () {
      expect(helper, contains('putInt("prevVolume", prevVolume)'));
      expect(helper, contains('putBoolean("prevMuted", prevMuted)'));
      expect(kotlin, contains('override fun onCreate'));
      expect(kotlin, contains('"muteRecognizerBeep" -> try {'));
      expect(kotlin, contains('"restoreRecognizerBeep" -> try {'));
    });

    final dart = File('lib/providers/global_voice_service_provider.dart').readAsStringSync();
    for (final reason in [
      'wake_word',
      'gemini_session_start',
      'exit_job_scope',
      'app_paused',
      'app_detached',
      'voice_muted',
      'logout',
      'dispose',
    ]) {
      test('restore wired: $reason', () => expect(dart, contains("_restoreIdleBeep('$reason')")));
    }

    test('mute is fire-and-forget right before the idle listen()', () {
      final muteAt = dart.indexOf('_idleBeepMute.muteForIdleListener(');
      final listenAt = dart.indexOf("'baseline wake-word listen() params:");
      expect(muteAt, greaterThan(0));
      expect(muteAt, lessThan(listenAt));
      expect(dart.substring(muteAt - 40, muteAt), contains('unawaited('));
      expect(dart, contains('geminiSessionActive: _externallyPaused'));
    });

    test('restore at session start comes before the recognizer is stopped for Gemini', () {
      final pauseAt = dart.indexOf('Future<void> pauseForExternalSession(');
      final restoreAt = dart.indexOf("_restoreIdleBeep('gemini_session_start')", pauseAt);
      final stopAt = dart.indexOf("await _lockedStop('pauseForExternalSession", pauseAt);
      expect(restoreAt, greaterThan(pauseAt));
      expect(restoreAt, lessThan(stopAt));
    });

    test('restart interval untouched (400 ms debounce, 18 s / 58 s listen params)', () {
      expect(dart, contains('_restartDebounceTimer = Timer(const Duration(milliseconds: 400)'));
      expect(dart, contains('static const Duration _wakeWordPauseFor = Duration(seconds: 18);'));
      expect(dart, contains('static const Duration _wakeWordListenFor = Duration(seconds: 58);'));
    });
  });
}
