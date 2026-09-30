package com.xstocker.tabletbrowser

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 防翻页: the settings mapping and the invariants of the injected mask script.
 *
 * The mask itself only exists in a real WebView, so what a JVM test can protect
 * is everything around it — the values the script is built with, the switches it
 * reads, and the promises the settings UI makes to the operator (which gestures
 * are blocked, which are not).
 */
class FlipGuardTest {

    @Test
    fun `defaults keep the flip guard off on the native side`() {
        val settings = WebViewSettings.fromMap(null)
        assertFalse(settings.flipGuardEnabled)
        assertEquals(2, settings.flipGuardSeconds)

        // A payload from an app version that did not know the flag: no injection.
        assertFalse(WebViewSettings.fromMap(mapOf("javaScript" to true)).flipGuardEnabled)
    }

    @Test
    fun `the flip guard round trips through the settings map`() {
        val settings = WebViewSettings.fromMap(
            mapOf("flipGuardEnabled" to true, "flipGuardSeconds" to 7),
        )
        assertTrue(settings.flipGuardEnabled)
        assertEquals(7, settings.flipGuardSeconds)

        val merged = WebViewSettings.merge(settings, mapOf("textZoom" to 120))
        assertTrue("unchanged by an unrelated patch", merged.flipGuardEnabled)
        assertEquals(7, merged.flipGuardSeconds)

        val retuned = WebViewSettings.merge(merged, mapOf("flipGuardSeconds" to 3))
        assertTrue(retuned.flipGuardEnabled)
        assertEquals(3, retuned.flipGuardSeconds)

        val off = WebViewSettings.merge(retuned, mapOf("flipGuardEnabled" to false))
        assertFalse(off.flipGuardEnabled)
    }

    @Test
    fun `the cooldown is baked into the script, clamped to 1-600 seconds`() {
        assertTrue(FlipGuard.scriptFor(2).contains("cooldownMs: 2000"))
        assertTrue(FlipGuard.scriptFor(7).contains("cooldownMs: 7000"))
        // 0 s would be a no-op lock, 10 minutes would wedge the page.
        assertTrue(FlipGuard.scriptFor(0).contains("cooldownMs: 1000"))
        assertTrue(FlipGuard.scriptFor(99999).contains("cooldownMs: 600000"))
        // The placeholder must never survive into the injected script.
        assertFalse(FlipGuard.scriptFor(2).contains("__COOLDOWN_MS__"))
    }

    @Test
    fun `the script is idempotent, ES5 and blocks through the mask`() {
        val script = FlipGuard.scriptFor(2)

        // A second injection (page-start fallback) must only retune, not stack.
        assertTrue(script.contains("window.__dshFlipGuard"))
        assertTrue(script.contains("setCooldown"))

        // Idle lets everything through, cooling eats it.
        assertTrue(script.contains("pointer-events:none"))
        assertTrue(script.contains("pointerEvents = on ? 'auto' : 'none'"))

        // Our own nodes are marked so their insertion is not read as a page turn.
        assertTrue(script.contains("data-dsh-flip"))
        assertTrue(script.contains("isOurs"))

        // Detection: picture swaps, hash changes, gestures.
        assertTrue(script.contains("MutationObserver"))
        assertTrue(script.contains("attributeFilter: ['src']"))
        assertTrue(script.contains("bigPicture"))
        assertTrue(script.contains("hashchange"))
        assertTrue(script.contains("popstate"))
        assertTrue(script.contains("swipe"))

        // Typing and dragging a slider must never be interrupted.
        assertTrue(script.contains("editableFocused"))

        // Old WebViews: no arrow functions, no template literals, no let/const.
        assertFalse(script.contains("=>"))
        assertFalse(script.contains("`"))
        assertFalse(script.contains("let "))
        assertFalse(script.contains("const "))
    }

    @Test
    fun `the documented geometry is what the script actually uses`() {
        val script = FlipGuard.scriptFor(2)
        // Picture swap = at least 55% of the viewport; the settings hint says so.
        assertTrue(script.contains("areaRatio: 0.55"))
        // Immediate tap band 12%, latch band 26%; swipe threshold 40 px.
        assertTrue(script.contains("quickBand: 0.12"))
        assertTrue(script.contains("edgeBand: 0.26"))
        assertTrue(script.contains("swipePx: 40"))
        assertTrue(script.contains("latchMs: 1500"))
        // A scroll only ever confirms a latched gesture.
        assertTrue(script.contains("latched()"))
        // An unconfirmed edge tap must not cost the whole cool-down (games have
        // controls out there); it locks for the provisional window only.
        assertTrue(script.contains("provisionalMs: 700"))
        assertTrue(script.contains("provisional = span < CFG.cooldownMs"))
        assertTrue(script.contains("function confirm(reason)"))
        assertTrue(script.contains("if (cooling() && !provisional) { return; }"))
    }

    @Test
    fun `every detected turn is logged under the prefix logcat filters on`() {
        val script = FlipGuard.scriptFor(2)
        assertTrue(script.contains("console.log('" + FlipGuard.LOG_PREFIX))
        // Support reads these lines to tell a false positive from a page that
        // ignores the mask, so the reasons have to stay unique.
        for (reason in listOf("picture-added", "picture-removed", "swipe", "edge-tap")) {
            assertTrue(reason, script.contains("'" + reason + "'"))
        }
        // The full life of a lock is traceable from logcat alone: arm, release,
        // and whether a gesture was actually eaten.
        assertTrue(script.contains("say('cool '"))
        assertTrue(script.contains("say('release')"))
        assertTrue(script.contains("say('blocked '"))
    }

    @Test
    fun `the gesture that caused the turn is allowed to finish`() {
        val script = FlipGuard.scriptFor(2)
        // A drag-to-turn book flips on the tail of the drag, so arming the mask
        // must not cut that gesture off; only the next gesture is eaten.
        assertTrue(script.contains("passThrough"))
        assertTrue(script.contains("gestureInFlight"))
        assertTrue(script.contains("if (gestureInFlight) { passThrough = true; }"))
    }

    @Test
    fun `retuning a loaded document only calls setCooldown`() {
        val snippet = FlipGuard.cooldownSnippet(5)
        assertTrue(snippet.contains("__dshFlipGuard"))
        assertTrue(snippet.contains("setCooldown(5000)"))
        assertFalse(snippet.contains("__COOLDOWN_MS__"))
        // Clamped the same way the script is.
        assertTrue(FlipGuard.cooldownSnippet(0).contains("setCooldown(1000)"))
        assertTrue(FlipGuard.cooldownSnippet(99999).contains("setCooldown(600000)"))
    }
}
