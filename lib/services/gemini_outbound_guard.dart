/// FIX 4 (Module B) — the hard guarantee that no internal tracking/debug
/// label reaches Gemini-facing text. CONFIRMED once (98badd29 log): the
/// intent check's opening "INTENT CHECK" plus its local id "ic2" were sent
/// inside a `clientContent` turn and Gemini SPOKE them (~690ms of
/// generation before it could be muted). That message was rewritten; this
/// guard sits at the outbound choke points (every scripted line and the
/// intent-check instruction) so no future edit can reintroduce the class
/// of bug: a label is stripped before sending and the strip is logged as
/// `INTERNAL LABEL LEAK PREVENTED`.
///
/// Only app-internal vocabulary is matched — the UPPERCASE log tags this
/// app prints, local ids (`ic3`), and `key=value` debug fields — never
/// ordinary words, so spoken lines and job data are left alone.
library;

/// The app's own uppercase log tags. Case-sensitive on purpose: "hang on"
/// or "latency" in a sentence is not a label; "STALE TURN" is.
const List<String> internalLogTags = [
  'GEMINI INTENT CHECK',
  'INTENT CHECK',
  'INTERNAL LABEL LEAK PREVENTED',
  'KB GATE',
  'KB TIMEOUT/ERROR SPOKEN',
  'KB CATCH-ALL',
  'CAMERA GATE',
  'CAMERA REQUEST REJECTED',
  'STALE TURN CUT SHORT',
  'STALE TURN',
  'TURN IDENTITY',
  'READBACK TAIL SUPPRESSED',
  'PENDING CALL FILLER',
  'CONTEXT REFRESH',
  'GO BACK COOLDOWN',
  'VOICE LATENCY',
  'LATENCY',
  'DEAD STRETCH',
  'SESSION HANG',
  'DETERMINISTIC',
  'FUZZY MATCH',
  'LOOSE NAV MATCH',
  'RECONFIRM',
  'PHOTO NOTE',
  'PHOTO TIMING',
  'TRANSCRIPT TIMEOUT',
];

final List<RegExp> _labelPatterns = [
  for (final tag in internalLogTags) RegExp('${RegExp.escape(tag)}(\\s*\\[[^\\]]*\\])?:?'),
  // Local intent-check ids: ic1, ic12.
  RegExp(r'\bic\d+\b'),
  // key=value debug fields this app logs (id=, check_id=, reason=, trigger=)
  // — not short ones like "u=" that real KB answers could contain.
  RegExp(r'\b(?:id|check_id|reason|trigger)=\S*'),
  RegExp(r'\btoolCall\b'),
];

/// [text] with every internal label removed, plus what was removed (empty
/// when the text was already clean — the normal case).
({String text, List<String> removed}) scrubInternalLabels(String text) {
  final removed = <String>[];
  var out = text;
  for (final pattern in _labelPatterns) {
    out = out.replaceAllMapped(pattern, (m) {
      removed.add(m.group(0)!);
      return ' ';
    });
  }
  if (removed.isEmpty) return (text: text, removed: removed);
  out = out
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAllMapped(RegExp(r'\s+([,.;:!?])'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'^[\s,.;:—–-]+'), '')
      .trim();
  return (text: out, removed: removed);
}
