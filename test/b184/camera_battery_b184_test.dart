// Bob's live-camera battery and the b183 device-log remark set, build 183
// vs build 184, with NO help from the Gemini intent check (it timed out on
// device: "geminiIntent=none via timeout"). Prints the table it checks.
import 'package:flutter_test/flutter_test.dart';

import 'live_camera_route_b184.dart';

class _Row {
  const _Row(this.label, this.text, this.expected, this.b183, this.b184, {this.question});
  final String label;
  final String text;
  final String expected;
  final String b183;
  final String b184;
  final String? question;
}

const _rows = [
  _Row('1', 'That looks good', 'conversation', 'conversation:fallback', 'conversation:quick_reply_noted'),
  _Row('2', 'The photo is blurry', 'conversation', 'conversation:fallback', 'conversation:quick_reply_noted'),
  _Row('3', 'Take another one', 'capture', 'conversation:fallback', 'capture:another_one'),
  _Row('4', 'Snap it', 'capture', 'capture:phrase_list', 'capture:phrase_list'),
  _Row('5', 'I like what I see', 'conversation', 'conversation:narration_note', 'conversation:narration_note'),
  _Row('6', 'Do it', 'capture', 'capture:wider_capture', 'capture:wider_capture', question: 'Should I take a photo?'),
  _Row('R', 'I like the photo.', 'conversation', 'conversation:fallback', 'conversation:quick_reply_noted'),
  _Row('R', 'The photo is blurry.', 'conversation', 'conversation:fallback', 'conversation:quick_reply_noted'),
  _Row('R', 'Nice shot.', 'conversation', 'conversation:fallback', 'conversation:quick_reply_noted'),
  _Row('R', 'This photo is dark.', 'conversation', 'conversation:fallback', 'conversation:quick_reply_noted'),
  _Row('R', 'The picture looks great', 'conversation', 'conversation:fallback', 'conversation:quick_reply_noted'),
  _Row('R', 'I like it', 'conversation', 'conversation:fallback', 'conversation:quick_reply_noted'),
  _Row('P4', 'Yes, take another one', 'capture', 'conversation:narration_note', 'capture:yes_capture_routing'),
];

void main() {
  test("Bob's battery + remark set: b183 vs b184 (Gemini intent check answering nothing)", () {
    final lines = <String>['#  | utterance               | expected     | b183                         | b184'];
    for (final r in _rows) {
      final b183 = routeB183(r.text, heardQuestion: r.question);
      final b184 = routeLiveCameraB184(r.text, heardQuestion: r.question);
      expect(b183, r.b183, reason: '${r.text} (b183)');
      expect(b184, r.b184, reason: '${r.text} (b184)');
      expect(b184.startsWith('capture:'), r.expected == 'capture', reason: r.text);
      lines.add('${r.label.padRight(2)} | ${r.text.padRight(23)} | ${r.expected.padRight(12)} | ${b183.padRight(28)} | $b184');
    }
    // ignore: avoid_print
    print(lines.join('\n'));
  });

  test('remarks stay conversation even if Gemini wrongly answers capture_photo (b184)', () {
    for (final r in _rows.where((r) => r.expected == 'conversation')) {
      expect(capturesB184(r.text, geminiIntent: 'capture_photo'), isFalse, reason: r.text);
    }
  });
}
