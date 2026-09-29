package com.xstocker.tabletbrowser

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The per-view WebView settings map: what the Dart side sends, how a partial
 * `updateSettings` patch lands on top of it, and which values a payload written
 * by an older app version falls back to.
 */
class WebViewSettingsTest {

    @Test
    fun `defaults keep the local fetch patch off`() {
        val settings = WebViewSettings.fromMap(null)
        assertFalse(settings.localFetchShim)
        assertTrue(settings.javaScript)

        // A payload from an app version that did not know the flag: off.
        assertFalse(WebViewSettings.fromMap(mapOf("javaScript" to true)).localFetchShim)
    }

    @Test
    fun `the local fetch patch round trips through the settings map`() {
        val settings = WebViewSettings.fromMap(mapOf("localFetchShim" to true))
        assertTrue(settings.localFetchShim)

        val merged = WebViewSettings.merge(settings, mapOf("textZoom" to 120))
        assertTrue("unchanged by an unrelated patch", merged.localFetchShim)
        assertEquals(120, merged.textZoom)

        val off = WebViewSettings.merge(merged, mapOf("localFetchShim" to false))
        assertFalse(off.localFetchShim)
    }

    @Test
    fun `the injected patch only rewrites file urls`() {
        val script = LocalFetchShim.SCRIPT
        assertTrue(script.contains("location.protocol !== 'file:'"))
        assertTrue(script.contains("url.indexOf('file:') !== 0"))
        // Idempotent: a second injection (page-start fallback) must be a no-op.
        assertTrue(script.contains("__dshLocalFetchShim"))
        // AbortSignal support, so a cancelled fetch does not hang.
        assertTrue(script.contains("xhr.onabort"))
    }
}
