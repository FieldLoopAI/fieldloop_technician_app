# flutter_sound_core 9.30.0 — vendored and patched

**Upstream:** https://github.com/canardoux/flutter_sound_core, tag `9.30.0`
(commit `7036dd1db46a1e7ea610eef947a3a2de1ef4f102`). **License:** MPL-2.0 (see
`LICENSE`); the one modified file keeps its MPL header plus a modification notice.

**How it's used:** the `flutter_sound` plugin (pub, 9.30.0) depends on the
prebuilt `com.github.canardoux:flutter_sound_core:9.30.0` from JitPack. The root
`android/build.gradle.kts` substitutes this module for that artifact in every
subproject, and `android/settings.gradle.kts` includes it. Nothing in the pub
cache is edited. `build.gradle.kts` here replaces upstream's `build.gradle`,
which pins AGP 8.6 and carries publishing tasks; its android/dependency settings
are upstream's.

## The one change: `FlautoRecorderEngine.java`

Upstream reads the microphone by **polling from the Android main thread**. A
runnable does a non-blocking `AudioRecord.read`, then immediately re-posts itself
to the main thread with no delay, forever while recording. It also posts the
next run *before* checking whether the read found audio, so every read that did
find audio queues an extra copy of the loop.

In a FieldLoop trace this was ~3,600 main-thread messages per second
(`FlautoRecorderEngine$5`), holding the main thread 30-42% busy continuously
(91% at peak). Camera open and capture, which also need that thread, slowed from
2.9s to 42.7s within one session.

**Patched:**

- The same loop runs on a dedicated `FlutterSoundRecorderRead` thread. It makes
  the same non-blocking reads through the same `writeData16`/`writeData32`
  methods, which still hand each chunk to Dart on the main thread (Flutter
  channels require that). So chunk contents, sizes and order are unchanged.
- An empty read sleeps 5ms instead of re-polling at once. This adds at most
  ~5ms before a chunk is picked up.
- `_stopRecorder` stops and joins the thread before stopping and releasing the
  `AudioRecord` it reads from.

**Unchanged:** audio format, sample rate, channels, audio source, noise
suppression, echo cancellation, and the player side.

**Upgrading flutter_sound:** re-vendor the matching `flutter_sound_core` tag and
re-apply this change, or drop this module (remove the substitution and the
`include`) if upstream has moved reads off the main thread by then.
