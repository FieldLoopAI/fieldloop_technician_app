/// Build 178 Step 5 (flag `SNAP_IT_FIX`) — short camera commands that the
/// phrase lists do not open the camera for.
///
/// b177 part 4: "Snap it." (15:09:48) matched nothing with the camera
/// closed ("snap it" is only a capture_photo phrase), so it waited on the
/// Gemini intent check, which timed out at 902ms, and the garbled quick
/// repeat asked to repeat; the same words 8s later opened the camera via
/// the intent check (801ms). Recognised here so the screen can route the
/// whole utterance through the normal open_camera trigger at once (the
/// negation guard and state guards still apply there).
///
/// Negated forms ("Don't snap it.", "No, snap it", "I don't want to snap
/// a photo.") are reported as [SnapCommand.negated] so the screen answers
/// "Okay." at once instead of "Sorry, can you say that again?".
///
/// Deliberately strict: the WHOLE utterance must be one of
/// [snapCommandPhrases], optionally wrapped in polite filler or led by a
/// negation. Anything else returns null and is routed exactly as before.
library;

import 'trigger_phrase_matcher.dart';

const List<String> snapCommandPhrases = [
  'snap it',
  'snap a photo',
  'snap a picture',
  'get a shot of this',
  'get a shot of that',
  'grab a shot',
];

enum SnapCommand { request, negated }

/// Words allowed around the command ("okay snap it please").
const Set<String> _politeFiller = {'ok', 'okay', 'please', 'just', 'so', 'now', 'go', 'ahead', 'and', 'um', 'uh'};

/// Negation words (apostrophes become spaces: "don't" -> "don t").
const Set<String> _negationWords = {'no', 'not', 'never', 'dont', 'don', 't', 'do', 'didn', 'didnt', 'won', 'wont'};

/// Words that may sit between a negation and the command ("I don't WANT
/// TO snap a photo").
const Set<String> _negationFiller = {'i', 'we', 'you', 'want', 'wanna', 'need', 'to', 'really', 'please', 'just'};

/// The negation tokens that actually make it a refusal ("do" alone does not).
const Set<String> _negationCues = {'no', 'not', 'never', 'dont', 'didnt', 'wont', 't'};

SnapCommand? classifySnapCommand(String transcript) {
  var words = tokenizeTriggerText(transcript);
  while (words.isNotEmpty && _politeFiller.contains(words.last)) {
    words = words.sublist(0, words.length - 1);
  }
  for (final phrase in snapCommandPhrases) {
    final p = phrase.split(' ');
    if (words.length < p.length) continue;
    var tailMatches = true;
    for (var i = 0; i < p.length; i++) {
      if (words[words.length - p.length + i] != p[i]) {
        tailMatches = false;
        break;
      }
    }
    if (!tailMatches) continue;
    final prefix = words.sublist(0, words.length - p.length).where((w) => !_politeFiller.contains(w)).toList();
    if (prefix.isEmpty) return SnapCommand.request;
    final onlyNegation = prefix.every((w) => _negationWords.contains(w) || _negationFiller.contains(w));
    if (onlyNegation && prefix.any(_negationCues.contains)) return SnapCommand.negated;
    return null;
  }
  return null;
}
