import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/transliterated_greeting.dart';

void main() {
  group('English greetings rendered in another script are recognized', () {
    for (final text in [
      'हेलो हेलो हेलो हेलो', // the exact transcript from the real trace
      'हेलो',
      'हैलो?',
      'हाय',
      'हे, हेलो',
      'हैलो, कैन यू हियर मी?',
      'कैन यू हियर मी',
      'आर यू देयर',
      'नमस्ते',
      'टेस्टिंग टेस्टिंग',
      'હેલો',
      'હાય, કેન યુ હિયર મી?',
    ]) {
      test('"$text"', () => expect(looksLikeTransliteratedGreeting(text), isTrue));
    }
  });

  group('everything else is still discarded by the non-Latin guard', () {
    for (final text in [
      'फोटो लो', // "take photo" — a command, never routed via this path
      'टेक अ फोटो',
      'शो मी द एस्टिमेट',
      'हेलो, फोटो लो', // a greeting plus a command is not small talk
      'यू मी', // supporting words with no greeting cue
      'मुझे इनवॉइस दिखाओ',
      '안녕하세요', // not a script/phrase this list covers
      'привет',
      '',
      '   ',
    ]) {
      test('"$text"', () => expect(looksLikeTransliteratedGreeting(text), isFalse));
    }
  });
}
