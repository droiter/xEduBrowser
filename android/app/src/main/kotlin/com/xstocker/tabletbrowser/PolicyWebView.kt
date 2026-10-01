package com.xstocker.tabletbrowser

import android.annotation.SuppressLint
import android.app.DownloadManager
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.DownloadListener
import android.webkit.GeolocationPermissions
import android.webkit.JsResult
import android.webkit.PermissionRequest
import android.webkit.URLUtil
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.ScriptHandler
import com.xstocker.tabletbrowser.policy.PolicyConfig
import com.xstocker.tabletbrowser.policy.PolicyDecision
import com.xstocker.tabletbrowser.policy.PolicyEngine
import com.xstocker.tabletbrowser.policy.parseUrl
import io.flutter.plugin.platform.PlatformView
import java.io.ByteArrayInputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Immutable snapshot of the per-view WebView settings, decoded from the
 * PlatformView creation params and from the `updateSettings` command.
 */
data class WebViewSettings(
    val javaScript: Boolean = true,
    val domStorage: Boolean = true,
    val fileAccess: Boolean = true,
    val allowFileUrlCrossAccess: Boolean = true,
    val mediaAutoplay: Boolean = false,
    val userAgent: String? = null,
    val textZoom: Int = 100,
    val blockPageHtml: String? = null,
    /**
     * Serve `fetch()` on `file:` pages over XHR (see [LocalFetchShim]).
     *
     * **Off by default**: the patch runs inside every local page, so it is
     * something the operator opts into per device rather than a silent change
     * to how pages behave.
     */
    val localFetchShim: Boolean = false,
    /**
     * 防翻页 — block input for a moment after the page turns (see [FlipGuard]).
     *
     * **Off by default on this side**: Dart owns the real default (on) and always
     * sends both keys, so a map that omits them means "old caller" and must not
     * silently start patching pages.
     */
    val flipGuardEnabled: Boolean = false,
    /** How long a detected turn blocks input, in seconds (1–600). */
    val flipGuardSeconds: Int = 10,
) {
    companion object {
        @JvmStatic
        fun fromMap(map: Map<*, *>?): WebViewSettings {
            if (map == null) return WebViewSettings()
            val base = WebViewSettings()
            return WebViewSettings(
                javaScript = map["javaScript"] as? Boolean ?: base.javaScript,
                domStorage = map["domStorage"] as? Boolean ?: base.domStorage,
                fileAccess = map["fileAccess"] as? Boolean ?: base.fileAccess,
                allowFileUrlCrossAccess = map["allowFileUrlCrossAccess"] as? Boolean
                    ?: base.allowFileUrlCrossAccess,
                mediaAutoplay = map["mediaAutoplay"] as? Boolean ?: base.mediaAutoplay,
                userAgent = map["userAgent"] as? String,
                textZoom = (map["textZoom"] as? Number)?.toInt() ?: base.textZoom,
                blockPageHtml = map["blockPageHtml"] as? String,
                localFetchShim = map["localFetchShim"] as? Boolean ?: base.localFetchShim,
                flipGuardEnabled = map["flipGuardEnabled"] as? Boolean ?: base.flipGuardEnabled,
                flipGuardSeconds = (map["flipGuardSeconds"] as? Number)?.toInt()
                    ?: base.flipGuardSeconds,
            )
        }

        /** Applies a partial settings map on top of [base]. */
        @JvmStatic
        fun merge(base: WebViewSettings, patch: Map<*, *>?): WebViewSettings {
            if (patch == null) return base
            return WebViewSettings(
                javaScript = patch["javaScript"] as? Boolean ?: base.javaScript,
                domStorage = patch["domStorage"] as? Boolean ?: base.domStorage,
                fileAccess = patch["fileAccess"] as? Boolean ?: base.fileAccess,
                allowFileUrlCrossAccess = patch["allowFileUrlCrossAccess"] as? Boolean
                    ?: base.allowFileUrlCrossAccess,
                mediaAutoplay = patch["mediaAutoplay"] as? Boolean ?: base.mediaAutoplay,
                userAgent = if (patch.containsKey("userAgent")) patch["userAgent"] as? String
                else base.userAgent,
                textZoom = (patch["textZoom"] as? Number)?.toInt() ?: base.textZoom,
                blockPageHtml = if (patch.containsKey("blockPageHtml")) patch["blockPageHtml"] as? String
                else base.blockPageHtml,
                localFetchShim = patch["localFetchShim"] as? Boolean ?: base.localFetchShim,
                flipGuardEnabled = patch["flipGuardEnabled"] as? Boolean
                    ?: base.flipGuardEnabled,
                flipGuardSeconds = (patch["flipGuardSeconds"] as? Number)?.toInt()
                    ?: base.flipGuardSeconds,
            )
        }
    }
}

/** Applies one settings snapshot to a live [WebSettings]. UI thread only. */
@SuppressLint("SetJavaScriptEnabled")
@Suppress("DEPRECATION")
internal fun WebSettings.applyPolicySettings(snapshot: WebViewSettings, defaultUserAgent: String?) {
    javaScriptEnabled = snapshot.javaScript
    domStorageEnabled = snapshot.domStorage
    databaseEnabled = true
    allowFileAccess = snapshot.fileAccess
    // allowFileUrlCrossAccess: XHR/fetch from file:// pages.
    allowFileAccessFromFileURLs = snapshot.allowFileUrlCrossAccess
    allowUniversalAccessFromFileURLs = snapshot.allowFileUrlCrossAccess
    mediaPlaybackRequiresUserGesture = !snapshot.mediaAutoplay
    loadsImagesAutomatically = true
    setGeolocationEnabled(false)
    saveFormData = false
    // Popups must be announced so Flutter can open a tab of its own.
    setSupportMultipleWindows(true)
    javaScriptCanOpenWindowsAutomatically = true
    mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
    textZoom = snapshot.textZoom.coerceIn(1, 1000)
    userAgentString = snapshot.userAgent?.takeIf { it.isNotBlank() } ?: defaultUserAgent
}

/**
 * A WebView that lets a **mouse drag work like a finger drag on local pages**.
 *
 * Local ebooks are usually Flip PDF style flipbooks whose page-turn is bound to
 * `touchstart`/`touchmove` handlers that read `changedTouches[0]` — there is no
 * mouse branch for the drag (only the wheel has one), so dragging with a mouse
 * attached to the tablet turns no pages while a finger does.
 *
 * Rewriting the event as a touchscreen event with a finger tool type is the only
 * way to satisfy such a page without patching it: the source and tool type are
 * exactly what Chromium uses to decide whether a page receives touch or mouse
 * events. It is deliberately limited to local pages (`file://` and the built-in
 * loopback server), so ordinary web pages keep normal mouse behaviour such as
 * text selection.
 *
 * Replaying the gesture as touch means the **button half** of the same click has
 * to be dropped, or the page sees two clicks — see `onGenericMotionEvent`.
 */
private class TouchCompatWebView(context: Context) : WebView(context) {

    /** Set on ACTION_DOWN, so the whole gesture is judged by the page it began on. */
    private var convertGesture = false

    /**
     * Decides which half of a mouse click's **button** events to drop.
     *
     * Android reports one mouse click on two paths, and only one of them is
     * replayed as touch below.
     */
    private val primaryButton = PrimaryButtonFilter()

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!MouseDragBridge.isMouse(event)) {
            return super.onTouchEvent(event)
        }
        // 目前 Flutter 的 AndroidView 只把触摸与滚轮转发给平台视图，鼠标按键事件到不了这里
        // （见 README「已知限制」）。留一条只针对鼠标的日志：一旦哪天事件真的进来了，
        // 这条日志就是最直接的证据。
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            convertGesture = MouseDragBridge.isLocalPage(url)
            Log.i(TAG_TOUCH, "mouse DOWN local=$convertGesture url=$url")
        }
        val converted = if (convertGesture) MouseDragBridge.toTouch(event) else null
        return super.onTouchEvent(converted ?: event)
    }

    /**
     * Drops the **button half** of a primary-button click on local pages.
     *
     * One physical click reaches the WebView twice: as `ACTION_DOWN`/`ACTION_UP`
     * with `SOURCE_MOUSE` on [onTouchEvent] — replayed as a touch, so the page gets
     * its tap — **and** as `ACTION_BUTTON_PRESS`/`ACTION_BUTTON_RELEASE` here, which
     * Chromium turns into a mouse click of its own. Left alone, Chromium folds the
     * two halves into a single click; but the touch twin has already produced a
     * click, so every click becomes two and a page that turns one page per click
     * turns two. A finger sends no button events at all, which is why only a mouse
     * (or the keyboard cover's touchpad) shows it.
     *
     * Secondary buttons are left alone — nothing replays them as touch — and so are
     * pages whose input we do not touch at all.
     */
    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (MouseDragBridge.isMouse(event) &&
            MouseDragBridge.isLocalPage(url) &&
            primaryButton.shouldSwallow(event.actionMasked, event.buttonState)
        ) {
            return true
        }
        return super.onGenericMotionEvent(event)
    }

    private companion object {
        const val TAG_TOUCH = "TouchCompat"
    }
}

/** Translates mouse gestures into touch gestures for pages that only listen to touch. */
internal object MouseDragBridge {

    /** Pages a mouse should behave on like a finger: local files and the app's own server. */
    fun isLocalPage(url: String?): Boolean {
        if (url.isNullOrBlank()) return false
        return url.startsWith("file://") ||
            url.startsWith("http://127.0.0.1") ||
            url.startsWith("https://127.0.0.1")
    }

    fun isMouse(event: MotionEvent): Boolean =
        (event.source and InputDevice.SOURCE_MOUSE) == InputDevice.SOURCE_MOUSE ||
            event.getToolType(0) == MotionEvent.TOOL_TYPE_MOUSE

    /**
     * The touchscreen twin of a mouse press/drag/release, or null for an event
     * that is not part of a drag (hover, scroll, ...).
     *
     * Built with the six-argument `obtain`, which is the one overload that is
     * both public and unambiguous: it produces a single-pointer event whose tool
     * type is *not* `TOOL_TYPE_MOUSE`, and the source is then set explicitly. The
     * source and the tool type are the two signals Chromium uses to choose
     * between touch and mouse delivery, and after this both say "finger".
     * (The pointer-properties overloads would allow setting the tool type
     * outright, but they are exactly the ones Kotlin cannot resolve here.)
     */
    fun toTouch(event: MotionEvent): MotionEvent? {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE,
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> Unit
            else -> return null
        }
        val touch = MotionEvent.obtain(
            event.downTime,
            event.eventTime,
            event.action,
            event.x,
            event.y,
            event.metaState,
        )
        touch.setSource(InputDevice.SOURCE_TOUCHSCREEN)
        return touch
    }
}

/**
 * Which half of a mouse click's button events must not reach the WebView.
 *
 * Android reports one physical click twice: `ACTION_DOWN`/`ACTION_UP` with
 * `SOURCE_MOUSE` (replayed as touch by [TouchCompatWebView.onTouchEvent], so the
 * page gets its tap) **and** `ACTION_BUTTON_PRESS`/`ACTION_BUTTON_RELEASE`, which
 * Chromium turns into a mouse click of its own. Chromium folds the two halves
 * into a single click when both arrive as mouse events, but the touch twin has
 * already produced one — so without this the page sees **two** clicks and a page
 * that turns one page per click turns two. A finger sends no button events at
 * all, which is why only a mouse or a touchpad shows it.
 *
 * Kept as a plain object (no [MotionEvent]) so the state machine is unit
 * testable: the press is swallowed and remembered, and the release that pairs
 * with it is swallowed too. Anything else — secondary buttons, a release whose
 * press we did not see — is passed through untouched.
 */
internal class PrimaryButtonFilter {

    /** True while the press we swallowed is still waiting for its release. */
    private var pendingRelease = false

    /** Whether this button event has to be dropped instead of dispatched. */
    fun shouldSwallow(actionMasked: Int, buttonState: Int): Boolean {
        when (actionMasked) {
            MotionEvent.ACTION_BUTTON_PRESS -> {
                pendingRelease =
                    (buttonState and MotionEvent.BUTTON_PRIMARY) != 0
                return pendingRelease
            }
            MotionEvent.ACTION_BUTTON_RELEASE -> {
                if (!pendingRelease) return false
                pendingRelease = false
                return true
            }
        }
        return false
    }
}

/**
 * The Android WebView platform view (`tablet_browser/webview`) with every
 * enforcement point from CONTRACT.md section 2 wired in.
 *
 * Threading: everything here runs on the platform (UI) thread except
 * [WebViewClient.shouldInterceptRequest], which the WebView calls on a
 * background thread. That callback never touches the WebView and never blocks:
 * it reads the immutable engine snapshot held by [PolicyBridge], decides
 * synchronously and hands the resulting event to the bridge, which posts it to
 * the main thread.
 */
class PolicyWebView(
    private val context: Context,
    val viewId: Int,
    initialSettings: WebViewSettings,
    private val bridge: PolicyBridge,
    /**
     * A policy that applies to **this view only**, replacing the shared engine.
     *
     * Used by the bookmark preview: the parent confirms a page's content before
     * allowing it, so that one view runs with filtering switched off. Every
     * other view keeps using the shared engine.
     */
    previewPolicy: PolicyConfig? = null,
) : PlatformView {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val webView: WebView = TouchCompatWebView(context)

    /** Filtering for this view alone, when it was created with one. */
    private val ownEngine: PolicyEngine? = previewPolicy?.let { PolicyEngine(it) }

    /**
     * Decides [url] for this view: its own engine when it has one, the shared
     * snapshot otherwise. Never blocks, so it is safe on the WebView worker
     * thread too.
     */
    private fun decide(url: String): PolicyDecision = ownEngine?.decide(url) ?: bridge.decide(url)

    private var settings: WebViewSettings = initialSettings
    private val defaultUserAgent: String? = webView.settings.userAgentString

    @Volatile
    private var disposed = false

    private var lastTitle: String? = null

    /**
     * Set while the in-memory block page is displayed. `loadDataWithBaseURL`
     * reports a `data:` URL through the page callbacks; the operator should see
     * the URL that was actually blocked in the address bar, so the block page
     * reports this URL instead.
     */
    private var blockPageUrl: String? = null

    /**
     * Keeps the document-start fetch patch installed while the setting is on, so
     * switching it off removes the script again instead of leaving it behind for
     * the rest of the view's life.
     */
    private var fetchShimHandler: ScriptHandler? = null

    /**
     * The document-start handler registered for [FlipGuard], plus the cool-down it
     * was built with: the script inlines its cool-down, so a different value needs
     * a fresh handler.
     */
    private var flipGuardHandler: ScriptHandler? = null
    private var flipGuardSecondsInstalled: Int? = null

    /**
     * The cool-down the *loaded document* is running with, or null when the guard
     * is not live there. The script is injected before a document is parsed, so
     * without this a page that was already open when the operator flipped the
     * switch kept turning pages freely — the switch looked on and did nothing.
     */
    private var flipGuardLiveSeconds: Int? = null

    init {
        webView.settings.applyPolicySettings(settings, defaultUserAgent)
        applyFetchShim()
        applyFlipGuard()
        webView.webViewClient = PolicyClient()
        webView.webChromeClient = PolicyChromeClient()
        webView.setDownloadListener(DownloadListener { url, userAgent, contentDisposition, mimeType, contentLength ->
            onDownloadStart(url, userAgent, contentDisposition, mimeType, contentLength)
        })
    }

    override fun getView(): View = webView

    override fun dispose() {
        disposed = true
        // Stop being reachable by viewId: a command dispatched to a disposed
        // view is silently dropped (`loadUrl` returns early), which is how a
        // navigation used to vanish and leave the tab blank. Only this exact
        // instance is removed, so a newer view registered under the same tab id
        // is left alone.
        bridge.unregister(viewId, this)
        // The handler belongs to this WebView, but dropping it here keeps the
        // "installed or not" state honest for anything that outlives the view.
        fetchShimHandler?.remove()
        fetchShimHandler = null
        flipGuardHandler?.remove()
        flipGuardHandler = null
        flipGuardSecondsInstalled = null
        try {
            webView.stopLoading()
            webView.webChromeClient = null
            webView.webViewClient = WebViewClient()
            webView.setDownloadListener(null)
            webView.loadUrl("about:blank")
            webView.removeAllViews()
            webView.destroy()
        } catch (t: Throwable) {
            Log.w(TAG, "dispose failed for view $viewId", t)
        }
    }

    // ------------------------------------------------------------------
    // Commands from Flutter (all invoked on the platform thread)
    // ------------------------------------------------------------------

    /** Navigates, applying the policy gate to Flutter-initiated loads as well. */
    fun loadUrl(url: String) {
        if (disposed || url.isBlank()) return
        if (gateNavigation(url, isMainFrame = true)) return
        webView.loadUrl(url)
    }

    fun reload() {
        if (!disposed) webView.reload()
    }

    fun stopLoading() {
        if (!disposed) webView.stopLoading()
    }

    fun goBack(): Boolean {
        if (disposed || !webView.canGoBack()) return false
        webView.goBack()
        return true
    }

    fun goForward(): Boolean {
        if (disposed || !webView.canGoForward()) return false
        webView.goForward()
        return true
    }

    fun canGoBack(): Boolean = !disposed && webView.canGoBack()

    fun canGoForward(): Boolean = !disposed && webView.canGoForward()

    fun currentUrl(): String? = if (disposed) null else webView.url

    fun pageTitle(): String? = if (disposed) null else webView.title

    fun userAgent(): String? = if (disposed) null else webView.settings.userAgentString

    fun evaluateJavascript(script: String, onResult: (String?) -> Unit) {
        if (disposed) {
            onResult(null)
            return
        }
        try {
            webView.evaluateJavascript(script) { value -> onResult(value) }
        } catch (t: Throwable) {
            Log.w(TAG, "evaluateJavascript failed for view $viewId", t)
            onResult(null)
        }
    }

    fun updateSettings(patch: Map<*, *>?) {
        settings = WebViewSettings.merge(settings, patch)
        if (!disposed) webView.settings.applyPolicySettings(settings, defaultUserAgent)
        applyFetchShim()
        applyFlipGuard()
    }

    /**
     * Installs or removes [LocalFetchShim] to match the current settings.
     *
     * With JavaScript off the patch is pointless, so it is not installed at all.
     */
    private fun applyFetchShim() {
        val wanted = settings.localFetchShim && settings.javaScript && !disposed
        if (wanted) {
            if (fetchShimHandler == null) fetchShimHandler = LocalFetchShim.install(webView)
        } else {
            fetchShimHandler?.remove()
            fetchShimHandler = null
        }
    }

    /**
     * Installs, removes or re-tunes [FlipGuard] to match the current settings.
     *
     * The cool-down is baked into the script, so changing *only* the seconds
     * cannot just keep the handler: the already loaded document is told about the
     * new value through `setCooldown`, while the handler is swapped so the next
     * navigation starts with it.
     */
    private fun applyFlipGuard() {
        val wanted = settings.flipGuardEnabled && settings.javaScript && !disposed
        if (!wanted) {
            flipGuardHandler?.remove()
            flipGuardHandler = null
            flipGuardSecondsInstalled = null
            // Switching off has to reach the page that is already open too.
            if (flipGuardLiveSeconds != null) {
                evaluate(FlipGuard.enableSnippet(false), "flip guard could not be switched off")
                flipGuardLiveSeconds = null
            }
            return
        }
        val seconds = settings.flipGuardSeconds.coerceIn(1, 600)
        if (flipGuardLiveSeconds != seconds) {
            // The loaded document first (idempotent: the script re-runs as a
            // no-op that only retunes the cool-down), then the handler for
            // documents that have not been parsed yet.
            evaluate(FlipGuard.scriptFor(seconds), "flip guard could not be injected")
            flipGuardLiveSeconds = seconds
        }
        if (flipGuardHandler != null && flipGuardSecondsInstalled == seconds) return
        flipGuardHandler?.remove()
        flipGuardHandler = FlipGuard.install(webView, seconds)
        flipGuardSecondsInstalled = if (flipGuardHandler != null) seconds else null
    }

    /** `evaluateJavascript` with the error handling every caller here wants. */
    private fun evaluate(script: String, what: String) {
        try {
            webView.evaluateJavascript(script, null)
        } catch (t: Throwable) {
            Log.w(TAG, "$what (view $viewId)", t)
        }
    }

    fun clearCache() {
        if (!disposed) webView.clearCache(true)
    }

    fun clearHistory() {
        if (!disposed) webView.clearHistory()
    }

    /**
     * Captures the frame this view is currently showing as PNG bytes scaled to
     * [maxWidth] (CONTRACT.md section 4). UI thread only: `WebView.draw` is a
     * view operation.
     *
     * Never throws and never forces a re-layout — it draws the frame that is
     * already rendered. The block page is captured like any other document, and
     * a disposed or not-yet-laid-out view simply returns `null`.
     */
    fun captureThumbnail(maxWidth: Int): ByteArray? {
        if (disposed) return null
        return ThumbnailCapture.capture(webView, maxWidth)
    }

    // ------------------------------------------------------------------
    // Enforcement point 1: navigations (main frame and subframes)
    // ------------------------------------------------------------------

    /**
     * Decides a navigation. Returns true when the navigation was cancelled
     * (denied), in which case the caller must not load the URL.
     */
    private fun gateNavigation(url: String, isMainFrame: Boolean): Boolean {
        if (!isPolicyGatedScheme(url)) return false
        val decision = decide(url)
        if (decision.allowed) return false

        bridge.emit(
            mapOf(
                "type" to "navigationBlocked",
                "viewId" to viewId,
                "url" to url,
                "allowed" to false,
                "reason" to decision.reason.wire,
                "explanation" to decision.explanation,
                "matched" to matchedPatterns(decision),
            )
        )

        // A denied subframe navigation is simply cancelled; replacing the main
        // document with the block page would destroy the page around it.
        if (isMainFrame) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                mainHandler.post { showBlockPage(url, decision) }
            } else {
                showBlockPage(url, decision)
            }
        }
        return true
    }

    private fun showBlockPage(url: String, decision: PolicyDecision) {
        if (disposed) return
        try {
            webView.stopLoading()
            val html = BlockPageRenderer.render(settings.blockPageHtml, url, decision)
            blockPageUrl = url
            webView.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
        } catch (t: Throwable) {
            Log.w(TAG, "block page rendering failed for view $viewId", t)
        }
    }

    /**
     * Maps a URL coming out of the WebView to the URL reported to Flutter: a
     * block page keeps reporting the URL it replaced.
     */
    private fun reportedUrl(rawUrl: String?): String? {
        if (rawUrl == null) return null
        val blocked = blockPageUrl ?: return rawUrl
        if (rawUrl.startsWith("data:") || rawUrl.startsWith("about:")) return blocked
        blockPageUrl = null
        return rawUrl
    }

    private fun matchedPatterns(decision: PolicyDecision): List<String> {
        val decisive = decision.decisiveRules.map { it.rule.pattern }
        if (decisive.isNotEmpty()) return decisive
        val blacklist = decision.blacklistMatches.map { it.rule.pattern }
        if (blacklist.isNotEmpty()) return blacklist
        return decision.whitelistMatches.map { it.rule.pattern }
    }

    private inner class PolicyClient : WebViewClient() {

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val url = request.url?.toString() ?: return false
            // `loadDataWithBaseURL` does not come through here, but script-driven
            // about:/data: navigations do: they are never policy gated.
            return gateNavigation(url, request.isForMainFrame)
        }

        @Deprecated("Kept for API < 24 WebViews", ReplaceWith(""))
        override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean {
            return gateNavigation(url, isMainFrame = true)
        }

        /**
         * Enforcement point 2: every subresource. Runs on a WebView worker
         * thread, so it must decide synchronously (the engine snapshot is
         * immutable and `@Volatile`) and must never touch the WebView.
         */
        override fun shouldInterceptRequest(
            view: WebView,
            request: WebResourceRequest,
        ): WebResourceResponse? {
            val url = try {
                request.url?.toString()
            } catch (t: Throwable) {
                null
            } ?: return null
            if (!isPolicyGatedScheme(url)) return null

            val decision = decide(url)
            if (decision.allowed) return null

            val resourceType = if (request.isForMainFrame) "mainFrame" else "subresource"
            bridge.emit(
                mapOf(
                    "type" to "requestBlocked",
                    "viewId" to viewId,
                    "url" to url,
                    "resourceType" to resourceType,
                    "allowed" to false,
                    "reason" to decision.reason.wire,
                    "explanation" to decision.explanation,
                    "matched" to matchedPatterns(decision),
                )
            )
            return WebResourceResponse(
                "text/plain",
                "utf-8",
                403,
                "Blocked by policy",
                emptyMap<String, String>(),
                ByteArrayInputStream(ByteArray(0)),
            )
        }

        override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
            if (disposed) return
            val effectiveUrl = reportedUrl(url) ?: return
            lastTitle = null
            emitPage("pageStarted", effectiveUrl)
            emitUrlChanged(effectiveUrl)
            // Belt and braces for the fetch patch. The document-start injection
            // is what makes it land before the page's own scripts, but whether the
            // wildcard origin rule matches an opaque `file://` origin is up to the
            // WebView — and a WebView without the document-start feature has no
            // other route at all. So a `file://` navigation is patched here too;
            // the script ignores a second run, so the cost is one round trip.
            if (settings.localFetchShim && settings.javaScript &&
                url != null && url.startsWith("file:")
            ) {
                view.evaluateJavascript(LocalFetchShim.SCRIPT, null)
            }
            // Same belt and braces for 防翻页: every document gets the guard, not
            // just local ones, because a WebView without document-start injection
            // has no other route. The script no-ops when it is already installed.
            if (settings.flipGuardEnabled && settings.javaScript) {
                view.evaluateJavascript(
                    FlipGuard.scriptFor(settings.flipGuardSeconds),
                    null,
                )
            }
        }

        override fun onPageFinished(view: WebView, url: String?) {
            if (disposed) return
            val effectiveUrl = reportedUrl(url) ?: return
            val title = view.title ?: ""
            lastTitle = title
            bridge.emit(
                mapOf(
                    "type" to "pageFinished",
                    "viewId" to viewId,
                    "url" to effectiveUrl,
                    "title" to title,
                )
            )
            emitUrlChanged(effectiveUrl)
        }

        override fun doUpdateVisitedHistory(view: WebView, url: String?, isReload: Boolean) {
            if (disposed) return
            reportedUrl(url)?.let { emitUrlChanged(it) }
        }

        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError,
        ) {
            if (!request.isForMainFrame) return
            emitPageError(
                code = error.errorCode,
                description = error.description?.toString() ?: "",
                url = request.url?.toString() ?: view.url.orEmpty(),
            )
        }

        @Deprecated("Kept for API < 23 WebViews", ReplaceWith(""))
        override fun onReceivedError(
            view: WebView,
            errorCode: Int,
            description: String?,
            failingUrl: String?,
        ) {
            emitPageError(errorCode, description ?: "", failingUrl ?: view.url.orEmpty())
        }
    }

    private inner class PolicyChromeClient : WebChromeClient() {

        override fun onProgressChanged(view: WebView, newProgress: Int) {
            bridge.emit(
                mapOf("type" to "progress", "viewId" to viewId, "progress" to newProgress)
            )
        }

        override fun onReceivedTitle(view: WebView, title: String?) {
            if (disposed) return
            val value = title ?: return
            if (value == lastTitle) return
            lastTitle = value
            bridge.emit(mapOf("type" to "titleChanged", "viewId" to viewId, "title" to value))
        }

        /**
         * Every page console message, source and line included.
         *
         * A page that dies inside its own `<script>` still finishes loading, so
         * `onReceivedError` never fires and the shell sees a successful load of
         * a document that rendered nothing. The console message is then the only
         * trace of *why* — which is what lets 访问日志 explain a blank page
         * without adb. Source and line are what make it actionable.
         */
        override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
            val text = consoleMessage.message()
            // 防翻页 narrates every detected turn; keep it in logcat so a support
            // session can tell a false positive from a page that ignores the mask.
            if (text.startsWith(FlipGuard.LOG_PREFIX)) {
                Log.i("FlipGuard", "view $viewId $text")
            }
            bridge.emit(
                mapOf(
                    "type" to "consoleMessage",
                    "viewId" to viewId,
                    "message" to text,
                    "level" to consoleMessage.messageLevel().name,
                    "source" to consoleMessage.sourceId(),
                    "line" to consoleMessage.lineNumber(),
                )
            )
            return true
        }

        override fun onGeolocationPermissionsShowPrompt(
            origin: String?,
            callback: GeolocationPermissions.Callback?,
        ) {
            // Geolocation is disabled by policy; deny every request.
            callback?.invoke(origin, false, false)
        }

        override fun onPermissionRequest(request: PermissionRequest?) {
            request?.deny()
        }

        override fun onJsAlert(
            view: WebView,
            url: String?,
            message: String?,
            result: JsResult?,
        ): Boolean {
            result?.confirm()
            return true
        }

        /**
         * Enforcement point 3: popups. The popup itself is never shown; Flutter
         * is told about it (`newWindow`) so it can open a tab of its own.
         */
        override fun onCreateWindow(
            view: WebView,
            isDialog: Boolean,
            isUserGesture: Boolean,
            resultMsg: Message,
        ): Boolean {
            // `<a target="_blank">` clicks already expose their href.
            val hitTestUrl = try {
                view.hitTestResult.extra
            } catch (t: Throwable) {
                null
            }
            if (!hitTestUrl.isNullOrBlank() && isPolicyGatedScheme(hitTestUrl)) {
                emitNewWindow(hitTestUrl)
                return false
            }

            // `window.open(...)`: the target URL is only known once the popup
            // starts loading, so a throwaway WebView is used to capture it. The
            // popup is still never displayed.
            val transport = resultMsg.obj as? WebView.WebViewTransport
            if (transport == null) {
                emitNewWindow("about:blank")
                return false
            }
            val emitted = AtomicBoolean(false)
            val capture = WebView(context)

            fun captureAndCancel(target: String?) {
                if (emitted.compareAndSet(false, true)) {
                    emitNewWindow(target?.takeIf { it.isNotBlank() } ?: "about:blank")
                }
                destroyQuietly(capture)
            }

            capture.settings.javaScriptEnabled = false
            capture.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                    captureAndCancel(request.url?.toString())
                    return true
                }

                @Deprecated("Kept for API < 24 WebViews", ReplaceWith(""))
                override fun shouldOverrideUrlLoading(v: WebView, url: String): Boolean {
                    captureAndCancel(url)
                    return true
                }

                override fun onPageStarted(v: WebView, url: String?, favicon: Bitmap?) {
                    if (url != null && isPolicyGatedScheme(url)) captureAndCancel(url)
                }
            }
            transport.webView = capture
            try {
                resultMsg.sendToTarget()
            } catch (t: Throwable) {
                captureAndCancel(null)
                return true
            }
            mainHandler.postDelayed({
                if (emitted.compareAndSet(false, true)) {
                    emitNewWindow("about:blank")
                    destroyQuietly(capture)
                }
            }, POPUP_CAPTURE_TIMEOUT_MS)
            return true
        }
    }

    private fun destroyQuietly(view: WebView) {
        mainHandler.post {
            try {
                view.stopLoading()
                view.destroy()
            } catch (t: Throwable) {
                Log.w(TAG, "popup capture view destroy failed", t)
            }
        }
    }

    // ------------------------------------------------------------------
    // Enforcement point 4: downloads
    // ------------------------------------------------------------------

    private fun onDownloadStart(
        url: String,
        userAgent: String?,
        contentDisposition: String?,
        mimeType: String?,
        contentLength: Long,
    ) {
        val decision = decide(url)
        bridge.emit(
            mapOf(
                "type" to "downloadRequested",
                "viewId" to viewId,
                "url" to url,
                "userAgent" to userAgent,
                "contentDisposition" to contentDisposition,
                "mimeType" to mimeType,
                "contentLength" to contentLength,
                "allowed" to decision.allowed,
                "reason" to decision.reason.wire,
            )
        )
        if (!decision.allowed) {
            // A denied URL is never handed to the download manager.
            bridge.emit(
                mapOf(
                    "type" to "requestBlocked",
                    "viewId" to viewId,
                    "url" to url,
                    "resourceType" to "download",
                    "allowed" to false,
                    "reason" to decision.reason.wire,
                    "explanation" to decision.explanation,
                    "matched" to matchedPatterns(decision),
                )
            )
            return
        }
        startDownload(url, userAgent, contentDisposition, mimeType)
    }

    private fun startDownload(
        url: String,
        userAgent: String?,
        contentDisposition: String?,
        mimeType: String?,
    ) {
        try {
            val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as? DownloadManager ?: return
            val request = DownloadManager.Request(Uri.parse(url))
            if (!mimeType.isNullOrBlank()) request.setMimeType(mimeType)
            if (!userAgent.isNullOrBlank()) request.addRequestHeader("User-Agent", userAgent)
            val cookies = CookieManager.getInstance().getCookie(url)
            if (!cookies.isNullOrBlank()) request.addRequestHeader("Cookie", cookies)
            val fileName = URLUtil.guessFileName(url, contentDisposition, mimeType)
            request.setDestinationInExternalFilesDir(context, Environment.DIRECTORY_DOWNLOADS, fileName)
            request.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            manager.enqueue(request)
        } catch (t: Throwable) {
            Log.w(TAG, "download failed for $url", t)
            emitPageError(-1, "download failed: ${t.message}", url)
        }
    }

    // ------------------------------------------------------------------
    // Event helpers
    // ------------------------------------------------------------------

    private fun emitPage(type: String, url: String) {
        bridge.emit(mapOf("type" to type, "viewId" to viewId, "url" to url))
    }

    private fun emitUrlChanged(url: String) {
        bridge.emit(
            mapOf(
                "type" to "urlChanged",
                "viewId" to viewId,
                "url" to url,
                "canGoBack" to canGoBack(),
                "canGoForward" to canGoForward(),
            )
        )
    }

    private fun emitPageError(code: Int, description: String, url: String) {
        bridge.emit(
            mapOf(
                "type" to "pageError",
                "viewId" to viewId,
                "code" to code,
                "description" to description,
                "url" to url,
            )
        )
    }

    private fun emitNewWindow(url: String) {
        bridge.emit(mapOf("type" to "newWindow", "viewId" to viewId, "url" to url))
    }

    companion object {
        private const val TAG = "PolicyWebView"
        private const val POPUP_CAPTURE_TIMEOUT_MS = 750L

        /** Schemes whose URLs are evaluated by the policy engine. */
        fun isPolicyGatedScheme(rawUrl: String): Boolean {
            val parsed = parseUrl(rawUrl) ?: return false
            return when (parsed.scheme.lowercase()) {
                "http", "https", "file" -> true
                else -> false
            }
        }
    }
}

/**
 * Renders the block page. `settings.blockPageHtml` is a template with the
 * `{{URL}}`, `{{REASON}}`, `{{MATCHED}}` and `{{TIME}}` placeholders; every
 * substituted value is HTML escaped. A dark/light aware built-in page is used
 * when no usable template is configured.
 */
object BlockPageRenderer {

    private val timeFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)

    @JvmStatic
    fun render(template: String?, url: String, decision: PolicyDecision): String {
        val escapedUrl = escape(url)
        val escapedReason = escape(decision.explanation)
        val escapedMatched = escape(
            decision.decisiveRules.map { it.rule.pattern }.joinToString("、")
        )
        val escapedTime = escape(timeFormat.format(Date()))
        val rawTemplate = template?.takeIf { it.isNotBlank() }
        if (rawTemplate == null) {
            return fallbackHtml(escapedUrl, escapedReason, escapedMatched, escapedTime)
        }
        return rawTemplate
            .replace("{{URL}}", escapedUrl)
            .replace("{{REASON}}", escapedReason)
            .replace("{{MATCHED}}", escapedMatched)
            .replace("{{TIME}}", escapedTime)
    }

    /** HTML escapes one substituted value. */
    @JvmStatic
    fun escape(value: String): String = buildString(value.length) {
        for (ch in value) {
            when (ch) {
                '&' -> append("&amp;")
                '<' -> append("&lt;")
                '>' -> append("&gt;")
                '"' -> append("&quot;")
                '\'' -> append("&#39;")
                else -> append(ch)
            }
        }
    }

    private fun fallbackHtml(
        url: String,
        reason: String,
        matched: String,
        time: String,
    ): String = """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>访问已被拦截</title>
        <style>
          :root { color-scheme: light dark; }
          body { margin: 0; padding: 48px 24px; font-family: system-ui, -apple-system, "Noto Sans SC", sans-serif;
                 background: #f6f7f9; color: #16181d; display: flex; justify-content: center; }
          .card { max-width: 640px; width: 100%; background: #ffffff; border-radius: 16px;
                  padding: 32px; box-shadow: 0 8px 28px rgba(0,0,0,.08); }
          h1 { margin: 0 0 8px; font-size: 26px; }
          .reason { margin: 0 0 24px; font-size: 17px; color: #b3261e; font-weight: 600; }
          dl { margin: 0; }
          dt { font-size: 13px; text-transform: uppercase; letter-spacing: .06em; color: #6b7280; margin-top: 18px; }
          dd { margin: 6px 0 0; font-size: 15px; word-break: break-all; font-family: ui-monospace, monospace; }
          footer { margin-top: 28px; font-size: 13px; color: #6b7280; }
          @media (prefers-color-scheme: dark) {
            body { background: #101216; color: #e8eaed; }
            .card { background: #1b1e24; box-shadow: none; }
            .reason { color: #ff8a80; }
            dt, footer { color: #9aa0a6; }
          }
        </style>
        </head>
        <body>
          <main class="card">
            <h1>访问已被拦截</h1>
            <p class="reason">$reason</p>
            <dl>
              <dt>网址</dt><dd>$url</dd>
              <dt>命中的规则</dt><dd>$matched</dd>
              <dt>时间</dt><dd>$time</dd>
            </dl>
            <footer>该网址不在允许范围内，或已被黑名单拦截。</footer>
          </main>
        </body>
        </html>
    """.trimIndent()
}
