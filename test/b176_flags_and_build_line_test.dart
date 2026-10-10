import 'dart:io';
import 'dart:typed_data';

import 'package:fielloop/build_identity.dart';
import 'package:fielloop/screens/gemini_live_test_screen.dart' show kVoiceFlagsSummary;
import 'package:fielloop/services/mic_gain.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/gemini_intent_harness.dart' as harness;

void main() {
  group('BUILD line: build 175 part unchanged, only the new build 176 flags added', () {
    // Copied from the b175 log (VOICE_TEST_LOG_20261008_175.txt, BUILD line
    // at app_start), the flags=[...] content.
    const b175Flags =
        'negationGuard=true cameraCancelCuesExtended=true cameraRequestNarration=true atomicVoiceRegistry=true '
        'coalesceRegistryNavigation=true jobFactAudioCache=true jobFactClipLengthFromText=true '
        'jobDetailsReplyCacheable=true kbCatchAllTimeoutSaysOutOfScope=true jobFactsAnswers=true '
        'estimateNotLoadedHonestReply=true offTopicFastRefusal=true cacheFixedReplyLines=true '
        'jobFactClipPrewarm=false playShortScriptedLinesImmediately=false timingFromTrueSpeechEnd=true '
        'unsupportedActionReplies=true kbMissSaysOutOfScope=true cameraNarrationAsPhotoNote=true '
        'shortCameraOpenReply=true cachedConfirmationClips=true prefetchJobData=true '
        'silentOnMissingTranscript=true transcriptTimeoutMs=3000';

    test('the build 175 flags are a prefix, unchanged (default build)', () {
      expect(kVoiceFlagsSummary.startsWith(b175Flags), isTrue, reason: kVoiceFlagsSummary);
    });

    test('the new flags and their defaults', () {
      final added = kVoiceFlagsSummary.substring(b175Flags.length).trim();
      // Build 177 appends its own flags after these (see
      // b177_flags_test.dart); the build 176 part must read exactly as before.
      expect(
        added.startsWith(
          'negationWordOrderFree=true cameraRequestNarrationAnyForm=true garbledQuickRepeat=true '
          'jobFactPhraseVariants=true micGain=off speechEdgeRms=500',
        ),
        isTrue,
        reason: added,
      );
    });

    test('VAD A/B defines: default build sends nothing and says so', () {
      expect(kVadSettingLabel, 'vad_silence_ms=default vad_end_sensitivity=default');
      expect(describeFullBuildLine(flags: 'x', when: 'test'), contains(kVadSettingLabel));
    });
  });

  group('Step 6 — job-fact clip prewarm is a build-time define, OFF by default', () {
    test('wired to --dart-define=JOB_FACT_CLIP_PREWARM, default false', () {
      final source = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();
      expect(source, contains("const bool _jobFactClipPrewarm = bool.fromEnvironment('JOB_FACT_CLIP_PREWARM');"));
      expect(kVoiceFlagsSummary, contains('jobFactClipPrewarm=false'));
    });
  });

  group('Step 7 — mic gain / speech-edge level, OFF by default', () {
    test('default: gain 1.0 returns the same chunk object, edge 500', () {
      final chunk = Uint8List.fromList([0x10, 0x00, 0xF0, 0xFF]);
      expect(identical(applyMicGain(chunk, kMicGain), chunk), isTrue);
      expect(kMicGain, 1.0);
      expect(kSpeechEdgeRms, 500);
      expect(describeMicKnobs(), 'micGain=off speechEdgeRms=500');
    });

    test('gain scales and clips int16', () {
      final data = ByteData(6)
        ..setInt16(0, 100, Endian.little)
        ..setInt16(2, -200, Endian.little)
        ..setInt16(4, 20000, Endian.little);
      final out = ByteData.sublistView(applyMicGain(data.buffer.asUint8List(), 2.0));
      expect(out.getInt16(0, Endian.little), 200);
      expect(out.getInt16(2, Endian.little), -400);
      expect(out.getInt16(4, Endian.little), 32767);
    });

    test('define parsing is bounded', () {
      expect(parseMicGain(''), 1.0);
      expect(parseMicGain('abc'), 1.0);
      expect(parseMicGain('0.5'), 1.0);
      expect(parseMicGain('2.5'), 2.5);
      expect(parseMicGain('9'), 4.0);
      expect(describeMicKnobs(gain: 2.0, edgeRms: 300), 'micGain=2.0 speechEdgeRms=300');
    });
  });

  group('Step 8 — intent harness mirrors the app and is not in the app', () {
    final source = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();

    test('20 phrases', () => expect(harness.phrases, hasLength(20)));

    test('same instruction fragments and function declaration text as the app', () {
      final text = harness.buildIntentCheckInstruction('x', 'open_camera');
      for (final fragment in [
        'This is automatic speech recognition, so it may be misspelled, cut short, heavily accented, informal, or partly',
        'Right now the camera is not open: if they want to take a picture, in any wording, the intent is',
        'Use "none" for questions, remarks, or anything that is',
      ]) {
        expect(text.replaceAll(RegExp(r'\s+'), ' '), contains(fragment));
      }
      expect(source, contains('Classification step. ONLY call this when a message explicitly asks you to classify'));
      expect(harness.functionDeclaration['description'] as String, startsWith('Classification step. ONLY call this'));
    });

    test('nothing under lib/ imports the harness', () {
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        expect(f.readAsStringSync(), isNot(contains('gemini_intent_harness')), reason: f.path);
      }
    });
  });
}
