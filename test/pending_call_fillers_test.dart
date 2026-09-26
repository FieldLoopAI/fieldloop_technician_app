import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/completion_claim_detector.dart';
import 'package:fielloop/services/pending_call_fillers.dart';

/// Filler lines bypass `_lastVerbatimScriptText` (see
/// `pending_call_fillers.dart`), so the completion-claim audit has no
/// scripted-line exemption for them — any completed-action wording here
/// would be flagged and "corrected" out loud mid-capture.
void main() {
  for (final entry in pendingCallFillers.entries) {
    test('"${entry.key}" filler is not a completion claim', () {
      expect(completionClaimFunctionIn(entry.value.text), isNull);
    });
  }

  test('capture/upload fillers fire within ~2s of silence', () {
    expect(pendingCallFillers['capture_photo']!.delay, lessThanOrEqualTo(const Duration(seconds: 2)));
    expect(pendingCallFillers['confirm_photo_upload']!.delay, lessThanOrEqualTo(const Duration(seconds: 2)));
  });

  for (final entry in pendingCallFollowUpFillers.entries) {
    test('"${entry.key}" follow-up filler is not a completion claim', () {
      expect(completionClaimFunctionIn(entry.value.text), isNull);
    });

    test('"${entry.key}" follow-up comes well after the first filler and differs from it', () {
      final first = pendingCallFillers[entry.key]!;
      expect(entry.value.delay, greaterThan(first.delay + const Duration(seconds: 5)));
      expect(entry.value.text, isNot(first.text)); // never tripped as a duplicate response
    });
  }
}
