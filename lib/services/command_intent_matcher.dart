/// Keyword-and-similarity intent matching for voice commands — the LAST
/// layer, consulted only once an utterance has ended with NO existing
/// trigger matching it (see `_GeminiLiveTestScreenState._maybeResolveByIntent`).
/// Every existing phrase list and matcher in `gemini_live_test_screen.dart`
/// still runs first and unchanged; this only decides what happens to
/// utterances that used to fall straight through to the knowledge-base
/// catch-all.
///
/// Three ideas, in order:
///  1. Normalize: lowercase, letters only, drop filler ("um", "please", ...).
///  2. Keywords, not sentences: each intent names the OBJECT words that mean
///     it ("photo", "picture", "shot"...) and the ACTION words that go with
///     it ("take", "grab", "snap"...). An action + object anywhere in the
///     utterance is a strong match, so "grab a shot of that" works without
///     being listed anywhere.
///  3. Sound-alike/typo tolerance on those keywords, so a truncated or
///     garbled transcript like "foto" still reaches "photo".
///
/// It never guesses between close candidates: [classifyCommandIntent]
/// reports [IntentDecisionKind.ambiguous] so the caller can ask "did you
/// mean A or B?", and question-shaped utterances only act on strong matches
/// so trade/job questions keep reaching the knowledge base.
library;

import 'trigger_phrase_matcher.dart';

/// Words dropped before matching — spoken filler that carries no intent.
const Set<String> commandFillerWords = {
  'um', 'umm', 'uh', 'uhh', 'uhm', 'er', 'erm', 'ah', 'hmm', 'mm', 'please', 'like', 'so', 'just', 'okay', 'ok',
  'yeah', 'well', 'actually', 'basically', 'kinda', 'maybe', 'alright', 'right',
};

/// Grammar words that don't count as "content" when deciding whether an
/// utterance is nothing but a bare command noun ("the invoice").
const Set<String> _nonContentWords = {
  'a', 'an', 'the', 'me', 'my', 'this', 'that', 'it', 'of', 'to', 'for', 'on', 'at', 'can', 'could', 'would',
  'will', 'you', 'i', 'we', 'us', 'let', 's', 'some', 'up', 'in', 'with', 'our', 'your', 'there', 'here',
  'now', 'and', 'or', 'is', 'be', 'do', 'one', 'real', 'quick', 'again',
};

/// Words that veto whatever follows them within a couple of words ("don't
/// open the camera", "no photo"). Apostrophes normalize to spaces, so
/// "don't" arrives as "don" + "t".
const Set<String> _negationWords = {
  'no', 'not', 'never', 'nope', 'dont', 'don', 'didn', 'doesn', 'cant', 'won', 'wont', 'stop', 'cancel',
};

const Set<String> _questionOpeners = {
  'what', 'how', 'why', 'when', 'where', 'who', 'which', 'is', 'are', 'does', 'do', 'did', 'should', 'would',
  'could', 'can', 'will', 'whats', 'hows',
};

/// One command the fuzzy layer can resolve to.
class CommandIntent {
  const CommandIntent({
    required this.trigger,
    required this.label,
    required this.objects,
    required this.actions,
    this.vetoWords = const {},
  });

  /// The trigger/function name, e.g. `open_camera`.
  final String trigger;

  /// How the clarifying question names it: "did you mean [label], or ...".
  final String label;

  /// Each entry is one object, as a word sequence ("change order" is two).
  final List<List<String>> objects;
  final Set<String> actions;

  /// Any of these anywhere in the utterance rules this intent out — keeps
  /// neighboring intents from colliding ("last photo" is get_last_photo,
  /// never open_camera).
  final Set<String> vetoWords;
}

const Set<String> _navigationActions = {
  'show', 'see', 'view', 'open', 'pull', 'bring', 'check', 'look', 'display', 'go', 'take', 'give', 'need', 'want',
  'review', 'switch', 'get', 'find', 'read',
};

/// The intents this layer covers: the camera and the navigation screens.
/// Deliberately NOT capture_photo/keep/retake (shutter and upload
/// decisions keep their own tightly-tuned, safety-reviewed matchers), nor
/// go_back (its cooldown semantics live in its own detector), nor
/// questions (those belong to the knowledge base).
const List<CommandIntent> defaultCommandIntents = [
  CommandIntent(
    trigger: 'open_camera',
    label: 'take a photo',
    objects: [
      ['photo'], ['picture'], ['pic'], ['image'], ['shot'], ['snapshot'], ['camera'],
    ],
    actions: {
      'take', 'snap', 'grab', 'get', 'capture', 'shoot', 'open', 'start', 'turn', 'need', 'want', 'make',
      // "fire up / pull up / bring up the camera", "click a picture".
      'fire', 'pull', 'bring', 'click',
    },
    vetoWords: {'last', 'previous', 'latest', 'recent', 'earlier', 'delete'},
  ),
  CommandIntent(
    trigger: 'get_last_photo',
    label: 'see the last photo',
    objects: [
      ['last', 'photo'], ['last', 'picture'], ['last', 'pic'], ['last', 'shot'], ['last', 'image'],
      ['previous', 'photo'], ['previous', 'picture'], ['latest', 'photo'], ['latest', 'picture'],
    ],
    actions: _navigationActions,
  ),
  CommandIntent(
    trigger: 'view_estimate',
    label: 'show the estimate',
    objects: [['estimate'], ['quote']],
    actions: _navigationActions,
  ),
  CommandIntent(
    trigger: 'view_invoice',
    label: 'show the invoice',
    objects: [['invoice'], ['bill']],
    actions: _navigationActions,
  ),
  CommandIntent(
    trigger: 'view_change_orders',
    label: 'show the change orders',
    objects: [['change', 'order']],
    actions: _navigationActions,
  ),
  CommandIntent(
    trigger: 'view_job_history',
    label: 'show the job history',
    objects: [['history'], ['activity', 'log']],
    actions: _navigationActions,
  ),
];

/// Strong: an action word plus an object word.
const double _actionPlusObject = 0.9;

/// The whole utterance is just the object ("foto", "the invoice").
const double _bareObject = 0.8;

/// An object in a short utterance with other words but no action verb.
const double _objectInShortUtterance = 0.55;

/// At or above: act on it (or, with a close second, ask which one).
const double confidentThreshold = 0.75;

/// At or above (but below [confidentThreshold]): too weak to act on —
/// answered with the existing "not sure what you need" options reply.
const double weakThreshold = 0.5;

/// Two candidates closer than this are ambiguous, never silently picked.
const double ambiguityMargin = 0.15;

/// Lowercased, letters-only, filler-free word list.
List<String> normalizeCommandWords(String text) =>
    tokenizeTriggerText(text).where((w) => !commandFillerWords.contains(w)).toList();

/// Sound-alike key: stem, then fold spellings that sound the same ("ph"/"f",
/// "ck"/"k") and doubled letters, so "foto" and "photos" share a key.
String commandSoundKey(String word) {
  var w = stemTriggerWord(word).replaceAll('ph', 'f').replaceAll('ck', 'k').replaceAll('q', 'k');
  final out = StringBuffer();
  for (var i = 0; i < w.length; i++) {
    if (i == 0 || w[i] != w[i - 1]) out.write(w[i]);
  }
  w = out.toString();
  return w;
}

int _editDistance(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost].reduce((x, y) => x < y ? x : y);
    }
    prev = cur;
  }
  return prev[b.length];
}

/// Same sound key, or — for words long enough that one slip can't turn
/// them into a different common word — one edit apart ("camara"/"camera",
/// "invoise"/"invoice"). Short words must match exactly by sound.
bool _sameWord(String heard, String keyword) {
  final a = commandSoundKey(heard);
  final b = commandSoundKey(keyword);
  if (a == b) return true;
  if (a.length < 5 || b.length < 5) return false;
  return _editDistance(a, b) <= 1;
}

/// Index where [object] starts in [words] (consecutive), or -1.
int _findObject(List<String> words, List<String> object) {
  for (var start = 0; start + object.length <= words.length; start++) {
    var ok = true;
    for (var j = 0; j < object.length; j++) {
      if (!_sameWord(words[start + j], object[j])) {
        ok = false;
        break;
      }
    }
    if (ok) return start;
  }
  return -1;
}

bool _negatedBefore(List<String> words, int index) {
  for (var i = index - 1; i >= 0 && i >= index - 3; i--) {
    if (_negationWords.contains(words[i])) return true;
  }
  return false;
}

/// Whether the utterance reads as a question — those only act on strong
/// matches, so "what's the history of this unit" still goes to the KB.
bool looksLikeQuestion(String text) {
  if (text.trim().endsWith('?')) return true;
  final words = normalizeCommandWords(text);
  return words.isNotEmpty && _questionOpeners.contains(words.first);
}

class IntentScore {
  const IntentScore(this.intent, this.confidence, this.reason);

  final CommandIntent intent;
  final double confidence;

  /// Human-readable why, for the FUZZY MATCH log line.
  final String reason;

  String get trigger => intent.trigger;
}

/// Scores one intent against already-normalized [words].
IntentScore? scoreIntent(CommandIntent intent, List<String> words) {
  if (words.any((w) => intent.vetoWords.any((v) => _sameWord(w, v)))) return null;

  int objectAt = -1;
  List<String>? object;
  for (final candidate in intent.objects) {
    final at = _findObject(words, candidate);
    if (at >= 0) {
      objectAt = at;
      object = candidate;
      break;
    }
  }
  if (object == null) return null;
  if (_negatedBefore(words, objectAt)) return null;

  final heardObject = words.sublist(objectAt, objectAt + object.length).join(' ');
  final objectNote = heardObject == object.join(' ') ? '"$heardObject"' : '"$heardObject"~"${object.join(' ')}"';

  for (var i = 0; i < words.length; i++) {
    if (i >= objectAt && i < objectAt + object.length) continue;
    final action = intent.actions.where((a) => _sameWord(words[i], a)).firstOrNull;
    if (action == null) continue;
    if (_negatedBefore(words, i)) return null;
    return IntentScore(intent, _actionPlusObject, 'action "${words[i]}" + object $objectNote');
  }

  final content = [
    for (var i = 0; i < words.length; i++)
      if (!_nonContentWords.contains(words[i])) i,
  ];
  final onlyObject = content.every((i) => i >= objectAt && i < objectAt + object!.length);
  if (onlyObject) return IntentScore(intent, _bareObject, 'bare object $objectNote');
  if (content.length <= 4) {
    return IntentScore(intent, _objectInShortUtterance, 'object $objectNote without an action word');
  }
  return null;
}

/// Photo nouns that — ONLY once the live camera preview is up and armed —
/// can only mean "take the picture now" (see [liveCameraShotNoun]).
const Set<String> liveCameraShotNouns = {'shot', 'pic', 'snap', 'snapshot', 'photo', 'picture', 'image'};

/// The more lenient capture rule, for a caller that has ALREADY checked the
/// live camera preview is showing and armed — never use it otherwise. A
/// bare photo noun normally scores FUZZY WEAK (no action verb, e.g. ASR's
/// "Tika shot" for "take a shot"), but with the camera live and nothing
/// else going on, the context alone makes the intent clear. Returns the
/// heard noun, or `null` when the utterance:
///  - is question-shaped ("is the photo okay?"),
///  - negates the noun ("no photo yet"),
///  - names an earlier photo ("last"/"previous"/..., get_last_photo's
///    territory — same vetoes as the open_camera intent),
///  - or carries more than two other content words ("the photo needs more
///    light" is a remark, not a shutter command).
String? liveCameraShotNoun(String transcript) {
  if (looksLikeQuestion(transcript)) return null;
  final words = normalizeCommandWords(transcript);
  if (words.isEmpty) return null;
  const vetoWords = {'last', 'previous', 'latest', 'recent', 'earlier', 'delete'};
  if (words.any((w) => vetoWords.any((v) => _sameWord(w, v)))) return null;
  for (var i = 0; i < words.length; i++) {
    if (!liveCameraShotNouns.any((n) => _sameWord(words[i], n))) continue;
    if (_negatedBefore(words, i)) return null;
    final otherContent = [
      for (var j = 0; j < words.length; j++)
        if (j != i && !_nonContentWords.contains(words[j])) words[j],
    ];
    if (otherContent.length > 2) return null;
    return words[i];
  }
  return null;
}

enum IntentDecisionKind {
  /// Nothing this layer recognizes — leave it to the existing fallback.
  none,

  /// One clear winner: act on [IntentDecision.best].
  confident,

  /// Two plausible candidates, too close to pick: ask which.
  ambiguous,

  /// A single weak candidate: don't act, give the options reply.
  weak,
}

class IntentDecision {
  const IntentDecision(this.kind, {this.best, this.runnerUp, this.scores = const []});

  final IntentDecisionKind kind;
  final IntentScore? best;
  final IntentScore? runnerUp;

  /// Every candidate that scored, best first — for the log.
  final List<IntentScore> scores;

  String describe(String text) {
    final all = scores.map((s) => '${s.trigger}=${s.confidence.toStringAsFixed(2)}').join(', ');
    switch (kind) {
      case IntentDecisionKind.none:
        return "FUZZY NO MATCH: text='$text'${all.isEmpty ? '' : ' (below threshold: $all)'}";
      case IntentDecisionKind.confident:
        return 'FUZZY MATCH: trigger=${best!.trigger} confidence=${best!.confidence.toStringAsFixed(2)} '
            "text='$text' (${best!.reason}; all: $all)";
      case IntentDecisionKind.ambiguous:
        return 'FUZZY AMBIGUOUS: ${best!.trigger} vs ${runnerUp!.trigger} '
            "text='$text' (all: $all) — asking which, not guessing";
      case IntentDecisionKind.weak:
        return 'FUZZY WEAK: trigger=${best!.trigger} confidence=${best!.confidence.toStringAsFixed(2)} '
            "text='$text' (${best!.reason}) — too weak to act on";
    }
  }
}

/// Decides what [transcript] most likely means among [intents].
IntentDecision classifyCommandIntent(String transcript, {List<CommandIntent> intents = defaultCommandIntents}) {
  final words = normalizeCommandWords(transcript);
  if (words.isEmpty) return const IntentDecision(IntentDecisionKind.none);

  final scores = [
    for (final intent in intents) ?scoreIntent(intent, words),
  ]..sort((a, b) => b.confidence.compareTo(a.confidence));
  if (scores.isEmpty) return const IntentDecision(IntentDecisionKind.none);

  final best = scores.first;
  final runnerUp = scores.length > 1 ? scores[1] : null;
  // Questions only act on strong matches; weaker ones stay with the KB.
  final floor = looksLikeQuestion(transcript) ? confidentThreshold : weakThreshold;
  if (best.confidence < floor) return IntentDecision(IntentDecisionKind.none, scores: scores);

  if (runnerUp != null && runnerUp.confidence >= floor && best.confidence - runnerUp.confidence < ambiguityMargin) {
    return IntentDecision(IntentDecisionKind.ambiguous, best: best, runnerUp: runnerUp, scores: scores);
  }
  if (best.confidence >= confidentThreshold) {
    return IntentDecision(IntentDecisionKind.confident, best: best, runnerUp: runnerUp, scores: scores);
  }
  return IntentDecision(IntentDecisionKind.weak, best: best, runnerUp: runnerUp, scores: scores);
}
