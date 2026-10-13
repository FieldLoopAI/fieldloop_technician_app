import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../tool/analyze_voice_logs.dart';

/// Build 178 Step 8 — the new analyzer sections, on a small synthetic log
/// with SOCKET DEAD / RECONNECT / closeCode=1011 (lines in the exact form
/// the app now prints them).
const String _part1 = '''
10-12 15:09:00.000 11446 11446 I flutter : BUILD: stamp=178 commit=abc12345 mode=release vad_silence_ms=default flags=[x] when=session_open
10-12 15:09:01.000 11446 11446 I flutter : GEMINI TOKEN: wakeAt=15:09:00.900 takenAt=15:09:00.910 gapMs=10 source=spare
10-12 15:09:01.400 11446 11446 I flutter : VOICE LATENCY: wake-word-detected -> mic-live: 500ms (first captured mic chunk, 640 bytes)
10-12 15:09:02.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:02.000] setupComplete received from server — raw payload: {} — starting mic stream now
10-12 15:09:05.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:05.000] VOICE PIPELINE [u=1] utterance_start: speech edge
10-12 15:09:06.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:06.000] VOICE PIPELINE [u=1] transcript_received: "Snap it." (x)
10-12 15:09:06.001 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:06.001] inputTranscription chunk: "Snap it."
10-12 15:09:06.900 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:06.900] TURN TIMING: speech end -> transcript 1000ms, transcript -> action done 5ms, action done -> first audio 300ms, total 1305ms (reply=deterministic)
10-12 15:09:10.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:10.000] VOICE PIPELINE [u=2] utterance_start: speech edge
10-12 15:09:14.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:14.000] DEAD STRETCH: 3000ms since the technician stopped speaking with no response yet
10-12 15:09:20.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:20.000] VOICE PIPELINE [u=3] utterance_start: speech edge
10-12 15:09:20.001 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:20.001] TURN TIMING: none utterance=2 reason=no_reply_audio
10-12 15:09:30.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:30.000] WebSocket closed by server (closeCode=1011, closeReason=Internal error encountered.)
10-12 15:09:30.001 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:30.001] SOCKET DEAD: code=1011 reason="Internal error encountered." initiatedBy=server sessionAgeMs=28000 utterancesSinceSetup=3 transcriptsSinceSetup=1 lastServerMessageAgoMs=20000
10-12 15:09:30.002 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:30.002] RECONNECT: scheduled attempt=1 reason=1011 in=2000
10-12 15:09:30.500 11446 11446 I flutter : GEMINI LIVE TEST: [15:09:30.500] SPEECH WATCHDOG: forcing "stopped speaking" (older timer — not a b178 WATCHDOG line)
10-12 15:09:33.900 11446 11446 I flutter : RECONNECT: attempt=1 reason=1011 delayMs=2000 result=ok totalDowntimeMs=3900
''';

const String _part2 = '''
10-12 15:20:00.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:20:00.000] setupComplete received from server — raw payload: {} — starting mic stream now
10-12 15:20:05.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:20:05.000] VOICE PIPELINE [u=1] utterance_start: speech edge
10-12 15:20:12.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:20:12.000] VOICE PIPELINE [u=2] utterance_start: speech edge
10-12 15:20:16.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:20:16.000] WATCHDOG: no transcript for 2 utterances this session -> restarting session
10-12 15:20:17.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:20:17.000] NETWORK: state=offline
10-12 15:20:18.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:20:18.000] goAway received — server will close the connection soon: {timeLeft: 5s}
10-12 15:20:19.000 11446 11446 I flutter : GEMINI LIVE TEST: [15:20:19.000] ERROR (WebSocket): SocketException: Connection reset
10-12 15:20:19.001 11446 11446 I flutter : GEMINI LIVE TEST: [15:20:19.001] WebSocket closed by server (closeCode=null, closeReason=null)
10-12 15:20:19.100 11446 11446 I flutter : GEMINI LIVE TEST: [15:20:19.100] TURN TIMING: speech end -> transcript 2000ms, transcript -> action done 5ms, action done -> first audio 1000ms, total 3005ms (reply=gemini) (estimated speech end: transcript arrival, a lower bound)
''';

List<int> _utf16le(String s) => [0xFF, 0xFE, for (final u in s.codeUnits) ...[u & 0xFF, u >> 8]];

void main() {
  late String report;
  setUpAll(() => report = analyzeVoiceLogs({'part_1': _part1, 'part_2': _part2}));

  test('the build 177 sections are still all there, first, unchanged in form', () {
    expect(report, startsWith('VOICE LOG ANALYSIS — 2 part(s)'));
    expect(report.indexOf('== SESSION END / APP CRASH'), lessThan(report.indexOf('== B178 MODULE A')));
    expect(report, contains('part_1: turns=1 p50=1305ms'));
  });

  test('Module A: each wake -> mic-live value numbered, with file and time', () {
    expect(report, contains('  1. part_1 15:09:01.400 500ms'));
  });

  test('GEMINI TOKEN lines quoted verbatim', () {
    expect(report, contains('part_1 15:09:01.000 GEMINI TOKEN: wakeAt=15:09:00.900 takenAt=15:09:00.910 gapMs=10 source=spare'));
  });

  test('Module B combined across files, with DEAD STRETCH and HANG counts', () {
    expect(
      report,
      contains('COMBINED: turns=2 p50=1305ms p90=3005ms max=3005ms >=3000ms=1 estimated=1 true_edge=1 '
          'DEAD STRETCH lines=1 SESSION HANG lines=0'),
    );
    expect(report, contains('part_2: turns=1'));
  });

  test('per-utterance table, including TURN TIMING: none rows', () {
    expect(report, contains('part_1 | 15:09:06.900 | "Snap it." | deterministic | true_edge | 1305'));
    expect(report, contains('part_1 | 15:09:20.001 | "" | none(no_reply_audio) | none | -'));
    expect(report, contains('part_2 | 15:20:19.100 | "" | gemini | estimated | 3005'));
  });

  test('recovery counts and verbatim lines; closeCode counted per code; old SPEECH WATCHDOG not counted', () {
    expect(report, contains('SOCKET DEAD=1'));
    expect(report, contains('RECONNECT=2'));
    expect(report, contains('RECONNECT: attempt=1 reason=1011 delayMs=2000 result=ok totalDowntimeMs=3900'));
    expect(report, contains('WATCHDOG=1'));
    expect(report, contains('NETWORK=1'));
    expect(report, contains('goAway=1'));
    expect(report, contains('ERROR (WebSocket)=1'));
    expect(report, contains('WebSocket closed=2 (closeCode=1011: 1, closeCode=null: 1)'));
  });

  test('sessions with utterances but zero transcripts', () {
    expect(report, contains('part_2 session from 15:20:00.000: utterances=2 transcripts=0'));
    expect(report, isNot(contains('part_1 session from')));
    expect(report, contains('sessions=1'));
  });

  test('UTF-16LE and UTF-8 logs give the same report', () {
    final viaUtf16 = analyzeVoiceLogs({
      'part_1': decodeLogBytes(_utf16le(_part1)),
      'part_2': decodeLogBytes(utf8.encode(_part2)),
    });
    expect(viaUtf16, report);
  });
}
