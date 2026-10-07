import 'package:fielloop/build_identity.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BUILD line has stamp, commit and mode in one greppable line', () {
    expect(
      describeBuildIdentity(stamp: 173, commit: 'abc1234', mode: 'release', builtAt: '2026-10-06 12:00'),
      'BUILD: stamp=173 commit=abc1234 mode=release built=2026-10-06 12:00',
    );
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
}
