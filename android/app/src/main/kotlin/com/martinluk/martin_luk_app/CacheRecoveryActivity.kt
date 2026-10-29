package com.martinluk.martin_luk_app

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

/**
 * The launcher and notification entrypoint. Flutter's SharedPreferences plugin
 * is not constructed until legacy cache recovery has completed successfully.
 */
class CacheRecoveryActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var progress: ProgressBar
    private lateinit var retry: Button
    private var opening = false
    private var resumed = false
    private var latestState: CacheRecoveryResult? = null
    private val recoveryObserver: (CacheRecoveryResult?) -> Unit = { state ->
        latestState = state
        render(state)
    }
    private val recovery: MartinLukApplication
        get() = application as MartinLukApplication

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val padding = (24 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(padding, padding, padding, padding)
            setBackgroundColor(Color.rgb(11, 21, 33))
        }
        root.addView(TextView(this).apply {
            text = "Martin Luk 動能觀察"
            textSize = 23f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
        })
        progress = ProgressBar(this)
        root.addView(progress)
        status = TextView(this).apply {
            textSize = 17f
            gravity = Gravity.CENTER
            setPadding(0, padding, 0, padding)
            setTextColor(Color.rgb(210, 226, 235))
        }
        root.addView(status)
        retry = Button(this).apply {
            text = "重試安全整理"
            visibility = View.GONE
            setOnClickListener {
                if (latestState?.ready == true) render(latestState)
                else recovery.retryCacheRecovery()
            }
        }
        root.addView(retry)
        setContentView(root)
        recovery.observeCacheRecovery(recoveryObserver)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        render(latestState)
    }

    override fun onPause() {
        resumed = false
        super.onPause()
    }

    override fun onDestroy() {
        recovery.removeCacheRecoveryObserver(recoveryObserver)
        super.onDestroy()
    }

    private fun render(state: CacheRecoveryResult?) {
        if (isFinishing || isDestroyed) return
        if (state?.ready == true) {
            // Finishing IO while the user pressed Home must not start an
            // Activity/Flutter engine in the background. Resume owns navigation.
            if (!resumed) {
                progress.visibility = View.GONE
                retry.visibility = View.GONE
                status.text = "行情快取已就緒，返回畫面後開啟 App。"
                return
            }
            if (opening) return
            opening = true
            // Preserve local-notification payloads/deep-link data. The target
            // is internal; external launchers cannot bypass this recovery gate.
            val target = Intent(this, FlutterHostActivity::class.java)
                .setAction(intent.action)
                .setData(intent.data)
                .putExtras(intent)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            try {
                startActivity(target)
                finish()
            } catch (error: Exception) {
                opening = false
                progress.visibility = View.GONE
                retry.visibility = View.VISIBLE
                retry.text = "重新開啟 App"
                status.text = "行情快取已整理完成；目前無法開啟主畫面，請重試。"
                Log.w("QuoteCacheRecovery", "openNotCompleted type=${error.javaClass.simpleName}")
            }
            return
        }
        progress.visibility = if (state == null) View.VISIBLE else View.GONE
        retry.visibility = if (state == null) View.GONE else View.VISIBLE
        status.text = state?.message ?: "正在整理舊行情快取…\n持股、帳戶設定與掃描進度會保留。\n資料較多時請稍候，無需清除 App 資料。"
    }
}
