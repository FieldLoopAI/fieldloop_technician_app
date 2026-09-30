import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps a live voice session alive on an installed (untethered) Android
/// release build — see `android/app/.../VoiceSessionService.kt` for why.
/// Every call here is best-effort: a refusal is logged and the voice
/// session carries on exactly as it would without it. No-ops off Android.
class VoiceSessionPower {
  VoiceSessionPower._();

  static const MethodChannel _channel = MethodChannel('com.fieldloop.fielloop/voice_session');

  /// Starts the microphone foreground service (persistent notification +
  /// partial wake lock). Must be called while the app is in the foreground
  /// and after the microphone permission is granted — Android refuses it
  /// otherwise (reported as `false`, never thrown).
  static Future<bool> startForegroundSession() async {
    if (!Platform.isAndroid) return false;
    try {
      final started = await _channel.invokeMethod<bool>('startForegroundSession') ?? false;
      debugPrint('VOICE FGS: start requested -> ${started ? 'accepted' : 'REFUSED by Android'}');
      return started;
    } catch (e) {
      debugPrint('VOICE FGS: start failed: $e');
      return false;
    }
  }

  static Future<void> stopForegroundSession() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('stopForegroundSession');
      debugPrint('VOICE FGS: stop requested');
    } catch (e) {
      debugPrint('VOICE FGS: stop failed: $e');
    }
  }

  /// Battery-optimization exemption / Doze / power-save / background-
  /// restriction snapshot, for the session log. Empty on failure.
  static Future<Map<String, Object?>> powerState() async {
    if (!Platform.isAndroid) return const {};
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('getPowerState');
      return {for (final e in (raw ?? const {}).entries) '${e.key}': e.value};
    } catch (e) {
      debugPrint('VOICE POWER: power state unavailable: $e');
      return const {};
    }
  }
}

/// Battery-optimization exemption (REQUEST_IGNORE_BATTERY_OPTIMIZATIONS),
/// requested through permission_handler, which opens Android's own
/// "Let app always run in background?" dialog.
class BatteryOptimizationExemption {
  BatteryOptimizationExemption._();

  static const _askedKey = 'battery_optimization_exemption_asked';

  static Future<bool> isGranted() async {
    if (!Platform.isAndroid) return true;
    try {
      return await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> request() async {
    if (!Platform.isAndroid) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_askedKey, true);
      final status = await Permission.ignoreBatteryOptimizations.request();
      debugPrint('VOICE POWER: battery-optimization exemption request -> $status');
      return status.isGranted;
    } catch (e) {
      debugPrint('VOICE POWER: battery-optimization exemption request failed: $e');
      return false;
    }
  }

  /// Asks once per install, the first time a voice session starts — for
  /// devices that finished the one-time Permissions Setup before this
  /// existed (the setup screen asks it for new installs, and can be
  /// revisited from Profile).
  static Future<void> askOnceIfNeeded() async {
    if (!Platform.isAndroid || await isGranted()) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_askedKey) ?? false) {
        debugPrint('VOICE POWER: battery-optimization exemption NOT granted (already asked once — not re-prompting)');
        return;
      }
    } catch (_) {
      return;
    }
    await request();
  }
}
