/// A yes/no ANSWER to the question the technician just heard, rather than
/// a command of its own.
///
/// 9948b4d log (u=9): Gemini offered another photo ("...one more...") with
/// the camera live; the technician said "Yes, take another one." No phrase
/// list matches it ("another" is a protected scope word, and no capture
/// phrase says "take another one"), the fuzzy layer has no photo object in
/// it, and the Gemini intent check — given only the transcript, never the
/// question it answered — returned `none`. It ended in "Sorry, I missed
/// that". The words only make sense against the question, so this pairs
/// them: [looksLikePhotoOfferQuestion] recognizes the offer,
/// [classifyContinuationAnswer] the answer.
///
/// Both deliberately narrow: an answer only counts when EVERYTHING after
/// the yes/no word is photo-continuation vocabulary ("Yes, take another
/// one", "Sure, go ahead", "No thanks, I'm done"). Anything with real
/// content of its own ("Yes, but what's the pressure rating?", "No, show me
/// the invoice") is a new request and goes through normal routing instead.
library;

import 'trigger_phrase_matcher.dart';

enum ContinuationAnswer { affirmative, negative, none }

const Set<String> _affirmativeLeads = {
  'yes', 'yeah', 'yep', 'yup', 'ya', 'yea', 'sure', 'absolutely', 'definitely', 'please', 'si',
};

/// Two-word affirmative leads ("go ahead", "of course", "do it").
const List<List<String>> _affirmativeLeadPairs = [
  ['go', 'ahead'], ['of', 'course'], ['do', 'it'], ['why', 'not'], ['sounds', 'good'],
];

const Set<String> _negativeLeads = {'no', 'nope', 'nah', 'not'};

/// Fillers allowed before the yes/no word ("Okay, yes", "Um, no").
const Set<String> _leadingFillers = {'okay', 'ok', 'um', 'uh', 'so', 'alright', 'right', 'well', 'oh', 'hmm'};

/// What may follow "yes" and still be nothing but "yes, do the photo".
const Set<String> _affirmativeTail = {
  'yes', 'yeah', 'yep', 'sure', 'please', 'go', 'ahead', 'do', 'it', 'that', 'let', 's', 'lets', 'take', 'get',
  'grab', 'snap', 'capture', 'shoot', 'another', 'one', 'more', 'photo', 'picture', 'pic', 'shot', 'a', 'the',
  'this', 'again', 'okay', 'ok', 'now', 'on', 'thanks', 'thank', 'you', 'i', 'want', 'need', 'd', 'like',
  'would', 'will', 'll', 'ready', 'and', 'of', 'course', 'definitely', 'absolutely', 'why', 'not',
};

/// What may follow "no" and still be nothing but "no, no more photos".
const Set<String> _negativeTail = {
  'no', 'thanks', 'thank', 'you', 'i', 'm', 'am', 'done', 'good', 'fine', 'that', 's', 'thats', 'it', 'all',
  'we', 're', 'are', 'okay', 'ok', 'now', 'not', 'need', 'don', 't', 'dont', 'more', 'another', 'one', 'photo',
  'photos', 'picture', 'pictures', 'enough', 'for', 'is', 'just', 'right', 'alright', 'pass', 'skip',
  'nope', 'nah',
};

/// Whole negative answers with no leading "no" ("I'm done", "That's fine").
const List<String> _negativeWholeAnswers = [
  'i m done', 'i am done', 'that s fine', 'thats fine', 'that s all', 'thats all', 'that s it', 'thats it',
  'all done', 'we re good', 'we re done', 'i m good', 'i m fine', 'not now', 'that s enough', 'that s okay',
  'no thanks', 'no thank you', 'skip it', 'pass',
];

ContinuationAnswer classifyContinuationAnswer(String utterance) {
  var words = tokenizeTriggerText(utterance);
  while (words.isNotEmpty && _leadingFillers.contains(words.first)) {
    words = words.sublist(1);
  }
  if (words.isEmpty) return ContinuationAnswer.none;

  final joined = words.join(' ');
  if (_negativeWholeAnswers.contains(joined)) return ContinuationAnswer.negative;

  if (_negativeLeads.contains(words.first)) {
    return words.skip(1).every(_negativeTail.contains) ? ContinuationAnswer.negative : ContinuationAnswer.none;
  }

  var rest = <String>[];
  if (_affirmativeLeads.contains(words.first)) {
    rest = words.sublist(1);
  } else {
    final pair = _affirmativeLeadPairs.where((p) => words.length >= 2 && words[0] == p[0] && words[1] == p[1]);
    if (pair.isEmpty) return ContinuationAnswer.none;
    rest = words.sublist(2);
  }
  // "Yes — no, wait" / "yeah don't" changes its mind: not an answer.
  if (rest.any((w) => _negativeLeads.contains(w) || w == 'don' || w == 'dont' || w == 'wait' || w == 'stop')) {
    return ContinuationAnswer.none;
  }
  return rest.every(_affirmativeTail.contains) ? ContinuationAnswer.affirmative : ContinuationAnswer.none;
}

const Set<String> _photoOfferWords = {
  'photo', 'photos', 'picture', 'pictures', 'pic', 'pics', 'shot', 'shots', 'another', 'capture', 'snap',
};

const Set<String> _questionLeads = {
  'do', 'does', 'did', 'would', 'want', 'wanna', 'should', 'shall', 'ready', 'any', 'need', 'can', 'could', 'will',
  'how', 'what', 'anything', 'more', 'another', 'one', 'like', 'care',
};

/// Whether [heardText] — the last thing the technician heard from the
/// assistant — was a question offering (another) photo: "Want to take one
/// more?", "Should I grab another shot?", "Need another picture?".
bool looksLikePhotoOfferQuestion(String heardText) {
  final words = tokenizeTriggerText(heardText);
  if (words.isEmpty) return false;
  final mentionsPhoto = words.any(_photoOfferWords.contains) || heardText.toLowerCase().contains('one more');
  if (!mentionsPhoto) return false;
  if (heardText.contains('?')) return true;
  // Spoken transcripts don't always carry the "?" — a question-shaped start
  // within the final sentence counts too.
  final sentences = heardText.split(RegExp(r'[.!]\s*')).where((s) => s.trim().isNotEmpty).toList();
  final last = tokenizeTriggerText(sentences.isEmpty ? heardText : sentences.last);
  return last.isNotEmpty && _questionLeads.contains(last.first) && last.any(_photoOfferWords.contains);
}
