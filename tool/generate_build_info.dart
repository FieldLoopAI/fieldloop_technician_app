import 'dart:io';

/// Regenerates `lib/build_info.dart` with an incrementing build number and
/// the current wall-clock time, so the "Build: ..." label on
/// `LoginScreen` always reflects the actual build instead of a
/// hardcoded value someone forgot to update.
///
/// Wired into `android/app/build.gradle.kts`'s `preBuild` task, so every
/// Android build (`flutter run`/`flutter build apk`/...) regenerates this
/// automatically. Safe to run manually too:
///   dart run tool/generate_build_info.dart
/// — but MUST be run from the repo root (relative paths below assume
/// `Directory.current` is the Flutter project root, e.g. where
/// `pubspec.yaml` lives), which is also how Gradle invokes it (see this
/// script's own `workingDir` in build.gradle.kts).
void main() {
  final projectRoot = Directory.current.path;
  final counterFile = File('$projectRoot/build_number.txt');

  var buildNumber = 0;
  if (counterFile.existsSync()) {
    buildNumber = int.tryParse(counterFile.readAsStringSync().trim()) ?? 0;
  }
  buildNumber++;
  counterFile.writeAsStringSync('$buildNumber\n');

  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final timestamp = '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}';

  final outFile = File('$projectRoot/lib/build_info.dart');
  outFile.writeAsStringSync('''
// GENERATED FILE — DO NOT EDIT BY HAND.
//
// Regenerated automatically before every Android build by
// tool/generate_build_info.dart (wired into android/app/build.gradle.kts's
// `preBuild` task) — see that script for how. Committing the regenerated
// version after a build is expected; the values here just reflect whichever
// build last ran the generator, not a manually maintained constant.
//
// Run `dart run tool/generate_build_info.dart` from the repo root to
// regenerate manually (e.g. before a `flutter build`/`flutter run` on a
// platform that doesn't go through this project's Android Gradle build).

/// Incrementing build counter — see `build_number.txt` at the repo root,
/// which the generator script bumps by 1 every time it runs.
const int kBuildNumber = $buildNumber;

/// Wall-clock time this build was generated, captured when the generator
/// script ran — NOT a hardcoded value that could be forgotten to update.
const String kBuildTimestamp = '$timestamp';
''');

  stdout.writeln('generate_build_info: wrote build #$buildNumber @ $timestamp -> ${outFile.path}');
}
