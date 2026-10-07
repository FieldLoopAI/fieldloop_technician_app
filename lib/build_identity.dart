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

/// Version as the APK is named: `FieldLoop_v1.0.<build>_<date>.apk`.
String versionForBuild(int stamp) => '1.0.$stamp';

/// The full BUILD line: identity, version, VAD setting, voice flags, and
/// [when] it was printed (app start / first session open).
String describeFullBuildLine({required String flags, required String when}) =>
    '${describeBuildIdentity(stamp: kBuildNumber, commit: kGitCommit, mode: currentBuildMode, builtAt: kBuildTimestamp)} '
    'version=${versionForBuild(kBuildNumber)} $kVadSettingLabel flags=[$flags] when=$when';

/// Printed at app start ([when] = `app_start`) and again on the first voice
/// session open of the process (`first_session_open`), in case logcat was
/// started after launch.
void logBuildIdentity({String flags = '', String when = 'app_start'}) {
  debugPrint(describeFullBuildLine(flags: flags, when: when));
}

bool _buildLineLoggedForSession = false;

/// Once per process — see [logBuildIdentity].
void logBuildIdentityOnFirstSessionOpen({required String flags}) {
  if (_buildLineLoggedForSession) return;
  _buildLineLoggedForSession = true;
  logBuildIdentity(flags: flags, when: 'first_session_open');
}
