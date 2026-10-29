package tv.velvet.ui.sports

import android.content.Context
import android.os.Handler
import android.os.SystemClock
import android.os.Looper
import org.mozilla.geckoview.AllowOrDeny
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoRuntimeSettings
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoSessionSettings
import org.mozilla.geckoview.GeckoView
import org.mozilla.geckoview.WebRequestError
import org.mozilla.geckoview.WebResponse
import org.mozilla.geckoview.WebExtension
import org.json.JSONObject
import tv.velvet.data.sports.isSportsStartupFrameAllowed
import tv.velvet.data.sports.isEmbedNavigationAllowed
import tv.velvet.data.sports.isSafeEmbed

/** A maintained browser engine, isolated from Velvet's accounts, history and native players. */
internal class SportsBrowserView(
    context: Context,
    private val embed: String,
    private val onLoading: (Boolean) -> Unit,
    private val onError: (String, Boolean) -> Unit,
    private val onFullscreen: (Boolean) -> Unit,
    private val onStarted: () -> Unit,
    private val onPlaybackObservation: (String) -> Unit = {},
) : GeckoView(context) {
    private val browserSession = GeckoSession(GeckoSessionSettings.Builder().usePrivateMode(true).build())
    private val children = mutableSetOf<GeckoSession>()
    private val handler = Handler(Looper.getMainLooper())
    private var closed = false
    private var started = false
    private var loadStartedAt = 0L
    private var playingPort: WebExtension.Port? = null
    private var failed = false
    private var startupExtension: WebExtension? = null
    private val startupPorts = mutableSetOf<WebExtension.Port>()

    private fun stopStartup() {
        startupPorts.forEach { runCatching { it.postMessage(JSONObject().put("type", "stop")) } }
    }
    private fun startPort(port: WebExtension.Port) {
        startupPorts += port
        // Share the same overall deadline with JS, leaving a one-second delivery
        // margin before native timeout. Page-load time never extends this budget.
        val observeMs = (44_000L - (SystemClock.elapsedRealtime() - loadStartedAt)).coerceIn(0L, 44_000L)
        port.postMessage(JSONObject().put("type", if (started || failed) "stop" else "start").put("observeMs", observeMs))
    }
    private val startupMessages = object : WebExtension.MessageDelegate {
        override fun onConnect(port: WebExtension.Port) {
            val sender = port.sender
            val accepted = isSportsStartupFrameAllowed(embed, sender.url, sender.isTopLevel)
            android.util.Log.d("VelvetSports", "Startup frame: top=${sender.isTopLevel}, approved=$accepted")
            if (closed || failed || sender.session !== browserSession || startupPorts.size >= 4 || !accepted) {
                port.disconnect(); return
            }
            startupPorts += port
            port.setDelegate(object : WebExtension.PortDelegate {
                override fun onPortMessage(message: Any, source: WebExtension.Port) {
                    val value = message as? JSONObject ?: return
                    if (closed || failed || source !in startupPorts) return
                    if (value.optString("state") == "observation" && source === playingPort) {
                        val state = value.optString("playbackState")
                        if (state in setOf("playing", "paused", "buffering", "ended")) onPlaybackObservation(state)
                        return
                    }
                    if (started) return
                    if (value.optString("state") == "startup") {
                        android.util.Log.d("VelvetSports", "Startup status: attempts=${value.optInt("attempts").coerceIn(0, 8)}, video=${value.optBoolean("video")}, visible=${value.optBoolean("visibleVideo")}, source=${value.optBoolean("source")}, idleControl=${value.optBoolean("idleControl")}, player=${value.optBoolean("player")}, ready=${value.optInt("readyState").coerceIn(0, 4)}, paused=${value.optBoolean("paused")}, network=${value.optInt("networkState").coerceIn(0, 3)}, error=${value.optInt("errorCode").coerceIn(0, 4)}")
                        return
                    }
                    if (value.optString("state") != "playing" || !value.optBoolean("advanced") || value.optInt("readyState") !in 2..4 ||
                        value.optInt("width") !in 1..16384 || value.optInt("height") !in 1..16384 ||
                        value.optInt("viewportWidth") !in 320..16384 || value.optInt("viewportHeight") !in 180..16384) return
                    started = true
                    playingPort = source
                    android.util.Log.d("VelvetSports", "Playback advanced: ${value.optInt("width")}x${value.optInt("height")}, ready=${value.optInt("readyState")}")
                    stopStartup()
                    onLoading(false); onStarted()
                }
                override fun onDisconnect(port: WebExtension.Port) { startupPorts -= port }
            })
            if (accepted) startPort(port)
        }
    }

    init {
        require(isSafeEmbed(embed))
        isFocusable = false
        isFocusableInTouchMode = false
        keepScreenOn = true
        browserSession.navigationDelegate = object : GeckoSession.NavigationDelegate {
            override fun onLoadRequest(session: GeckoSession, request: GeckoSession.NavigationDelegate.LoadRequest): GeckoResult<AllowOrDeny> {
                // New windows get a real, transient blank browsing context. Its delegate denies
                // all outbound loads, so a page cannot launch an ad, another app, or a download.
                val allowed = !closed && (request.target == GeckoSession.NavigationDelegate.TARGET_WINDOW_NEW ||
                    isEmbedNavigationAllowed(embed, request.uri))
                return decision(allowed)
            }
            override fun onSubframeLoadRequest(session: GeckoSession, request: GeckoSession.NavigationDelegate.LoadRequest) =
                decision(false) // StreamFree plays in this document; its iframe is an advertisement.
            override fun onNewSession(session: GeckoSession, uri: String): GeckoResult<GeckoSession>? = blankChild()
            override fun onLoadError(session: GeckoSession, uri: String?, error: WebRequestError): GeckoResult<String>? {
                fail("This stream couldn't load. Try another stream or Reload.")
                return null // Never bypass a certificate or browser security error.
            }
        }
        browserSession.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onPageStart(session: GeckoSession, url: String) { if (!closed) onLoading(true) }
            override fun onPageStop(session: GeckoSession, success: Boolean) {
                if (!closed) {
                    onLoading(false)
                    if (!success && !started) fail("This stream couldn't load. Try another stream or Reload.")
                }
            }
        }
        browserSession.contentDelegate = object : GeckoSession.ContentDelegate {
            override fun onFirstContentfulPaint(session: GeckoSession) { if (!closed) onLoading(false) }
            override fun onFullScreen(session: GeckoSession, fullScreen: Boolean) { if (!closed) onFullscreen(fullScreen) }
            override fun onCrash(session: GeckoSession) = fail("The embedded player stopped. Choose Reload or another stream.")
            override fun onKill(session: GeckoSession) = fail("The embedded player stopped. Choose Reload or another stream.")
            override fun onExternalResponse(session: GeckoSession, response: WebResponse) { runCatching { response.body?.close() }; Unit }
        }
        browserSession.permissionDelegate = mediaPermissions
        // An empty prompt delegate rejects prompts by default: no authentication, file picker,
        // credential autofill, external-app launch or native JavaScript bridge is supplied.
        browserSession.promptDelegate = object : GeckoSession.PromptDelegate {}
        val runtime = SportsBrowserRuntime.get(context)
        browserSession.open(runtime)
        setSession(browserSession)
        browserSession.setFocused(true)
        runtime.webExtensionController.ensureBuiltIn("resource://android/assets/sports-startup/", "sports-startup@velvet.local").accept({ extension ->
            if (!closed && extension != null) {
                runtime.webExtensionController.setAllowedInPrivateBrowsing(extension, true).accept({ allowed ->
                    if (!closed && allowed != null) {
                        startupExtension = allowed
                        browserSession.webExtensionController.setMessageDelegate(allowed, startupMessages, "velvetSportsStartup")
                        loadStartedAt = SystemClock.elapsedRealtime()
                        browserSession.loadUri(embed)
                        handler.postDelayed({ if (!closed && !started) fail("Automatic startup timed out. Try Player controls, another stream or Reload.", manual = true) }, 45_000)
                    }
                }, { if (!closed) fail("The player couldn't start. Choose Reload and try again.") })
            }
        }, { if (!closed) fail("The player couldn't start. Choose Reload and try again.") })
    }

    private fun blankChild(): GeckoResult<GeckoSession>? {
        if (closed || children.size >= 4) return null
        val child = GeckoSession(GeckoSessionSettings.Builder().usePrivateMode(true).build())
        children += child
        child.navigationDelegate = object : GeckoSession.NavigationDelegate {
            override fun onLoadRequest(session: GeckoSession, request: GeckoSession.NavigationDelegate.LoadRequest) =
                decision(!closed && request.uri == "about:blank")
            override fun onSubframeLoadRequest(session: GeckoSession, request: GeckoSession.NavigationDelegate.LoadRequest) = decision(false)
        }
        child.contentDelegate = object : GeckoSession.ContentDelegate {
            override fun onCloseRequest(session: GeckoSession) = closeChild(child)
            override fun onExternalResponse(session: GeckoSession, response: WebResponse) { runCatching { response.body?.close() }; Unit }
        }
        child.promptDelegate = object : GeckoSession.PromptDelegate {}
        child.permissionDelegate = object : GeckoSession.PermissionDelegate {}
        handler.postDelayed({ closeChild(child) }, 5_000)
        return GeckoResult.fromValue(child)
    }

    private fun closeChild(child: GeckoSession) {
        if (children.remove(child)) child.close()
    }
    private fun fail(message: String, manual: Boolean = false) {
        if (!closed && !failed) {
            failed = true
            stopStartup()
            onLoading(false); onError(message, manual)
        }
    }
    fun exitPlayerFullscreen() { if (!closed) browserSession.exitFullScreen() }
    fun close() {
        if (closed) return
        closed = true
        keepScreenOn = false
        handler.removeCallbacksAndMessages(null)
        children.toList().forEach(::closeChild)
        startupPorts.forEach { it.disconnect() }
        startupPorts.clear()
        startupExtension?.let { browserSession.webExtensionController.setMessageDelegate(it, null, "velvetSportsStartup") }
        browserSession.setActive(false)
        browserSession.setFocused(false)
        releaseSession()
        browserSession.close()
    }

    companion object {
        private fun decision(allow: Boolean) = GeckoResult.fromValue(if (allow) AllowOrDeny.ALLOW else AllowOrDeny.DENY)
        private val mediaPermissions = object : GeckoSession.PermissionDelegate {
            override fun onContentPermissionRequest(session: GeckoSession, permission: GeckoSession.PermissionDelegate.ContentPermission): GeckoResult<Int> {
                val playback = permission.permission == GeckoSession.PermissionDelegate.PERMISSION_AUTOPLAY_AUDIBLE ||
                    permission.permission == GeckoSession.PermissionDelegate.PERMISSION_AUTOPLAY_INAUDIBLE
                return GeckoResult.fromValue(if (playback) GeckoSession.PermissionDelegate.ContentPermission.VALUE_ALLOW else GeckoSession.PermissionDelegate.ContentPermission.VALUE_DENY)
            }
        }
    }
}

/** Gecko permits one runtime per process. Private sessions are closed on every source change/exit. */
private object SportsBrowserRuntime {
    private var runtime: GeckoRuntime? = null
    fun get(context: Context): GeckoRuntime = runtime ?: GeckoRuntime.create(
        context.applicationContext, GeckoRuntimeSettings.Builder().build(),
    ).also { runtime = it }
}
