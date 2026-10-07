import 'package:flutter/foundation.dart';

import 'build_info.dart';

/// End-of-speech A/B (build 174) — chosen per APK at build time:
///   flutter build apk --release --dart-define=VAD_SILENCE_MS=400
/// 0/absent = nothing sent, the Gemini server default (see
/// `_serverVadSilenceDurationMs` in `gemini_live_test_screen.dart`).
const int kVadSilenceMsDefine = int.fromEnvironment('VAD_SILENCE_MS');

/// Optional: HIGH | LOW (`endOfSpeechSensitivity`); absent = not sent.
const String kVadEndSensitivityDefine = String.fromEnvironment('VAD_END_SENSITIVITY');

/// `vad_silence_ms=400 vad_end_sensitivity=default` — the same text in the
/// BUILD line and TURN TIMING SUMMARY.
const String kVadSettingLabel =
    'vad_silence_ms=${kVadSilenceMsDefine > 0 ? '$kVadSilenceMsDefine' : 'default'} '
    'vad_end_sensitivity=${kVadEndSensitivityDefine == 'HIGH' || kVadEndSensitivityDefine == 'LOW' ? kVadEndSensitivityDefine : 'default'}';

/// The one startup line that ties a log to the exact build it came from —
/// `grep "BUILD: stamp="`. [stamp]/[commit]/[builtAt] come from the
/// generated `build_info.dart`; [mode] is release/profile/debug.
String describeBuildIdentity({
  required int stamp,
  required String commit,
  required String mode,
  required String builtAt,
}) => 'BUILD: stamp=$stamp commit=$commit mode=$mode built=$builtAt';

String get currentBuildMode => kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug');

void logBuildIdentity() {
  debugPrint(
    '${describeBuildIdentity(stamp: kBuildNumber, commit: kGitCommit, mode: currentBuildMode, builtAt: kBuildTimestamp)} '
    '$kVadSettingLabel',
  );
}
