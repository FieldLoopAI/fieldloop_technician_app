import 'dart:io';

import 'package:fielloop/build_identity.dart';
import 'package:fielloop/screens/gemini_live_test_screen.dart' show kVoiceFlagsSummary;
import 'package:flutter_test/flutter_test.dart';

/// Build 177 Step 7(a) — VAD_SILENCE_MS / VAD_END_SENSITIVITY reach the
/// Gemini setup message, the BUILD line and the VAD CONFIG line. Run also
/// with each A/B define:
///   flutter test --dart-define=VAD_SILENCE_MS=400 test/b177_vad_config_test.dart
///   flutter test --dart-define=VAD_SILENCE_MS=300 test/b177_vad_config_test.dart
///   flutter test --dart-define=VAD_END_SENSITIVITY=HIGH test/b177_vad_config_test.dart
void main() {
  final source = File('lib/screens/gemini_live_test_screen.dart').readAsStringSync();

  test('defines -> label (BUILD line, TURN TIMING SUMMARY)', () {
    final ms = kVadSilenceMsDefine > 0 ? '$kVadSilenceMsDefine' : 'default';
    final sens = kVadEndSensitivityDefine == 'HIGH' || kVadEndSensitivityDefine == 'LOW'
        ? kVadEndSensitivityDefine
        : 'default';
    expect(kVadSettingLabel, 'vad_silence_ms=$ms vad_end_sensitivity=$sens');
    expect(describeFullBuildLine(flags: kVoiceFlagsSummary, when: 'test'), contains(kVadSettingLabel));
  });

  test('setup message: realtimeInputConfig.automaticActivityDetection sent only when a define is set', () {
    expect(source, contains('const int _vadSilenceMsDefine = kVadSilenceMsDefine;'));
    expect(source, contains("if (_vadSilenceMsDefine > 0) 'silenceDurationMs': _vadSilenceMsDefine,"));
    expect(
      source,
      contains("if (_vadEndSensitivityDefine == 'HIGH') 'endOfSpeechSensitivity': 'END_SENSITIVITY_HIGH',"),
    );
    expect(source, contains("if (_vadEndSensitivityDefine == 'LOW') 'endOfSpeechSensitivity': 'END_SENSITIVITY_LOW',"));
    expect(
      source,
      contains(
        "          if (_serverVadSettings.isNotEmpty)\n"
        "            'realtimeInputConfig': {'automaticActivityDetection': _serverVadSettings},",
      ),
    );
    // Inside the `setup` object that is actually sent.
    final setup = source.indexOf("final setupMessage = jsonEncode({\n        'setup': {");
    final rtic = source.indexOf("'realtimeInputConfig': {'automaticActivityDetection': _serverVadSettings}");
    expect(setup, greaterThan(0));
    expect(rtic, greaterThan(setup));
    expect(rtic - setup, lessThan(6000));
  });

  test('VAD CONFIG line names the values sent', () {
    expect(source, contains("'VAD CONFIG: realtimeInputConfig NOT sent"));
    expect(source, contains("'silenceDurationMs=\${_serverVadSilenceDurationMs ?? 'default'} '"));
    expect(source, contains("'endOfSpeechSensitivity=\${_serverVadEndSensitivity ?? 'default'}"));
  });
}
