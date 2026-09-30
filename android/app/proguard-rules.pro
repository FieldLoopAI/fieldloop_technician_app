# R8 keep rules for the release build (see android/app/build.gradle.kts).
#
# Scope note: the Gemini Live WebSocket client, PCM/base64 audio encoding and
# the realtimeInput send path are all DART code, compiled ahead-of-time into
# libapp.so — R8 never sees or touches them. What R8 CAN strip/rename is the
# Java/Kotlin side of the Android plugins reached over platform channels, so
# every plugin involved in capturing, playing or routing audio (and the
# camera) is kept whole here, plus this app's own native code.

# flutter_sound — the plugin AND the vendored, patched flutter_sound_core
# (android/flutter_sound_core: background-thread mic reads). Keep rules only;
# the patched code itself is untouched.
-keep class xyz.canardoux.** { *; }
-keep interface xyz.canardoux.** { *; }
-dontwarn xyz.canardoux.**

# flutter_pcm_sound — Gemini response audio playback.
-keep class com.lib.flutter_pcm_sound.** { *; }

# speech_to_text — on-device wake word recognizer.
-keep class com.csdcorp.speech_to_text.** { *; }

# camera — CameraX implementation (camera_android_camerax) and the camera2
# one, plus CameraX itself.
-keep class io.flutter.plugins.camerax.** { *; }
-keep class io.flutter.plugins.camera.** { *; }
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**

# flutter_tts — MainActivity.routeTtsAudioTo reads the plugin's PRIVATE `tts`
# field BY NAME via reflection (Bluetooth SCO routing for spoken output).
# R8 renames private fields in release, which would silently break that
# lookup (it's caught and falls back to the phone speaker).
-keep class com.eyedeadevelopment.fluttertts.** { *; }

# permission_handler — microphone / battery-optimization requests.
-keep class com.baseflow.permissionhandler.** { *; }

# This app's own native code: MainActivity's method-channel handlers and
# VoiceSessionService (the microphone foreground service).
-keep class com.fieldloop.fielloop.** { *; }
