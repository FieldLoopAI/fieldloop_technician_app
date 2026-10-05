import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/question_announcement.dart';

void main() {
  for (final text in [
    'one question',
    'One question.',
    'I have a question',
    "I've got a question",
    'quick question',
    'I have a quick question for you',
    'question for you',
    'can I ask something',
    'can I ask you something',
    'hey, one more question',
    'question',
  ]) {
    test('"$text" is a question announcement', () => expect(isQuestionAnnouncement(text), isTrue));
  }

  for (final text in [
    'I have a question about the water heater',
    'what is the question',
    'how do I reset the breaker',
    'no question',
    'can you take a photo',
    'show me the invoice',
    'okay',
    '',
  ]) {
    test('"$text" is not a question announcement', () => expect(isQuestionAnnouncement(text), isFalse));
  }
}
