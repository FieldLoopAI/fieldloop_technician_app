// Build 177 Step 1 — read-only voice log analyzer (no app code is touched).
//
// Reads one or more `adb logcat` text dumps (UTF-8 or UTF-16LE/BE, with or
// without a BOM) and prints a plain-text summary of the tags the acceptance
// test reads: BUILD line, TURN TIMING per part and overall, wake -> mic-live,
// GEMINI TOKEN gapMs, negation guard, RAPID SWAP, transcript timeouts, job-fact
// clips, Gemini intent checks, camera opens and app session end / crash lines.
//
// Usage (from the repo root):
//   dart run tool/analyze_voice_logs.dart FieldLoop_b176_part_1.txt FieldLoop_b176_part_2.txt ...
//
// Written in Dart (not Python) so it runs with the SDK this repo already
// needs and its test runs inside `flutter test`. It imports nothing from
// `lib/`, so a log can be analyzed on any machine with the Dart SDK.

import 'dart:convert';
import 'dart:io';

const String appPackage = 'com.fieldloop.fielloop';

/// Decodes a logcat dump: UTF-16LE/BE by BOM (or by the zero bytes a BOM-less
/// UTF-16LE file has at odd offsets), otherwise UTF-8 (malformed bytes kept as
/// U+FFFD so a truncated dump still reads).
String decodeLogBytes(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return _utf16(bytes.sublist(2), littleEndian: true);
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return _utf16(bytes.sublist(2), littleEndian: false);
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  final probe = bytes.length < 400 ? bytes.length : 400;
  var oddZeros = 0;
  for (var i = 1; i < probe; i += 2) {
    if (bytes[i] == 0) oddZeros++;
  }
  if (probe >= 4 && oddZeros > probe / 4) return _utf16(bytes, littleEndian: true);
  return utf8.decode(bytes, allowMalformed: true);
}

String _utf16(List<int> bytes, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(littleEndian ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(units);
}

/// Nearest-rank percentile, the same method as `latency_stats.dart`.
int? nearestRank(List<int> values, int p) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  var rank = (p / 100 * sorted.length).ceil();
  if (rank < 1) rank = 1;
  return sorted[rank - 1];
}

/// Milliseconds since the start of the year (approx.) from a logcat
/// "MM-DD HH:MM:SS.mmm" prefix; null when the line has none.
int? logTimeMs(String line) {
  final m = _logTime.firstMatch(line);
  if (m == null) return null;
  int g(int i) => int.parse(m.group(i)!);
  return ((((g(1) * 31 + g(2)) * 24 + g(3)) * 60 + g(4)) * 60 + g(5)) * 1000 + g(6);
}

final RegExp _logTime = RegExp(r'^(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d{3})');
final RegExp _turnTiming = RegExp(
  r'TURN TIMING: speech end -> transcript (\S+), transcript -> action done (\S+), '
  r'action done -> first audio (\S+), total (\d+)ms \(reply=([^)]*)\)(.*)$',
);
final RegExp _wakeMic = RegExp(r'wake-word-detected -> mic-live: (\d+)ms');
final RegExp _tokenGap = RegExp(r'GEMINI TOKEN: .*gapMs=(\d+)');
final RegExp _negationBlocked = RegExp(r'NEGATION GUARD blocked intent=(\S+) transcript="(.*?)"');
final RegExp _transcriptChunk = RegExp(r'inputTranscription chunk: "(.*)"');
final RegExp _clipNotUsed = RegExp(r'cached clip for "(.*)" not used \(([^)]*)\)');
final RegExp _jobFactCached = RegExp(r'JOB FACT CACHED (hit|miss|stored|not stored)\b.*?kind=(\w+)');
final RegExp _timeoutRecovery = RegExp(r'TRANSCRIPT TIMEOUT RECOVERY: action=(\S+)');
final RegExp _transcriptLate = RegExp(r'TRANSCRIPT LATE ms=(\d+) action=(\S+)');
final RegExp _intentAsk = RegExp(r'GEMINI INTENT CHECK: asking Gemini');
final RegExp _intentResult = RegExp(r'GEMINI INTENT CHECK: heard="(.*?)" geminiIntent=(\S+) action=(\S+) \((.*)\)');
final RegExp _cameraOpened = RegExp(r'screen task: "open_camera" succeeded');
final RegExp _cameraWord = RegExp(r'\b(photo|photos|picture|pic|camera|capture|snap|shot)\b', caseSensitive: false);
final RegExp _negationCue = RegExp(
  r"\b(don't|dont|do not|not|never|no|forget|forgot|cancel|never mind|nevermind|changed my mind|hold on|stop)\b",
  caseSensitive: false,
);
final RegExp _cameraOrNoteDone = RegExp(
  r'TRIGGER: (open_camera|capture_photo|retake_photo|site_condition) succeeded'
  r'|toolCall: "(open_camera|capture_photo|retake_photo|site_condition)".*succeeded'
  r'|CAMERA NARRATION NOTED|outcome=saved',
);
final RegExp _utteranceStart = RegExp(r'VOICE PIPELINE \[u=\d+\] utterance_start');

class _Turn {
  _Turn(this.line);
  final String line;
  late final RegExpMatch m = _turnTiming.firstMatch(line)!;
  int get total => int.parse(m.group(4)!);
  int? get firstAudio => int.tryParse(m.group(3)!.replaceAll('ms', ''));
  String get reply => m.group(5)!;
  bool get estimated => m.group(6)!.contains('estimated speech end');
}

class _Part {
  _Part(this.name, this.lines);
  final String name;
  final List<String> lines;
  late final List<_Turn> turns = [
    for (final l in lines)
      if (_turnTiming.hasMatch(l)) _Turn(l),
  ];
}

String _stats(List<_Turn> turns) {
  if (turns.isEmpty) return 'turns=0';
  final totals = [for (final t in turns) t.total];
  final est = turns.where((t) => t.estimated).length;
  return 'turns=${turns.length} p50=${nearestRank(totals, 50)}ms p90=${nearestRank(totals, 90)}ms '
      'max=${totals.reduce((a, b) => a > b ? a : b)}ms >=3000ms=${totals.where((t) => t >= 3000).length} '
      'estimated=$est true_edge=${turns.length - est}';
}

String _tail(String line) {
  final i = line.indexOf(' : ');
  return (i < 0 ? line : line.substring(i + 3)).trim();
}

String _clock(String line) => line.length >= 18 ? line.substring(6, 18) : line;

/// The whole report for [parts] (name -> decoded log text), in order.
String analyzeVoiceLogs(Map<String, String> parts) {
  final ps = [for (final e in parts.entries) _Part(e.key, const LineSplitter().convert(e.value))];
  final all = [for (final p in ps) ...p.lines];
  final out = StringBuffer();
  void h(String title) => out.writeln('\n== $title');
  Iterable<String> matching(Pattern p) => all.where((l) => l.contains(p));

  out.writeln('VOICE LOG ANALYSIS — ${ps.length} part(s), ${all.length} lines');

  h('BUILD');
  final builds = <String>{for (final l in matching('BUILD: stamp=')) _tail(l).replaceAll(RegExp(r' when=\S+$'), '')};
  if (builds.isEmpty) out.writeln('  (no BUILD line)');
  for (final b in builds) {
    out.writeln('  $b');
  }

  h('TURN TIMING (per-turn lines; SUMMARY lines not counted)');
  for (final p in ps) {
    out.writeln('  ${p.name}: ${_stats(p.turns)}');
  }
  final turns = [for (final p in ps) ...p.turns];
  out.writeln('  OVERALL: ${_stats(turns)}');
  final kinds = <String, int>{};
  for (final t in turns) {
    kinds[t.reply] = (kinds[t.reply] ?? 0) + 1;
  }
  out.writeln('  reply kinds: ${kinds.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
  final glitches = turns.where((t) => (t.firstAudio ?? 0) > t.total).toList();
  out.writeln('  first audio > total (arithmetic glitch): ${glitches.length}');
  for (final g in glitches) {
    out.writeln('    ${_clock(g.line)} first_audio=${g.firstAudio}ms total=${g.total}ms');
  }
  final sessionTotals = matching('TURN TIMING SESSION TOTAL:').toList();
  if (sessionTotals.isNotEmpty) {
    out.writeln('  SESSION TOTAL lines: ${sessionTotals.length}');
    for (final l in sessionTotals) {
      out.writeln('    ${_clock(l)} ${_tail(l).replaceFirst(RegExp(r'^.*TURN TIMING SESSION TOTAL: '), '')}');
    }
  }

  h('WAKE -> MIC LIVE');
  final wake = [for (final l in all) ?_wakeMic.firstMatch(l)?.group(1)];
  out.writeln('  n=${wake.length} values_ms=[${wake.join(', ')}]');

  h('GEMINI TOKEN gapMs');
  final gaps = [for (final l in all) ?_tokenGap.firstMatch(l)?.group(1)];
  out.writeln('  n=${gaps.length} values_ms=[${gaps.join(', ')}]');

  h('NEGATION GUARD');
  final blocked = <String>[];
  for (final l in all) {
    final m = _negationBlocked.firstMatch(l);
    if (m != null) blocked.add('${_clock(l)} intent=${m.group(1)} "${m.group(2)}"');
  }
  out.writeln('  blocked=${blocked.length}');
  for (final b in blocked) {
    out.writeln('    $b');
  }
  // A negated camera transcript followed — before the next utterance starts,
  // at most 6s — by a camera action or a saved note is a defect to check.
  final suspicious = <String>[];
  for (var i = 0; i < all.length; i++) {
    final m = _transcriptChunk.firstMatch(all[i]);
    if (m == null) continue;
    final text = m.group(1)!;
    if (!_cameraWord.hasMatch(text) || !_negationCue.hasMatch(text)) continue;
    final t0 = logTimeMs(all[i]);
    for (var j = i + 1; j < all.length; j++) {
      final tj = logTimeMs(all[j]);
      if (_utteranceStart.hasMatch(all[j]) ||
          _transcriptChunk.hasMatch(all[j]) ||
          (t0 != null && tj != null && tj - t0 > 6000))
        break;
      if (_cameraOrNoteDone.hasMatch(all[j])) {
        suspicious.add(
          '${_clock(all[i])} "$text" -> ${_tail(all[j]).substring(0, _tail(all[j]).length.clamp(0, 140))}',
        );
        break;
      }
    }
  }
  out.writeln('  negated camera transcript followed by camera-open/note (CHECK each): ${suspicious.length}');
  for (final s in suspicious) {
    out.writeln('    $s');
  }

  h('RAPID SWAP');
  out.writeln('  lines=${matching('RAPID SWAP').length}');

  h('TRANSCRIPTS');
  final recov = <String, int>{};
  for (final l in all) {
    final a = _timeoutRecovery.firstMatch(l)?.group(1);
    if (a != null) recov[a] = (recov[a] ?? 0) + 1;
  }
  out.writeln(
    '  TRANSCRIPT TIMEOUT RECOVERY=${recov.values.fold(0, (a, b) => a + b)} '
    '(${recov.entries.map((e) => '${e.key}=${e.value}').join(', ')})',
  );
  final late = [
    for (final l in all)
      if (_transcriptLate.firstMatch(l) case final m?) '${_clock(l)} ms=${m.group(1)} action=${m.group(2)}',
  ];
  out.writeln('  TRANSCRIPT LATE=${late.length}');
  for (final l in late) {
    out.writeln('    $l');
  }

  h('JOB FACT CLIPS');
  final jf = <String, int>{'hit': 0, 'miss': 0, 'stored': 0, 'not stored': 0};
  for (final l in all) {
    final m = _jobFactCached.firstMatch(l);
    if (m != null) jf[m.group(1)!] = jf[m.group(1)!]! + 1;
  }
  out.writeln('  JOB FACT CACHED ${jf.entries.map((e) => '${e.key}=${e.value}').join(' ')}');
  final notUsed = <String, int>{};
  final notUsedLines = <String>[];
  for (final l in all) {
    final m = _clipNotUsed.firstMatch(l);
    if (m == null) continue;
    notUsed[m.group(2)!] = (notUsed[m.group(2)!] ?? 0) + 1;
    notUsedLines.add('${_clock(l)} (${m.group(2)}) "${m.group(1)}"');
  }
  out.writeln(
    '  cached clip not used=${notUsedLines.length} '
    '(${notUsed.entries.map((e) => '${e.key}=${e.value}').join(', ')})',
  );
  for (final l in notUsedLines) {
    out.writeln('    $l');
  }
  final waited = matching('CACHED CLIP WAIT').toList();
  if (waited.isNotEmpty) {
    out.writeln('  CACHED CLIP WAIT lines=${waited.length}');
    for (final l in waited) {
      out.writeln('    ${_clock(l)} ${_tail(l).replaceFirst(RegExp(r'^.*CACHED CLIP WAIT'), 'CACHED CLIP WAIT')}');
    }
  }

  h('GEMINI INTENT CHECK');
  final results = [for (final l in all) ?_intentResult.firstMatch(l)];
  final viaTimeout = results.where((m) => m.group(4)!.contains('via timeout')).length;
  out.writeln('  asked=${all.where(_intentAsk.hasMatch).length} results=${results.length} via_timeout=$viaTimeout');
  for (final m in results) {
    out.writeln('    "${m.group(1)}" -> ${m.group(2)} action=${m.group(3)} (${m.group(4)})');
  }

  h('CAMERA');
  final opens = all.where(_cameraOpened.hasMatch).length;
  final cameraTranscripts = [
    for (final l in all)
      if (_transcriptChunk.firstMatch(l) case final m? when _cameraWord.hasMatch(m.group(1)!)) m.group(1)!,
  ];
  final negated = cameraTranscripts.where(_negationCue.hasMatch).length;
  out.writeln(
    '  CAMERA OPEN (open_camera succeeded)=$opens; transcripts with a camera word=${cameraTranscripts.length} '
    '(with a negation cue=$negated, without=${cameraTranscripts.length - negated})',
  );

  h('SESSION END / APP CRASH');
  out.writeln('  SESSION END lines=${matching('SESSION END:').length}');
  final crash = <String>[];
  for (var i = 0; i < all.length; i++) {
    final l = all[i];
    final fatal =
        l.contains('FATAL EXCEPTION') && all.skip(i + 1).take(3).any((n) => n.contains('Process: $appPackage'));
    if (fatal ||
        l.contains('ANR in $appPackage') ||
        RegExp('Process ${RegExp.escape(appPackage)} \\(pid \\d+\\) has died').hasMatch(l) ||
        (l.contains('flutter') && l.contains('Unhandled Exception'))) {
      crash.add('${_clock(l)} ${_tail(l)}');
    }
  }
  out.writeln('  app crash / ANR / died / unhandled exception lines=${crash.length}');
  for (final c in crash) {
    out.writeln('    $c');
  }
  return out.toString();
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/analyze_voice_logs.dart <logcat.txt> [more.txt ...]');
    exitCode = 64;
    return;
  }
  final parts = <String, String>{
    for (final path in args) File(path).uri.pathSegments.last: decodeLogBytes(File(path).readAsBytesSync()),
  };
  stdout.write(analyzeVoiceLogs(parts));
}
