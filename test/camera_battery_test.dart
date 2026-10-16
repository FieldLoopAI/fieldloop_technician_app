// Bob's live-camera battery (client requirement, Oct 15) — six utterances
// with the camera preview live, run through the screen's real matcher /
// utterance-end order (test/support/live_camera_route.dart), for build 182
// (both b183 flags off) and build 183 (flags on). The Gemini intent check
// is the only non-deterministic step: each case states what Gemini is told
// to answer for it ("none" for remarks, "capture_photo" for a request), and
// a second group shows the result with NO help from Gemini at all.
import 'package:fielloop/services/continuation_answer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_camera_route.dart';

class _Case {
  const _Case(this.n, this.text, {required this.capture, this.question, this.b182, this.noGemini});
  final int n;
  final String text;

  /// Bob's expectation: COMMAND (capture) or CONVERSATION (no capture).
  final bool capture;
  final String? question;

  /// Build 182 result when it differs from [capture] (a FAIL there).
  final bool? b182;

  /// Result with Gemini answering nothing, when it differs from [capture].
  final bool? noGemini;

  String get gemini => capture ? 'capture_photo' : 'none';
}

const _battery = [
  _Case(1, 'That looks good', capture: false),
  _Case(2, 'The photo is blurry', capture: false, b182: true),
  _Case(3, 'Take another one', capture: true, noGemini: false),
  _Case(4, 'Snap it', capture: true),
  _Case(5, 'I like what I see', capture: false),
  _Case(6, 'Do it', capture: true, question: 'Should I take a photo?'),
];

void main() {
  group("Bob's battery — Gemini intent check answering as instructed", () {
    for (final c in _battery) {
      final label = '${c.n}. "${c.text}"${c.question == null ? '' : ' after "${c.question}"'} -> '
          '${c.capture ? 'COMMAND, capture' : 'CONVERSATION, no capture'}';
      test(label, () {
        final b183 = capturesB183(c.text, geminiIntent: c.gemini, heardQuestion: c.question);
        final b182 = capturesB182(c.text, geminiIntent: c.gemini, heardQuestion: c.question);
        expect(b183, c.capture, reason: 'build 183 ${routeLiveCamera(c.text, remarkVeto: true, intentCheckVeto: true, geminiIntent: c.gemini, heardQuestion: c.question)}');
        expect(b182, c.b182 ?? c.capture, reason: 'build 182');
      });
    }
  });

  group("Bob's battery — remarks stay conversation even if Gemini wrongly says capture_photo (b183)", () {
    for (final c in _battery.where((c) => !c.capture)) {
      test('${c.n}. "${c.text}"', () {
        expect(capturesB183(c.text, geminiIntent: 'capture_photo'), isFalse);
      });
    }
  });

  group("Bob's battery — no answer from Gemini (deterministic path only)", () {
    for (final c in _battery) {
      test('${c.n}. "${c.text}"', () {
        expect(capturesB183(c.text, heardQuestion: c.question), c.noGemini ?? c.capture);
      });
    }

    test('3. gap (unchanged from b182): no deterministic capture for "take another one" with the camera live', () {
      // The photo-offer answer needs a yes-word lead, so the bare form still
      // waits on the Gemini intent check even right after an offer.
      expect(classifyContinuationAnswer('Take another one'), ContinuationAnswer.none);
      expect(capturesB183('Take another one', heardQuestion: 'Want to take one more?'), isFalse);
      // Reported, not changed: with the camera LIVE, C13 narration
      // (`_maybeNoteCameraNarration`) runs before `_maybeAnswerPhotoOffer`
      // and keeps the 4-word "Yes, take another one" as a photo note.
      for (final build in [true, false]) {
        expect(
          routeLiveCamera('Yes, take another one', remarkVeto: build, intentCheckVeto: build, heardQuestion: 'Want to take one more?'),
          'conversation:narration_note',
        );
      }
    });
  });

  group('6. "Do it" — the pending question already exists (no new state)', () {
    test('camera live: "do it" is a whole-utterance shutter word, question or not', () {
      expect(routeLiveCamera('Do it', remarkVeto: true, intentCheckVeto: true), 'capture:wider_capture');
      expect(routeLiveCamera('Do it', remarkVeto: true, intentCheckVeto: true, heardQuestion: 'Should I take a photo?'),
          'capture:wider_capture');
    });

    test('the photo-offer answer (`_maybeAnswerPhotoOffer`) also reads it as yes to that question', () {
      expect(looksLikePhotoOfferQuestion('Should I take a photo?'), isTrue);
      expect(classifyContinuationAnswer('Do it'), ContinuationAnswer.affirmative);
      expect(productionScreen.contains('if (_maybeAnswerPhotoOffer(transcript)) return;'), isTrue);
    });
  });
}
