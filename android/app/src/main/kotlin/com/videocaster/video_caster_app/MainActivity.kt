package com.videocaster.video_caster_app

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.videocaster/multicast"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    try {
                        if (multicastLock == null) {
                            val wifi = applicationContext
                                .getSystemService(Context.WIFI_SERVICE) as WifiManager
                            multicastLock = wifi.createMulticastLock("VideoCasterSSDPLock")
                            multicastLock!!.setReferenceCounted(true)
                        }
                        if (multicastLock?.isHeld == false) {
                            multicastLock!!.acquire()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("MULTICAST", e.message, null)
                    }
                }
                "release" -> {
                    try {
                        if (multicastLock?.isHeld == true) {
                            multicastLock!!.release()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("MULTICAST", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        if (multicastLock?.isHeld == true) {
            multicastLock?.release()
        }
        super.onDestroy()
    }
}
