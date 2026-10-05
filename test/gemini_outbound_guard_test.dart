import 'package:fielloop/services/gemini_outbound_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('internal labels never reach Gemini-facing text (FIX 4)', () {
    test('the 98badd29 leak: "INTENT CHECK ic2" is stripped', () {
      final r = scrubInternalLabels('INTENT CHECK ic2: A field technician just said: "take a photo".');
      expect(r.text, 'A field technician just said: "take a photo".');
      expect(r.removed, containsAll(['INTENT CHECK', 'ic2']));
    });

    test('log tags, bracketed tags and key=value fields are stripped', () {
      expect(scrubInternalLabels('STALE TURN Got it.').text, 'Got it.');
      expect(scrubInternalLabels('KB GATE [job_detail]: Here is the answer.').text, 'Here is the answer.');
      expect(scrubInternalLabels('Camera is open id=abc123 reason=deterministic').text, 'Camera is open');
      expect(scrubInternalLabels('toolCall Opening the camera.').text, 'Opening the camera.');
    });

    test('ordinary spoken lines and job data are left untouched', () {
      const lines = [
        "The camera's already open — say 'ready' or 'capture it' when you want the photo.",
        'Hang on, the latency on this line is fine.',
        'Customer: ACME HVAC, 12 Main St.',
        "Here's the estimate — want me to read out any part of it?",
        'Did you mean take a photo, or show the invoice?',
        'The ice machine is in bay 2.',
        'Use a window with U=0.30 or lower (source=NFRC).',
      ];
      for (final line in lines) {
        final r = scrubInternalLabels(line);
        expect(r.text, line, reason: line);
        expect(r.removed, isEmpty, reason: line);
      }
    });
  });
}
