import 'package:fielloop/build_identity.dart';
import 'package:fielloop/screens/gemini_live_test_screen.dart' show kVoiceFlagsSummary;
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BUILD line has stamp, commit and mode in one greppable line', () {
    expect(
      describeBuildIdentity(stamp: 173, commit: 'abc1234', mode: 'release', builtAt: '2026-10-06 12:00'),
      'BUILD: stamp=173 commit=abc1234 mode=release built=2026-10-06 12:00',
    );
  });

  test('full BUILD line carries version, VAD value, flags and when it was printed', () {
    final line = describeFullBuildLine(flags: 'negationGuard=true', when: 'first_session_open');
    expect(line, startsWith('BUILD: stamp='));
    expect(line, contains('version=1.0.'));
    expect(line, contains('vad_silence_ms=default'));
    expect(line, contains('flags=[negationGuard=true]'));
    expect(line, endsWith('when=first_session_open'));
    expect(versionForBuild(174), '1.0.174');
  });

  test('VAD label: default when no --dart-define (the test run passes none)', () {
    expect(kVadSilenceMsDefine, 0);
    expect(kVadSettingLabel, 'vad_silence_ms=default vad_end_sensitivity=default');
  });

  // Module A's note command — 'log a note' was added to the site_condition
  // phrase list in gemini_live_test_screen.dart.
  group('"log a note" phrase (Module A)', () {
    test('matches the client phrasing, with or without the colon', () {
      expect(matchAnyTriggerPhrase('Log a note: attic access is tight', ['log a note']), isNotNull);
      expect(matchAnyTriggerPhrase('log a note attic access is tight', ['log a note']), isNotNull);
    });

    test('does not match look-alike or negated speech', () {
      for (final text in ['Look at the note', 'lock a door', 'Go to the note', "Don't log a note", 'log in now']) {
        expect(matchAnyTriggerPhrase(text, ['log a note']), isNull, reason: text);
      }
    });
  });

  test('build 175: every new voice flag is in the BUILD line flags, default true', () {
    for (final flag in [
      'jobFactClipLengthFromText',
      'jobDetailsReplyCacheable',
      'kbCatchAllTimeoutSaysOutOfScope',
      'coalesceRegistryNavigation',
    ]) {
      expect(kVoiceFlagsSummary, contains('$flag=true'), reason: flag);
    }
  });
}
