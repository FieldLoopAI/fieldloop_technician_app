package com.fieldloop.fielloop

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import com.eyedeadevelopment.fluttertts.FlutterTtsPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        /** See [installSlowMainThreadMessageLogger]. Debug builds only, even when true. */
        private const val PROFILE_MAIN_THREAD = false
    }

    private val audioDiagnosticsChannel = "com.fieldloop.fielloop/audio_diagnostics"

    /** See [VoiceSessionService] — the live voice session's foreground service. */
    private val voiceSessionChannel = "com.fieldloop.fielloop/voice_session"

    // Guards [startBluetoothScoAudio]'s broadcast wait so a second call
    // (shouldn't normally happen — GlobalVoiceService only calls it once
    // per job-scope session — but defensive against a stray double call)
    // cleans up its own receiver/timeout rather than leaking either.
    private var scoStateReceiver: BroadcastReceiver? = null
    private val scoTimeoutHandler = Handler(Looper.getMainLooper())
    private var scoTimeoutRunnable: Runnable? = null

    // Kept from configureFlutterEngine so [routeTtsAudioTo] can look up the
    // live flutter_tts plugin instance later, from a method-channel call
    // that arrives well after configureFlutterEngine has returned.
    private var engine: FlutterEngine? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        engine = flutterEngine
        installSlowMainThreadMessageLogger()
        // Bluetooth-headset-mic-ignored investigation/fix — see each
        // handler function's own doc comment. getAudioRouteInfo is
        // read-only diagnostics; isBluetoothAudioDevicePresent/
        // startBluetoothScoAudio/stopBluetoothScoAudio route the mic input;
        // routeTtsAudioToBluetoothSco/restoreTtsAudioRouting route TTS
        // output the same way.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, audioDiagnosticsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAudioRouteInfo" -> result.success(getAudioRouteInfo())
                    "getActiveRecordingInfo" -> result.success(getActiveRecordingInfo())
                    "isBluetoothAudioDevicePresent" -> result.success(isBluetoothAudioDevicePresent())
                    "startBluetoothScoAudio" -> startBluetoothScoAudio(result)
                    "stopBluetoothScoAudio" -> result.success(stopBluetoothScoAudio())
                    "routeTtsAudioToBluetoothSco" ->
                        result.success(routeTtsAudioTo(AudioAttributes.USAGE_VOICE_COMMUNICATION))
                    "restoreTtsAudioRouting" ->
                        result.success(routeTtsAudioTo(AudioAttributes.USAGE_MEDIA))
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, voiceSessionChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForegroundSession" -> result.success(VoiceSessionService.start(applicationContext))
                    "stopForegroundSession" -> result.success(VoiceSessionService.stop(applicationContext))
                    "getPowerState" -> result.success(getPowerState())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * The app is closing (back out of the root screen, or the task removed)
     * while a Gemini voice session is still live — its foreground service
     * would otherwise keep the process alive with flutter_sound's native
     * recorder orphaned. See [VoiceSessionService.endOrphanedProcessSoon].
     * Only when a session is live: every other close, and every
     * configuration-change recreation, is untouched.
     */
    override fun onDestroy() {
        if (isFinishing && VoiceSessionService.isRunning) {
            VoiceSessionService.stop(applicationContext)
            VoiceSessionService.endOrphanedProcessSoon("activity finishing with a live voice session")
        }
        super.onDestroy()
    }

    /**
     * Read-only power/background-restriction snapshot for the voice-session
     * log: whether this app is exempt from battery optimization, whether the
     * device is in Doze or power-save right now, and whether the user/OEM has
     * background-restricted the app.
     */
    private fun getPowerState(): Map<String, Any?> {
        val powerManager = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        return mapOf(
            "ignoringBatteryOptimizations" to powerManager.isIgnoringBatteryOptimizations(packageName),
            "deviceIdle" to powerManager.isDeviceIdleMode,
            "powerSave" to powerManager.isPowerSaveMode,
            "backgroundRestricted" to
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) activityManager.isBackgroundRestricted else null,
            "foregroundServiceRunning" to VoiceSessionService.isRunning,
        )
    }

    /**
     * DIAGNOSTIC ONLY — added to investigate a reported issue: a connected
     * Bluetooth headset's microphone is being ignored in favor of the
     * phone's built-in mic during voice capture (`speech_to_text`). Called
     * from `GlobalVoiceService._logAudioRoute` right as a listen() session
     * starts, purely to observe and log routing state — this function never
     * requests SCO or otherwise changes routing itself (see
     * [startBluetoothScoAudio] for the actual fix).
     *
     * `BLUETOOTH_CONNECT` (see AndroidManifest.xml) is now declared and
     * requested at runtime (see `GlobalVoiceService._maybeRouteBluetoothSco`
     * / `permission_providers.dart`'s `bluetoothPermissionProvider`), so
     * `bluetoothConnected` below should no longer come back `null` from a
     * `SecurityException` once granted — confirmed root cause of the
     * original bug report, before this permission existed at all: with it
     * missing, `permissionToEnableBluetooth` in `speech_to_text`'s own
     * `SpeechToTextPlugin.kt` was unconditionally false, silently no-opping
     * that plugin's own built-in `optionallyStartBluetooth()`/
     * `setupBluetooth()` logic on every device.
     */
    private fun getAudioRouteInfo(): Map<String, Any?> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // No special permission required — reflects whether the system has
        // an active Bluetooth SCO (voice) connection routed right now, as
        // opposed to merely a Bluetooth device being connected/paired.
        val bluetoothScoActive = audioManager.isBluetoothScoOn

        var bluetoothConnected: Boolean? = null
        try {
            val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            val adapter: BluetoothAdapter? = bluetoothManager?.adapter
            if (adapter == null || !adapter.isEnabled) {
                bluetoothConnected = false
            } else {
                // Requires BLUETOOTH_CONNECT on API 31+ (see doc comment
                // above) — caught below rather than crashing the caller on
                // a device/build where the permission still isn't granted
                // (e.g. denied by the technician).
                val headsetState = adapter.getProfileConnectionState(BluetoothProfile.HEADSET)
                val a2dpState = adapter.getProfileConnectionState(BluetoothProfile.A2DP)
                bluetoothConnected = headsetState == BluetoothProfile.STATE_CONNECTED ||
                        a2dpState == BluetoothProfile.STATE_CONNECTED
            }
        } catch (e: SecurityException) {
            bluetoothConnected = null
        } catch (e: Exception) {
            bluetoothConnected = null
        }

        // Best-effort description of the currently active/available input
        // route. AudioManager.getCommunicationDevice() (API 31+) is the
        // closest thing Android exposes to "the actual input device in use
        // for a voice session right now"; below that we can only report
        // which input devices are present, not which one is selected.
        var inputDevice = "unknown"
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val active = audioManager.communicationDevice
                inputDevice = if (active != null) describeDevice(active) else "none_reported"
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val inputs = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
                val btSco = inputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                inputDevice = if (btSco != null) {
                    "bluetooth_sco_input_present:${describeDevice(btSco)} (device selection not " +
                        "queryable below API 31)"
                } else {
                    "no_bluetooth_sco_input_device (device selection not queryable below API 31)"
                }
            }
        } catch (e: Exception) {
            inputDevice = "error:${e.javaClass.simpleName}"
        }

        return mapOf(
            "bluetoothConnected" to bluetoothConnected,
            "bluetoothScoActive" to bluetoothScoActive,
            "inputDevice" to inputDevice
        )
    }

    /**
     * Whether a Bluetooth audio device (headset mic or A2DP) is currently
     * present as an audio route — used by
     * `GlobalVoiceService._maybeRouteBluetoothSco` to decide whether it's
     * even worth asking for `BLUETOOTH_CONNECT` in the first place (per the
     * task: request the permission "the first time voice listening starts
     * if a Bluetooth device is detected as connected", not unconditionally
     * for every technician). Deliberately uses `AudioManager.getDevices`
     * (audio-framework device list), NOT `BluetoothAdapter` — this needs to
     * work BEFORE `BLUETOOTH_CONNECT` is granted, and `AudioManager`'s
     * device list requires no Bluetooth permission at all.
     */
    private fun isBluetoothAudioDevicePresent(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return outputs.any {
            it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO || it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
        }
    }

    /**
     * THE FIX for the reported bug: Android does not automatically route
     * microphone input through a connected Bluetooth headset just because
     * it's connected — `speech_to_text`'s on-device recognizer (and the
     * platform mic pipeline generally) only picks up the headset mic once
     * an app has explicitly opened a Bluetooth SCO (voice) audio link via
     * [AudioManager.startBluetoothSco]. Confirmed via a real
     * `SecurityException` in testing that the missing `BLUETOOTH_CONNECT`
     * permission (now declared/requested — see [getAudioRouteInfo]'s doc
     * comment) was blocking this from ever happening.
     *
     * `AudioManager.MODE_IN_COMMUNICATION` is set alongside this because a
     * plain `startBluetoothSco()` call without it is a well-documented
     * source of "SCO connects but the mic still doesn't route through it"
     * on real devices — communication mode is what tells the platform
     * audio HAL this is a voice-capture session, not media playback.
     * Restored to `MODE_NORMAL` in [stopBluetoothScoAudio].
     *
     * `startBluetoothSco()` is asynchronous — the link isn't actually up
     * the instant this returns, only once the system broadcasts
     * `ACTION_SCO_AUDIO_STATE_UPDATED` with `SCO_AUDIO_STATE_CONNECTED`.
     * This function's `result` isn't resolved until that broadcast lands
     * (or a 3s timeout elapses, in case a device that reports as
     * SCO-capable never actually confirms the link) — so the Dart-side
     * `await` in `GlobalVoiceService._maybeRouteBluetoothSco` genuinely
     * means "SCO is connected, or we gave up," not just "we asked." That
     * matters here specifically because `_maybeRouteBluetoothSco` runs
     * BEFORE the native listen() session opens the mic — the whole point
     * is for the headset mic to already be the active route by the time
     * capture starts, not to race it.
     */
    private fun startBluetoothScoAudio(result: MethodChannel.Result) {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            cleanUpScoWait()
            var resultSent = false
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (resultSent) return
                    val scoState = intent?.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, -1)
                    if (scoState == AudioManager.SCO_AUDIO_STATE_CONNECTED) {
                        resultSent = true
                        cleanUpScoWait()
                        result.success(true)
                    } else if (scoState == AudioManager.SCO_AUDIO_STATE_ERROR) {
                        resultSent = true
                        cleanUpScoWait()
                        result.success(false)
                    }
                    // SCO_AUDIO_STATE_DISCONNECTED mid-connect-attempt is
                    // ignored here (not a final answer) — either
                    // CONNECTED/ERROR or the timeout below will resolve.
                }
            }
            scoStateReceiver = receiver
            registerReceiver(receiver, IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED))

            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            audioManager.isBluetoothScoOn = true
            audioManager.startBluetoothSco()

            val timeout = Runnable {
                if (!resultSent) {
                    resultSent = true
                    cleanUpScoWait()
                    // Report whatever the system actually settled on rather
                    // than assuming failure — some OEM stacks are slow to
                    // broadcast even after the link is genuinely up.
                    result.success(audioManager.isBluetoothScoOn)
                }
            }
            scoTimeoutRunnable = timeout
            scoTimeoutHandler.postDelayed(timeout, 3000)
        } catch (e: SecurityException) {
            cleanUpScoWait()
            result.success(false)
        } catch (e: Exception) {
            cleanUpScoWait()
            result.success(false)
        }
    }

    /** Counterpart to [startBluetoothScoAudio] — called from
     * `GlobalVoiceService` when the whole job-scope voice session ends
     * (job exited, muted, or logout), not on every individual listen()
     * restart within a session (SCO is requested once per session — see
     * `GlobalVoiceService._bluetoothScoActive`).
     */
    private fun stopBluetoothScoAudio(): Boolean {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return try {
            cleanUpScoWait()
            audioManager.isBluetoothScoOn = false
            audioManager.stopBluetoothSco()
            audioManager.mode = AudioManager.MODE_NORMAL
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun cleanUpScoWait() {
        scoTimeoutRunnable?.let { scoTimeoutHandler.removeCallbacks(it) }
        scoTimeoutRunnable = null
        scoStateReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (e: Exception) {
                // Already unregistered (e.g. cleanUpScoWait called twice in
                // a row) — harmless.
            }
        }
        scoStateReceiver = null
    }

    /**
     * FIX (Bluetooth-headset-TTS-ignored bug) — companion to
     * [startBluetoothScoAudio] for the OUTPUT side: real-device testing
     * confirmed mic input correctly routes over Bluetooth SCO once that
     * function runs, but spoken TTS prompts/answers still came out of the
     * phone's own speaker. Root cause: Android's audio policy only pulls
     * audio explicitly tagged `AudioAttributes.USAGE_VOICE_COMMUNICATION`
     * (the same tag phone calls/VoIP apps use) onto an active SCO link —
     * ordinary media-style audio, which is what flutter_tts's underlying
     * `android.speech.tts.TextToSpeech` engine uses by default, is never
     * pulled onto SCO even while it's active for the mic. A mono
     * voice-only headset like the BlueParrott has no separate A2DP sink to
     * fall back onto either, so that audio just plays out the phone
     * speaker instead.
     *
     * flutter_tts exposes no Dart/platform-channel method for this — its
     * only Android audio-attributes hook, `setAudioAttributesForNavigation()`
     * (see its own `FlutterTtsPlugin.kt`), tags
     * `USAGE_ASSISTANCE_NAVIGATION_GUIDANCE`, which Android's audio policy
     * routes the same as ordinary media (speaker/A2DP), never SCO — not
     * usable here either. So this reaches flutter_tts's own
     * already-initialized `TextToSpeech` engine directly, via reflection
     * into its private `tts` field (there's no supported way to reach an
     * already-running plugin's internal engine otherwise, short of forking
     * flutter_tts or running a second, fully duplicate `TextToSpeech`
     * engine alongside it — voice/rate/pitch configuration, completion
     * callbacks, and all). Deliberately narrow and defensive: wrapped
     * entirely in try/catch, returns `false` rather than throwing if that
     * field is ever renamed/removed in a future flutter_tts version — the
     * Dart-side caller ([GlobalVoiceService]'s TTS-routing helpers) treats
     * that exactly like "no Bluetooth headset connected" and falls back to
     * the phone speaker, which is the CURRENT (pre-fix) behavior, not a
     * regression.
     *
     * Called around every [GlobalVoiceService.speak] call (unlike
     * [startBluetoothScoAudio], which only runs once per job-scope
     * session): `usage = USAGE_VOICE_COMMUNICATION` right before
     * `_tts.speak()`, then `usage = USAGE_MEDIA` right after, so a headset
     * that disconnects mid-session — or a technician who never had one
     * connected — is never left routed onto the voice-communication audio
     * path by mistake.
     */
    private fun routeTtsAudioTo(usage: Int): Boolean {
        return try {
            val ttsPlugin = engine?.plugins?.get(FlutterTtsPlugin::class.java) ?: return false
            val ttsField = ttsPlugin.javaClass.getDeclaredField("tts")
            ttsField.isAccessible = true
            val tts = ttsField.get(ttsPlugin) as? TextToSpeech ?: return false
            val attributes = AudioAttributes.Builder()
                .setUsage(usage)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            tts.setAudioAttributes(attributes)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * DIAGNOSTIC, debug builds only — names whatever is holding the Android
     * main thread. The Dart-side `main_thread_probe` (see
     * `gemini_function_dispatcher.dart`) proved it was blocked for 2-19s at a
     * time during photo capture (the capture itself took 27s and 88s in one
     * trace), but nothing native logged in that window, so the probe can say
     * THAT it's blocked, not by WHAT. Android's Looper reports each message it
     * dispatches ("Dispatching to Handler (...) {callback}") and when it
     * finishes; any message that ran 200ms+ is logged with that description,
     * which names the plugin/handler class doing the work. Off in release
     * builds: the Printer runs for every main-thread message.
     */
    private fun installSlowMainThreadMessageLogger() {
        // OFF by default now that it has done its job (it identified
        // flutter_sound's FlautoRecorderEngine$5 main-thread read loop,
        // ~3,600 messages/s). With a Printer installed, Looper formats two
        // description strings for EVERY main-thread message, and the backlog
        // profile below adds a regex per message — at that message rate the
        // instrumentation itself adds real main-thread and CPU load to the
        // very debug builds used to measure camera timing. Flip to true for a
        // dedicated diagnostic run only.
        if (!PROFILE_MAIN_THREAD) return
        val debuggable = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!debuggable) return
        var dispatchedAt = 0L
        var dispatching: String? = null
        // Backlog profile (CONFIRMED needed: during two slow photo captures
        // the Dart-side probe saw 0.7-2.3s main-thread round trips, yet not a
        // single message crossed the 200ms line above — the thread was busy
        // with MANY short messages, not one long one). Every message's time
        // is summed per handler/callback class; any 2s window in which the
        // thread was more than 30% busy logs its top contributors.
        val windowMs = 2000L
        var windowStartedAt = android.os.SystemClock.uptimeMillis()
        val busyByKey = HashMap<String, Long>()
        val countByKey = HashMap<String, Int>()
        val keyPattern = Regex("""\(([^)]*)\) \{[0-9a-f]+\} ([^@:\s]+)""")
        Looper.getMainLooper().setMessageLogging { line ->
            if (line.startsWith(">>>>> Dispatching")) {
                dispatchedAt = android.os.SystemClock.uptimeMillis()
                dispatching = line
            } else if (line.startsWith("<<<<< Finished")) {
                val finishedAt = android.os.SystemClock.uptimeMillis()
                val tookMs = finishedAt - dispatchedAt
                if (tookMs >= 200) {
                    android.util.Log.w("MainThreadSlow", "main-thread message took ${tookMs}ms: $dispatching")
                }
                val match = dispatching?.let { keyPattern.find(it) }
                val key = if (match != null) "${match.groupValues[1]} / ${match.groupValues[2]}" else "other"
                busyByKey[key] = (busyByKey[key] ?: 0L) + tookMs
                countByKey[key] = (countByKey[key] ?: 0) + 1
                dispatching = null
                if (finishedAt - windowStartedAt >= windowMs) {
                    val busy = busyByKey.values.sum()
                    val elapsed = finishedAt - windowStartedAt
                    if (busy * 100 >= elapsed * 30) {
                        val top = busyByKey.entries.sortedByDescending { it.value }.take(5)
                            .joinToString("; ") { "${it.value}ms/${countByKey[it.key]}x ${it.key}" }
                        android.util.Log.w(
                            "MainThreadBusy",
                            "main thread ${busy}ms busy in the last ${elapsed}ms (${busy * 100 / elapsed}%) — top: $top",
                        )
                    }
                    busyByKey.clear()
                    countByKey.clear()
                    windowStartedAt = finishedAt
                }
            }
        }
    }

    /**
     * DIAGNOSTIC ONLY (FIX 5 — tablet-only transcript timeouts). Read-only:
     * what Android ACTUALLY has in effect for this app's live recording(s),
     * as opposed to what the app asked flutter_sound for. A non-privileged
     * app only ever sees its own recordings here. Answers the open
     * tablet-vs-phone question with data: the real client and hardware
     * capture formats, the audio source and input device in use, whether
     * the platform is silencing this client, and which pre-processing
     * effects (AEC / noise suppression / AGC) are attached.
     */
    private fun getActiveRecordingInfo(): Map<String, Any?> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        fun describeFormat(format: android.media.AudioFormat): String =
            "${format.sampleRate}Hz ch=${format.channelCount} encoding=${format.encoding}"

        val recordings = try {
            audioManager.activeRecordingConfigurations.map { config ->
                val entry = mutableMapOf<String, Any?>(
                    "audioSource" to config.clientAudioSource,
                    "sessionId" to config.clientAudioSessionId,
                    "clientFormat" to describeFormat(config.clientFormat),
                    "deviceFormat" to describeFormat(config.format),
                    "inputDevice" to (config.audioDevice?.let { describeDevice(it) } ?: "unknown"),
                )
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    entry["clientSilenced"] = config.isClientSilenced
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    entry["clientEffects"] = config.clientEffects.map { it.name }
                    entry["deviceEffects"] = config.effects.map { it.name }
                }
                entry
            }
        } catch (e: Exception) {
            listOf(mapOf("error" to "${e.javaClass.simpleName}: ${e.message}"))
        }

        return mapOf(
            "device" to "${Build.MANUFACTURER} ${Build.MODEL} (API ${Build.VERSION.SDK_INT})",
            "smallestScreenWidthDp" to resources.configuration.smallestScreenWidthDp,
            "isTablet" to (resources.configuration.smallestScreenWidthDp >= 600),
            "audioMode" to audioManager.mode,
            "outputSampleRate" to audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE),
            "aecAvailable" to android.media.audiofx.AcousticEchoCanceler.isAvailable(),
            "nsAvailable" to android.media.audiofx.NoiseSuppressor.isAvailable(),
            "agcAvailable" to android.media.audiofx.AutomaticGainControl.isAvailable(),
            "activeRecordings" to recordings,
        )
    }

    private fun describeDevice(device: AudioDeviceInfo): String {
        val typeName = when (device.type) {
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "BLUETOOTH_SCO"
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> "BUILTIN_MIC"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "WIRED_HEADSET"
            AudioDeviceInfo.TYPE_USB_HEADSET -> "USB_HEADSET"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "BLUETOOTH_A2DP"
            else -> "TYPE_${device.type}"
        }
        return "$typeName(\"${device.productName}\")"
    }
}
