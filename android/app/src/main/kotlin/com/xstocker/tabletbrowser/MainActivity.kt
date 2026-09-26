package com.xstocker.tabletbrowser

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Hosts the native WebView layer described in docs/CONTRACT.md section 2:
 *
 *  * registers the `tablet_browser/webview` platform view factory;
 *  * creates the `tablet_browser/commands` MethodChannel and the
 *    `tablet_browser/events` EventChannel on the Flutter engine;
 *  * keeps the live views in [PolicyBridge], keyed by `viewId`.
 *
 * Every command is handled on the platform thread (MethodChannel delivers there
 * by default). The one callback that runs off-thread,
 * `WebViewClient.shouldInterceptRequest`, talks to the immutable policy
 * snapshot only and never posts-and-waits on the platform thread.
 */
class MainActivity : FlutterActivity() {

    private var bridge: PolicyBridge? = null
    private var commandChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val bridge = PolicyBridge(applicationContext)
        this.bridge = bridge

        flutterEngine.platformViewsController.registry.registerViewFactory(
            VIEW_TYPE,
            PolicyWebViewFactory(bridge),
        )

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        eventChannel = EventChannel(messenger, EVENTS_CHANNEL).also {
            it.setStreamHandler(bridge)
        }

        commandChannel = MethodChannel(messenger, COMMANDS_CHANNEL).also {
            it.setMethodCallHandler { call, result -> handleCommand(call, result, bridge) }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        try {
            bridge?.disposeAll()
            commandChannel?.setMethodCallHandler(null)
            eventChannel?.setStreamHandler(null)
        } catch (_: Throwable) {
            // Engine teardown must never throw.
        }
        bridge = null
        commandChannel = null
        eventChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // ------------------------------------------------------------------
    // tablet_browser/commands
    // ------------------------------------------------------------------

    private fun handleCommand(call: MethodCall, result: MethodChannel.Result, bridge: PolicyBridge) {
        try {
            when (call.method) {
                "loadUrl" -> {
                    val view = viewFor(call, result, bridge) ?: return
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("invalid_args", "loadUrl requires a non-empty 'url'", null)
                        return
                    }
                    view.loadUrl(url)
                    result.success(mapOf("ok" to true))
                }

                "goBack" -> {
                    val view = viewFor(call, result, bridge) ?: return
                    view.goBack()
                    result.success(historyState(view))
                }

                "goForward" -> {
                    val view = viewFor(call, result, bridge) ?: return
                    view.goForward()
                    result.success(historyState(view))
                }

                "reload" -> {
                    val view = viewFor(call, result, bridge) ?: return
                    view.reload()
                    result.success(mapOf("ok" to true))
                }

                "stopLoading" -> {
                    val view = viewFor(call, result, bridge) ?: return
                    view.stopLoading()
                    result.success(mapOf("ok" to true))
                }

                "canGoBack" -> {
                    val view = viewFor(call, result, bridge) ?: return
                    result.success(view.canGoBack())
                }

                "canGoForward" -> {
                    val view = viewFor(call, result, bridge) ?: return
                    result.success(view.canGoForward())
                }

                "currentUrl" -> {
                    val view = viewFor(call, result, bridge) ?: return
                    result.success(view.currentUrl())
                }

                "pageTitle" -> {
                    val view = viewFor(call, result, bridge) ?: return
                    result.success(view.pageTitle())
                }

                "userAgent" -> {
                    val view = viewFor(call, result, bridge) ?: return
                    result.success(view.userAgent())
                }

                "evaluateJavascript" -> {
                    val view = viewFor(call, result, bridge) ?: return
                    val script = call.argument<String>("script") ?: ""
                    view.evaluateJavascript(script) { value -> result.success(value) }
                }

                "setPolicy" -> {
                    bridge.setPolicyFromJson(call.argument<Map<*, *>>("policy"))
                    result.success(mapOf("ok" to true))
                }

                "updateSettings" -> {
                    val view = viewFor(call, result, bridge) ?: return
                    view.updateSettings(call.argument<Map<*, *>>("settings"))
                    result.success(mapOf("ok" to true))
                }

                "disposeView" -> {
                    val viewId = viewIdOf(call)
                    if (viewId != null) bridge.disposeView(viewId)
                    result.success(mapOf("ok" to true))
                }

                "clearCache" -> {
                    bridge.clearCache()
                    bridge.clearWebStorage()
                    result.success(mapOf("ok" to true))
                }

                "clearCookies" -> {
                    bridge.clearCookies {
                        mainHandler.post { result.success(mapOf("ok" to true)) }
                    }
                }

                "clearHistory" -> {
                    bridge.clearHistory()
                    result.success(mapOf("ok" to true))
                }

                // CONTRACT.md section 4. Unlike every other per-view command
                // this one answers `null` instead of an error for a bad or
                // unknown viewId: a thumbnail is a convenience, and the Dart
                // side must fall back to its generated tile silently.
                "captureThumbnail" -> {
                    val viewId = viewIdOf(call)
                    val maxWidth = (call.argument<Any?>("maxWidth") as? Number)?.toInt()
                    val answered = AtomicBoolean(false)
                    // The capture answers from the main looper, asynchronously,
                    // so the result is guarded here as well as in the bridge.
                    val answer: (ByteArray?) -> Unit = { bytes ->
                        if (answered.compareAndSet(false, true)) result.success(bytes)
                    }
                    if (viewId == null) {
                        answer(null)
                    } else {
                        bridge.captureThumbnail(viewId, maxWidth) { bytes -> answer(bytes) }
                    }
                }

                // PDF bookmarks: Android's WebView cannot show a PDF, so the
                // page is rendered here and the Flutter pager displays it.
                "pdfPageCount" -> {
                    val path = call.argument<String>("path").orEmpty()
                    val answered = AtomicBoolean(false)
                    val answer: (Int) -> Unit = { count ->
                        if (answered.compareAndSet(false, true)) result.success(count)
                    }
                    if (path.isEmpty()) answer(0) else PdfPageRenderer.pageCount(path, answer)
                }

                "renderPdfPage" -> {
                    val path = call.argument<String>("path").orEmpty()
                    val index = (call.argument<Any?>("index") as? Number)?.toInt() ?: -1
                    val maxWidth = (call.argument<Any?>("maxWidth") as? Number)?.toInt()
                    val answered = AtomicBoolean(false)
                    val answer: (ByteArray?) -> Unit = { bytes ->
                        if (answered.compareAndSet(false, true)) result.success(bytes)
                    }
                    if (path.isEmpty() || index < 0) {
                        answer(null)
                    } else {
                        PdfPageRenderer.renderPage(path, index, maxWidth, answer)
                    }
                }

                // Not part of the frozen contract table, but the Dart bridge
                // calls it: send the operator to the system screen that grants
                // MANAGE_EXTERNAL_STORAGE so local files can be browsed.
                "openManageStorageSettings" -> {
                    result.success(mapOf("ok" to openManageStorageSettings()))
                }

                // Whether the app really holds MANAGE_EXTERNAL_STORAGE. Without
                // it, listing /sdcard silently returns nothing, which looks
                // exactly like an empty directory to the user.
                "hasAllFilesAccess" -> {
                    result.success(hasAllFilesAccess())
                }

                // The installed package's own version, for the settings screen's
                // 关于 card. Read from the package manager rather than compiled
                // in, so it always names the APK that is actually installed.
                "appVersion" -> {
                    result.success(appVersion())
                }

                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.error("native_error", t.message ?: t.toString(), null)
        }
    }

    /// `versionName` + `versionCode` of the installed package.
    ///
    /// The deprecated `getPackageInfo(String, int)` overload is kept for API 24
    /// and only bypassed where the platform requires it, so the same code runs on
    /// both ends of the supported range.
    private fun appVersion(): Map<String, Any> {
        val manager = packageManager
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.getPackageInfo(packageName, android.content.pm.PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            manager.getPackageInfo(packageName, 0)
        }
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        return mapOf(
            "versionName" to (info.versionName ?: ""),
            "versionCode" to code,
        )
    }

    private fun historyState(view: PolicyWebView): Map<String, Any?> = mapOf(
        "ok" to true,
        "canGoBack" to view.canGoBack(),
        "canGoForward" to view.canGoForward(),
    )

    private fun viewIdOf(call: MethodCall): Int? =
        (call.argument<Any?>("viewId") as? Number)?.toInt()

    private fun viewFor(
        call: MethodCall,
        result: MethodChannel.Result,
        bridge: PolicyBridge,
    ): PolicyWebView? {
        val viewId = viewIdOf(call)
        if (viewId == null) {
            result.error("invalid_args", "${call.method} requires an integer 'viewId'", null)
            return null
        }
        val view = bridge.view(viewId)
        if (view == null) {
            result.error("unknown_view", "no platform view registered for viewId=$viewId", null)
            return null
        }
        return view
    }

    /**
     * Opens the system screen that grants MANAGE_EXTERNAL_STORAGE, which a
     * local-file browser needs on Android 11+. Falls back to the app details
     * screen on older releases.
     */
    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            // Below Android 11 the legacy read permission is what matters.
            checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        }
    }

    private fun openManageStorageSettings(): Boolean {
        return try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:$packageName"),
                )
            } else {
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName"),
                )
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (t: Throwable) {
            try {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                true
            } catch (t2: Throwable) {
                false
            }
        }
    }

    companion object {
        const val VIEW_TYPE = "tablet_browser/webview"
        const val COMMANDS_CHANNEL = "tablet_browser/commands"
        const val EVENTS_CHANNEL = "tablet_browser/events"
    }}
