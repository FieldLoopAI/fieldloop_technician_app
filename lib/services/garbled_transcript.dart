/// Build 176 Step 5 — a short, garbled transcript nothing understood.
///
/// b175: "Can you got a sort that for me?" (quiet speech, mic avg RMS 108)
/// matched nothing, the Gemini intent check answered nothing (1803ms, via
/// timeout), and the KB catch-all then held the turn up to its 8s timeout
/// before answering. Such an utterance gets the existing "say that again"
/// line at once instead — but ONLY when every one of these holds:
///  - short (at most [garbledMaxWords] words);
///  - no job or trade word ([jobAnchorWords] + [_tradeWords]);
///  - not shaped like a real question ("how/what/why…", "is/does/should…",
///    "can I…") — those still go to the KB exactly as before.
/// Pure and conservative: anything else goes on to the KB unchanged.
library;

import 'job_facts.dart';
import 'trigger_phrase_matcher.dart';

/// "About 6 words" in the request; the b175 case it targets is 8 words
/// ("can you got a sort that for me"), so 8.
const int garbledMaxWords = 8;

/// Trade words beyond [jobAnchorWords] that mark a real KB question.
const Set<String> _tradeWords = {
  'breaker', 'breakers', 'circuit', 'outlet', 'outlets', 'switch', 'valve', 'valves', 'thermostat', 'filter',
  'filters', 'duct', 'ducts', 'drain', 'drains', 'faucet', 'toilet', 'sink', 'heater', 'boiler', 'compressor',
  'refrigerant', 'voltage', 'volt', 'volts', 'amp', 'amps', 'gas', 'vent', 'vents', 'insulation', 'drywall',
  'fuse', 'meter', 'pressure', 'leak', 'leaking', 'mold', 'damage', 'flashing', 'siding', 'window', 'door',
  'tile', 'floor', 'ceiling', 'wall', 'beam', 'joist', 'code', 'gfci', 'pvc', 'copper', 'sealant', 'caulk',
  'nail', 'nails', 'screw', 'screws', 'torque', 'psi', 'btu', 'ton', 'coil', 'condenser', 'furnace', 'tank',
};

/// First words of a real question — those always reach the KB.
const Set<String> _questionOpeners = {
  'how', 'what', 'whats', 'why', 'when', 'where', 'which', 'who', 'whos', 'is', 'are', 'does', 'do', 'did',
  'should', 'will', 'was', 'were', 'has', 'have', 'tell', 'explain',
};

/// Two-word openers that are questions too ("can I …", "could we …").
const Set<String> _questionPairs = {'can i', 'could i', 'can we', 'could we', 'should i', 'would i'};

/// Why [text] is NOT a garbled short utterance, or `null` when it is.
String? garbledShortRejection(String text) {
  final words = tokenizeTriggerText(text);
  if (words.isEmpty) return 'empty';
  if (words.length > garbledMaxWords) return 'longer than $garbledMaxWords words';
  final anchor = words.where((w) => jobAnchorWords.contains(w) || _tradeWords.contains(w)).firstOrNull;
  if (anchor != null) return 'job/trade word "$anchor"';
  if (_questionOpeners.contains(words.first)) return 'question opener "${words.first}"';
  if (words.length > 1 && _questionPairs.contains('${words[0]} ${words[1]}')) {
    return 'question opener "${words[0]} ${words[1]}"';
  }
  return null;
}

bool looksLikeGarbledShortUtterance(String text) => garbledShortRejection(text) == null;
