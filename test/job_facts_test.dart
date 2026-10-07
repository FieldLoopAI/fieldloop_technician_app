import 'package:fielloop/models/job_estimate.dart';
import 'package:fielloop/services/command_intent_matcher.dart';
import 'package:fielloop/services/job_facts.dart';
import 'package:fielloop/services/navigation_destination.dart';
import 'package:fielloop/services/trigger_phrase_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// Existing commands that must keep their current routing — none of them
/// may be taken by the new job-facts / unsupported-action lists.
const List<String> existingCommands = [
  'Show me the estimate',
  "What's on the estimate?",
  'Open the estimate',
  'Which screen am I on?',
  'What screen is this?',
  'Where am I?',
  'What time did we arrive?',
  'When did we arrive?',
  'Take me back',
  'Go back',
  'Take a photo',
  'How do I check the breaker panel?',
  'Show me the invoice',
  'Take me to the invoice',
  'Show me the change orders',
  'Show me the job history',
  'Tell me about this job',
  'Log a note: attic access is tight',
  'Keep it',
  'Retake it',
  'What can you do?',
];

JobEstimate _estimate(List<(String, double)> items, double total, {DateTime? voidedAt}) => JobEstimate(
  id: 'e1',
  jobId: 'j1',
  sourceDictationId: null,
  lineItems: [for (final (d, a) in items) EstimateLineItem(description: d, amount: a)],
  totalAmount: total,
  status: 'draft',
  voidedAt: voidedAt,
);

void main() {
  group('job facts phrases (C14-C17, C22)', () {
    final cases = <String, JobFactKind>{
      "What's the customer's name?": JobFactKind.customerName,
      'Whats the customers name': JobFactKind.customerName,
      'Who are we here for?': JobFactKind.customerName,
      "What's the address?": JobFactKind.address,
      'What is the address': JobFactKind.address,
      'Where are we?': JobFactKind.address,
      "What's the job address?": JobFactKind.address,
      'What is the job address': JobFactKind.address,
      'How long have we been here?': JobFactKind.timeOnSite,
      'How long have we been on site?': JobFactKind.timeOnSite,
      // Build 174 — the garbled b173 transcript and its siblings (C17).
      'How long have been here?': JobFactKind.timeOnSite,
      'how long been here': JobFactKind.timeOnSite,
      'How long we been here?': JobFactKind.timeOnSite,
      'How long have been on site?': JobFactKind.timeOnSite,
      'What was on the estimate?': JobFactKind.estimateSummary,
      'What did we quote?': JobFactKind.estimateSummary,
    };
    cases.forEach((text, kind) {
      test('"$text" -> ${kind.name}', () => expect(matchJobFactQuestion(text)?.kind, kind));
    });

    test('a screen question is never taken as an address question', () {
      expect(matchJobFactQuestion('Where are we, which screen is this?'), isNull);
      expect(matchJobFactQuestion('Where are we on this page?'), isNull);
    });

    test('real out-of-scope "how long" questions stay off the job-fact path (KB gate keeps them)', () {
      for (final text in ['How long does a breaker last?', 'How long has this panel been here?', 'How long is the warranty?']) {
        expect(matchJobFactQuestion(text), isNull, reason: text);
      }
    });

    test('C19 out-of-scope reply is under 10 words', () {
      expect(outOfScopeReply.split(' ').length, lessThan(10));
    });

    test('negated / unrelated speech does not match', () {
      for (final text in ["Don't tell me the address", 'The address on my phone is wrong', 'We are here']) {
        // "The address on my phone" has no address question phrase.
        expect(matchJobFactQuestion(text), isNull, reason: text);
      }
    });
  });

  group('existing commands are unchanged', () {
    for (final text in existingCommands) {
      test('"$text" matches no job-fact or unsupported-action phrase', () {
        expect(matchJobFactQuestion(text), isNull);
        expect(matchUnsupportedAction(text), isNull);
      });
    }

    test('"where are we" no longer belongs to the screen question; "which screen am I on" still does', () {
      expect(looksLikeCurrentScreenQuestion('Which screen am I on?'), isTrue);
      expect(looksLikeCurrentScreenQuestion('Where are we?'), isFalse);
    });

    test('"show me the estimate" still scores as view_estimate in the fuzzy layer', () {
      expect(classifyCommandIntent('Show me the estimate').best?.trigger, 'view_estimate');
    });

    test('"How do I check the breaker panel?" still carries the KB cue', () {
      expect(matchAnyTriggerPhrase('How do I check the breaker panel?', ['how do i']), isNotNull);
    });
  });

  group('C20 unsupported actions', () {
    test('calls', () {
      for (final text in ['Can you call the customer for me?', 'Call the customer', 'Give the customer a call']) {
        expect(matchUnsupportedAction(text)?.kind, UnsupportedActionKind.call, reason: text);
      }
    });
    test('text / email / message', () {
      for (final text in ['Text the customer', 'Can you email the customer?', 'Message the client', 'Send a text']) {
        expect(matchUnsupportedAction(text)?.kind, UnsupportedActionKind.message, reason: text);
      }
    });
    test('negated request does not match', () {
      expect(matchUnsupportedAction("Don't call the customer"), isNull);
    });
    test('replies are under 10 words', () {
      for (final kind in UnsupportedActionKind.values) {
        final reply = unsupportedActionReply(kind);
        expect(reply.split(' ').length, lessThan(10), reason: reply);
      }
      expect(unsupportedActionReply(UnsupportedActionKind.call), "Sorry, I can't make calls.");
      expect(unsupportedActionReply(UnsupportedActionKind.message), "Sorry, I can't send messages.");
    });
  });

  group('replies', () {
    test('customer name / address are the value only', () {
      expect(customerNameReply('Maria Lopez'), 'Maria Lopez.');
      expect(customerNameReply('Not provided'), "There's no customer name on this job.");
      expect(addressReply('123 Main St, Tampa, FL 33601'), '123 Main St, Tampa, FL 33601.');
      expect(addressReply(null), "There's no address on this job.");
    });

    test('time on site', () {
      final now = DateTime(2026, 10, 6, 12);
      String reply(DateTime? at, {bool? ever, bool loaded = true}) =>
          timeOnSiteReply(now: now, loaded: loaded, openVisitArrivedAt: at, everArrived: ever);
      expect(reply(now.subtract(const Duration(minutes: 42))), '42 minutes on site.');
      expect(reply(now.subtract(const Duration(minutes: 1))), '1 minute on site.');
      expect(reply(now.subtract(const Duration(seconds: 20))), 'Less than a minute on site.');
      expect(reply(now.subtract(const Duration(minutes: 125))), '2 hours 5 minutes on site.');
      expect(reply(null, ever: false), "You haven't arrived yet.");
      expect(reply(null, ever: true), "You're not on site right now.");
      expect(reply(null, loaded: false), 'The arrival time is still loading.');
    });

    test('estimate: total + up to 3 items, one sentence', () {
      expect(estimateSummaryReply(loaded: true), "There's no estimate on this job yet.");
      expect(estimateSummaryReply(loaded: false), 'The estimate is still loading.');
      expect(
        estimateSummaryReply(loaded: true, estimate: _estimate([('Roof patch', 800), ('Gutter cleaning', 450)], 1250)),
        'The estimate is \$1,250 for Roof patch and Gutter cleaning.',
      );
      expect(
        estimateSummaryReply(
          loaded: true,
          estimate: _estimate([('A', 1), ('B', 1), ('C', 1), ('D', 1), ('E', 1.5)], 5.5),
        ),
        'The estimate is \$5.50 for A, B and C, plus 2 more.',
      );
      expect(estimateSummaryReply(loaded: true, estimate: _estimate(const [], 300)), 'The estimate is \$300.');
      expect(
        estimateSummaryReply(loaded: true, estimate: _estimate(const [], 300, voidedAt: DateTime(2026))),
        'The estimate on this job was voided.',
      );
    });

    test('C19 out-of-scope reply is the agreed 7 words', () {
      expect(outOfScopeReply, 'I can only help with this job.');
      expect(outOfScopeReply.split(' ').length, 7);
    });
  });
}
