package com.martinluk.martin_luk_app

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/** Main-thread ownership and channel bridge for the existing UI FlutterEngine. */
internal object ScanServiceBridge : MethodChannel.MethodCallHandler {
    private const val CHANNEL = "martin_luk/background_scan"
    private const val ENGINE_ID = "martin_luk_scan_ui_engine"
    private const val NOTIFICATION_PERMISSION_REQUEST = 7121
    private const val START_TIMEOUT_MS = 7_000L
    private const val PERMISSION_TIMEOUT_MS = 45_000L
    private const val VISIBLE_RESUME_TIMEOUT_MS = 5_000L
    private const val ENGINE_SHUTDOWN_GRACE_MS = 5_000L
    private val handler = Handler(Looper.getMainLooper())

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var activity = WeakReference<MainActivity>(null)
    private var activityVisible = false
    private var service: ScanForegroundService? = null
    private var paused = false
    private var message: String? = null
    private var nextStartToken = 0L
    private var pendingStart: PendingStart? = null
    private var permissionDialogToken: Long? = null
    private var engineShutdown: Runnable? = null

    private class PendingStart(
        val token: Long,
        val result: MethodChannel.Result,
    ) {
        var timeout: Runnable? = null
        var awaitingVisibleAfterPermission = false
        var launched = false
    }

    fun cachedEngine(): FlutterEngine? = engine

    fun attachEngine(value: FlutterEngine, host: MainActivity) {
        cancelEngineShutdown()
        if (activity.get()?.let { it !== host } == true) {
            if (pendingStart != null) {
                failStart("ACTIVITY_RECREATED", "啟動畫面已重建；請再次啟動背景輪掃。")
            }
            permissionDialogToken = null
        }
        if (engine !== value) {
            check(engine == null) { "A scan already owns the UI FlutterEngine." }
            engine = value
            // Reference retention only: attaching this same UI engine through
            // serviceControlSurface would detach its Activity plugin host.
            // The Service must never call attachToService/create another engine.
            FlutterEngineCache.getInstance().put(ENGINE_ID, value)
            channel = MethodChannel(value.dartExecutor.binaryMessenger, CHANNEL).also {
                it.setMethodCallHandler(this)
            }
        }
        activity = WeakReference(host)
        activityVisible = false
    }

    fun setActivityVisible(host: MainActivity, visible: Boolean) {
        if (activity.get() !== host) return
        activityVisible = visible
        if (visible) {
            cancelEngineShutdown()
            pendingStart?.takeIf { it.awaitingVisibleAfterPermission }?.let {
                it.awaitingVisibleAfterPermission = false
                launchService(host, it.token)
            }
        }
    }

    fun detachActivity(host: MainActivity) {
        if (activity.get() !== host) return
        activity.clear()
        activityVisible = false
        permissionDialogToken = null
        if (pendingStart != null) {
            failStart("ACTIVITY_CLOSED", "啟動畫面已關閉；請返回 App 後重試。")
        }
        scheduleEngineShutdown()
    }

    private fun state(reason: String? = null): Map<String, Any?> = buildMap {
        put("active", service != null)
        put("paused", service != null && paused)
        put("message", message)
        if (reason != null) put("reason", reason)
    }

    private fun emit(reason: String) {
        // Engine disposal and service callbacks are serialized on the main
        // looper. Never retain the Activity in a MethodChannel closure.
        try {
            channel?.invokeMethod("stateChanged", state(reason))
        } catch (error: RuntimeException) {
            Log.w("BackgroundScan", "Dart state listener is unavailable", error)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> start(result)
                "status" -> result.success(state())
                "stop" -> {
                    if (pendingStart != null) {
                        failStart("START_CANCELLED", "背景輪掃啟動已取消。")
                    }
                    service?.stopScan("user_stop")
                    result.success(state())
                }
                "pause" -> {
                    service?.pauseScan()
                    result.success(state())
                }
                "resume" -> {
                    service?.resumeScan()
                    result.success(state())
                }
                "update" -> {
                    @Suppress("UNCHECKED_CAST")
                    val arguments = call.arguments as? Map<String, Any?> ?: emptyMap()
                    service?.updateProgress(arguments)
                    result.success(state())
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            Log.e("BackgroundScan", "Native operation ${call.method} failed", error)
            result.error("BACKGROUND_SCAN_ERROR", error.message ?: "背景輪掃操作失敗。", null)
        }
    }

    private fun start(result: MethodChannel.Result) {
        if (service != null) {
            result.success(state())
            return
        }
        if (pendingStart != null) {
            result.error("START_IN_PROGRESS", "背景輪掃仍在啟動中。", null)
            return
        }
        val host = activity.get()
        if (host == null || !activityVisible || host.isFinishing || host.isDestroyed) {
            result.error("VISIBLE_ACTIVITY_REQUIRED", "請在 App 畫面開啟時啟動背景輪掃。", null)
            return
        }
        if (engine == null) {
            result.error("ENGINE_UNAVAILABLE", "App 尚未就緒，無法啟動背景輪掃。", null)
            return
        }
        val needsNotificationPermission = Build.VERSION.SDK_INT >= 33 &&
            host.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        if (needsNotificationPermission && permissionDialogToken != null) {
            result.error("PERMISSION_REQUEST_IN_PROGRESS", "請先關閉目前的通知權限對話框，再重試。", null)
            return
        }
        cancelEngineShutdown()
        val token = ++nextStartToken
        val request = PendingStart(token, result)
        pendingStart = request
        if (needsNotificationPermission) {
            armStartTimeout(request, PERMISSION_TIMEOUT_MS, "通知權限等待逾時；請確認權限後重試。")
            try {
                permissionDialogToken = token
                host.requestPermissions(
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_PERMISSION_REQUEST,
                )
            } catch (error: Exception) {
                permissionDialogToken = null
                failStart("PERMISSION_REQUEST_FAILED", error.message ?: "無法要求通知權限。")
            }
        } else {
            launchService(host, token)
        }
    }

    fun onPermissionResult(host: MainActivity, requestCode: Int, results: IntArray) {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST || activity.get() !== host) return
        val permissionToken = permissionDialogToken
        permissionDialogToken = null
        val request = pendingStart ?: return // A late dialog result cannot start work.
        if (request.token != permissionToken) return
        if (results.isEmpty() || results[0] != PackageManager.PERMISSION_GRANTED) {
            failStart("NOTIFICATION_PERMISSION_REQUIRED", "請允許通知，才能顯示可暫停／停止的背景輪掃服務。")
        } else if (host.isFinishing || host.isDestroyed) {
            failStart("VISIBLE_ACTIVITY_REQUIRED", "請返回 App 畫面後再次啟動背景輪掃。")
        } else if (!activityVisible) {
            // Runtime permission dialogs can pause the Activity, and Android
            // may deliver the result before onResume. Wait for that callback
            // within the same bounded start budget; do not launch from background.
            request.awaitingVisibleAfterPermission = true
            armStartTimeout(request, VISIBLE_RESUME_TIMEOUT_MS, "畫面尚未返回前台；請開啟 App 後重試。")
        } else {
            launchService(host, request.token)
        }
    }

    private fun launchService(host: MainActivity, token: Long) {
        val request = pendingStart ?: return
        if (request.token != token || request.launched) return
        try {
            val manager = host.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) {
                failStart("NOTIFICATION_PERMISSION_REQUIRED", "請先在 Android 設定中允許 App 通知，再啟動背景輪掃。")
                return
            }
            if (Build.VERSION.SDK_INT >= 26 &&
                manager.getNotificationChannel(ScanForegroundService.CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE
            ) {
                failStart("NOTIFICATION_PERMISSION_REQUIRED", "請在 Android 通知設定中開啟「市場輪掃」頻道。")
                return
            }
            request.launched = true
            armStartTimeout(request, START_TIMEOUT_MS, "Android 前景服務啟動逾時；請稍後重試。")
            val intent = Intent(host, ScanForegroundService::class.java)
                .setAction(ScanForegroundService.ACTION_START)
                .putExtra(ScanForegroundService.EXTRA_START_TOKEN, token)
            if (Build.VERSION.SDK_INT >= 26) host.startForegroundService(intent)
            else host.startService(intent)
        } catch (error: Exception) {
            failStart("FOREGROUND_START_FAILED", error.message ?: "Android 拒絕啟動前景服務。")
        }
    }

    /** Reject OS-restored/cold service starts: only the visible user's request is valid. */
    fun acceptsStart(token: Long): Boolean = engine != null && pendingStart?.token == token

    fun serviceStarted(value: ScanForegroundService) {
        cancelEngineShutdown()
        service = value
        paused = false
        message = "背景輪掃已啟動。"
        val request = pendingStart
        pendingStart = null
        if (request != null) {
            request.timeout?.let(handler::removeCallbacks)
            request.result.success(state())
        }
        emit("started")
    }

    fun servicePaused(value: ScanForegroundService, isPaused: Boolean) {
        if (service !== value) return
        paused = isPaused
        message = if (isPaused) "背景輪掃已暫停，進度保留。" else "背景輪掃已繼續。"
        emit(if (isPaused) "paused" else "resumed")
    }

    fun serviceStopped(value: ScanForegroundService, reason: String) {
        if (service !== value) return
        service = null
        paused = false
        message = when (reason) {
            "system_timeout" -> "Android 已結束本次背景執行時段；請開啟 App 後重啟。"
            "service_destroyed" -> "Android 已停止背景輪掃，進度將於下次開啟時續掃。"
            else -> "背景輪掃已停止，進度保留。"
        }
        emit(reason)
        // Give the existing Dart controller a bounded chance to cancel/save an
        // in-flight page before its last engine owner goes away.
        scheduleEngineShutdown()
    }

    fun failStart(code: String, details: String) {
        val request = pendingStart
        pendingStart = null
        if (request != null) {
            request.timeout?.let(handler::removeCallbacks)
            request.result.error(code, details, null)
        }
        message = details
        emit(code)
        scheduleEngineShutdown()
    }

    private fun armStartTimeout(request: PendingStart, delayMs: Long, details: String) {
        request.timeout?.let(handler::removeCallbacks)
        val watchdog = Runnable {
            if (pendingStart?.token == request.token) failStart("START_TIMEOUT", details)
        }
        request.timeout = watchdog
        handler.postDelayed(watchdog, delayMs)
    }

    private fun cancelEngineShutdown() {
        engineShutdown?.let(handler::removeCallbacks)
        engineShutdown = null
    }

    private fun scheduleEngineShutdown() {
        cancelEngineShutdown()
        if (activity.get() != null || service != null || pendingStart != null) return
        val ownedEngine = engine ?: return
        val shutdown = Runnable {
            engineShutdown = null
            if (activity.get() == null && service == null && pendingStart == null && engine === ownedEngine) {
                channel?.setMethodCallHandler(null)
                channel = null
                if (FlutterEngineCache.getInstance().get(ENGINE_ID) === ownedEngine) {
                    FlutterEngineCache.getInstance().remove(ENGINE_ID)
                }
                engine = null
                ownedEngine.destroy()
            }
        }
        engineShutdown = shutdown
        handler.postDelayed(shutdown, ENGINE_SHUTDOWN_GRACE_MS)
    }
}
