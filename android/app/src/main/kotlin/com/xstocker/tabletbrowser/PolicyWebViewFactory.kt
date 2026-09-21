package com.xstocker.tabletbrowser

import android.content.Context
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Factory for the `tablet_browser/webview` platform view.
 *
 * Creation params (see CONTRACT.md section 2) are a JSON map:
 *
 * ```json
 * {
 *   "viewId": 1,
 *   "settings": { "javaScript": true, "domStorage": true, ... },
 *   "policy": { "enabled": true, "rules": [...], "localServer": {...} }
 * }
 * ```
 *
 * The Flutter AndroidView/PlatformViewLink machinery passes that map as `args`;
 * the numeric `id` argument is used as a fallback for `viewId`.
 */
class PolicyWebViewFactory(private val bridge: PolicyBridge) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, id: Int, args: Any?): PlatformView {
        val params = args as? Map<*, *>
        val viewId = (params?.get("viewId") as? Number)?.toInt() ?: id
        val settings = WebViewSettings.fromMap(params?.get("settings") as? Map<*, *>)

        // A policy supplied at creation time is shared by every view.
        (params?.get("policy") as? Map<*, *>)?.let { bridge.setPolicyFromJson(it) }

        val view = PolicyWebView(context, viewId, settings, bridge)
        bridge.register(view)
        return view
    }
}
