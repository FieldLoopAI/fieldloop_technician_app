import 'package:flutter/foundation.dart';

import 'build_info.dart';

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
    describeBuildIdentity(stamp: kBuildNumber, commit: kGitCommit, mode: currentBuildMode, builtAt: kBuildTimestamp),
  );
}
