import 'dart:io';
import 'dart:typed_data';

import 'package:fielloop/services/wake_greeting_clip.dart';
import 'package:flutter_test/flutter_test.dart';

/// 20ms of 16kHz mono int16 at a constant amplitude.
Uint8List chunkAt(int amplitude) {
  final data = ByteData(640);
  for (var i = 0; i < 320; i++) {
    data.setInt16(i * 2, i.isEven ? amplitude : -amplitude, Endian.little);
  }
  return data.buffer.asUint8List();
}

const chunkDuration = Duration(milliseconds: 20);

void main() {
  group('pcm16Rms', () {
    test('silence is zero, constant amplitude is that amplitude', () {
      expect(pcm16Rms(chunkAt(0)), 0);
      expect(pcm16Rms(chunkAt(1000)), closeTo(1000, 0.01));
      expect(pcm16Rms(Uint8List(0)), 0);
    });
  });

  group('isCleanGreetingTranscript', () {
    test('accepts the greeting regardless of punctuation and case', () {
      expect(isCleanGreetingTranscript("Hey, I'm here to help - what do you need?"), isTrue);
      expect(isCleanGreetingTranscript('hey i m here to help what do you need'), isTrue);
    });

    test('rejects anything missing or added', () {
      expect(isCleanGreetingTranscript("Hey, I'm here to help"), isFalse);
      expect(isCleanGreetingTranscript("Hey, I'm here to help — what do you need? Say exactly"), isFalse);
      expect(isCleanGreetingTranscript(''), isFalse);
    });
  });

  group('pcm16ToWav', () {
    test('writes a 44-byte PCM header in front of the samples', () {
      final pcm = Uint8List.fromList(List.filled(480, 7));
      final wav = pcm16ToWav(pcm);
      final header = ByteData.sublistView(wav, 0, 44);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(header.getUint32(24, Endian.little), kWakeGreetingSampleRateHz);
      expect(header.getUint16(22, Endian.little), 1);
      expect(header.getUint32(40, Endian.little), pcm.length);
      expect(wav.length, 44 + pcm.length);
    });
  });

  group('WakeGreetingMicGate', () {
    final t0 = DateTime(2026, 10, 2, 9);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

    test('the clip\'s quiet echo never counts as barge-in', () {
      final gate = WakeGreetingMicGate();
      for (var ms = 0; ms < 2500; ms += 20) {
        expect(gate.add(chunkAt(900), at(ms), chunkDuration), WakeGreetingMicAction.hold);
      }
      expect(gate.bargeInOnset, isNull);
    });

    test('a single loud blip is not speech', () {
      final gate = WakeGreetingMicGate();
      gate.add(chunkAt(4000), at(0), chunkDuration);
      gate.add(chunkAt(4000), at(20), chunkDuration);
      for (var ms = 40; ms < 600; ms += 20) {
        expect(gate.add(chunkAt(300), at(ms), chunkDuration), isNot(WakeGreetingMicAction.bargeIn));
      }
      expect(gate.bargeInOnset, isNull);
    });

    test('sustained speech confirms barge-in with the onset at its first loud chunk', () {
      final gate = WakeGreetingMicGate();
      for (var ms = 0; ms < 400; ms += 20) {
        gate.add(chunkAt(900), at(ms), chunkDuration);
      }
      WakeGreetingMicAction? action;
      var ms = 400;
      while (action != WakeGreetingMicAction.bargeIn && ms < 1000) {
        action = gate.add(chunkAt(3000), at(ms), chunkDuration);
        ms += 20;
      }
      expect(action, WakeGreetingMicAction.bargeIn);
      expect(gate.bargeInOnset, at(400));
      expect(ms - 400, lessThanOrEqualTo(320));
    });

    test('ec736a7a: the clip\'s own loud echo (all inside its echo window) never barges in', () {
      final gate = WakeGreetingMicGate();
      final actions = <WakeGreetingMicAction>[];
      // 1s of very loud echo while the clip is audible, then quiet as it pauses.
      for (var ms = 0; ms < 1000; ms += 20) {
        actions.add(gate.add(chunkAt(15000), at(ms), chunkDuration, clipAudible: true));
      }
      for (var ms = 1000; ms < 1300; ms += 20) {
        actions.add(gate.add(chunkAt(200), at(ms), chunkDuration, clipAudible: false));
      }
      expect(actions, isNot(contains(WakeGreetingMicAction.bargeIn)));
      expect(actions, contains(WakeGreetingMicAction.rejectedLoudRun));
      expect(gate.lastRejectedRun!.outsideEcho, Duration.zero);
      expect(gate.bargeInOnset, isNull);
    });

    test('talking over the greeting is confirmed once the speech continues where the clip is quiet', () {
      final gate = WakeGreetingMicGate();
      WakeGreetingMicAction? action;
      var ms = 0;
      // Loud from 0ms; the clip is audible for the first 500ms, then pauses.
      while (action != WakeGreetingMicAction.bargeIn && ms < 1500) {
        action = gate.add(chunkAt(4000), at(ms), chunkDuration, clipAudible: ms < 500);
        ms += 20;
      }
      expect(action, WakeGreetingMicAction.bargeIn);
      expect(gate.bargeInOnset, at(0), reason: 'onset is where the speech began, under the clip');
      expect(ms, lessThanOrEqualTo(640));
    });

    test('a short transient with the clip quiet is not speech (camera/click)', () {
      final gate = WakeGreetingMicGate();
      final actions = [
        gate.add(chunkAt(16000), at(0), chunkDuration),
        gate.add(chunkAt(16000), at(20), chunkDuration),
        gate.add(chunkAt(16000), at(40), chunkDuration),
        for (var ms = 60; ms < 400; ms += 20) gate.add(chunkAt(100), at(ms), chunkDuration),
      ];
      expect(actions, isNot(contains(WakeGreetingMicAction.bargeIn)));
      expect(gate.lastRejectedRun!.loud, const Duration(milliseconds: 60));
    });

    test('short gaps between syllables keep one run going', () {
      final gate = WakeGreetingMicGate();
      var action = WakeGreetingMicAction.hold;
      // 100ms loud, 60ms quiet, 100ms loud, 60ms quiet, 100ms loud.
      var ms = 0;
      for (final segment in [(true, 100), (false, 60), (true, 100), (false, 60), (true, 100)]) {
        for (var i = 0; i < segment.$2; i += 20) {
          action = gate.add(chunkAt(segment.$1 ? 3000 : 200), at(ms), chunkDuration);
          ms += 20;
          if (action == WakeGreetingMicAction.bargeIn) break;
        }
        if (action == WakeGreetingMicAction.bargeIn) break;
      }
      expect(action, WakeGreetingMicAction.bargeIn);
      expect(gate.bargeInOnset, at(0));
    });

    test('barge-in releases audio from before the clip plus the speech (with pre-roll), not the echo', () {
      final gate = WakeGreetingMicGate();
      final beforeClip = chunkAt(100);
      gate.add(beforeClip, at(0), chunkDuration);
      final startedAt = at(20);
      final echo = <Uint8List>[];
      for (var ms = 20; ms < 1000; ms += 20) {
        final c = chunkAt(900);
        echo.add(c);
        gate.add(c, at(ms), chunkDuration);
      }
      final speech = <Uint8List>[];
      var ms = 1000;
      while (gate.bargeInOnset == null) {
        final c = chunkAt(3000);
        speech.add(c);
        gate.add(c, at(ms), chunkDuration);
        ms += 20;
      }
      gate.resolveBargeIn(startedAt: startedAt);
      final released = gate.takeReleased();
      expect(released.first, same(beforeClip));
      // Every speech chunk is kept, in order, at the end.
      expect(released.sublist(released.length - speech.length), orderedEquals(speech));
      // Only the 300ms pre-roll of echo before the onset is kept.
      final echoKept = released.length - 1 - speech.length;
      expect(echoKept, 15);
      expect(gate.takeReleased(), isEmpty);
    });

    test('a clip that played out drops its echo but keeps audio from before it started', () {
      final gate = WakeGreetingMicGate();
      final beforeClip = chunkAt(100);
      gate.add(beforeClip, at(0), chunkDuration);
      for (var ms = 20; ms < 2000; ms += 20) {
        gate.add(chunkAt(900), at(ms), chunkDuration);
      }
      gate.resolvePlayed(startedAt: at(20));
      expect(gate.takeReleased(), [beforeClip]);
    });

    test('a clip that never played releases everything in order', () {
      final gate = WakeGreetingMicGate();
      final chunks = [for (var i = 0; i < 5; i++) chunkAt(900)];
      for (var i = 0; i < chunks.length; i++) {
        gate.add(chunks[i], at(i * 20), chunkDuration);
      }
      gate.resolveUnused();
      expect(gate.takeReleased(), orderedEquals(chunks));
    });

    test('echo tail', () {
      final gate = WakeGreetingMicGate();
      expect(gate.withinEchoTail(endedAt: at(0), at: at(299)), isTrue);
      expect(gate.withinEchoTail(endedAt: at(0), at: at(300)), isFalse);
    });
  });

  group('WakeGreetingPlayback.clipAudibleAt', () {
    final start = DateTime(2026, 10, 2, 9);
    DateTime at(int ms) => start.add(Duration(milliseconds: ms));
    // 20ms frames: loud 0-400ms, a 600ms pause, loud 1000-1400ms, then ends.
    final envelope = [
      for (var i = 0; i < 20; i++) 3000.0,
      for (var i = 0; i < 30; i++) 50.0,
      for (var i = 0; i < 20; i++) 3000.0,
    ];
    final playback = WakeGreetingPlayback.forTesting(startedAt: start, envelope: envelope);

    test('echo is possible while the clip is (or just was) loud', () {
      expect(playback.clipAudibleAt(at(154)), isTrue); // the ec736a7a onset moment
      expect(playback.clipAudibleAt(at(700)), isTrue, reason: 'within echo reach of the first loud part');
      expect(playback.clipAudibleAt(at(1200)), isTrue);
    });

    test('a long pause, the moment before it starts, and well after it ends are echo-free', () {
      expect(playback.clipAudibleAt(at(900)), isFalse);
      expect(playback.clipAudibleAt(start.subtract(const Duration(milliseconds: 50))), isFalse);
      expect(playback.clipAudibleAt(at(1900)), isFalse);
    });
  });

  group('WakeGreetingClipStore', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('wake_greeting_test'));
    tearDown(() async => dir.delete(recursive: true));

    Uint8List pcmOf(Duration d) => Uint8List((d.inMicroseconds * kWakeGreetingSampleRateHz ~/ 1000000) * 2);

    test('nothing saved loads as null', () async {
      final store = WakeGreetingClipStore(directory: () async => dir);
      expect(await store.load(kWakeGreetingText), isNull);
    });

    test('a saved clip loads back as WAV, also from a fresh store (disk)', () async {
      final pcm = pcmOf(const Duration(seconds: 2));
      expect(await WakeGreetingClipStore(directory: () async => dir).save(kWakeGreetingText, pcm), isTrue);
      final loaded = await WakeGreetingClipStore(directory: () async => dir).load(kWakeGreetingText);
      expect(loaded, isNotNull);
      expect(loaded!.length, 44 + pcm.length);
    });

    test('a different greeting text misses the old clip', () async {
      final store = WakeGreetingClipStore(directory: () async => dir);
      await store.save(kWakeGreetingText, pcmOf(const Duration(seconds: 2)));
      expect(await WakeGreetingClipStore(directory: () async => dir).load('Hi there, what do you need?'), isNull);
    });

    test('implausibly short or long audio is not saved', () async {
      final store = WakeGreetingClipStore(directory: () async => dir);
      expect(await store.save(kWakeGreetingText, pcmOf(const Duration(milliseconds: 300))), isFalse);
      expect(await store.save(kWakeGreetingText, pcmOf(const Duration(seconds: 9))), isFalse);
      expect(await store.load(kWakeGreetingText), isNull);
    });
  });
}
