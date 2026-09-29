package com.xstocker.tabletbrowser

import android.view.MotionEvent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The filter that keeps one mouse click from reaching a local page twice.
 *
 * Android reports a click on two paths — the source-mouse `ACTION_DOWN`/`UP` that
 * the compat WebView replays as touch, and the `ACTION_BUTTON_PRESS`/`RELEASE`
 * Chromium turns into a mouse click of its own. The press and the release that
 * pairs with it are dropped; everything else is passed through.
 */
class PrimaryButtonFilterTest {

    @Test
    fun `the primary button's press and its release are dropped`() {
        val filter = PrimaryButtonFilter()
        assertTrue(filter.shouldSwallow(MotionEvent.ACTION_BUTTON_PRESS, MotionEvent.BUTTON_PRIMARY))
        assertTrue(filter.shouldSwallow(MotionEvent.ACTION_BUTTON_RELEASE, 0))
    }

    @Test
    fun `a second release is passed through`() {
        val filter = PrimaryButtonFilter()
        filter.shouldSwallow(MotionEvent.ACTION_BUTTON_PRESS, MotionEvent.BUTTON_PRIMARY)
        assertTrue(filter.shouldSwallow(MotionEvent.ACTION_BUTTON_RELEASE, 0))
        // The pairing is done: a stray release must reach Chromium again.
        assertFalse(filter.shouldSwallow(MotionEvent.ACTION_BUTTON_RELEASE, 0))
    }

    @Test
    fun `a release that was never pressed is passed through`() {
        val filter = PrimaryButtonFilter()
        assertFalse(filter.shouldSwallow(MotionEvent.ACTION_BUTTON_RELEASE, 0))
    }

    @Test
    fun `secondary buttons keep their behaviour`() {
        val filter = PrimaryButtonFilter()
        assertFalse(filter.shouldSwallow(MotionEvent.ACTION_BUTTON_PRESS, MotionEvent.BUTTON_SECONDARY))
        // …and their release is not mistaken for the primary one's.
        assertFalse(filter.shouldSwallow(MotionEvent.ACTION_BUTTON_RELEASE, MotionEvent.BUTTON_SECONDARY))
    }

    @Test
    fun `other mouse events are untouched`() {
        val filter = PrimaryButtonFilter()
        assertFalse(filter.shouldSwallow(MotionEvent.ACTION_HOVER_MOVE, 0))
        assertFalse(filter.shouldSwallow(MotionEvent.ACTION_SCROLL, 0))
        assertFalse(filter.shouldSwallow(MotionEvent.ACTION_DOWN, 0))
    }

    @Test
    fun `a secondary press does not arm the next primary release`() {
        val filter = PrimaryButtonFilter()
        assertFalse(filter.shouldSwallow(MotionEvent.ACTION_BUTTON_PRESS, MotionEvent.BUTTON_SECONDARY))
        assertFalse(filter.shouldSwallow(MotionEvent.ACTION_BUTTON_RELEASE, 0))
    }
}
