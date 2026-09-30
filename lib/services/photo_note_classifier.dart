import 'trigger_phrase_matcher.dart' show matchAnyTriggerPhrase, tokenizeTriggerText;

/// Classifies what a technician said while the voice photo-description
/// flow is waiting on them — see `_GeminiLiveTestScreenState`'s
/// `_photoNote*` methods in `gemini_live_test_screen.dart`, which own the
/// state, timing, speaking and saving; this only classifies text. Kept a
/// standalone, unit-testable module for the same reason
/// `photo_decision_classifier.dart` is (see
/// `test/photo_note_classifier_test.dart`).
///
/// Two moments are classified:
///  - [classifyPhotoNoteReply]: right after "Want to add a note about this
///    photo?" — a decline, an interrupting command, a bare "yes" with no
///    note yet, or the note itself.
///  - [classifyPhotoNoteConfirmation]: after the note is read back — save
///    it, drop it, "no" (ask again), or a corrected/extended note.
enum PhotoNoteReplyKind { decline, interruptCommand, affirmOnly, redo, description }

enum PhotoNoteConfirmationKind { confirm, discard, reask, interruptCommand, redo, correction, addition, unclear }

class PhotoNoteReply {
  const PhotoNoteReply(this.kind, [this.text = '']);

  final PhotoNoteReplyKind kind;

  /// The cleaned note for [PhotoNoteReplyKind.description] — the
  /// technician's own words with only leading filler/"yes" removed, never
  /// paraphrased. Empty otherwise.
  final String text;
}

class PhotoNoteConfirmation {
  const PhotoNoteConfirmation(this.kind, [this.text = '']);

  final PhotoNoteConfirmationKind kind;

  /// The replacement note ([PhotoNoteConfirmationKind.correction]) or the
  /// text to append ([PhotoNoteConfirmationKind.addition]). Empty otherwise.
  final String text;
}

/// Commands that must break out of the description flow and run through
/// the normal trigger path instead of being saved as a note. Deliberately
/// narrow and explicit — a NOTE can easily mention a photo, a camera, or
/// "taking another look", so this is not the loose noun+action matcher
/// open_camera itself uses; only phrasings that are unmistakably a request.
/// Negated forms ("don't take another photo") never match — see
/// [matchAnyTriggerPhrase].
const List<String> _interruptCommandPhrases = [
  'take a photo',
  'take a picture',
  'take a pic',
  'take another photo',
  'take another picture',
  'take another one',
  'take one more',
  'another photo',
  'another picture',
  'one more photo',
  'one more picture',
  'lets take a photo',
  'lets take a picture',
  'snap a photo',
  'snap another',
  'open the camera',
  'open camera',
  'turn on the camera',
  'start the camera',
  'go back',
  'take me back',
  'go home',
];

/// Words that carry no note content on their own — dropped before deciding
/// whether a whole utterance is "just a decline"/"just a yes", and trimmed
/// off the front of a real note.
const Set<String> _fillerWords = {
  'um', 'uh', 'er', 'erm', 'hmm', 'oh', 'ah', 'well', 'so', 'please', 'thanks', 'thank', 'you', 'just',
  'actually', 'ok', 'okay', 'alright', 'right',
};

/// Explicit cancel/skip words — end the note flow outright in EITHER phase
/// (CONFIRMED via flutter_run_log 97579c46: with no recognized way out, a
/// technician's every attempt to leave was saved as note text). Also
/// accepted after a leading "no" ("no, cancel that").
const List<String> _cancelPhrases = [
  'cancel',
  'cancel it',
  'cancel that',
  'cancel the note',
  'never mind',
  'nevermind',
  'forget it',
  'forget that',
  'forget the note',
  'skip',
  'skip it',
  'skip that',
  'skip the note',
  'no thanks',
  'no thank you',
  'no note',
  'don t save',
  'dont save',
  'don t save it',
  'dont save it',
  'don t save that',
  'dont save that',
  'don t bother',
  'dont bother',
  'stop',
  'exit',
  'quit',
  'discard',
  'discard it',
  'delete it',
  'delete that',
  'scratch that',
];

/// "Let me say it again" — re-record the note from scratch; never saved as
/// the note itself (CONFIRMED via flutter_run_log 97579c46: "No, I want to
/// say it again." was read back and nearly saved as the note). Matched
/// anywhere in a SHORT utterance only (see [_maxRedoUtteranceWords]), so a
/// long note that happens to say "start over" stays a note. Deliberately
/// not "say THAT again", which asks the app to repeat itself (see
/// [_unclearPhrases]).
const List<String> _redoPhrases = [
  'say it again',
  'say it over',
  'redo it',
  'redo that',
  'redo the note',
  'let me redo',
  'start over',
  'start again',
  'try again',
  'let me try again',
  'let me repeat',
  'record it again',
  'record again',
  'rerecord',
  're record',
  'one more time',
  'change the note',
  'let me change it',
  'i want to change it',
  'new note',
  // "That's not it" after the read-back — the candidate is wrong and the
  // technician wants to say the note again (a REDO, never a decline, and
  // never read back as the note "That's not it").
  'that s not it',
  'thats not it',
  'that is not it',
  'not what i said',
  'not what i meant',
  'wrong note',
  'let me say it again',
  'let me say that again',
  'say the note again',
];

const int _maxRedoUtteranceWords = 10;

/// A leading "no"/"nope"/"nah" in front of a redo request. The phrase
/// matcher reads a "no" directly before a phrase as negating it (right for
/// "no take it"), which made "No, that's not it" and "No, try again" never
/// match — checked again with the lead-in stripped.
final RegExp _leadingNoLeadIn = RegExp(r'^\W*(?:(?:no|nope|nah)\b[\s,.:;!\-]*)+', caseSensitive: false);

bool _isRedo(String text) {
  if (tokenizeTriggerText(text).length > _maxRedoUtteranceWords) return false;
  return matchAnyTriggerPhrase(text, _redoPhrases) != null ||
      matchAnyTriggerPhrase(text.replaceFirst(_leadingNoLeadIn, ''), _redoPhrases) != null;
}

/// [_cancelPhrases], optionally after a leading "no"/"nope"/"nah".
bool _isCancel(String text) =>
    _isComposedOnlyOf(text, _cancelPhrases) ||
    _isComposedOnlyOf(text.replaceFirst(RegExp(r'^\W*(no|nope|nah)\b', caseSensitive: false), ''), _cancelPhrases);

/// Whole-utterance declines. Tokens are space-joined after [tokenizeTriggerText]
/// (so "that's fine" arrives as "that s fine" — both forms listed).
const List<String> _declinePhrases = [
  'no',
  'nope',
  'nah',
  'no thanks',
  'no note',
  'no notes',
  'no need',
  'skip',
  'skip it',
  'skip that',
  'skip the note',
  'nothing',
  'nothing to add',
  'none',
  'not now',
  'not needed',
  'that s fine',
  'thats fine',
  'it s fine',
  'its fine',
  'fine',
  'that s it',
  'thats it',
  'i m good',
  'im good',
  'all good',
  'we re good',
  'were good',
  'never mind',
  'nevermind',
  'don t bother',
  'dont bother',
  'don t need one',
  'dont need one',
  'pass',
  'move on',
  'no that s fine',
  'no thats fine',
  'no i m good',
  'no im good',
];

/// Whole-utterance "yes" with no note in it yet — answered with "go
/// ahead", not saved as the note.
const List<String> _affirmOnlyPhrases = [
  'yes',
  'yeah',
  'yep',
  'yup',
  'sure',
  'ok',
  'okay',
  'alright',
  'i do',
  'yes please',
  'sure thing',
  'go ahead',
  'let s do it',
  'lets do it',
  'add a note',
  'yes add a note',
];

const List<String> _confirmPhrases = [
  'yes',
  'yeah',
  'yep',
  'yup',
  'correct',
  'that s correct',
  'thats correct',
  'that s right',
  'thats right',
  'right',
  'exactly',
  'save',
  'save it',
  'save that',
  'yes save it',
  'sounds good',
  'looks good',
  'perfect',
  'great',
  'good',
  'ok',
  'okay',
  'sure',
  'do it',
  'go ahead',
  'yes please',
  'that works',
  'that s good',
  'thats good',
  'that s it',
  'thats it',
];

const List<String> _discardPhrases = [
  'cancel',
  'cancel it',
  'cancel that',
  'never mind',
  'nevermind',
  'forget it',
  'forget that',
  'skip',
  'skip it',
  'don t save',
  'dont save',
  'don t save it',
  'dont save it',
  'delete it',
  'delete that',
  'scratch that',
  'discard',
  'discard it',
  'no note',
  'no thanks',
];

/// Neither a yes/no nor a usable correction ("hmm", "what?", "say again") —
/// the caller re-prompts once ("Save that note — yes or no?") rather than
/// reading "Hmm" back as a new note.
const List<String> _unclearPhrases = [
  'what',
  'huh',
  'sorry',
  'pardon',
  'come again',
  'say again',
  'say that again',
  'repeat that',
  'what was that',
  'what did you say',
  'i don t know',
  'i dont know',
  'not sure',
  'let me think',
  'hold on',
  'one sec',
  'one second',
  'wait',
];

/// Filler words that, on their own after a read-back, still read as a
/// polite acceptance ("thank you", "alright") — every other filler-only
/// reply ("um", "hmm") is unclear.
const Set<String> _acceptingFillerWords = {'thanks', 'thank', 'you', 'please', 'ok', 'okay', 'alright', 'right'};

/// A bare "no" after the read-back — the note is wrong but no correction
/// was given yet, so ask for it again rather than guessing.
const List<String> _reaskPhrases = [
  'no',
  'nope',
  'nah',
  'wrong',
  'that s wrong',
  'thats wrong',
  'not quite',
  'incorrect',
  'not right',
  'that s not right',
  'thats not right',
  'no no',
];

/// True when EVERY word of [text] is covered by a back-to-back sequence of
/// [phrases] and [_fillerWords], with at least one real phrase among them —
/// "no thank you, I'm good" is a decline; "no leaks at the valve" is not,
/// it has content words left over. Phrases are tried longest-first and
/// before fillers, so "that's right" is one phrase, not "that s" + filler.
bool _isComposedOnlyOf(String text, List<String> phrases) {
  final words = tokenizeTriggerText(text);
  if (words.isEmpty) return false;
  final phraseWords = [for (final p in phrases) p.split(' ')]..sort((a, b) => b.length.compareTo(a.length));
  var i = 0;
  var sawPhrase = false;
  while (i < words.length) {
    List<String>? hit;
    for (final pw in phraseWords) {
      if (i + pw.length > words.length) continue;
      var matches = true;
      for (var j = 0; j < pw.length; j++) {
        if (words[i + j] != pw[j]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        hit = pw;
        break;
      }
    }
    if (hit != null) {
      sawPhrase = true;
      i += hit.length;
    } else if (_fillerWords.contains(words[i])) {
      i++;
    } else {
      return false;
    }
  }
  return sawPhrase;
}

bool _isOnlyFiller(String text) {
  final words = tokenizeTriggerText(text);
  return words.isNotEmpty && words.every(_fillerWords.contains);
}

final RegExp _segmentBreaks = RegExp(r'[.,!?;:]+');

/// Acknowledgment words that can open a segment in front of a command
/// ("No, go back", "Okay, take another photo").
final RegExp _leadingAckNoise = RegExp(
  r"^\s*(?:(?:no|nope|nah|ok|okay|yes|yeah|um+|uh+|so|and|wait)\b[\s,.:;!\-]*)+",
  caseSensitive: false,
);

/// The interrupting command in [text], or `null` — returned from the
/// matching segment onward with its lead-in stripped, ready to hand to the
/// normal trigger path.
///
/// CONFIRMED via flutter_run_log 6038bc76: "No, go back." — and "Go back."
/// said while an earlier "No" was still in the buffer ("No Go back") —
/// never exited the flow. [matchAnyTriggerPhrase] treats a "no" directly
/// before a phrase as negating it (correct for "no take it"), and
/// tokenization drops the comma that made "No, go back" two sentences. So
/// each punctuation-separated segment is checked on its own, after
/// stripping a leading "no"/"okay"; a real negation inside a segment ("don't
/// go back") still vetoes it.
String? photoNoteInterruptCommand(String text) {
  final segments = text.split(_segmentBreaks);
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i].replaceFirst(_leadingAckNoise, '').trim();
    if (segment.isEmpty) continue;
    if (matchAnyTriggerPhrase(segment, _interruptCommandPhrases) != null) {
      return [segment, ...segments.sublist(i + 1).map((s) => s.trim())].where((s) => s.isNotEmpty).join('. ');
    }
  }
  return null;
}

bool _isInterruptCommand(String text) => photoNoteInterruptCommand(text) != null;

/// A SHORT reply whose intent is "no, I don't want a note" in the
/// technician's own words — CONFIRMED via flutter_run_log 6038bc76: "No, I
/// don't want to add notes." was read back as the note itself ("…Should I
/// save that?"). The whole-phrase lists above can't enumerate phrasings
/// like that, so this matches the declining SHAPE instead, limited so a
/// real note that happens to contain "don't want" ("We don't want to lose
/// the capacitor") stays a note: at most [_maxDeclineWords] words, and
/// either very short or explicitly about the note ("note(s)", "it", "one",
/// "anything"…).
final RegExp _declineIntent = RegExp(
  r"\b(?:don t|dont|do not)\s+(?:really\s+)?(?:want|need)\b|\bno\s+(?:need|thanks|thank you)\b|"
  // "No, don't add a note" / "don't save the note" — only with the note
  // itself as the object, so a short real note ("Don't add refrigerant")
  // stays a note.
  r"\b(?:don t|dont|do not)\s+(?:add|save|put|include|write|attach)\s+(?:a\s+|the\s+|any\s+)?"
  r"(?:note|notes|it|that|one|anything)\b|\bwithout\s+(?:a\s+)?notes?\b|"
  r"\bnot\s+(?:now|needed|necessary|today|this time|right now)\b|\bno\s+notes?\b|\bskip\b|\bnever\s*mind\b|"
  r"\bnothing\s+to\s+add\b|\bi m\s+good\b|\bim\s+good\b|\bi ll\s+pass\b",
);
const Set<String> _declineObjectWords = {'note', 'notes', 'it', 'that', 'one', 'anything', 'any', 'this'};
const int _maxDeclineWords = 10;
/// Tokens, after "don't" splits into "don t" — "I don't want to" is 5.
const int _shortDeclineWords = 5;

bool _isShortDecline(String text) {
  final words = tokenizeTriggerText(text);
  if (words.isEmpty || words.length > _maxDeclineWords) return false;
  if (!_declineIntent.hasMatch(words.join(' '))) return false;
  return words.length <= _shortDeclineWords || words.any(_declineObjectWords.contains);
}

/// Leading filler / "yes" in front of a note ("Yeah, um, the coil is iced
/// over") — stripped off the RAW text so the saved note keeps the
/// technician's own casing and punctuation.
///
/// Deliberately excludes words that are also real content at the start of
/// a note ("right side panel…", "well pump…", "so…" is fine to keep).
final RegExp _leadingNoteFiller = RegExp(
  r"^\s*(?:(?:yes|yeah|yep|yup|sure|ok|okay|alright|um+|uh+|er+|erm|hmm+|oh|"
  r"add a note|the note is)\b[\s,.:;!\-]*)+",
  caseSensitive: false,
);

/// Leading "no, it should be..."-style lead-ins in front of a correction.
final RegExp _leadingCorrectionMarker = RegExp(
  r"^\s*(?:(?:no|nope|nah|not quite|actually|sorry|i said|i meant|it should say|it should be|"
  r"should say|should be|change it to|make it|correction|um+|uh+|ok|okay)\b[\s,.:;!\-]*)+",
  caseSensitive: false,
);

/// "Yes, and also the fan is noisy" / "Also add that..." — extends the note
/// rather than replacing it.
final RegExp _leadingAdditionMarker = RegExp(
  r"^\s*(?:(?:yes|yeah|yep|yup|correct|right)\b[\s,.:;!\-]*)?(?:and also|and add|also add|add that|and|also|plus)\b[\s,.:;!\-]*",
  caseSensitive: false,
);

/// Leading words that make an utterance a request or question rather than a
/// statement — see [looksLikeRequestOrQuestion].
const List<String> _requestOrQuestionOpeners = [
  'show', 'open', 'pull up', 'bring up', 'go', 'take me', 'view', 'see', 'let me see', 'let s see', 'lets see',
  'let s look', 'lets look', 'can you', 'could you', 'would you', 'will you', 'can i', 'can we', 'what', 'which',
  'where', 'when', 'how', 'who', 'why', 'tell me', 'give me', 'i want to see', 'i want to know', 'i need to see',
  'i d like to see', 'id like to see', 'is there', 'are there', 'do we', 'did we', 'have we', 'hey', 'hello',
  'hi',
];

/// Lead-ins stripped before checking [_requestOrQuestionOpeners]: "No,
/// wait, which screen are we on" still opens with "which".
final RegExp _leadingRequestNoise = RegExp(
  r"^\s*(?:(?:no|nope|yes|yeah|ok|okay|actually|wait|sorry|um+|uh+|so|and|but|hold on)\b[\s,.:;!\-]*)+",
  caseSensitive: false,
);

/// Whether [text] is shaped like a request or question — the break-out
/// gate in the photo-note flow. A real command during a note ("Can you
/// tell me which screen we are", "Show me the job history") must reach
/// normal routing, but a DECLARATIVE note that happens to contain a
/// command's words ("The estimate for the compressor is high, show the
/// customer." — a confident view_estimate match for the loose noun+action
/// layer) must stay a note. Requests open with a request/question word or
/// carry a question mark; notes don't.
bool looksLikeRequestOrQuestion(String text) {
  if (text.contains('?')) return true;
  final stripped = text.replaceFirst(_leadingRequestNoise, '');
  final words = tokenizeTriggerText(stripped);
  if (words.isEmpty) return false;
  for (final opener in _requestOrQuestionOpeners) {
    final openerWords = opener.split(' ');
    if (openerWords.length > words.length) continue;
    var hit = true;
    for (var i = 0; i < openerWords.length; i++) {
      if (words[i] != openerWords[i]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// Collapses whitespace, trims trailing separators, capitalizes the first
/// letter. Content is otherwise untouched.
String tidyPhotoNote(String text) {
  var t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  t = t.replaceAll(RegExp(r'^[\s,.:;!\-]+'), '').trim();
  if (t.isEmpty) return t;
  return t[0].toUpperCase() + t.substring(1);
}

PhotoNoteReply classifyPhotoNoteReply(String text) {
  if (tokenizeTriggerText(text).isEmpty) return const PhotoNoteReply(PhotoNoteReplyKind.decline);
  if (_isInterruptCommand(text)) return const PhotoNoteReply(PhotoNoteReplyKind.interruptCommand);
  if (_isRedo(text)) return const PhotoNoteReply(PhotoNoteReplyKind.redo);
  if (_isCancel(text) || _isComposedOnlyOf(text, _declinePhrases) || _isShortDecline(text)) {
    return const PhotoNoteReply(PhotoNoteReplyKind.decline);
  }
  if (_isComposedOnlyOf(text, _affirmOnlyPhrases)) return const PhotoNoteReply(PhotoNoteReplyKind.affirmOnly);
  // Nothing but "thanks"/"um" — no note content at all.
  if (_isOnlyFiller(text)) return const PhotoNoteReply(PhotoNoteReplyKind.decline);
  final note = tidyPhotoNote(text.replaceFirst(_leadingNoteFiller, ''));
  if (tokenizeTriggerText(note).isEmpty) return const PhotoNoteReply(PhotoNoteReplyKind.affirmOnly);
  return PhotoNoteReply(PhotoNoteReplyKind.description, note);
}

PhotoNoteConfirmation classifyPhotoNoteConfirmation(String text) {
  if (tokenizeTriggerText(text).isEmpty) return const PhotoNoteConfirmation(PhotoNoteConfirmationKind.reask);
  if (_isInterruptCommand(text)) return const PhotoNoteConfirmation(PhotoNoteConfirmationKind.interruptCommand);
  // Redo before everything that could read "No, I want to say it again" as
  // a "no" or as correction text.
  if (_isRedo(text)) return const PhotoNoteConfirmation(PhotoNoteConfirmationKind.redo);
  // Discard before re-ask: "no thanks" / "no, cancel that" drop it
  // outright, a bare "no" asks again.
  if (_isCancel(text) || _isComposedOnlyOf(text, _discardPhrases) || _isShortDecline(text)) {
    return const PhotoNoteConfirmation(PhotoNoteConfirmationKind.discard);
  }
  if (_isComposedOnlyOf(text, _reaskPhrases)) return const PhotoNoteConfirmation(PhotoNoteConfirmationKind.reask);
  if (_isComposedOnlyOf(text, _confirmPhrases)) return const PhotoNoteConfirmation(PhotoNoteConfirmationKind.confirm);
  if (_isOnlyFiller(text)) {
    // "Thank you" after the read-back is an acceptance; "um"/"hmm" is not
    // an answer at all.
    final accepting = tokenizeTriggerText(text).any(_acceptingFillerWords.contains);
    return PhotoNoteConfirmation(accepting ? PhotoNoteConfirmationKind.confirm : PhotoNoteConfirmationKind.unclear);
  }
  if (_isComposedOnlyOf(text, _unclearPhrases)) return const PhotoNoteConfirmation(PhotoNoteConfirmationKind.unclear);

  final addition = _leadingAdditionMarker.firstMatch(text);
  if (addition != null) {
    final extra = tidyPhotoNote(text.substring(addition.end));
    if (tokenizeTriggerText(extra).isNotEmpty) {
      return PhotoNoteConfirmation(PhotoNoteConfirmationKind.addition, extra);
    }
  }
  final corrected = tidyPhotoNote(text.replaceFirst(_leadingCorrectionMarker, ''));
  if (tokenizeTriggerText(corrected).isEmpty) return const PhotoNoteConfirmation(PhotoNoteConfirmationKind.reask);
  return PhotoNoteConfirmation(PhotoNoteConfirmationKind.correction, corrected);
}
