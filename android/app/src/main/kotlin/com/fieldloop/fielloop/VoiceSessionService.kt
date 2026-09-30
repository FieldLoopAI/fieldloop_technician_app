package com.fieldloop.fielloop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.util.Log

/**
 * Microphone foreground service for the live Gemini voice session.
 *
 * WHY: an installed release APK (not tethered to adb/`flutter run`) is
 * subject to Android's background restrictions — Doze, App Standby, OEM
 * "sleep unused apps". Once the screen turns off or the app leaves the
 * foreground, a process with no foreground service can lose mic capture
 * (Android 9+ silences background mic access for apps without one) and
 * network access. A `microphone`-type foreground service with a persistent
 * notification is Android's supported way to keep both alive for an active,
 * user-started voice session. A PARTIAL wake lock keeps the CPU running the
 * mic/WebSocket loop with the screen off.
 *
 * Started/stopped from Dart over the `com.fieldloop.fielloop/voice_session`
 * channel (see MainActivity) when a Gemini session starts/tears down. Never
 * throws into the caller: Android 12+ refuses a foreground-service start
 * from the background, and Android 14+ refuses a microphone one without a
 * granted RECORD_AUDIO — both are logged and reported as `false`, and the
 * voice session carries on exactly as it does today.
 */
class VoiceSessionService : Service() {
    companion object {
        private const val TAG = "VoiceSessionService"
        private const val CHANNEL_ID = "voice_session"
        private const val NOTIFICATION_ID = 4101
        /** Upper bound on the wake lock, so a missed stop can never hold the CPU awake indefinitely. */
        private const val WAKE_LOCK_TIMEOUT_MS = 3L * 60L * 60L * 1000L

        @Volatile
        var isRunning = false
            private set

        fun start(context: Context): Boolean {
            return try {
                context.startForegroundService(Intent(context, VoiceSessionService::class.java))
                true
            } catch (e: Exception) {
                Log.w(TAG, "VOICE FGS: start refused (${e.javaClass.simpleName}: ${e.message})")
                false
            }
        }

        fun stop(context: Context): Boolean {
            return try {
                context.stopService(Intent(context, VoiceSessionService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "VOICE FGS: stop failed (${e.javaClass.simpleName}: ${e.message})")
                false
            }
        }

        /** Time for the Activity's own teardown (camera, location, ...) to finish first. */
        private const val ORPHAN_PROCESS_EXIT_DELAY_MS = 1500L

        /**
         * The app was closed while a voice session was live. CONFIRMED via
         * logcat: this service kept the process alive after the Activity and
         * Flutter engine were gone, and flutter_sound's native recorder kept
         * capturing and posting to the detached engine indefinitely (500+
         * "FlutterJNI was detached ... Channel: xyz.canardoux.flutter_sound_recorder").
         * Dart asks the recorder to stop on `AppLifecycleState.detached`, but
         * nothing guarantees that platform call lands before the engine is
         * destroyed, and the plugin exposes no native handle to stop it from
         * here. With no UI and no engine left, ending the process is what
         * Android itself does when an app without a foreground service is
         * swiped away.
         */
        fun endOrphanedProcessSoon(reason: String) {
            Log.i(TAG, "VOICE FGS: $reason — ending the process in ${ORPHAN_PROCESS_EXIT_DELAY_MS}ms so no native recorder is left orphaned")
            Handler(Looper.getMainLooper()).postDelayed({
                Log.i(TAG, "VOICE FGS: ending process now ($reason)")
                Process.killProcess(Process.myPid())
            }, ORPHAN_PROCESS_EXIT_DELAY_MS)
        }
    }

    /** Swiped away from recents while a voice session was live. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "VOICE FGS: app task removed while the voice session was live — stopping the service")
        stopSelf()
        endOrphanedProcessSoon("task removed (swiped from recents)")
        super.onTaskRemoved(rootIntent)
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            acquireWakeLock()
            isRunning = true
            Log.i(TAG, "VOICE FGS: running (microphone foreground service + partial wake lock)")
        } catch (e: Exception) {
            // e.g. ForegroundServiceStartNotAllowedException / SecurityException.
            Log.w(TAG, "VOICE FGS: startForeground refused (${e.javaClass.simpleName}: ${e.message}) — stopping")
            isRunning = false
            stopSelf()
        }
        // An active voice session can't be meaningfully resumed by the system
        // after a kill — the app restarts it itself.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        isRunning = false
        Log.i(TAG, "VOICE FGS: stopped")
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Voice assistant", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while the hands-free voice assistant is listening"
                    setShowBadge(false)
                },
            )
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("FieldLoop voice assistant is on")
            .setContentText("Listening for hands-free commands on this job")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .apply { if (launch != null) setContentIntent(launch) }
            .build()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "fieldloop:voice_session").apply {
            setReferenceCounted(false)
            acquire(WAKE_LOCK_TIMEOUT_MS)
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }
}
