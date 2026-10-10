import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../tool/analyze_voice_logs.dart';

/// Build 177 Step 1 — the read-only log analyzer, on a short fixture built
/// from real build 176 lines.
const String _fixture = '''
10-09 14:05:26.023 11446 11446 I flutter : BUILD: stamp=176 commit=ab2db54f mode=release vad_silence_ms=default flags=[negationGuard=true] when=app_start
10-09 14:05:54.616 11446 11446 I flutter : GEMINI TOKEN: wakeAt=14:05:54.615 takenAt=14:05:54.615 gapMs=0 source=inflight
10-09 14:05:55.029 11446 11446 I flutter : VOICE LATENCY: wake-word-detected -> mic-live: 413ms (first captured mic chunk, 640 bytes)
10-09 14:06:08.157 11446 11446 I flutter : GEMINI LIVE TEST: [14:06:08.157] inputTranscription chunk: "What is the job address?"
10-09 14:06:09.369 11446 11446 I flutter : GEMINI LIVE TEST: [14:06:09.369] TURN TIMING: speech end -> transcript n/a, transcript -> action done n/a, action done -> first audio 11745ms, total 1212ms (reply=deterministic) (estimated speech end: transcript arrival, a lower bound)
10-09 14:06:09.370 11446 11446 I flutter : GEMINI LIVE TEST: [14:06:09.370] JOB FACT CACHED miss job=8ae3 kind=address ms_to_first_audio=11745 (Gemini spoke it)
10-09 14:06:19.345 11446 11446 I flutter : GEMINI LIVE TEST: [14:06:19.345] JOB FACT CACHED stored job=8ae3 kind=address clip=499682B/10410ms
10-09 14:06:27.409 11446 11446 I flutter : GEMINI LIVE TEST: [14:06:27.409] TURN TIMING: speech end -> transcript 2878ms, transcript -> action done 2ms, action done -> first audio 1055ms, total 3936ms (reply=deterministic)
10-09 14:06:59.666 11446 11446 I flutter : GEMINI LIVE TEST: [14:06:59.666] TURN TIMING: speech end -> transcript 1695ms, transcript -> action done 15ms, action done -> first audio 0ms, total 1711ms (reply=cached clip)
10-09 14:06:59.700 11446 11446 I flutter : GEMINI LIVE TEST: TURN TIMING SUMMARY: n=3; total p50=1711ms
10-09 14:07:40.977 11446 11446 I flutter : GEMINI LIVE TEST: [14:07:40.977] TRANSCRIPT TIMEOUT RECOVERY: action=silent_await_late — no transcript 3000ms after the speech edge; logged as TRANSCRIPT LATE with how late it was
10-09 14:17:36.687 11446 11446 I flutter : GEMINI LIVE TEST: [14:17:36.687] inputTranscription chunk: "I don't want to take photo."
10-09 14:17:36.702 11446 11446 I flutter : GEMINI LIVE TEST: [14:17:36.702] NEGATION GUARD blocked intent=open_camera transcript="I don't want to take photo." (cue="do not ... take", screen=none)
10-09 14:17:36.702 11446 11446 I flutter : GEMINI LIVE TEST: [14:17:36.702] CONFIRMATION CLIP: cached clip for "Okay." not used (audio player re-initialising) — Gemini speaks it instead
10-09 14:18:29.000 11446 11446 I flutter : GEMINI LIVE TEST: [14:18:29.000] inputTranscription chunk: "No, forget the photo."
10-09 14:18:29.500 11446 11446 I flutter : GEMINI LIVE TEST: [14:18:29.500] DETERMINISTIC OPEN_CAMERA TRIGGER: open_camera succeeded: {status: camera_open}
10-09 14:18:29.501 11446 11446 I flutter : GEMINI LIVE TEST: [14:18:29.501] screen task: "open_camera" succeeded -> cameraLive
10-09 14:19:03.448 11446 11446 I flutter : GEMINI LIVE TEST: [14:19:03.448] GEMINI INTENT CHECK: asking Gemini (ic1) heard="Forgot the photo." context=open_camera
10-09 14:19:03.448 11446 11446 I flutter : GEMINI LIVE TEST: [14:19:03.448] GEMINI INTENT CHECK: heard="Forgot the photo." geminiIntent=none action=fallback_weak_match (confidence=none, 1801ms, via timeout)
10-09 15:09:46.348 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:46.348] TRANSCRIPT LATE ms=12388 action=no_app_action cause=unconfirmed text="First"
10-09 15:10:29.299 11446 11446 I flutter : GEMINI LIVE TEST: [15:10:29.299] CONFIRMATION CLIP: cached clip for "I can only help with this job." not used (other audio still playing) — Gemini speaks it instead
10-09 15:20:00.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:20:00.000] SESSION END: left job scope — closing the Gemini Live session now
10-09 15:21:00.000  1588  2226 I ActivityManager: Process com.samsung.android.MtpApplication (pid 5692) has died: fore SVC
''';

List<int> _utf16le(String s, {bool bom = true}) => [
  if (bom) ...[0xFF, 0xFE],
  for (final u in s.codeUnits) ...[u & 0xFF, u >> 8],
];

void main() {
  late String report;
  setUpAll(() => report = analyzeVoiceLogs({'part_1': _fixture}));

  group('decoding', () {
    test('UTF-16LE with BOM, UTF-16LE without BOM, and UTF-8 all read the same', () {
      expect(decodeLogBytes(_utf16le(_fixture)), _fixture);
      expect(decodeLogBytes(_utf16le(_fixture, bom: false)), _fixture);
      expect(decodeLogBytes(utf8.encode(_fixture)), _fixture);
    });
  });

  test('BUILD line without the when= tail', () {
    expect(report, contains('BUILD: stamp=176 commit=ab2db54f'));
    expect(report, isNot(contains('when=app_start')));
  });

  test('TURN TIMING per-turn lines only, with p50/p90/max, >=3s and estimated counts', () {
    expect(report, contains('part_1: turns=3 p50=1711ms p90=3936ms max=3936ms >=3000ms=1 estimated=1 true_edge=2'));
    expect(report, contains('reply kinds: deterministic=2, cached clip=1'));
    expect(report, contains('first audio > total (arithmetic glitch): 1'));
  });

  test('wake -> mic-live and token gap values', () {
    expect(report, contains('n=1 values_ms=[413]'));
    expect(report, contains('n=1 values_ms=[0]'));
  });

  test('negation guard blocks, and a negated camera transcript that opened the camera is flagged', () {
    expect(report, contains('blocked=1'));
    expect(report, contains('negated camera transcript followed by camera-open/note (CHECK each): 1'));
    expect(report, matches(RegExp(r'"No, forget the photo." -> .*OPEN_CAMERA TRIGGER: open_camera succeeded')));
  });

  test('timeouts and late transcripts (the recovery line\'s own "TRANSCRIPT LATE" text is not counted)', () {
    expect(report, contains('TRANSCRIPT TIMEOUT RECOVERY=1 (silent_await_late=1)'));
    expect(report, contains('TRANSCRIPT LATE=1'));
  });

  test('job-fact clip counts and every cached-clip-not-used reason', () {
    expect(report, contains('JOB FACT CACHED hit=0 miss=1 stored=1 not stored=0'));
    expect(report, contains('cached clip not used=2 (audio player re-initialising=1, other audio still playing=1)'));
  });

  test('intent checks and how many ended via timeout', () {
    expect(report, contains('asked=1 results=1 via_timeout=1'));
  });

  test('camera opens vs camera-word transcripts', () {
    expect(report, contains('CAMERA OPEN (open_camera succeeded)=1; transcripts with a camera word=2'));
  });

  test('session end counted; another app dying is not an app crash', () {
    expect(report, contains('SESSION END lines=1'));
    expect(report, contains('app crash / ANR / died / unhandled exception lines=0'));
  });

  test('nearest-rank percentile matches latency_stats', () {
    expect(nearestRank([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 50), 5);
    expect(nearestRank([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 90), 9);
    expect(nearestRank([], 50), isNull);
  });
}
