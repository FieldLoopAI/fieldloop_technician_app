import 'dart:io';

import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/garbled_transcript.dart';
import 'package:fielloop/services/job_facts.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 177 Step 4 — the Gemini intent check waits 900ms (was 1800ms), and
/// a garbled short utterance with no camera word does not wait for it.
List<String> _productionPhrases(String listName) {
  final source = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();
  final block = RegExp('const List<String> $listName = \\[(.*?)\\n\\];', dotAll: true).firstMatch(source);
  if (block == null) throw StateError('$listName not found in the production file');
  return [
    for (final m in RegExp(r'''^\s*(?:'([^']*)'|"([^"]*)"),''', multiLine: true).allMatches(block.group(1)!))
      m.group(1) ?? m.group(2)!,
  ];
}

void main() {
  final source = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();
  final kbPhrases = _productionPhrases('_getKbAnswerIndicatorPhrases');

  group('real short trade questions still reach the KB exactly as before', () {
    const questions = [
      'How do I reset a tripped breaker?',
      'What does a P-trap do?',
      'What size wire for a 20 amp circuit?',
      'How do I shut off the water main?',
      'What is a GFCI outlet?',
    ];
    for (final q in questions) {
      test(q, () {
        // Never skips the intent wait, and never turned into "say that again"
        // after it either — the KB catch-all (or the KB phrase match) runs.
        expect(garbledSkipIntentWaitRejection(q), isNotNull);
        expect(garbledShortRejection(q), isNotNull);
        // Not refused as off-topic.
        final offTopic = classifyOffTopicQuestion(q);
        expect(offTopic == null || offTopic.anchor != null, isTrue);
        // No confident command steals it in the fuzzy matcher.
        expect(classifyCommandIntent(q).kind, isNot(IntentDecisionKind.confident));
      });
    }

    test('the "how do I" ones are caught earlier by the KB phrase list itself (KB early match)', () {
      expect(matchAnyTriggerPhrase('How do I reset a tripped breaker?', kbPhrases), isNotNull);
      expect(matchAnyTriggerPhrase('How do I shut off the water main?', kbPhrases), isNotNull);
    });
  });

  group('garbled short utterances skip the wait', () {
    test('b176 "for me" and b175 "Can you got a sort that for me?" answer at once', () {
      expect(garbledSkipIntentWaitRejection('for me'), isNull);
      expect(garbledSkipIntentWaitRejection('Can you got a sort that for me?'), isNull);
    });

    test('a camera word still waits for the intent check (it reads unclear photo requests)', () {
      expect(garbledSkipIntentWaitRejection('get a pic for me'), contains('camera word'));
      expect(garbledSkipIntentWaitRejection('uh the snap thing'), contains('camera word'));
      // ... but garbledShortRejection alone (the post-check rule) is unchanged.
      expect(garbledShortRejection('get a pic for me'), isNull);
    });

    test('job / trade words and long utterances never skip', () {
      expect(garbledSkipIntentWaitRejection('the breaker thing there'), contains('trade word'));
      expect(garbledSkipIntentWaitRejection('the customer said something'), contains('job/trade word'));
      expect(garbledSkipIntentWaitRejection('one two three four five six seven eight nine'), contains('longer'));
    });
  });

  group('screen wiring', () {
    test('intent check timeout: dart-define, default 900ms', () {
      expect(
        source,
        contains(
          "const int _intentCheckTimeoutMs = int.fromEnvironment('INTENT_CHECK_TIMEOUT_MS', defaultValue: 900);",
        ),
      );
      expect(
        source,
        contains('static const Duration _geminiIntentCheckTimeout = Duration(milliseconds: _intentCheckTimeoutMs);'),
      );
    });

    test('the skip only applies to NO MATCH, where the check would start, behind its flag', () {
      expect(source, contains('const bool _garbledQuickRepeatSkipsIntentWait = true;'));
      final at = source.indexOf('_garbledQuickRepeatSkipsIntentWait &&');
      expect(at, greaterThan(0));
      final guard = source.substring(at - 60, at + 320);
      expect(guard, contains('decision.kind == IntentDecisionKind.none'));
      expect(guard, contains('_geminiIntentCheckWouldStart(transcript)'));
      expect(guard, contains('garbledSkipIntentWaitRejection(transcript) == null'));
      // It sits after the off-topic refusal and before the intent check.
      expect(at, greaterThan(source.indexOf('_maybeRefuseOffTopicFast(transcript)) return;')));
      expect(at, lessThan(source.indexOf('_maybeStartGeminiIntentCheck(transcript, decision)) {')));
    });
  });
}
