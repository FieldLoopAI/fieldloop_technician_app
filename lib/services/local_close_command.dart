/// Build 179 item B — app-side ("local") spoken close commands.
///
/// b178: no app-side close phrase existed. A spoken close depended on
/// Gemini calling `end_session`, which it never did (0 toolCalls); "I am
/// done." got "Sorry, can you say that again?" four times
/// (`continuation_answer.dart:57` only knows it as a "no" to a photo offer).
///
/// Two tiers:
///  - EXPLICIT ("close this session", "stop listening", "loop off", "bye"):
///    close at once.
///  - SOFT ("I'm done", "that's all"): ask "Do you want me to close the
///    session?" once; a local yes closes, a no (or no answer in 8 s) keeps
///    the session open.
///
/// THE WHOLE-UTTERANCE RULE (see [matchLocalClose]): the utterance, after
/// removing filler words, must be exactly a close phrase, optionally
/// followed by one short tail ("for now", "here", "today"...), and at most
/// [localCloseMaxWords] words. "I'm done taking photos of the kitchen" and
/// "that's all the damage on the roof" therefore never close — they contain
/// a close phrase but are about something else (`too_long`).
///
/// Pure Dart and deterministic: no network, no Gemini call.
library;

import 'trigger_phrase_matcher.dart';

/// `--dart-define=LOCAL_CLOSE_COMMANDS=false` turns item B off.
const bool kLocalCloseCommands = bool.fromEnvironment('LOCAL_CLOSE_COMMANDS', defaultValue: true);

/// Longest utterance (after filler removal) that can still be a close.
const int localCloseMaxWords = 6;

const Duration localCloseConfirmTimeout = Duration(seconds: 8);

/// Same 5 s repeat-block every deterministic trigger uses.
const Duration localCloseRepeatBlock = Duration(seconds: 5);

/// Hard cap on waiting for "Okay, closing the session." before teardown.
const Duration localCloseReplyWaitCap = Duration(seconds: 2);

const String localCloseConfirmQuestion = 'Do you want me to close the session?';
const String localCloseClosingLine = 'Okay, closing the session.';

enum LocalCloseTier { explicit, soft }

/// Close phrases as tokenized word sequences ("that's" -> "that s").
const List<String> localCloseExplicitPhrases = [
  'close this session',
  'close the session',
  'close session',
  'end this session',
  'end the session',
  'end session',
  'stop the session',
  'stop this session',
  'stop listening',
  'loop off',
  'fieldloop stop',
  'fieldloop off',
  // ASR writes the wake word as two words as often as one.
  'field loop stop',
  'field loop off',
  'goodbye',
  'good bye',
  'bye',
  'bye bye',
];

const List<String> localCloseSoftPhrases = [
  'i am done',
  'i m done',
  'we re done',
  'we are done',
  'that s all',
  'that is all',
  'that s it',
  'that is it',
  'nothing else',
  'all done',
  'i m finished',
  'i am finished',
];

/// Words that carry no meaning for the close decision, dropped anywhere.
const Set<String> _fillerWords = {
  'um', 'umm', 'uh', 'uhh', 'okay', 'ok', 'alright', 'so', 'well', 'please', 'yeah', 'yes', 'hey', 'thanks',
  'actually', 'just', 'guys',
};

/// Short tails allowed after a close phrase ("that's all for now").
const List<List<String>> _allowedTails = [
  ['for', 'now'],
  ['for', 'today'],
  ['for', 'the', 'day'],
  ['here'],
  ['now'],
  ['then'],
  ['today'],
  ['thank', 'you'],
];

const Set<String> _negationTokens = {'not', 'never', 'dont', 'didnt', 'wont', 'cant', 'isnt'};

/// Contraction stems: "don't" tokenizes to "don" + "t".
const Set<String> _negationStems = {'don', 'didn', 'won', 'can', 'isn', 'aren', 'doesn', 'shouldn'};

sealed class LocalCloseResult {
  const LocalCloseResult();
}

class LocalCloseMatch extends LocalCloseResult {
  const LocalCloseMatch(this.tier, this.phrase);
  final LocalCloseTier tier;
  final String phrase;
}

class LocalCloseBlocked extends LocalCloseResult {
  const LocalCloseBlocked(this.reason, {this.phrase});

  /// negation | too_long (context reasons come from [LocalCloseController]).
  final String reason;
  final String? phrase;
}

List<String> _words(String text) => tokenizeTriggerText(text).where((w) => !_fillerWords.contains(w)).toList();

/// Drops negation tokens (and the "do" of "do not", the "t" of "don t").
/// Returns null when there was no negation at all.
List<String>? _withoutNegation(List<String> words) {
  final out = <String>[];
  var found = false;
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    final next = i + 1 < words.length ? words[i + 1] : null;
    if (_negationStems.contains(w) && next == 't') {
      found = true;
      i++;
      continue;
    }
    if (w == 'do' && next == 'not') continue;
    if (_negationTokens.contains(w)) {
      found = true;
      continue;
    }
    out.add(w);
  }
  return found ? out : null;
}

/// [words] minus a leading wake word ("FieldLoop, close the session").
List<String> _withoutLeadingWakeWord(List<String> words) {
  if (words.isNotEmpty && words.first == 'fieldloop') return words.sublist(1);
  if (words.length > 1 && words[0] == 'field' && words[1] == 'loop') return words.sublist(2);
  return words;
}

bool _startsWith(List<String> words, List<String> prefix) {
  if (prefix.length > words.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (words[i] != prefix[i]) return false;
  }
  return true;
}

/// The phrase [words] consists of — the phrase, optionally plus one
/// allowed tail — or null.
({String phrase, LocalCloseTier tier})? _wholeMatch(List<String> words) {
  for (final (tier, list) in [
    (LocalCloseTier.explicit, localCloseExplicitPhrases),
    (LocalCloseTier.soft, localCloseSoftPhrases),
  ]) {
    for (final phrase in list) {
      final p = phrase.split(' ');
      if (!_startsWith(words, p)) continue;
      final rest = words.sublist(p.length);
      if (rest.isEmpty) return (phrase: phrase, tier: tier);
      for (final tail in _allowedTails) {
        if (rest.length == tail.length && _startsWith(rest, tail)) return (phrase: phrase, tier: tier);
      }
    }
  }
  return null;
}

/// The first close phrase found anywhere in [words] (for the too_long log).
String? _containedPhrase(List<String> words) {
  final padded = ' ${words.join(' ')} ';
  for (final phrase in [...localCloseExplicitPhrases, ...localCloseSoftPhrases]) {
    if (padded.contains(' $phrase ')) return phrase;
  }
  return null;
}

/// Classifies one utterance. null = not a close phrase at all.
LocalCloseResult? matchLocalClose(String text) {
  final all = _words(text);
  if (all.isEmpty) return null;
  final words = _withoutLeadingWakeWord(all);
  final negationStripped = _withoutNegation(words);
  if (negationStripped != null) {
    // "don't close the session", "I'm not done": the request without its
    // negation would have closed — say why it didn't.
    final m = _wholeMatch(negationStripped) ?? _wholeMatch(_withoutLeadingWakeWord(negationStripped));
    if (m != null) return LocalCloseBlocked('negation', phrase: m.phrase);
    final contained = _containedPhrase(negationStripped);
    return contained == null ? null : LocalCloseBlocked('negation', phrase: contained);
  }
  if (words.length <= localCloseMaxWords) {
    final m = _wholeMatch(words) ?? _wholeMatch(all);
    if (m != null) return LocalCloseMatch(m.tier, m.phrase);
  }
  final contained = _containedPhrase(words);
  return contained == null ? null : LocalCloseBlocked('too_long', phrase: contained);
}

enum CloseConfirmAnswer { yes, no, none }

const Set<String> _confirmYes = {
  'yes', 'yeah', 'yep', 'yup', 'sure', 'close it', 'correct', 'please do', 'yes please', 'yes close it',
  'yeah close it', 'sure close it', 'yes please close it', 'yes do it', 'yeah sure', 'yes sure', 'yes correct',
};

const Set<String> _confirmNo = {
  'no', 'nope', 'nah', 'not yet', 'keep going', 'don t', 'dont', 'no thanks', 'no thank you', 'no keep going',
  'no not yet', 'don t close it', 'don t close', 'no don t', 'no don t close it',
};

/// The answer to [localCloseConfirmQuestion]: whole-utterance only.
CloseConfirmAnswer classifyCloseConfirmAnswer(String text) {
  final joined = tokenizeTriggerText(text).join(' ');
  if (_confirmYes.contains(joined)) return CloseConfirmAnswer.yes;
  if (_confirmNo.contains(joined)) return CloseConfirmAnswer.no;
  return CloseConfirmAnswer.none;
}

/// What is going on around the utterance — the existing handling wins in
/// every one of these.
class LocalCloseContext {
  const LocalCloseContext({
    this.cameraActive = false,
    this.photoNoteActive = false,
    this.answersPhotoOffer = false,
  });

  /// Any camera step on screen (opening, live, captured, closing).
  final bool cameraActive;

  /// The photo-note flow (dictation / confirm) is open.
  final bool photoNoteActive;

  /// The last line heard offered a photo AND this utterance answers it
  /// (`classifyContinuationAnswer` != none) — e.g. "I am done" as a "no".
  final bool answersPhotoOffer;
}

enum LocalCloseDecisionKind {
  /// Not a close utterance — route normally.
  none,

  /// A close phrase, held back (see [LocalCloseDecision.reason]); route
  /// normally so the existing handling answers.
  blocked,

  /// Close now (explicit phrase, or "yes" to the confirm question).
  closeNow,

  /// Soft phrase — ask [localCloseConfirmQuestion].
  askConfirm,

  /// "No" to the confirm question — stay open.
  declined,

  /// Something else said while the question was pending — the question is
  /// dropped (treated as no) and the utterance is routed normally.
  pendingDropped,

  /// A repeat of a close already handled — do nothing.
  duplicate,
}

class LocalCloseDecision {
  const LocalCloseDecision(this.kind, {this.phrase, this.reason, this.tier});
  final LocalCloseDecisionKind kind;
  final String? phrase;
  final String? reason;
  final LocalCloseTier? tier;
}

/// Per-session state: the pending yes/no question, the repeat-block, and
/// whether a close was already requested (local or Gemini `end_session`).
class LocalCloseController {
  LocalCloseController({this.confirmTimeout = localCloseConfirmTimeout, this.repeatBlock = localCloseRepeatBlock});

  final Duration confirmTimeout;
  final Duration repeatBlock;

  ({String phrase, DateTime askedAt})? _pending;
  bool _closeRequested = false;
  ({String phrase, DateTime at})? _last;

  bool get confirmPending => _pending != null;
  bool get closeRequested => _closeRequested;

  LocalCloseDecision decide(String text, {required LocalCloseContext context, required DateTime now}) {
    final match = matchLocalClose(text);
    if (_closeRequested) {
      return match is LocalCloseMatch
          ? LocalCloseDecision(LocalCloseDecisionKind.duplicate, phrase: match.phrase, reason: 'close_already_requested')
          : const LocalCloseDecision(LocalCloseDecisionKind.none);
    }

    final pending = _pending;
    if (pending != null && now.difference(pending.askedAt) > confirmTimeout) _pending = null;
    if (_pending != null) {
      final answer = classifyCloseConfirmAnswer(text);
      if (answer == CloseConfirmAnswer.yes) {
        _pending = null;
        return _close(pending!.phrase, LocalCloseTier.soft, now, reason: 'confirmed');
      }
      if (answer == CloseConfirmAnswer.no) {
        _pending = null;
        _last = (phrase: pending!.phrase, at: now);
        return LocalCloseDecision(LocalCloseDecisionKind.declined, phrase: pending.phrase);
      }
      if (match is LocalCloseMatch && match.tier == LocalCloseTier.soft) {
        // "I'm done" again while we're asking — no second question.
        return LocalCloseDecision(LocalCloseDecisionKind.duplicate, phrase: match.phrase, reason: 'already_asking');
      }
      if (match is! LocalCloseMatch) {
        _pending = null;
        return LocalCloseDecision(LocalCloseDecisionKind.pendingDropped, phrase: pending!.phrase);
      }
      _pending = null; // an explicit close while asking: falls through
    }

    if (match == null) return const LocalCloseDecision(LocalCloseDecisionKind.none);
    if (match is LocalCloseBlocked) {
      return LocalCloseDecision(LocalCloseDecisionKind.blocked, phrase: match.phrase, reason: match.reason);
    }
    final m = match as LocalCloseMatch;
    final contextReason = context.photoNoteActive
        ? 'photo_note'
        : context.cameraActive
        ? 'camera_live'
        : context.answersPhotoOffer
        ? 'photo_offer'
        : null;
    if (contextReason != null) {
      return LocalCloseDecision(LocalCloseDecisionKind.blocked, phrase: m.phrase, reason: contextReason, tier: m.tier);
    }
    final last = _last;
    if (last != null && last.phrase == m.phrase && now.difference(last.at) < repeatBlock) {
      return LocalCloseDecision(LocalCloseDecisionKind.duplicate, phrase: m.phrase, reason: 'repeat_block');
    }
    if (m.tier == LocalCloseTier.explicit) return _close(m.phrase, m.tier, now, reason: 'explicit');
    _pending = (phrase: m.phrase, askedAt: now);
    _last = (phrase: m.phrase, at: now);
    return LocalCloseDecision(LocalCloseDecisionKind.askConfirm, phrase: m.phrase, tier: m.tier);
  }

  LocalCloseDecision _close(String phrase, LocalCloseTier tier, DateTime now, {required String reason}) {
    _closeRequested = true;
    _last = (phrase: phrase, at: now);
    return LocalCloseDecision(LocalCloseDecisionKind.closeNow, phrase: phrase, tier: tier, reason: reason);
  }

  /// The confirm question's 8 s timer fired. True when it was still
  /// pending (log `timeout`); the session stays open and nothing is said.
  bool onConfirmTimeout(DateTime now) {
    final pending = _pending;
    if (pending == null || now.difference(pending.askedAt) < confirmTimeout) return false;
    _pending = null;
    return true;
  }

  /// Gemini's own `end_session` toolCall arrived. True = a local close is
  /// already under way, so Gemini's is the duplicate and must be ignored;
  /// false = Gemini closes, and any later local close is a no-op.
  bool onGeminiEndSession() {
    if (_closeRequested) return true;
    _closeRequested = true;
    _pending = null;
    return false;
  }
}
