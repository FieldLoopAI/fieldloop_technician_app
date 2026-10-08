/// Acceptance Test v1.0 C14–C17/C19/C20/C22 — short, local answers about the
/// current job, and the fixed replies for things the assistant can't do.
///
/// Everything here is pure (text in, text out) so it's unit-testable; the
/// session screen (`gemini_live_test_screen.dart`) reads the job data it
/// already holds in memory (job list, open visit, prefetched estimate) and
/// passes it in. Nothing here makes a network call.
///
/// Phrase lists are matched with the same [matchAnyTriggerPhrase] every
/// deterministic trigger uses (word-form drift, one filler word, negation
/// veto), and are written to be disjoint from the existing commands —
/// "show me the estimate", "what's on the estimate", "which screen am I on",
/// "what time did we arrive", "take me back" keep their current behavior
/// (see test/job_facts_test.dart).
library;

import '../models/job_estimate.dart';
import 'navigation_destination.dart';
import 'trigger_phrase_matcher.dart';

enum JobFactKind { customerName, address, timeOnSite, estimateSummary }

// Apostrophes normalize to a space ("what's" -> "what s"), so both that
// form and the no-apostrophe STT form are listed, same as every other list.
const List<String> customerNamePhrases = [
  'customer s name',
  'customers name',
  'customer name',
  'name of the customer',
  'client s name',
  'clients name',
  'homeowner s name',
  'who are we here for',
  'who is the customer',
  'who s the customer',
  'whos the customer',
  'who is this job for',
  'who s this job for',
  'whos this job for',
  'who are we working for',
];

const List<String> addressPhrases = [
  'what s the address',
  'whats the address',
  'what is the address',
  'job address',
  'service address',
  'address of this job',
  'address for this job',
  'where are we',
  'where is this job',
  'where s this job',
];

const List<String> timeOnSitePhrases = [
  'how long have we been here',
  'how long have we been on site',
  'how long have i been here',
  'how long have i been on site',
  'how long we ve been here',
  'how long we ve been on site',
  'how long have we been at this job',
  'how long have we been on this job',
  // Build 174 — STT drops the subject (6 Oct b173: "How long have been
  // here?" went to the KB and got "I can only help with this job.").
  'how long have been here',
  'how long have been on site',
  'how long been here',
  'how long been on site',
  'how long we been here',
  'how long we been on site',
];

const List<String> estimateSummaryPhrases = [
  'what was on the estimate',
  'what did we quote',
  'how much did we quote',
  'what was the quote',
  'what s the quote',
  'whats the quote',
  'what was the estimate',
  'what s the estimate total',
  'whats the estimate total',
  'what is the estimate total',
  'how much was the estimate',
  'how much is the estimate',
];

/// Which job fact [text] asks for, with the phrase that matched, or null.
/// Checked in a fixed order; a screen question ("where are we on this
/// screen?") is never taken as an address question — that stays with
/// get_current_screen.
({JobFactKind kind, TriggerPhraseMatch match})? matchJobFactQuestion(String text) {
  for (final (kind, phrases) in const [
    (JobFactKind.timeOnSite, timeOnSitePhrases),
    (JobFactKind.estimateSummary, estimateSummaryPhrases),
    (JobFactKind.customerName, customerNamePhrases),
    (JobFactKind.address, addressPhrases),
  ]) {
    final match = matchAnyTriggerPhrase(text, phrases);
    if (match == null) continue;
    if (kind == JobFactKind.address && _mentionsScreen(text)) return null;
    return (kind: kind, match: match);
  }
  return null;
}

bool _mentionsScreen(String text) {
  final words = tokenizeTriggerText(text);
  return words.contains('screen') || words.contains('page') || looksLikeCurrentScreenQuestion(text);
}

// --- Replies (ONE short sentence each, no preamble) -------------------------

String _sentence(String text) {
  final t = text.trim();
  if (t.isEmpty) return t;
  return RegExp(r'[.!?]$').hasMatch(t) ? t : '$t.';
}

/// [name] null/blank/"Not provided" = no name on file.
String customerNameReply(String? name) {
  final n = name?.trim() ?? '';
  if (n.isEmpty || n == 'Not provided') return "There's no customer name on this job.";
  return _sentence(n);
}

/// Address only — C22.
String addressReply(String? address) {
  final a = address?.trim() ?? '';
  if (a.isEmpty || a == 'Not provided') return "There's no address on this job.";
  return _sentence(a);
}

/// [openVisitArrivedAt]: when the CURRENT visit began (null = no open
/// visit). [everArrived]: whether any arrival was ever logged (null =
/// unknown). [loaded]: false while the open-visit state isn't known yet.
String timeOnSiteReply({
  required DateTime now,
  required bool loaded,
  DateTime? openVisitArrivedAt,
  bool? everArrived,
}) {
  if (!loaded) return 'The arrival time is still loading.';
  if (openVisitArrivedAt == null) {
    return everArrived == true ? "You're not on site right now." : "You haven't arrived yet.";
  }
  final minutes = now.difference(openVisitArrivedAt).inMinutes;
  if (minutes < 1) return 'Less than a minute on site.';
  if (minutes < 60) return '$minutes ${minutes == 1 ? 'minute' : 'minutes'} on site.';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  final h = '$hours ${hours == 1 ? 'hour' : 'hours'}';
  return rest == 0 ? '$h on site.' : '$h ${rest == 1 ? '1 minute' : '$rest minutes'} on site.';
}

/// C17 when the estimate isn't in memory (prefetch still running, failed,
/// or never started) — said instead of guessing (build 175 second pass).
const String estimateNotLoadedReply = "I don't have the estimate details loaded.";

/// Total and up to 3 line items, one sentence. [loaded] false while the
/// prefetched estimate hasn't arrived yet (or its fetch failed):
/// [honestNotLoaded] says [estimateNotLoadedReply], otherwise the older
/// "still loading" line.
String estimateSummaryReply({required bool loaded, JobEstimate? estimate, bool honestNotLoaded = true}) {
  if (!loaded) return honestNotLoaded ? estimateNotLoadedReply : 'The estimate is still loading.';
  if (estimate == null) return "There's no estimate on this job yet.";
  if (estimate.isVoided) return 'The estimate on this job was voided.';
  final total = spokenMoney(estimate.totalAmount);
  final items = [
    for (final item in estimate.lineItems)
      if (item.description.trim().isNotEmpty) _shortItem(item.description),
  ];
  if (items.isEmpty) return 'The estimate is $total.';
  final shown = items.take(3).toList();
  final list = shown.length == 1
      ? shown.first
      : '${shown.sublist(0, shown.length - 1).join(', ')} and ${shown.last}';
  final more = items.length - shown.length;
  return 'The estimate is $total for $list${more > 0 ? ', plus $more more' : ''}.';
}

String _shortItem(String description) {
  final words = description.trim().replaceAll(RegExp(r'[.!?]+$'), '').split(RegExp(r'\s+'));
  return words.length <= 8 ? words.join(' ') : words.take(8).join(' ');
}

/// "$1,250" for whole dollars, "$1,250.50" otherwise.
String spokenMoney(double amount) {
  final whole = amount == amount.roundToDouble();
  final fixed = amount.toStringAsFixed(whole ? 0 : 2);
  final parts = fixed.split('.');
  final digits = parts.first;
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return '\$$buf${parts.length > 1 ? '.${parts[1]}' : ''}';
}

// --- C20: actions the assistant can't do ----------------------------------

enum UnsupportedActionKind { call, message }

const List<String> unsupportedCallPhrases = [
  'call the customer',
  'call the client',
  'call the homeowner',
  'call the owner',
  'phone the customer',
  'phone the client',
  'ring the customer',
  'give the customer a call',
  'make a phone call',
];

const List<String> unsupportedMessagePhrases = [
  'text the customer',
  'text the client',
  'text the homeowner',
  'email the customer',
  'email the client',
  'email the homeowner',
  'message the customer',
  'message the client',
  'send the customer a text',
  'send the customer an email',
  'send the customer a message',
  'send a text',
  'send an email',
];

({UnsupportedActionKind kind, TriggerPhraseMatch match})? matchUnsupportedAction(String text) {
  final call = matchAnyTriggerPhrase(text, unsupportedCallPhrases);
  if (call != null) return (kind: UnsupportedActionKind.call, match: call);
  final message = matchAnyTriggerPhrase(text, unsupportedMessagePhrases);
  if (message != null) return (kind: UnsupportedActionKind.message, match: message);
  return null;
}

String unsupportedActionReply(UnsupportedActionKind kind) => switch (kind) {
  UnsupportedActionKind.call => "Sorry, I can't make calls.",
  UnsupportedActionKind.message => "Sorry, I can't send messages.",
};

// --- C19: no confident KB answer -------------------------------------------

/// Spoken instead of the knowledge-base-miss line (7 words).
const String outOfScopeReply = 'I can only help with this job.';

// --- C19 fast refusal (build 175 second pass) -------------------------------
//
// b174 14:51:42: "What's the weather today?" took ~10.5s from transcript to
// reply — a 1.8s Gemini intent check that never answered, then the KB
// catch-all's 8s timeout. These lists let the app refuse a clearly general-
// knowledge question at once, without either call. Positive evidence only:
// an off-topic word must be present AND no job/trade word may be — anything
// else ("what's the gate code", "is the rain going to hurt the roof") goes
// to the KB exactly as before.

/// General-knowledge topics, as whole words/phrases (normalized: lowercase,
/// apostrophes -> space).
const List<String> offTopicPhrases = [
  'weather',
  'forecast',
  'news',
  'headlines',
  'stock market',
  'stock price',
  'joke',
  'president',
  'prime minister',
  'capital of',
  'birthday',
  'movie',
  'movies',
  'song',
  'recipe',
  'who won',
  'football',
  'basketball',
  'baseball',
  'cricket',
  'what time is it',
  'what day is it',
  'what s the date',
  'whats the date',
  'what is the date',
  'today s date',
  'todays date',
];

/// Words that tie a question to the job — any one of them and the question
/// goes to the KB as before, off-topic word or not.
const Set<String> jobAnchorWords = {
  'job', 'customer', 'customers', 'client', 'homeowner', 'owner', 'gate', 'code', 'address', 'estimate', 'invoice',
  'quote', 'order', 'photo', 'picture', 'camera', 'site', 'house', 'home', 'roof', 'attic', 'panel', 'pipe', 'pipes',
  'leak', 'water', 'wire', 'wiring', 'unit', 'system', 'install', 'installation', 'repair', 'part', 'parts',
  'warranty', 'permit', 'appointment', 'visit', 'arrive', 'arrived', 'arrival', 'note', 'notes', 'history',
  'material', 'materials', 'tool', 'tools', 'crew', 'work', 'shingle', 'shingles', 'gutter', 'gutters', 'hvac',
  'furnace', 'ac', 'electrical', 'plumbing', 'concrete', 'paint', 'inspection', 'schedule', 'safety', 'phone',
};

/// The [offTopicPhrases] entry in [text] (whole words), with the first
/// [jobAnchorWords] word also in it — refuse only when `anchor` is null.
/// `null` when no off-topic phrase is there at all. Exact words only — no
/// fuzzy match, so "whether" is never "weather".
({String topic, String? anchor})? classifyOffTopicQuestion(String text) {
  final words = tokenizeTriggerText(text);
  if (words.isEmpty) return null;
  final padded = ' ${words.join(' ')} ';
  final topic = offTopicPhrases.where((p) => padded.contains(' $p ')).firstOrNull;
  if (topic == null) return null;
  final anchor = words.where(jobAnchorWords.contains).firstOrNull;
  return (topic: topic, anchor: anchor);
}

/// What a get_kb_answer TIMEOUT or ERROR says.
const String kbUnreachableReply = "Sorry, I couldn't reach the knowledge base right now — try again in a moment.";

/// Where a get_kb_answer call came from: `catch_all` = nothing else matched
/// the utterance (often off-topic, e.g. "What's the weather today?");
/// `match` = the KB's own phrase list matched a real job-knowledge question.
enum KbCallSource { catchAll, match }

/// Build 175 (item 3): a catch-all KB call that times out or errors says
/// [outOfScopeReply] when [catchAllSaysOutOfScope] — nothing marked it as a
/// job question, so "couldn't reach the knowledge base" only confused
/// (b174 14:51:52, "What's the weather today?"). A real KB match keeps
/// [kbUnreachableReply].
String kbFailureReply({required KbCallSource source, required bool catchAllSaysOutOfScope}) =>
    source == KbCallSource.catchAll && catchAllSaysOutOfScope ? outOfScopeReply : kbUnreachableReply;
