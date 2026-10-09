import 'dart:io';

import 'package:fielloop/models/job_estimate.dart';
import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/garbled_transcript.dart';
import 'package:fielloop/services/job_facts.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _productionPhrases(String listName) {
  final source = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();
  final block = RegExp('const List<String> $listName = \\[(.*?)\\n\\];', dotAll: true).firstMatch(source);
  if (block == null) throw StateError('$listName not found in the production file');
  return [
    for (final m in RegExp(r'''^\s*(?:'([^']*)'|"([^"]*)"),''', multiLine: true).allMatches(block.group(1)!))
      m.group(1) ?? m.group(2)!,
  ];
}

JobEstimate _estimate(List<(String, double)> items, double total) => JobEstimate(
  id: 'e1',
  jobId: 'j1',
  sourceDictationId: null,
  lineItems: [for (final (d, a) in items) EstimateLineItem(description: d, amount: a)],
  totalAmount: total,
  status: 'draft',
);

void main() {
  group('Step 4 — C17 "What was on the estimate?" from local job data', () {
    test('matches the estimate job fact (per-chunk, before the KB / intent layer)', () {
      expect(matchJobFactQuestion('What was on the estimate?')?.kind, JobFactKind.estimateSummary);
    });

    test('a loaded estimate -> total plus up to 3 line items, no network call', () {
      final estimate = _estimate([
        ('Replace water heater', 1400),
        ('Haul away old unit', 150),
        ('Expansion tank', 220),
        ('Permit fee', 80),
      ], 1850);
      final sw = Stopwatch()..start();
      final reply = estimateSummaryReply(loaded: true, estimate: estimate);
      sw.stop();
      expect(reply, r'The estimate is $1,850 for Replace water heater, Haul away old unit and Expansion tank, plus 1 more.');
      // Pure function over memory: microseconds. The spoken line still
      // needs Gemini's voice (or a cached clip) — that part is not timed here.
      expect(sw.elapsedMilliseconds, lessThan(50));
    });

    test('no estimate loaded -> the honest build 175 reply, unchanged', () {
      expect(estimateSummaryReply(loaded: false), estimateNotLoadedReply);
      expect(estimateNotLoadedReply, "I don't have the estimate details loaded.");
      expect(estimateSummaryReply(loaded: true), "There's no estimate on this job yet.");
    });
  });

  group('Step 5 — phrase variants', () {
    for (final text in [
      "What's the name of customer?",
      "What's the name of the customer?",
      'What is the name of the customer',
      'Who is the customer?',
    ]) {
      test('"$text" -> customer name', () => expect(matchJobFactQuestion(text)?.kind, JobFactKind.customerName));
    }

    final open = _productionPhrases('_openCameraIndicatorPhrases');
    final capture = _productionPhrases('_capturePhotoIndicatorPhrases');
    for (final text in ['get a shot of that', 'Can you get a shot of that for me?']) {
      test('"$text" -> take-photo action (open_camera closed / capture_photo live)', () {
        expect(matchAnyTriggerPhrase(text, open), isNotNull);
        expect(matchAnyTriggerPhrase(text, capture), isNotNull);
      });
    }
  });

  group('Step 5 — garbled quick repeat', () {
    test('the b175 garbled transcript is asked to repeat', () {
      expect(garbledShortRejection('Can you got a sort that for me?'), isNull);
      expect(classifyCommandIntent('Can you got a sort that for me?').kind, isNot(IntentDecisionKind.confident));
    });

    test('other short garbled lines', () {
      for (final text in ['Mm the sort of', 'Can you got a sort', 'Got the thing for me']) {
        expect(looksLikeGarbledShortUtterance(text), isTrue, reason: text);
      }
    });

    test('normal KB questions still reach the KB', () {
      for (final text in [
        'How do I reset a breaker?',
        'What size wire for a 30 amp circuit?',
        'Is it safe to touch?',
        'Why is it tripping?',
        'Can I use PVC here?',
        'Should I replace the filter?',
        'Take me to the job street.', // b175: has "job", went to the KB — still does
        'The camera upon my phone is different.',
        'What torque for these bolts on the unit?',
        'Tell me about the warranty',
        // Longer than 8 words, any content.
        'Can you got a sort that for me right now please',
      ]) {
        expect(looksLikeGarbledShortUtterance(text), isFalse, reason: text);
      }
    });

    test('the flag is in the BUILD line, default true', () {
      final source = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();
      expect(source, contains('const bool _garbledQuickRepeat = true;'));
      expect(source, contains(r'garbledQuickRepeat=$_garbledQuickRepeat'));
    });
  });
}
