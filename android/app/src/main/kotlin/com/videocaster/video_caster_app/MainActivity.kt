package com.videocaster.video_caster_app

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var shareEventSink: EventChannel.EventSink? = null
    private var initialShareUrl: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        CastBridge.attach(this, flutterEngine.dartExecutor.binaryMessenger)

        // ── Multicast lock channel ───────────────────────────────────────
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

        // ── Cast foreground service channel ─────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.videocaster/foreground"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val title = call.argument<String>("title") ?: "Casting video"
                    CastForegroundService.start(this, title)
                    result.success(true)
                }
                "stop" -> {
                    CastForegroundService.stop(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ── Share intent channel ─────────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.videocaster/share"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialSharedUrl" -> {
                    result.success(initialShareUrl)
                    initialShareUrl = null
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.videocaster/share_stream"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                shareEventSink = events
            }
            override fun onCancel(arguments: Any?) {
                shareEventSink = null
            }
        })

        // Handle initial intent
        handleShareIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        CastBridge.onHostResumed(this)
    }

    override fun onPause() {
        CastBridge.onHostPaused(this)
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
    }

    private fun handleShareIntent(intent: Intent) {
        val url = when (intent.action) {
            Intent.ACTION_SEND -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                extractUrl(text)
            }
            Intent.ACTION_VIEW -> intent.dataString
            else -> null
        }
        if (url != null) {
            if (shareEventSink != null) {
                shareEventSink?.success(url)
            } else {
                initialShareUrl = url
            }
        }
    }

    private fun extractUrl(text: String?): String? {
        if (text == null) return null
        val regex = Regex("https?://\\S+")
        return regex.find(text)?.value ?: if (text.startsWith("http")) text else null
    }

    override fun onDestroy() {
        CastBridge.detach(this)
        if (multicastLock?.isHeld == true) {
            multicastLock?.release()
        }
        super.onDestroy()
    }
}
