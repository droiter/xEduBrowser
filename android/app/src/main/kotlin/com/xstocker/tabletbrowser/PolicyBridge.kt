package com.xstocker.tabletbrowser

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.CookieManager
import android.webkit.WebStorage
import com.xstocker.tabletbrowser.policy.PolicyConfig
import com.xstocker.tabletbrowser.policy.PolicyDecision
import com.xstocker.tabletbrowser.policy.PolicyEngine
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Shared state for the native WebView layer:
 *
 *  * the current policy engine as an immutable snapshot (`@Volatile`, swapped
 *    atomically by `setPolicy`), so `shouldInterceptRequest` can decide
 *    synchronously on a WebView worker thread without ever waiting on the
 *    platform thread;
 *  * the `tablet_browser/events` sink, with emission marshalled to the platform
 *    thread;
 *  * the registry of live platform views by `viewId`.
 */
class PolicyBridge(private val appContext: Context) : EventChannel.StreamHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val views = ConcurrentHashMap<Int, PolicyWebView>()

    @Volatile
    private var currentEngine: PolicyEngine = PolicyEngine(PolicyConfig.EMPTY)

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    /** The engine snapshot. Never mutated in place. */
    val engine: PolicyEngine get() = currentEngine

    /** Replaces the whole policy (the `setPolicy` command / creation params). */
    fun setPolicyFromJson(json: Map<*, *>?) {
        currentEngine = PolicyEngine(PolicyConfig.fromJson(json))
    }

    fun policyJson(): Map<String, Any?> = currentEngine.config.toJson()

    /** Thread-safe: reads the immutable snapshot taken at the call site. */
    fun decide(url: String): PolicyDecision = currentEngine.decide(url)

    // ------------------------------------------------------------------
    // Event channel
    // ------------------------------------------------------------------

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    /**
     * Sends one event map. Safe to call from any thread: the sink itself is only
     * ever touched on the platform thread, and callers never block on it.
     */
    fun emit(event: Map<String, Any?>) {
        val sink = eventSink ?: return
        if (Looper.myLooper() == Looper.getMainLooper()) {
            sink.success(event)
        } else {
            mainHandler.post {
                if (eventSink === sink) {
                    sink.success(event)
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // View registry
    // ------------------------------------------------------------------

    fun register(view: PolicyWebView) {
        views[view.viewId] = view
    }

    fun unregister(viewId: Int) {
        views.remove(viewId)
    }

    fun view(viewId: Int): PolicyWebView? = views[viewId]

    fun allViews(): List<PolicyWebView> = views.values.toList()

    fun disposeView(viewId: Int): Boolean {
        val view = views.remove(viewId) ?: return false
        view.dispose()
        return true
    }

    fun disposeAll() {
        for (viewId in views.keys.toList()) {
            disposeView(viewId)
        }
    }

    // ------------------------------------------------------------------
    // Thumbnail capture
    // ------------------------------------------------------------------

    /**
     * Captures a PNG thumbnail of the frame a registered view is currently
     * showing (CONTRACT.md section 4).
     *
     * `WebView.draw(Canvas)` is a view operation, so the capture is *posted* to
     * the main looper — never awaited, never run on the caller's thread — which
     * keeps every other command handler deadlock free even if it were ever
     * invoked off the platform thread.
     *
     * [onResult] is invoked exactly once (from the platform thread) and this
     * method never throws: an unknown `viewId`, a disposed view, a zero-size
     * view, a failed allocation or any thrown `Throwable` all arrive as `null`,
     * because a missing screenshot must degrade to Flutter's generated tile
     * rather than surface an error.
     */
    fun captureThumbnail(viewId: Int, maxWidth: Int?, onResult: (ByteArray?) -> Unit) {
        val answered = AtomicBoolean(false)
        val deliver: (ByteArray?) -> Unit = { bytes ->
            if (answered.compareAndSet(false, true)) {
                try {
                    onResult(bytes)
                } catch (t: Throwable) {
                    Log.d(TAG, "captureThumbnail result delivery failed", t)
                }
            }
        }

        val posted = mainHandler.post {
            val bytes = try {
                views[viewId]?.captureThumbnail(ThumbnailSizing.effectiveMaxWidth(maxWidth))
            } catch (t: Throwable) {
                Log.d(TAG, "captureThumbnail failed for view $viewId", t)
                null
            }
            deliver(bytes)
        }
        if (!posted) {
            // The looper is gone; still answer, so Dart never waits forever.
            Log.d(TAG, "captureThumbnail dropped: main looper unavailable")
            deliver(null)
        }
    }

    // ------------------------------------------------------------------
    // Global commands
    // ------------------------------------------------------------------

    fun clearCache() {
        for (view in allViews()) {
            try {
                view.clearCache()
            } catch (t: Throwable) {
                Log.w(TAG, "clearCache failed", t)
            }
        }
    }

    fun clearHistory() {
        for (view in allViews()) {
            try {
                view.clearHistory()
            } catch (t: Throwable) {
                Log.w(TAG, "clearHistory failed", t)
            }
        }
    }

    fun clearCookies(onDone: () -> Unit) {
        try {
            val cookieManager = CookieManager.getInstance()
            cookieManager.removeAllCookies { onDone() }
            cookieManager.flush()
        } catch (t: Throwable) {
            Log.w(TAG, "clearCookies failed", t)
            onDone()
        }
    }

    fun clearWebStorage() {
        try {
            WebStorage.getInstance().deleteAllData()
        } catch (t: Throwable) {
            Log.w(TAG, "clearWebStorage failed", t)
        }
    }

    fun cookiesFor(url: String): String? = try {
        CookieManager.getInstance().getCookie(url)
    } catch (t: Throwable) {
        null
    }

    val context: Context get() = appContext

    private companion object {
        const val TAG = "PolicyBridge"
    }
}
