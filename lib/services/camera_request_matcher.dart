/// Module D3 — "camera opens unasked". Decides whether an utterance that
/// MENTIONS a camera/photo is actually ASKING for one, for the three paths
/// that can open the camera without a fixed-phrase match:
///
///  1. the deterministic open_camera trigger's loose (non-phrase-list)
///     matcher — see [matchLooseCameraRequest];
///  2. the fuzzy intent layer's open_camera scoring
///     (`command_intent_matcher.dart`, which applies the same verb-before-
///     object rule — see `CommandIntent.actionMaxGapBeforeObject`);
///  3. Gemini deciding on its own to call open_camera — see
///     [assessCameraRequest], used by the CAMERA GATE in
///     `gemini_live_test_screen.dart`.
///
/// CONFIRMED gap this closes (code trace, not a log): the old loose matcher
/// accepted a camera/photo noun plus ANY action word ANYWHERE in the
/// sentence, in either order and with no negation check — so "my phone
/// camera keeps going off" (`going` -> `go`), "the camera won't open", or
/// "I need to see the picture my wife sent" all opened the camera. A request
/// has the verb BEFORE its object ("open the camera", "I need a photo");
/// a remark has the camera as its subject ("the camera opens slowly",
/// "my phone takes better pictures") or is about the past ("did you take a
/// picture?"). The fixed phrase lists are untouched — every client phrasing
/// that is an exact list entry still matches exactly as before.
library;

import 'trigger_phrase_matcher.dart';

/// Nouns a photo request can be about. "camera" also accepts the
/// navigation-style verbs in [_cameraOnlyVerbs]; the photo nouns only accept
/// [_acquisitionVerbs] ("show me the picture" is about viewing one).
const List<String> cameraRequestPhotoNouns = ['photo', 'picture', 'pic', 'image', 'shot', 'snapshot', 'photograph'];
const String cameraRequestCameraNoun = 'camera';

/// Verbs that mean "make a new photo".
const List<String> _acquisitionVerbs = [
  'take', 'capture', 'snap', 'grab', 'get', 'shoot', 'click',
  // "I need a photo" / "I want a picture" — only with the article right
  // after, so "I need to see the picture" is not a request for a new one.
  'need a', 'want a', 'need an', 'want an',
];

/// Verbs that mean "bring the camera up" — only for the noun "camera".
const List<String> _cameraOnlyVerbs = [
  'open', 'start', 'turn on', 'pull up', 'bring up', 'fire up', 'launch', 'use', 'show', 'switch to', 'go to',
  'need', 'want',
];

/// How many words may sit between the verb and its noun ("open UP THE
/// camera", "snap A QUICK picture", "take ONE MORE picture").
const int _maxVerbToNounGap = 3;

/// Opening words that make the sentence about something already done.
const Set<String> _pastOpeners = {'did', 'didn', 'have', 'has', 'had', 'was', 'were', 'haven', 'hasn'};

/// Words that, anywhere, mean an earlier photo — get_last_photo's
/// territory, never open_camera's (same veto the old matcher had for 'last').
const Set<String> _earlierPhotoWords = {'last', 'previous', 'latest', 'recent', 'earlier'};

/// Standalone negation words.
const Set<String> _negations = {'no', 'not', 'never', 'dont', 'didnt', 'doesnt', 'cant', 'wont'};

/// Contraction stems left when the apostrophe becomes a space ("don't" ->
/// "don t") — a negation only when followed by "t", so "can you open the
/// camera" is never mistaken for "can't".
const Set<String> _negationStems = {'don', 'didn', 'doesn', 'can', 'won', 'shouldn', 'wouldn', 'couldn'};

/// Subject pronouns: "I take a lot of pictures" is a habit, not a request —
/// unless a modal/helper comes first ("can YOU take", "will you snap").
const Set<String> _subjectPronouns = {'i', 'we', 'they', 'you', 'he', 'she', 'it'};
const Set<String> _requestHelpers = {'can', 'could', 'will', 'would', 'please', 'let', 'gonna', 'll', 'should'};

/// Skipped when looking for the subject in front of a verb ("I ALWAYS take").
const Set<String> _frequencyAdverbs = {'always', 'usually', 'normally', 'often', 'sometimes', 'just', 'also',
  'still', 'really', 'already'};

/// Desire verbs read as a request even straight after "I"/"we" ("I need a
/// photo", "we want the camera").
const Set<String> _desireVerbs = {'need', 'want'};

/// Result of [matchLooseCameraRequest] — carried back for the log line.
class CameraRequestMatch {
  const CameraRequestMatch(this.verb, this.noun);
  final String verb;
  final String noun;
  String describe() => 'verb "$verb" + noun "$noun" (verb before noun)';
}

/// Why [matchLooseCameraRequest] refused a sentence that mentions a
/// camera/photo noun — logged as `CAMERA REQUEST REJECTED` so a future log
/// shows exactly why the camera stayed closed.
class CameraRequestRejection {
  const CameraRequestRejection(this.reason);
  final String reason;
}

class _Token {
  const _Token(this.raw, this.stem);
  final String raw;
  final String stem;
}

List<_Token> _tokens(String transcript) =>
    [for (final w in tokenizeTriggerText(transcript)) _Token(w, stemTriggerWord(w))];

int _findPhrase(List<_Token> tokens, String phrase, int from) {
  final words = stemTriggerWords(tokenizeTriggerText(phrase));
  for (var i = from; i + words.length <= tokens.length; i++) {
    var ok = true;
    for (var j = 0; j < words.length; j++) {
      if (tokens[i + j].stem != words[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

/// A verb said as a statement about something else rather than as a
/// request: third-person "-s" ("the camera TAKES", "it OPENS") or past
/// "-ed" ("I CAPTURED"). Plain, "-ing" ("taking the picture") and
/// imperative forms still count.
bool _inflectedAsStatement(String raw, String verbWord) {
  if (raw == verbWord) return false;
  if (raw.endsWith('ed')) return true;
  if (raw.endsWith('s') && !raw.endsWith('ss')) return true;
  return false;
}

bool _negatedAt(List<_Token> tokens, int index) {
  for (var i = index - 1; i >= 0 && i >= index - 2; i--) {
    final w = tokens[i].raw;
    if (w == 't' && i - 1 >= 0 && _negationStems.contains(tokens[i - 1].raw)) return true;
    if (_negations.contains(w)) return true;
  }
  return false;
}

/// "I (always) take pictures" / "they snap a photo" — a bare subject right
/// in front of the verb, with no modal before it, describes what someone
/// does rather than asking for it.
bool _habitualStatementAt(List<_Token> tokens, int verbIndex, String verbWord) {
  var i = verbIndex - 1;
  while (i >= 0 && _frequencyAdverbs.contains(tokens[i].raw)) {
    i--;
  }
  if (i < 0 || !_subjectPronouns.contains(tokens[i].raw)) return false;
  final subject = tokens[i].raw;
  if (_desireVerbs.contains(verbWord) && (subject == 'i' || subject == 'we')) return false;
  if (i - 1 >= 0 && _requestHelpers.contains(tokens[i - 1].raw)) return false;
  return true;
}

/// Index of the first camera/photo noun, or -1.
({int index, String noun})? _firstNoun(List<_Token> tokens) {
  for (var i = 0; i < tokens.length; i++) {
    for (final noun in [cameraRequestCameraNoun, ...cameraRequestPhotoNouns]) {
      if (tokens[i].stem == stemTriggerWord(noun)) return (index: i, noun: noun);
    }
  }
  return null;
}

/// The loose open_camera matcher: a camera/photo noun with a request verb
/// in front of it (within [_maxVerbToNounGap] words), not negated, not
/// inflected as a statement, not about an earlier photo, and not opened as
/// a question about the past. Returns the match, or a
/// [CameraRequestRejection] when a noun was present but the sentence isn't
/// a request, or `null` when no camera/photo noun was mentioned at all.
Object? matchLooseCameraRequest(String transcript) {
  final tokens = _tokens(transcript);
  if (tokens.isEmpty) return null;
  if (_firstNoun(tokens) == null) return null;

  if (tokens.any((t) => _earlierPhotoWords.contains(t.raw))) {
    return const CameraRequestRejection('mentions an earlier photo (last/previous/...) — not a new photo');
  }
  if (_pastOpeners.contains(tokens.first.raw)) {
    return CameraRequestRejection('opens with "${tokens.first.raw}" — a question/remark about the past');
  }

  String? lastRejection;
  for (var n = 0; n < tokens.length; n++) {
    final isCamera = tokens[n].stem == stemTriggerWord(cameraRequestCameraNoun);
    final photoNoun = cameraRequestPhotoNouns.where((p) => tokens[n].stem == stemTriggerWord(p)).firstOrNull;
    if (!isCamera && photoNoun == null) continue;
    final noun = isCamera ? cameraRequestCameraNoun : photoNoun!;
    final verbs = isCamera ? [..._acquisitionVerbs, ..._cameraOnlyVerbs] : _acquisitionVerbs;
    for (final verb in verbs) {
      final verbWords = tokenizeTriggerText(verb);
      for (var v = _findPhrase(tokens, verb, 0); v >= 0 && v < n; v = _findPhrase(tokens, verb, v + 1)) {
        final gap = n - (v + verbWords.length);
        if (gap < 0 || gap > _maxVerbToNounGap) continue;
        final rawVerb = tokens[v].raw;
        if (_inflectedAsStatement(rawVerb, verbWords.first)) {
          lastRejection = '"$rawVerb ... $noun" is a statement (verb inflected), not a request';
          continue;
        }
        if (_negatedAt(tokens, v)) {
          lastRejection = '"$rawVerb ... $noun" is negated';
          continue;
        }
        if (_habitualStatementAt(tokens, v, verbWords.first)) {
          lastRejection = '"${tokens[v - 1].raw} $rawVerb ... $noun" describes what someone does, not a request';
          continue;
        }
        return CameraRequestMatch(verb, noun);
      }
    }
  }
  return CameraRequestRejection(
    lastRejection ?? 'camera/photo mentioned but no request verb in front of it — a remark, not a request',
  );
}

/// What the CAMERA GATE decides about a Gemini-initiated open_camera.
enum CameraRequestAssessment {
  /// The words ask for a photo/the camera ([matchLooseCameraRequest] matched).
  request,

  /// A camera/photo noun with nothing else to go on ("photo", "Tika shot",
  /// "camera please") — left to Gemini, exactly as before.
  unclear,

  /// A camera/photo noun in a sentence that is a remark, not a request.
  statement,

  /// No camera/photo word at all.
  noMention,
}

/// Classifies [transcript] for the CAMERA GATE. Short, bare mentions stay
/// [CameraRequestAssessment.unclear] (Gemini may still read garbled ASR
/// right); only a sentence with enough words to be a remark — at least
/// [_minStatementWords] words with a rejected verb, or any rejected verb —
/// is treated as a [CameraRequestAssessment.statement].
({CameraRequestAssessment kind, String reason}) assessCameraRequest(String transcript) {
  final result = matchLooseCameraRequest(transcript);
  if (result == null) return (kind: CameraRequestAssessment.noMention, reason: 'no camera/photo word heard');
  if (result is CameraRequestMatch) return (kind: CameraRequestAssessment.request, reason: result.describe());
  final rejection = result as CameraRequestRejection;
  final words = tokenizeTriggerText(transcript).length;
  if (words < _minStatementWords) return (kind: CameraRequestAssessment.unclear, reason: rejection.reason);
  return (kind: CameraRequestAssessment.statement, reason: rejection.reason);
}

/// Below this many words a camera/photo mention is too short to call a
/// remark ("photo", "the camera", "uh camera please").
const int _minStatementWords = 4;
