package com.videocaster.video_caster_app

import android.net.Uri
import androidx.fragment.app.FragmentActivity
import androidx.mediarouter.app.MediaRouteChooserDialogFragment
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.MediaTrack
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

object CastBridge : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private const val METHOD_CHANNEL = "com.videocaster/cast_native"
    private const val EVENT_CHANNEL = "com.videocaster/cast_events"

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var hostActivity: FragmentActivity? = null
    private var remoteMediaClient: RemoteMediaClient? = null
    private var remoteCallback: RemoteMediaClient.Callback? = null
    private var castContext: CastContext? = null

    private val sessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarted(session: CastSession, sessionId: String) = bindSession(session)
        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) = bindSession(session)
        override fun onSessionEnded(session: CastSession, error: Int) = clearSession("ended", error)
        override fun onSessionResumeFailed(session: CastSession, error: Int) = clearSession("resume_failed", error)
        override fun onSessionStartFailed(session: CastSession, error: Int) = clearSession("start_failed", error)
        override fun onSessionStarting(session: CastSession) = emitState("starting")
        override fun onSessionEnding(session: CastSession) = emitState("ending")
        override fun onSessionResuming(session: CastSession, sessionId: String) = emitState("resuming")
        override fun onSessionSuspended(session: CastSession, reason: Int) = emit(mapOf("type" to "session_suspended", "reason" to reason))
    }

    fun attach(activity: FragmentActivity, messenger: BinaryMessenger) {
        hostActivity = activity
        if (methodChannel == null) {
            methodChannel = MethodChannel(messenger, METHOD_CHANNEL).also {
                it.setMethodCallHandler(this)
            }
        }
        if (eventChannel == null) {
            eventChannel = EventChannel(messenger, EVENT_CHANNEL).also {
                it.setStreamHandler(this)
            }
        }
    }

    fun detach(activity: FragmentActivity) {
        if (hostActivity === activity) {
            unregisterSessionListener()
            remoteMediaClient?.unregisterCallback(remoteCallback)
            remoteCallback = null
            remoteMediaClient = null
            hostActivity = null
        }
    }

    fun onHostResumed(activity: FragmentActivity) {
        hostActivity = activity
        val context = CastContext.getSharedInstance(activity)
        if (castContext !== context) {
            unregisterSessionListener()
            castContext = context
            context.sessionManager.addSessionManagerListener(sessionListener, CastSession::class.java)
        }
        context.sessionManager.currentCastSession?.let(::bindSession)
        emitSnapshot()
    }

    fun onHostPaused(activity: FragmentActivity) {
        if (hostActivity === activity) {
            emitSnapshot()
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "loadMedia" -> {
                    loadMedia(call)
                    result.success(true)
                }
                "play" -> {
                    currentClient()?.play()
                    result.success(true)
                }
                "pause" -> {
                    currentClient()?.pause()
                    result.success(true)
                }
                "togglePlayback" -> {
                    val client = currentClient()
                    val paused = client?.mediaStatus?.playerState == MediaStatus.PLAYER_STATE_PAUSED
                    if (paused) client.play() else client?.pause()
                    result.success(true)
                }
                "seekTo" -> {
                    val positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L
                    currentClient()?.seek(positionMs)
                    result.success(true)
                }
                "setVolume" -> {
                    val level = call.argument<Number>("level")?.toDouble() ?: 0.5
                    currentSession()?.setVolume(level.coerceIn(0.0, 1.0))
                    emitSnapshot()
                    result.success(true)
                }
                "getVolume" -> {
                    result.success(currentSession()?.volume)
                }
                "stop" -> {
                    currentClient()?.stop()
                    result.success(true)
                }
                "showCastDialog" -> {
                    showCastDialog()
                    result.success(true)
                }
                "getState" -> result.success(snapshot())
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.error("CAST", t.message, null)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        emitSnapshot()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun loadMedia(call: MethodCall) {
        val url = call.argument<String>("url") ?: error("url is required")
        val title = call.argument<String>("title") ?: "Video"
        val subtitle = call.argument<String>("subtitle")
        val subtitleLanguage = call.argument<String>("subtitleLanguage") ?: "en"
        val subtitleLabel = call.argument<String>("subtitleLabel") ?: "Subtitles"
        val contentType = call.argument<String>("contentType") ?: "video/mp4"
        val durationMs = call.argument<Number>("durationMs")?.toLong()
        val imageUrl = call.argument<String>("imageUrl")
        val subtitleUrl = call.argument<String>("subtitleUrl")

        val metadata = MediaMetadata(MediaMetadata.MEDIA_TYPE_MOVIE).apply {
            putString(MediaMetadata.KEY_TITLE, title)
            if (!subtitle.isNullOrBlank()) {
                putString(MediaMetadata.KEY_SUBTITLE, subtitle)
            }
            if (!imageUrl.isNullOrBlank()) {
                addImage(com.google.android.gms.common.images.WebImage(Uri.parse(imageUrl)))
            }
        }

        val infoBuilder = MediaInfo.Builder(url)
            .setContentType(contentType)
            .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
            .setMetadata(metadata)

        if (durationMs != null && durationMs > 0) {
            infoBuilder.setStreamDuration(durationMs)
        }

        if (!subtitleUrl.isNullOrBlank()) {
            val track = MediaTrack.Builder(1L, MediaTrack.TYPE_TEXT)
                .setName(subtitleLabel)
                .setSubtype(MediaTrack.SUBTYPE_SUBTITLES)
                .setContentId(subtitleUrl)
                .setContentType("text/vtt")
                .setLanguage(subtitleLanguage)
                .build()
            infoBuilder.setMediaTracks(listOf(track))
        }

        val request = MediaLoadRequestData.Builder()
            .setMediaInfo(infoBuilder.build())
            .setAutoplay(true)
            .apply {
                if (!subtitleUrl.isNullOrBlank()) {
                    setActiveTrackIds(longArrayOf(1L))
                }
            }
            .build()

        currentClient()?.load(request)
    }

    private fun bindSession(session: CastSession) {
        val client = session.remoteMediaClient
        if (client === remoteMediaClient) {
            emitSnapshot()
            return
        }
        remoteMediaClient?.unregisterCallback(remoteCallback)
        remoteMediaClient = client
        remoteCallback = object : RemoteMediaClient.Callback() {
            override fun onStatusUpdated() = emitSnapshot()
            override fun onMetadataUpdated() = emitSnapshot()
            override fun onQueueStatusUpdated() = emitSnapshot()
            override fun onPreloadStatusUpdated() = emitSnapshot()
            override fun onAdBreakStatusUpdated() = emitSnapshot()
            override fun onSendingRemoteMediaRequest() = emitState("requesting")
        }
        client?.registerCallback(remoteCallback)
        emit(mapOf(
            "type" to "session_connected",
            "deviceName" to session.castDevice?.friendlyName,
        ))
        emitSnapshot()
    }

    private fun clearSession(reason: String, error: Int) {
        remoteMediaClient?.unregisterCallback(remoteCallback)
        remoteCallback = null
        remoteMediaClient = null
        emit(mapOf("type" to "session_cleared", "reason" to reason, "error" to error))
        emitSnapshot()
    }

    private fun currentClient(): RemoteMediaClient? = castContext?.sessionManager?.currentCastSession?.remoteMediaClient
    private fun currentSession(): CastSession? = castContext?.sessionManager?.currentCastSession

    private fun showCastDialog() {
        val activity = hostActivity ?: return
        val context = CastContext.getSharedInstance(activity)
        val selector = context.mergedSelector
        val fragmentManager = activity.supportFragmentManager
        val existing = fragmentManager.findFragmentByTag("cast_route_chooser")
        if (existing != null) return
        val fragment = MediaRouteChooserDialogFragment().apply {
            routeSelector = selector
        }
        fragment.show(fragmentManager, "cast_route_chooser")
    }

    private fun emitSnapshot() {
        emit(snapshot())
    }

    private fun snapshot(): Map<String, Any?> {
        val session = castContext?.sessionManager?.currentCastSession
        val client = session?.remoteMediaClient
        val status = client?.mediaStatus
        val metadata = status?.mediaInfo?.metadata
        return mapOf(
            "type" to "state",
            "connected" to (session != null),
            "deviceName" to session?.castDevice?.friendlyName,
            "playerState" to playerStateName(status?.playerState),
            "idleReason" to idleReasonName(status?.idleReason),
            "positionMs" to client?.approximateStreamPosition,
            "durationMs" to status?.mediaInfo?.streamDuration,
            "volume" to session?.volume,
            "title" to metadata?.getString(MediaMetadata.KEY_TITLE),
            "subtitle" to metadata?.getString(MediaMetadata.KEY_SUBTITLE),
            "isPlayingAd" to status?.isPlayingAd,
            "isLive" to (status?.mediaInfo?.streamType == MediaInfo.STREAM_TYPE_LIVE),
            "supportedMediaCommands" to status?.supportedMediaCommands,
        )
    }

    private fun emitState(state: String) {
        emit(mapOf("type" to "state_hint", "state" to state))
    }

    private fun emit(payload: Map<String, Any?>) {
        eventSink?.success(payload)
    }

    private fun unregisterSessionListener() {
        val context = castContext ?: return
        context.sessionManager.removeSessionManagerListener(sessionListener, CastSession::class.java)
        castContext = null
    }

    private fun playerStateName(value: Int?): String? = when (value) {
        MediaStatus.PLAYER_STATE_IDLE -> "idle"
        MediaStatus.PLAYER_STATE_PLAYING -> "playing"
        MediaStatus.PLAYER_STATE_PAUSED -> "paused"
        MediaStatus.PLAYER_STATE_BUFFERING -> "buffering"
        MediaStatus.PLAYER_STATE_LOADING -> "loading"
        else -> null
    }

    private fun idleReasonName(value: Int?): String? = when (value) {
        MediaStatus.IDLE_REASON_NONE -> "none"
        MediaStatus.IDLE_REASON_CANCELLED -> "cancelled"
        MediaStatus.IDLE_REASON_ERROR -> "error"
        MediaStatus.IDLE_REASON_FINISHED -> "finished"
        MediaStatus.IDLE_REASON_INTERRUPTED -> "interrupted"
        else -> null
    }
}