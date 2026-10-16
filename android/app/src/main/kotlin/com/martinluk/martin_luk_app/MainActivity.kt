package com.martinluk.martin_luk_app

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The UI and the opt-in foreground scan use one engine and one Dart controller.
 * No background isolate is started, so a resumed screen cannot race a second
 * scanner for the same persisted cursor.
 */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        ScanServiceBridge.cachedEngine()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ScanServiceBridge.attachEngine(flutterEngine, this)
    }

    // The bridge explicitly destroys the engine after its last Activity AND
    // service owner disappear. Letting the Activity delegate destroy it here
    // would also kill an in-flight background page during Activity recreation.
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onResume() {
        super.onResume()
        ScanServiceBridge.setActivityVisible(this, true)
    }

    override fun onPause() {
        ScanServiceBridge.setActivityVisible(this, false)
        super.onPause()
    }

    override fun onDestroy() {
        super.onDestroy()
        ScanServiceBridge.detachActivity(this)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        ScanServiceBridge.onPermissionResult(this, requestCode, grantResults)
    }
}
