import 'package:fielloop/screens/gemini_live_test_screen.dart' show kVoiceFlagsSummary;
import 'package:flutter_test/flutter_test.dart';

/// Build 177 — the BUILD line keeps every build 176 field as before; only
/// the build 177 flags are appended after `speechEdgeRms=500`.
void main() {
  const b176Tail = 'jobFactPhraseVariants=true micGain=off speechEdgeRms=500';
  const b177Flags =
      'cachedClipWaitForPlayer=true jobFactClipKeepAcrossSessions=true intentCheckTimeoutMs=900 '
      'garbledQuickRepeatSkipsIntentWait=true';

  test('build 177 flags come right after the build 176 ones, with their defaults', () {
    final at = kVoiceFlagsSummary.indexOf(b176Tail);
    expect(at, greaterThan(0), reason: kVoiceFlagsSummary);
    expect(kVoiceFlagsSummary.substring(at + b176Tail.length).trim(), b177Flags);
  });
}
