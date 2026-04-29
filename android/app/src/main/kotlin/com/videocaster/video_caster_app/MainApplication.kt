package com.videocaster.video_caster_app

import android.app.Application
import android.util.Log
import com.google.android.gms.cast.framework.CastContext

class MainApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        initCastSdk()
    }

    private fun initCastSdk() {
        try {
            CastContext.getSharedInstance(this)
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to initialize CastContext", t)
        }
    }

    companion object {
        private const val TAG = "MainApplication"
    }
}
