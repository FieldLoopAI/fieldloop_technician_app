// Build 180 item A — scripted replies are clip-cacheable, seed clips are
// copied in only for missing keys, and the flag off restores the old
// tables. Offline.
import 'dart:io';
import 'dart:typed_data';

import 'package:fielloop/services/confirmation_clip.dart';
import 'package:fielloop/services/job_facts.dart';
import 'package:fielloop/services/local_close_command.dart';
import 'package:fielloop/services/scripted_reply_clips.dart';
import 'package:fielloop/services/wake_greeting_clip.dart';
import 'package:flutter_test/flutter_test.dart';

final String _screen = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();

/// A valid seed clip: mono 16-bit 24 kHz PCM of [ms] milliseconds.
Uint8List _wav(int ms) => pcm16ToWav(Uint8List(kWakeGreetingSampleRateHz * 2 * ms ~/ 1000));

void main() {
  test('flag defaults ON', () => expect(kScriptedReplyClips, isTrue));

  group('clip key stability (FNV-1a over the exact text)', () {
    for (final (text, key) in [
      ('Okay.', 'd4e804c5'),
      ('Sorry, can you say that again?', '51e95a1a'),
      ('I can only help with this job.', 'd480351a'),
      ('Okay, closing the session.', 'a476915b'),
    ]) {
      test(text, () {
        expect(clipFileKey(text), key);
        expect(clipFileKey(text), clipFileKey(text));
      });
    }
    test('punctuation and case are part of the key', () {
      expect(clipFileKey('Okay.'), isNot(clipFileKey('Okay')));
      expect(clipFileKey('Okay.'), isNot(clipFileKey('okay.')));
    });
  });

  group('every listed scripted line is cacheable under every reason it is spoken for', () {
    for (final line in scriptedReplyLines) {
      for (final reason in line.reasons) {
        test('$reason "${line.text}"', () {
          expect(isClipEligibleReply(reason, line.text, includeFixedLines: true), isTrue);
          expect(isClipEligibleReply(reason, line.text, includeFixedLines: false), isTrue);
        });
      }
    }
  });

  test('the required lines are all in the list', () {
    for (final text in [
      'Okay.',
      'Sorry, can you say that again?',
      "I didn't quite catch that — could you repeat it?",
      'Sorry, I missed that. What do you need?',
      'Sorry, still not catching that.',
      outOfScopeReply,
      localCloseConfirmQuestion,
      localCloseClosingLine,
      "The camera's still opening — give it a moment.",
      "Okay, I've taken you back.",
      "Got it — I've taken the photo. Keep it, or retake it?",
    ]) {
      expect(scriptedReplyClipLines, contains(text), reason: text);
    }
    final okay = scriptedReplyLines.firstWhere((l) => l.text == 'Okay.');
    expect(okay.reasons, containsAll(['decline', 'decline_close_camera', 'negation_guard', 'local_close_declined', 'wait_hold']));
  });

  test('every listed line is word for word what the app speaks', () {
    for (final line in scriptedReplyLines) {
      final text = line.text;
      if (text == outOfScopeReply || text == localCloseConfirmQuestion || text == localCloseClosingLine) continue;
      if (text == 'Okay.') {
        expect(_screen, contains("const String _negationGuardReply = 'Okay.';"));
        continue;
      }
      expect(_screen.contains("'$text'") || _screen.contains('"$text"'), isTrue, reason: text);
    }
  });

  test('variable lines are still never cached', () {
    for (final (reason, text) in [
      ('deterministic get_kb_answer', 'Turn the breaker off first.'),
      ('job_fact address', '401 Main St.'),
      ('decline', 'Okay, sure.'),
      ('clarify_fallback', 'Did you mean show the invoice?'),
      ('deterministic get_kb_answer error', kbUnreachableReply),
    ]) {
      expect(isClipEligibleReply(reason, text, includeFixedLines: true), isFalse, reason: '$reason "$text"');
    }
  });

  group('flag off restores the old tables exactly', () {
    test('scripted lines fall back to isCacheableReplyLine', () {
      for (final line in scriptedReplyLines) {
        for (final reason in [...line.reasons, 'some_other_reason']) {
          for (final fixed in [true, false]) {
            expect(
              isClipEligibleReply(reason, line.text, includeFixedLines: fixed, scriptedEnabled: false),
              isCacheableReplyLine(reason, line.text, includeFixedLines: fixed),
              reason: '$reason "${line.text}" fixed=$fixed',
            );
          }
        }
      }
    });
    test('"Okay." for decline was not cacheable before build 180', () {
      expect(isClipEligibleReply('decline', 'Okay.', includeFixedLines: true, scriptedEnabled: false), isFalse);
      expect(isScriptedReplyClipLine('Okay.', enabled: false), isFalse);
    });
  });

  group('seed asset names', () {
    for (final (path, key) in [
      ('assets/clips/d4e804c5.wav', 'd4e804c5'),
      ('assets/clips/confirmation_clip_d4e804c5.wav', 'd4e804c5'),
      ('assets/clips/README.md', null),
      ('assets/clips/okay.wav', null),
      ('assets/icon/d4e804c5.wav', null),
    ]) {
      test(path, () => expect(seedAssetClipKey(path), key));
    }
  });

  group('seed WAV checks keep the 600ms–8s bound', () {
    test('1s clip accepted', () => expect(seedWavRejection(_wav(1000)), isNull));
    test('300ms refused', () => expect(seedWavRejection(_wav(300)), contains('outside')));
    test('9s refused', () => expect(seedWavRejection(_wav(9000)), contains('outside')));
    test('wrong rate refused', () {
      final wav = pcm16ToWav(Uint8List(16000 * 2), sampleRate: 16000);
      expect(seedWavRejection(wav), contains('sample rate'));
    });
    test('garbage refused', () => expect(seedWavRejection(Uint8List.fromList(List.filled(100, 7))), isNotNull));
  });

  group('seeding copies only missing keys', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('b180_seed'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('no assets -> no-op', () async {
      final result = await seedClipStore(directory: dir, assetPaths: const [], loadAsset: (_) async => _wav(1000));
      expect(result.seeded, 0);
      expect(result.skippedExisting, 0);
      expect(dir.listSync(), isEmpty);
    });

    test('only README in the folder -> no-op', () async {
      final result = await seedClipStore(
        directory: dir,
        assetPaths: const ['assets/clips/README.md', 'assets/icon/icon_foreground.png'],
        loadAsset: (_) async => throw StateError('must not be read'),
      );
      expect(result.seeded, 0);
      expect(dir.listSync(), isEmpty);
    });

    test('missing keys copied, existing ones never overwritten', () async {
      final existing = File('${dir.path}${Platform.pathSeparator}confirmation_clip_d4e804c5.wav');
      existing.writeAsBytesSync(_wav(700));
      final before = existing.readAsBytesSync();
      final loads = <String>[];
      final result = await seedClipStore(
        directory: dir,
        assetPaths: const ['assets/clips/d4e804c5.wav', 'assets/clips/51e95a1a.wav', 'assets/clips/a476915b.wav'],
        loadAsset: (path) async {
          loads.add(path);
          return _wav(1500);
        },
      );
      expect(result.seeded, 2);
      expect(result.skippedExisting, 1);
      expect(loads, isNot(contains('assets/clips/d4e804c5.wav')));
      expect(existing.readAsBytesSync(), before);
      expect(File('${dir.path}${Platform.pathSeparator}confirmation_clip_51e95a1a.wav').existsSync(), isTrue);
      expect(File('${dir.path}${Platform.pathSeparator}confirmation_clip_a476915b.wav').existsSync(), isTrue);
    });

    test('seeded clips load through the normal store preload', () async {
      await seedClipStore(
        directory: dir,
        assetPaths: const ['assets/clips/d4e804c5.wav'],
        loadAsset: (_) async => _wav(1000),
      );
      final store = ConfirmationClipStore(directory: () async => dir);
      expect(await store.preload(), 1);
      expect(store.pcmFor('Okay.'), isNotNull);
      expect(store.keys, ['d4e804c5']);
    });

    test('a bad WAV is refused and not written', () async {
      final result = await seedClipStore(
        directory: dir,
        assetPaths: const ['assets/clips/d4e804c5.wav'],
        loadAsset: (_) async => _wav(200),
      );
      expect(result.seeded, 0);
      expect(result.rejected.keys, ['assets/clips/d4e804c5.wav']);
      expect(dir.listSync(), isEmpty);
    });
  });

  group('source: wiring in the screen', () {
    test('all three clip checks use the build 180 rule', () {
      expect(RegExp(r'isClipEligibleReply\(').allMatches(_screen).length, 3);
      expect(_screen, isNot(contains('!isCacheableReplyLine(')));
    });
    test('seeding runs before the preload; log tags present', () {
      expect(_screen, contains('_seedScriptedClips().then((_) => confirmationClips.preload())'));
      expect(_screen, contains('SCRIPTED CLIP: seeded'));
      expect(_screen, contains('SCRIPTED CLIP: store has'));
      expect(_screen, contains('SCRIPTED CLIP: clip folder on this device'));
    });
    test('pubspec bundles the seed folder', () {
      expect(File('pubspec.yaml').readAsStringSync(), contains('- assets/clips/'));
      expect(Directory('assets/clips').listSync().whereType<File>().where((f) => f.path.endsWith('.wav')), isEmpty);
    });
  });
}
