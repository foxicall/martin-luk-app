package com.martinluk.martin_luk_app

/**
 * Internal Flutter host. The historical exported .MainActivity component is an
 * activity-alias for CacheRecoveryActivity, so existing launcher shortcuts
 * safely enter recovery instead of bypassing it or becoming invalid on upgrade.
 * All engine ownership/lifecycle behavior remains in MainActivity unchanged.
 */
class FlutterHostActivity : MainActivity()
