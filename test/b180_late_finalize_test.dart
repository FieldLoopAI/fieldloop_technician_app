// Build 180 item B — the late-transcript settle (LATE_FINALIZE_MS) and the
// burst fix: a table of late-transcript cases with the exact number of
// times the end-of-utterance chain runs. Offline.
import 'dart:io';

import 'package:fielloop/services/late_finalize.dart';
import 'package:flutter_test/flutter_test.dart';

final String _screen = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();

/// Drives [LateFinalizeController] the way the screen does and counts how
/// often the end-of-utterance chain runs for each utterance, plus the log
/// reasons, so every case below states exact numbers.
class _Sim {
  _Sim({int? delayMs}) : c = LateFinalizeController(delayMs: delayMs ?? 100);
  final LateFinalizeController c;
  final Map<int, int> runs = {};
  final List<String> reasons = [];
  bool _timerPending = false;

  void _run(int seq, LateFinalizeStep step) {
    runs[seq] = (runs[seq] ?? 0) + 1;
    final r = lateFinalizeReason(step);
    if (r != null) reasons.add(r);
  }

  /// A late transcript chunk arrived (screen: _scheduleLateTranscriptFinalize).
  void lateChunk(int seq) {
    c.armed(seq);
    _timerPending = true;
  }

  /// The settle timer fires (only if still pending, as the screen cancels it).
  void timerFires(int seq, {bool speaking = false, bool resolved = false}) {
    if (!_timerPending) return;
    _timerPending = false;
    final step = c.onTimerFired(seq: seq, isSpeaking: speaking, alreadyResolved: resolved);
    if (step == LateFinalizeStep.runSettled) _run(seq, step);
    if (step == LateFinalizeStep.skippedAlreadyResolved) reasons.add(lateFinalizeReason(step)!);
  }

  /// A new utterance starts after [seq] (screen: _startNewUtterance).
  void newUtterance(int seq, {bool resolved = false}) {
    final step = c.onNewUtterance(seq: seq, alreadyResolved: resolved);
    _timerPending = false; // the screen cancels the timer on every new utterance
    if (step == LateFinalizeStep.runImmediate) _run(seq, step);
    if (step == LateFinalizeStep.skippedAlreadyResolved) reasons.add(lateFinalizeReason(step)!);
  }

  /// The mic goes quiet for [seq]: its normal routing runs (screen:
  /// _markStoppedSpeaking -> _finalizeUtteranceEndDeterministicTriggers).
  void speechEnds(int seq) {
    final step = c.onSpeechEnded(seq: seq);
    if (step == LateFinalizeStep.logAfterBurst) reasons.add(lateFinalizeReason(step)!);
    runs[seq] = (runs[seq] ?? 0) + 1;
  }
}

void main() {
  group('the settle value', () {
    test('default is 100ms (evidence in late_finalize.dart)', () {
      expect(kLateFinalizeMsDefine, 100);
      expect(kLateFinalizeMs, 100);
      expect(LateFinalizeController().delay, const Duration(milliseconds: 100));
    });
    test('clamped to 0–700', () {
      expect(clampLateFinalizeMs(-5), 0);
      expect(clampLateFinalizeMs(0), 0);
      expect(clampLateFinalizeMs(350), 350);
      expect(clampLateFinalizeMs(5000), 700);
    });
    test('700 = build 179 (burst fix off); anything shorter turns it on', () {
      expect(LateFinalizeController(delayMs: 700).burstFix, isFalse);
      expect(LateFinalizeController(delayMs: 699).burstFix, isTrue);
      expect(LateFinalizeController(delayMs: 0).burstFix, isTrue);
    });
  });

  group('late-transcript cases — exact chain runs per utterance', () {
    test('single chunk, quiet mic: runs once (settled)', () {
      final s = _Sim()
        ..lateChunk(1)
        ..timerFires(1);
      expect(s.runs, {1: 1});
      expect(s.reasons, ['settled']);
    });

    test('two chunks before the settle ends: still once', () {
      final s = _Sim()
        ..lateChunk(1)
        ..lateChunk(1)
        ..timerFires(1);
      expect(s.runs, {1: 1});
    });

    test('second chunk after the first re-run (separate command, as in the logs): once per chunk, as before', () {
      final s = _Sim()
        ..lateChunk(1)
        ..timerFires(1)
        ..lateChunk(1)
        ..timerFires(1);
      expect(s.runs, {1: 2});
    });

    test('burst starts a NEW utterance while the timer is pending: runs once, immediately', () {
      final s = _Sim()
        ..lateChunk(1)
        ..newUtterance(1)
        ..timerFires(1);
      expect(s.runs, {1: 1});
      expect(s.reasons, ['immediate']);
    });

    test('b178 14:48:52 shape: burst during the wait, then a new utterance: once, immediately', () {
      final s = _Sim()
        ..lateChunk(1)
        ..timerFires(1, speaking: true)
        ..newUtterance(1)
        ..speechEnds(2);
      expect(s.runs[1], 1);
      expect(s.reasons, ['immediate']);
    });

    test('burst continues the SAME utterance: its own speech end runs the chain once', () {
      final s = _Sim()
        ..lateChunk(1)
        ..timerFires(1, speaking: true)
        ..speechEnds(1);
      expect(s.runs, {1: 1});
      expect(s.reasons, ['after_burst']);
    });

    test('already resolved by a per-chunk matcher, burst during the wait: skipped (0)', () {
      final s = _Sim()
        ..lateChunk(1)
        ..timerFires(1, speaking: true, resolved: true)
        ..newUtterance(1, resolved: true);
      expect(s.runs, isEmpty);
      expect(s.reasons, ['skipped_already_resolved']);
    });

    test('already resolved, new utterance while pending: skipped (0)', () {
      final s = _Sim()
        ..lateChunk(1)
        ..newUtterance(1, resolved: true);
      expect(s.runs, isEmpty);
      expect(s.reasons, ['skipped_already_resolved']);
    });

    test('already resolved, quiet mic: runs once as before (every step stands down on its own flags)', () {
      final s = _Sim()
        ..lateChunk(1)
        ..timerFires(1, resolved: true);
      expect(s.runs, {1: 1});
    });

    test('no late transcript: a new utterance or speech end adds no late run', () {
      final s = _Sim()
        ..newUtterance(1)
        ..speechEnds(2);
      expect(s.runs, {2: 1});
      expect(s.reasons, isEmpty);
    });

    test('LATE_FINALIZE_MS=700 reproduces build 179: the burst case gets no run', () {
      final s = _Sim(delayMs: 700)
        ..lateChunk(1)
        ..timerFires(1, speaking: true)
        ..newUtterance(1);
      expect(s.runs, isEmpty);
      final t = _Sim(delayMs: 700)
        ..lateChunk(1)
        ..newUtterance(1);
      expect(t.runs, isEmpty);
    });

    test('never twice: a deferred run is consumed by whichever edge comes first', () {
      final s = _Sim()
        ..lateChunk(1)
        ..timerFires(1, speaking: true)
        ..speechEnds(1)
        ..newUtterance(1);
      expect(s.runs, {1: 1});
    });
  });

  group('source: wiring in the screen', () {
    test('the timer uses the controller delay, not a fixed 700ms', () {
      expect(_screen, contains('Timer(_lateFinalize.delay, () {'));
      expect(_screen, isNot(contains('Duration _lateTranscriptSettle')));
    });
    test('a pending re-run is handled before the new utterance resets its buffers', () {
      final at = _screen.indexOf('void _startNewUtterance(DateTime now');
      final flush = _screen.indexOf('_lateFinalize.onNewUtterance(', at);
      final reset = _screen.indexOf("_utteranceHeardText = '';", at);
      expect(flush, greaterThan(at));
      expect(flush, lessThan(reset));
    });
    test('the speech-end edge reports a deferred run before routing', () {
      final at = _screen.indexOf('void _markStoppedSpeaking({required String reason}) {');
      final block = _screen.substring(at, _screen.indexOf('\n  }\n', at));
      expect(block.indexOf('_lateFinalize.onSpeechEnded('), lessThan(block.indexOf('_finalizeUtteranceEndDeterministicTriggers();')));
    });
    test('per-chunk commands still run at arrival, before the late re-run is scheduled', () {
      final at = _screen.indexOf('void _onInputTranscription(String textChunk) {');
      final loop = _screen.indexOf('for (final entry in evaluators.entries) {', at);
      final late = _screen.indexOf('_scheduleLateTranscriptFinalize();', at);
      expect(loop, greaterThan(at));
      expect(loop, lessThan(late));
    });
    test('log tag', () => expect(_screen, contains("'LATE FINALIZE: delay=")));
  });
}
