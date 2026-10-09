import 'dart:io';

import 'package:fielloop/services/confirmation_clip.dart';
import 'package:fielloop/services/job_facts.dart';
import 'package:flutter_test/flutter_test.dart';

bool reasonIsUnsupported(Set<String> lines) =>
    identical(lines, cacheableFixedReplyLines['unsupported_action call']) ||
    identical(lines, cacheableFixedReplyLines['unsupported_action message']);

void main() {
  final screenSource = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();

  group('build 175 second pass — fixed reply lines cached by reason AND text', () {
    test('each fixed line is cacheable with the flag on, not with it off', () {
      cacheableFixedReplyLines.forEach((reason, lines) {
        for (final text in lines) {
          expect(isCacheableReplyLine(reason, text, includeFixedLines: true), isTrue, reason: '$reason "$text"');
          if (!isCacheableConfirmation(reason)) {
            expect(isCacheableReplyLine(reason, text, includeFixedLines: false), isFalse, reason: '$reason "$text"');
          }
        }
      });
    });

    test('a variable line under the same reason is never cached', () {
      expect(isCacheableReplyLine('deterministic get_kb_answer', 'Turn the breaker off first.', includeFixedLines: true),
          isFalse);
      expect(isCacheableReplyLine('deterministic capture_photo', "I couldn't take that photo — please try again.",
          includeFixedLines: true), isFalse);
      expect(
        isCacheableReplyLine(
          'deterministic confirm_photo_upload',
          'Got it — keeping that photo. Save the note "water damage" with it — yes or no?',
          includeFixedLines: true,
        ),
        isFalse,
      );
      expect(isCacheableReplyLine('deterministic get_kb_answer error', kbUnreachableReply, includeFixedLines: true),
          isFalse);
      expect(isCacheableReplyLine('job_fact address', '401 Main St.', includeFixedLines: true), isFalse);
    });

    test('first-pass cacheable reasons are unchanged (any text, flag on or off)', () {
      for (final reason in cacheableConfirmationReasons) {
        expect(isCacheableReplyLine(reason, 'anything', includeFixedLines: false), isTrue, reason: reason);
      }
    });

    test('every fixed line is word for word what the screen speaks', () {
      for (final lines in cacheableFixedReplyLines.values) {
        for (final text in lines) {
          // job_facts.dart lines — checked against their functions below.
          if (text == outOfScopeReply || reasonIsUnsupported(lines)) continue;
          final inSource = screenSource.contains("'$text'") ||
              screenSource.contains('"$text"') ||
              // confirm_photo_upload = 'Got it — keeping that photo.' + suffix
              (text.startsWith('Got it — keeping that photo.') &&
                  screenSource.contains("'Got it — keeping that photo.") &&
                  screenSource.contains("'Want to add a note about this photo?'"));
          expect(inSource, isTrue, reason: text);
        }
      }
      expect(unsupportedActionReply(UnsupportedActionKind.call), "Sorry, I can't make calls.");
      expect(unsupportedActionReply(UnsupportedActionKind.message), "Sorry, I can't send messages.");
    });
  });

  group('build 175 second pass — short scripted lines (flag default off)', () {
    test('1–2 word line: judged on its opening word', () {
      expect(shortScriptedLineOpened(['okay'], ['okay']), isTrue);
      expect(shortScriptedLineOpened(['noted'], ['noted']), isTrue);
      expect(shortScriptedLineOpened(['got'], ['got', 'it']), isTrue);
    });
    test('anything else keeps the hold', () {
      expect(shortScriptedLineOpened(['sure'], ['okay']), isFalse); // not the line: no early STALE TURN either
      expect(shortScriptedLineOpened(['okay'], ['okay', 'you', 're', 'on']), isFalse); // longer script
      expect(shortScriptedLineOpened(['okay', 'sure'], ['okay']), isFalse); // 2+ words: normal judging
      expect(shortScriptedLineOpened([], ['okay']), isFalse);
    });
  });

  group('build 175 second pass — new flags in the BUILD line', () {
    test('Step 3 defaults: fixed lines on, prewarm and short lines OFF', () {
      expect(screenSource, contains('const bool _cacheFixedReplyLines = true;'));
      // Build 176 Step 6: switchable per APK, still false unless built with
      // --dart-define=JOB_FACT_CLIP_PREWARM=true (bool.fromEnvironment's
      // default is false; the BUILD line test checks the runtime value).
      expect(screenSource, contains("const bool _jobFactClipPrewarm = bool.fromEnvironment('JOB_FACT_CLIP_PREWARM');"));
      expect(screenSource, contains('const bool _playShortScriptedLinesImmediately = false;'));
    });
  });
}
