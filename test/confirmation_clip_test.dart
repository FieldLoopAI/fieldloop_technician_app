import 'dart:io';
import 'dart:typed_data';

import 'package:fielloop/services/confirmation_clip.dart';
import 'package:fielloop/services/wake_greeting_clip.dart';
import 'package:flutter_test/flutter_test.dart';

/// [ms] of mono int16 PCM at 24kHz, with a recognizable ramp so a round trip
/// can be compared byte for byte.
Uint8List _pcm(int ms) {
  final bytes = Uint8List(24 * ms * 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = i % 251;
  }
  return bytes;
}

void main() {
  group('which lines are cached (change 3)', () {
    test('fixed navigation/camera confirmations only', () {
      for (final reason in [
        'deterministic go_back',
        'deterministic view_invoice',
        'deterministic view_change_orders',
        'deterministic view_job_history',
        'deterministic view_estimate',
        'deterministic view_job_details',
        'deterministic open_camera',
      ]) {
        expect(isCacheableConfirmation(reason), isTrue, reason: reason);
      }
    });

    test('never data-bearing lines, fillers, retries or guard replies', () {
      for (final reason in [
        'deterministic get_job_details',
        'deterministic get_kb_answer error',
        'deterministic get_job_timeline_answer',
        'pending_call_filler[open_camera]',
        'verbatim_instruction_leak_retry',
        'intent_ambiguous',
        'session_greeting',
        'inactivity_warning',
        'toolCall "view_invoice" (id=abc)',
      ]) {
        expect(isCacheableConfirmation(reason), isFalse, reason: reason);
      }
    });
  });

  group('a turn is saved only if it said exactly the script', () {
    const script = 'The invoice is up — anything you\'d like me to check on it?';
    test('same words, any punctuation/case/spacing', () {
      expect(confirmationTranscriptMatches("The invoice is up anything you'd like me to check on it", script), isTrue);
      expect(confirmationTranscriptMatches("  the INVOICE is up —  anything you'd like me to check on it?", script), isTrue);
    });
    test('extra, missing or different words are not saved', () {
      expect(confirmationTranscriptMatches('The invoice is up', script), isFalse);
      expect(
        confirmationTranscriptMatches("Okay! The invoice is up — anything you'd like me to check on it?", script),
        isFalse,
      );
      expect(confirmationTranscriptMatches("I've opened the invoice", script), isFalse);
      expect(confirmationTranscriptMatches('', script), isFalse);
    });
  });

  test('clip is split into whole-sample ~100ms chunks covering every byte', () {
    final pcm = _pcm(1730);
    final chunks = splitPcmForPlayback(pcm);
    expect(chunks.every((c) => c.length.isEven), isTrue);
    expect(chunks.take(chunks.length - 1).every((c) => c.length == 4800), isTrue);
    expect(chunks.fold<int>(0, (sum, c) => sum + c.length), pcm.length);
    expect(Uint8List.fromList([for (final c in chunks) ...c]), pcm);
    expect(splitPcmForPlayback(pcm, chunkBytes: 4801).first.length, 4802);
  });

  group('ConfirmationClipStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('confirmation_clip_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('no clip yet -> null, so the caller falls back to the Gemini path', () async {
      final store = ConfirmationClipStore(directory: () async => dir);
      expect(await store.preload(), 0);
      expect(store.pcmFor("Okay, I've taken you back."), isNull);
    });

    test('save, then a fresh store (next session) preloads it and plays the same PCM', () async {
      const line = "Okay, I've taken you back.";
      final pcm = _pcm(1500);
      expect(await ConfirmationClipStore(directory: () async => dir).save(line, pcm), isTrue);

      final nextSession = ConfirmationClipStore(directory: () async => dir);
      expect(nextSession.pcmFor(line), isNull, reason: 'nothing in memory before preload');
      expect(await nextSession.preload(), 1);
      expect(nextSession.pcmFor(line), pcm, reason: 'WAV header stripped, samples intact');
      expect(nextSession.pcmFor('Camera\'s open — ready when you are.'), isNull);
    });

    test('implausible lengths are never saved', () async {
      final store = ConfirmationClipStore(directory: () async => dir);
      expect(await store.save('x', _pcm(200)), isFalse);
      expect(await store.save('y', _pcm(9000)), isFalse);
      expect(store.pcmFor('x'), isNull);
      expect(dir.listSync(), isEmpty);
    });

    test('does not pick up the wake greeting clip living in the same directory', () async {
      File('${dir.path}${Platform.pathSeparator}wake_greeting_${clipFileKey(kWakeGreetingText)}.wav')
          .writeAsBytesSync(pcm16ToWav(_pcm(1500)));
      final store = ConfirmationClipStore(directory: () async => dir);
      expect(await store.preload(), 0);
    });
  });

  group('build 175 — live-spoken navigation replies become cacheable (item 2)', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('confirmation_clip_nav_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    // The reply lines behind the five slow b174 turns, keyed by the reason each is requested under.
    const cases = <String, String>{
      'go back to main/home screen': 'deterministic view_job_details',
      'open the invoice': 'deterministic view_invoice',
      'show me the change order(s)': 'deterministic view_change_orders',
    };
    final lines = <String, String>{
      'deterministic view_job_details': jobDetailsNavigatedReply(cacheableWording: true),
      'deterministic view_invoice': "The invoice is up — anything you'd like me to check on it?",
      'deterministic view_change_orders': "I've opened the change orders — there aren't any on this job yet.",
    };

    test('every case is a cacheable confirmation reason', () {
      cases.forEach((phrase, reason) => expect(isCacheableConfirmation(reason), isTrue, reason: phrase));
    });

    test('the 174 job-details transcript ("Okay —") never matched and is flagged as truncated', () {
      expect(confirmationTranscriptMatches('Okay —', jobDetailsNavigatedReplyOld), isFalse);
      expect(confirmationTranscriptTruncated('Okay —', jobDetailsNavigatedReplyOld), isTrue);
      expect(confirmationTranscriptTruncated("Okay — you're", jobDetailsNavigatedReplyOld), isTrue);
      expect(confirmationTranscriptTruncated('Okay — going back now', jobDetailsNavigatedReplyOld), isFalse);
      expect(confirmationTranscriptTruncated(jobDetailsNavigatedReplyOld, jobDetailsNavigatedReplyOld), isFalse);
    });

    test('the new job-details wording keeps the same words, comma instead of the dash', () {
      expect(jobDetailsNavigatedReply(cacheableWording: false), jobDetailsNavigatedReplyOld);
      expect(jobDetailsNavigatedReplyCacheable, "Okay, you're on the job details screen.");
      expect(confirmationTranscriptMatches("Okay, you're on the job details screen.", jobDetailsNavigatedReplyCacheable), isTrue);
    });

    for (final entry in cases.entries) {
      test('${entry.key}: first clean spoken reply is saved, then plays from cache by exact text', () async {
        final line = lines[entry.value]!;
        final store = ConfirmationClipStore(directory: () async => dir);
        await store.preload();
        expect(store.pcmFor(line), isNull, reason: 'no clip yet: Gemini fallback');
        // A full, exact transcript is the only thing that lets a turn be saved.
        expect(confirmationTranscriptMatches(line, line), isTrue);
        expect(await store.save(line, _pcm(2600)), isTrue);
        final next = ConfirmationClipStore(directory: () async => dir);
        await next.preload();
        expect(next.pcmFor(line), _pcm(2600));
        // Keyed by the exact text: any other wording misses (no stale text).
        expect(next.pcmFor('$line Anything else?'), isNull);
      });
    }

    test('a truncated turn is never saved, so Gemini stays the fallback', () async {
      final store = ConfirmationClipStore(directory: () async => dir);
      const line = jobDetailsNavigatedReplyCacheable;
      expect(confirmationTranscriptMatches('Okay,', line), isFalse, reason: 'the screen then never calls save()');
      expect(store.pcmFor(line), isNull);
      expect(dir.listSync(), isEmpty);
    });
  });
}
