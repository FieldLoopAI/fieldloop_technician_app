import 'package:fielloop/build_identity.dart';
import 'package:fielloop/screens/gemini_live_test_screen.dart' show kVoiceFlagsSummary;
import 'package:fielloop/services/latency_stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Step 5 — DEAD STRETCH / LATENCY from the true speech end', () {
    // b174 14:43:59.944 "Yes." (photo note): transcript at 01.199, later
    // non-speech edges at 01.285 and 02.209, first audio at 05.598.
    final trueEnd = DateTime(2026, 10, 7, 14, 43, 59, 944);
    final transcriptAt = DateTime(2026, 10, 7, 14, 44, 1, 199);
    final firstAudio = DateTime(2026, 10, 7, 14, 44, 5, 598);

    test('a later edge after the transcript arrived is ignored', () {
      expect(ignoreLaterSpeechEndEdge(enabled: true, currentSpeechEnd: trueEnd, transcriptAt: transcriptAt), isTrue);
      // So the turn is timed from 59.944: 5654ms, not 3389ms from 02.209.
      expect(firstAudio.difference(trueEnd).inMilliseconds, 5654);
    });

    test('the first edge of an utterance, or one before its transcript, still counts', () {
      expect(ignoreLaterSpeechEndEdge(enabled: true, currentSpeechEnd: null, transcriptAt: null), isFalse);
      expect(ignoreLaterSpeechEndEdge(enabled: true, currentSpeechEnd: trueEnd, transcriptAt: null), isFalse);
    });

    test('flag off: every edge counts, as before', () {
      expect(ignoreLaterSpeechEndEdge(enabled: false, currentSpeechEnd: trueEnd, transcriptAt: transcriptAt), isFalse);
    });
  });

  group('every build 175 second-pass flag is in the BUILD line', () {
    const expected = {
      'cameraCancelCuesExtended': true,
      'cameraRequestNarration': true,
      'estimateNotLoadedHonestReply': true,
      'offTopicFastRefusal': true,
      'cacheFixedReplyLines': true,
      'jobFactClipPrewarm': false,
      'playShortScriptedLinesImmediately': false,
      'timingFromTrueSpeechEnd': true,
    };
    expected.forEach((flag, value) {
      test('$flag=$value', () => expect(kVoiceFlagsSummary, contains('$flag=$value')));
    });

    test('earlier flags are still there', () {
      for (final flag in ['negationGuard=true', 'jobFactClipLengthFromText=true', 'coalesceRegistryNavigation=true']) {
        expect(kVoiceFlagsSummary, contains(flag));
      }
    });
  });

  group('Step 6 — VAD end-of-speech is chosen per APK with --dart-define', () {
    // `flutter test` passes no define, so this is the default build; run
    //   flutter test --dart-define=VAD_SILENCE_MS=400 test/b175_pass2_timing_and_flags_test.dart
    //   flutter test --dart-define=VAD_SILENCE_MS=300 test/b175_pass2_timing_and_flags_test.dart
    // to see the same label/BUILD line a 400 / 300 APK prints.
    test('label and BUILD line follow the define (default: nothing sent)', () {
      final expectedMs = kVadSilenceMsDefine > 0 ? '$kVadSilenceMsDefine' : 'default';
      expect(kVadSettingLabel, startsWith('vad_silence_ms=$expectedMs '));
      expect(describeFullBuildLine(flags: kVoiceFlagsSummary, when: 'test'), contains('vad_silence_ms=$expectedMs'));
    });
  });
}
