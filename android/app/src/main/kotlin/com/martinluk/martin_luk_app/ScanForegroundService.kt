package com.martinluk.martin_luk_app

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
import android.util.Log

/**
 * User-started foreground dataSync owner for the already running FlutterEngine.
 * It never creates a second engine, never restarts itself, and never starts on
 * boot. Android/user process termination still stops work; the Dart checkpoint
 * is the recovery boundary, not a guarantee of uninterrupted execution.
 */
class ScanForegroundService : Service() {
    companion object {
        const val ACTION_START = "com.martinluk.martin_luk_app.scan.START"
        const val ACTION_PAUSE = "com.martinluk.martin_luk_app.scan.PAUSE"
        const val ACTION_RESUME = "com.martinluk.martin_luk_app.scan.RESUME"
        const val ACTION_STOP = "com.martinluk.martin_luk_app.scan.STOP"
        const val EXTRA_START_TOKEN = "start_token"
        internal const val CHANNEL_ID = "market_background_scan"
        private const val NOTIFICATION_ID = 7301
        private const val WAKE_LOCK_TIMEOUT_MS = 10 * 60 * 1_000L
        private const val WAKE_LOCK_RENEW_MS = 9 * 60 * 1_000L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var running = false
    private var paused = false
    private var stopping = false
    private var progress: Map<String, Any?> = emptyMap()
    private val renewWakeLock = object : Runnable {
        override fun run() {
            if (!running || paused || stopping) return
            try {
                acquireWakeLock()
                handler.postDelayed(this, WAKE_LOCK_RENEW_MS)
            } catch (error: Exception) {
                Log.e("BackgroundScan", "Wake lock renewal failed", error)
                stopScan("service_failed")
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(CHANNEL_ID, "市場輪掃", NotificationManager.IMPORTANCE_LOW)
            channel.description = "顯示背景掃描進度，並提供暫停與停止。"
            channel.setShowBadge(false)
            notificationManager().createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val token = intent.getLongExtra(EXTRA_START_TOKEN, -1L)
                if (!ScanServiceBridge.acceptsStart(token)) {
                    // No hidden/cold-start scanner: notification actions after
                    // a killed process must not bootstrap a fresh engine.
                    if (!running) stopSelf(startId)
                    return START_NOT_STICKY
                }
                try {
                    val notification = buildNotification()
                    if (Build.VERSION.SDK_INT >= 29) {
                        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                    }
                    running = true
                    paused = false
                    stopping = false
                    acquireWakeLock()
                    handler.removeCallbacks(renewWakeLock)
                    handler.postDelayed(renewWakeLock, WAKE_LOCK_RENEW_MS)
                    // The Dart start Future completes only after startForeground.
                    ScanServiceBridge.serviceStarted(this)
                } catch (error: Exception) {
                    Log.e("BackgroundScan", "Foreground service startup failed", error)
                    ScanServiceBridge.failStart("FOREGROUND_START_FAILED", error.message ?: "無法啟動背景輪掃。")
                    stopScan("startup_failed")
                }
            }
            ACTION_PAUSE -> if (running) handleNotificationAction { pauseScan() } else stopSelf(startId)
            ACTION_RESUME -> if (running) handleNotificationAction { resumeScan() } else stopSelf(startId)
            ACTION_STOP -> stopScan("user_stop")
            else -> if (!running) stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    fun updateProgress(arguments: Map<String, Any?>) {
        if (!running || stopping) return
        progress = arguments.toMap()
        refreshNotification()
    }

    fun pauseScan() {
        if (!running || paused || stopping) return
        paused = true
        releaseWakeLock()
        ScanServiceBridge.servicePaused(this, true)
        refreshNotification()
    }

    fun resumeScan() {
        if (!running || !paused || stopping) return
        paused = false
        try {
            acquireWakeLock()
            handler.removeCallbacks(renewWakeLock)
            handler.postDelayed(renewWakeLock, WAKE_LOCK_RENEW_MS)
            ScanServiceBridge.servicePaused(this, false)
            refreshNotification()
        } catch (error: Exception) {
            // A failed acquisition cannot leave Dart believing a paused
            // service resumed. Restore both owners before reporting the error.
            paused = true
            releaseWakeLock()
            ScanServiceBridge.servicePaused(this, true)
            refreshNotification()
            throw error
        }
    }

    fun stopScan(reason: String) {
        if (stopping) return
        stopping = true
        running = false
        releaseWakeLock()
        try {
            ScanServiceBridge.serviceStopped(this, reason)
        } catch (error: Exception) {
            Log.e("BackgroundScan", "Service state callback failed while stopping", error)
        }
        try {
            if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
            else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (error: Exception) {
            Log.e("BackgroundScan", "Foreground notification removal failed", error)
        } finally {
            stopSelf()
        }
    }

    /** API 34 short-service timeout and API 35+ dataSync execution budget. */
    override fun onTimeout(startId: Int) {
        stopScan("system_timeout")
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopScan("system_timeout")
    }

    override fun onDestroy() {
        releaseWakeLock()
        handler.removeCallbacksAndMessages(null)
        if (!stopping) {
            running = false
            ScanServiceBridge.serviceStopped(this, "service_destroyed")
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun handleNotificationAction(action: () -> Unit) {
        try {
            action()
        } catch (error: Exception) {
            Log.e("BackgroundScan", "Notification action failed", error)
            stopScan("service_failed")
        }
    }

    private fun acquireWakeLock() {
        val lock = wakeLock ?: (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:MarketScan")
            .apply { setReferenceCounted(false) }
            .also { wakeLock = it }
        // Timed acquisition is renewed only while the explicit service is
        // active. Each individual acquisition expires even after a crash.
        lock.acquire(WAKE_LOCK_TIMEOUT_MS)
    }

    private fun releaseWakeLock() {
        handler.removeCallbacks(renewWakeLock)
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (error: RuntimeException) {
            // A timed acquisition can expire between isHeld and release.
            // Cleanup must still clear bridge ownership and stop the Service.
            Log.w("BackgroundScan", "Wake lock was already released", error)
        }
    }

    private fun refreshNotification() {
        try {
            notificationManager().notify(NOTIFICATION_ID, buildNotification())
        } catch (error: Exception) {
            // Updating notification text is observational. A notification
            // manager failure must not cancel HTTP work or reset scan progress.
            Log.w("BackgroundScan", "Progress notification update failed", error)
        }
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun actionIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, ScanForegroundService::class.java).setAction(action)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        return PendingIntent.getService(this, requestCode, intent, flags)
    }

    private fun buildNotification(): Notification {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        val open = PendingIntent.getActivity(
            this,
            7300,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            flags,
        )
        val total = (progress["total"] as? Number)?.toInt()?.coerceAtLeast(0) ?: 0
        val attempted = (progress["attempted"] as? Number)?.toInt()?.coerceIn(0, total.coerceAtLeast(0)) ?: 0
        val defaultText = if (total > 0) "已掃描 $attempted/$total 檔" else "正在分批輪掃；切換其他 App 後繼續。"
        val text = if (paused) "已暫停；目前進度保留。"
        else (progress["text"] as? String)?.take(240)?.takeIf { it.isNotBlank() } ?: defaultText
        val title = (progress["title"] as? String)?.take(80)?.takeIf { it.isNotBlank() } ?: "市場輪掃"
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
        else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder.setSmallIcon(R.drawable.ic_stat_scan)
            .setContentTitle(if (paused) "$title（已暫停）" else title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setProgress(total, attempted, total <= 0 && !paused)
            .addAction(
                if (paused) android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause,
                if (paused) "繼續" else "暫停",
                actionIntent(if (paused) ACTION_RESUME else ACTION_PAUSE, 7302),
            )
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "停止", actionIntent(ACTION_STOP, 7303))
        return builder.build()
    }
}
