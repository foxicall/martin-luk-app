package com.martinluk.martin_luk_app

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.Executors

/** A native-only startup gate keeps large legacy preferences off the UI thread. */
class MartinLukApplication : Application() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { task ->
        Thread(task, "legacy-quote-cache-recovery").apply { isDaemon = true }
    }
    private val observers = linkedSetOf<(CacheRecoveryResult?) -> Unit>()
    private var inFlight = false
    private var result: CacheRecoveryResult? = null

    override fun onCreate() {
        super.onCreate()
        retryCacheRecovery()
    }

    internal fun observeCacheRecovery(observer: (CacheRecoveryResult?) -> Unit) {
        observers.add(observer)
        observer(result)
    }

    internal fun removeCacheRecoveryObserver(observer: (CacheRecoveryResult?) -> Unit) {
        observers.remove(observer)
    }

    /** Main-thread callers share one job, including across Activity recreation. */
    internal fun retryCacheRecovery() {
        if (inFlight || result?.ready == true) return
        inFlight = true
        result = null
        publish()
        io.execute {
            val finished = try {
                LegacyQuoteCacheRecovery.recover(this)
            } catch (error: Exception) {
                Log.w("QuoteCacheRecovery", "workerNotCompleted type=${error.javaClass.simpleName}")
                CacheRecoveryResult(false, "行情快取整理未完成，原有資料已保留。請稍後重試。")
            }
            mainHandler.post {
                inFlight = false
                result = finished
                publish()
            }
        }
    }

    private fun publish() {
        for (observer in observers.toList()) observer(result)
    }
}
