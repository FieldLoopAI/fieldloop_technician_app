import 'package:fielloop/services/navigation_destination.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

// go_back's own list, as in gemini_live_test_screen.dart.
const goBackPhrases = [
  'go back', 'take me back', 'go home', 'back to home', 'back to the job', 'back to job details', 'return to the job',
];

void main() {
  group('matchJobDetailsDestination', () {
    test('every requested phrasing names Job Details', () {
      for (final text in [
        'Take me to job details.',
        'Show me the job screen.', // 1b059096 u=31
        'Go to job details',
        'Back to home', // u=7
        'Back to home screen',
        'Take me back to the job screen.', // u=29
        'Go to the main screen',
        'Go home',
        'Take me home',
        'Can you take me back to the job details screen?',
        'No, take me to the main page.',
        'Open the job details',
        'Switch to the home screen please',
      ]) {
        expect(matchJobDetailsDestination(text), isNotNull, reason: text);
      }
    });

    test('destination-less go-back phrasings never match — they stay with go_back', () {
      for (final text in ['Go back.', 'I said go back.', 'Previous screen', 'Take me back', 'Go back one screen']) {
        expect(matchJobDetailsDestination(text), isNull, reason: text);
        expect(matchAnyTriggerPhrase(text, goBackPhrases) != null || text == 'Previous screen', isTrue, reason: text);
      }
    });

    test('a bare noun with no navigation verb is not a destination (get_job_details territory)', () {
      for (final text in [
        'Job details',
        'Tell me the job details',
        "What's on the job screen?",
        'The main screen is slow today',
        'Tell me about this job',
      ]) {
        expect(matchJobDetailsDestination(text), isNull, reason: text);
      }
    });

    test('negated requests do not match', () {
      for (final text in ["Don't go home", "Don't show me the job screen", 'Never go to job details']) {
        expect(matchJobDetailsDestination(text), isNull, reason: text);
      }
    });
  });

  group('looksLikeCurrentScreenQuestion', () {
    test('any word order', () {
      for (final text in [
        'By the way, we are on which screen?', // 1b059096 u=25
        'Which screen am I on?',
        'What page are we on right now',
        'Can you tell me which screen we are on',
        'What screen is this?',
        'On which page am I?',
        "What screen we're on?",
        'Which screen is currently open', // "current(ly)"
      ]) {
        expect(looksLikeCurrentScreenQuestion(text), isTrue, reason: text);
      }
    });

    test('other screen questions and navigation are not "where am I"', () {
      for (final text in [
        'Which screen shows the estimate?',
        'What screen should I go to for the invoice?',
        'Take me to the job screen',
        'Which page has the photos?',
        'The screen is frozen',
        'What is the total on the invoice?',
        '',
      ]) {
        expect(looksLikeCurrentScreenQuestion(text), isFalse, reason: text);
      }
    });
  });
}
