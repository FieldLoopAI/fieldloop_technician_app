// Build 182 item A — one reply per utterance: the 2 s PREEMPTIVE DEFAULT MUTE
// safety timeout gives no second line to an utterance the app already
// answered (b181 14:21:16: garbled_quick_repeat clip, then
// preemptive_default_mute_timeout). Offline.
import 'dart:io';

import 'package:fielloop/services/b182_flags.dart';
import 'package:fielloop/services/one_reply_per_utterance.dart';
import 'package:flutter_test/flutter_test.dart';

final String _screen = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();

/// The screen's unclear-input streak, driven the way the screen drives it:
/// the timeout path's `_respondToUnclearInput` counts (and speaks by streak),
/// a suppressed timeout counts once via `_countUnclearInput`.
class _Sim {
  _Sim({bool enabled = true}) : guard = OneReplyGuard(enabled: enabled);
  final OneReplyGuard guard;
  int seq = 0;
  int streak = 0;
  final List<String> spoken = [];

  void _count() {
    streak++;
    guard.recordUnclearCounted(seq);
  }

  /// The `_respondToUnclearInput` escalation (unchanged in build 182).
  void _respondToUnclear(String reason) {
    _count();
    if (streak == 1) {
      _say('full', reason);
    } else if (streak == 2) {
      _say('short', reason);
    } else {
      spoken.add('quiet:$reason');
    }
  }

  void _say(String line, String reason) {
    spoken.add('$line:$reason');
    if (reason != 'preemptive_default_mute_timeout') guard.recordReply(seq, reason);
  }

  void utterance({required bool garbled}) {
    seq++;
    if (garbled) _say('Sorry, can you say that again?', 'garbled_quick_repeat');
    final d = guard.onSafetyTimeout(seq);
    if (d.suppress) {
      if (d.countUnclear) _count();
      return;
    }
    _respondToUnclear('preemptive_default_mute_timeout');
  }
}

void main() {
  test('flag defaults ON', () => expect(kOneReplyPerUtterance, isTrue));

  test('B182 FLAGS line', () {
    expect(describeB182Flags(), 'B182 FLAGS: oneReplyPerUtterance=true fuzzyRemarkVeto=true loopOffClose=true');
  });

  group('OneReplyGuard', () {
    test('answered by garbled_quick_repeat -> timeout suppressed, counted once', () {
      final g = OneReplyGuard(enabled: true)..recordReply(7, 'garbled_quick_repeat');
      final d = g.onSafetyTimeout(7);
      expect(d.suppress, isTrue);
      expect(d.countUnclear, isTrue);
      expect(d.answeredBy, 'garbled_quick_repeat');
    });

    test('nothing answered it -> the timeout reply runs as before', () {
      final g = OneReplyGuard(enabled: true);
      expect(g.onSafetyTimeout(1).suppress, isFalse);
      g.recordReply(1, 'garbled_quick_repeat');
      expect(g.onSafetyTimeout(2).suppress, isFalse, reason: 'a reply to an earlier utterance does not count');
    });

    test('a reply that already counted (clarify_fallback) is not counted twice', () {
      final g = OneReplyGuard(enabled: true)
        ..recordUnclearCounted(3)
        ..recordReply(3, 'clarify_fallback');
      final d = g.onSafetyTimeout(3);
      expect(d.suppress, isTrue);
      expect(d.countUnclear, isFalse);
    });

    test('flag off = build 181: never suppressed', () {
      final g = OneReplyGuard(enabled: false)..recordReply(1, 'garbled_quick_repeat');
      expect(g.onSafetyTimeout(1).suppress, isFalse);
    });
  });

  group('b181 14:21 sequence', () {
    test('ON: garbled utterances get the clip only, the streak still climbs 1, 2, 3', () {
      final s = _Sim();
      for (var i = 0; i < 4; i++) {
        s.utterance(garbled: true);
      }
      expect(s.spoken, List.filled(4, 'Sorry, can you say that again?:garbled_quick_repeat'));
      expect(s.streak, 4);
    });

    test('ON: unanswered utterances keep 1st full, 2nd short, 3rd+ quiet', () {
      final s = _Sim();
      for (var i = 0; i < 4; i++) {
        s.utterance(garbled: false);
      }
      expect(s.spoken, [
        'full:preemptive_default_mute_timeout',
        'short:preemptive_default_mute_timeout',
        'quiet:preemptive_default_mute_timeout',
        'quiet:preemptive_default_mute_timeout',
      ]);
    });

    test('ON: a garbled one followed by unanswered ones escalates exactly as build 181 counted', () {
      final on = _Sim()
        ..utterance(garbled: true)
        ..utterance(garbled: false)
        ..utterance(garbled: false);
      final off = _Sim(enabled: false)
        ..utterance(garbled: true)
        ..utterance(garbled: false)
        ..utterance(garbled: false);
      expect(on.streak, off.streak);
      expect(on.spoken.where((l) => l.endsWith('preemptive_default_mute_timeout')), [
        'short:preemptive_default_mute_timeout',
        'quiet:preemptive_default_mute_timeout',
      ]);
    });

    test('OFF: build 181 — the clip AND a second timeout line', () {
      final s = _Sim(enabled: false)..utterance(garbled: true);
      expect(s.spoken, ['Sorry, can you say that again?:garbled_quick_repeat', 'full:preemptive_default_mute_timeout']);
    });
  });

  group('screen wiring', () {
    test('the safety timeout consults the guard before its last-resort reply', () {
      final guardAt = _screen.indexOf('final oneReply = _oneReplyGuard.onSafetyTimeout(_utteranceSeq);');
      final replyAt = _screen.indexOf("_respondToUnclearInput(reason: 'preemptive_default_mute_timeout');");
      expect(guardAt, greaterThan(0));
      expect(replyAt, greaterThan(guardAt));
      expect(
        _screen.contains(r"_log_('ONE REPLY: suppressed timeout reply u=$_utteranceSeq (already answered by ${oneReply.answeredBy})');"),
        isTrue,
      );
      expect(_screen.contains("_clearPreemptiveDefaultMuteSilently('one_reply_per_utterance');"), isTrue);
    });

    test('every app reply is recorded; the timeout\'s own line is not', () {
      expect(_screen.contains("if (timesTurn && !isResend && reason != 'preemptive_default_mute_timeout') {"), isTrue);
      expect(_screen.contains('_oneReplyGuard.recordReply(_utteranceSeq, reason);'), isTrue);
    });

    test('_respondToUnclearInput still counts through the same streak code', () {
      expect(_screen.contains('bool _respondToUnclearInput({required String reason, bool clarify = false, String? reconfirmText}) {\n    _countUnclearInput();'), isTrue);
      expect(_screen.contains("_log_('UNCLEAR INPUT: 2nd in a row — short reply instead of repeating the full line (\$reason)');"), isTrue);
      expect(_screen.contains("_log_('UNCLEAR INPUT: \$_unclearInputStreak in a row — staying quiet (\$reason)');"), isTrue);
    });
  });
}
