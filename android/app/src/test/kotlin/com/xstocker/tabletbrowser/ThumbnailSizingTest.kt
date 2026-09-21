package com.xstocker.tabletbrowser

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM tests for the `captureThumbnail` maths (CONTRACT.md section 4).
 *
 * [ThumbnailSizing] deliberately touches no Android framework class, so the
 * sizing and blank-detection rules — the parts a device could only verify
 * visually — are checked here, in the same suite as the policy engine tests.
 * The bitmap/`WebView` plumbing around it needs a real device.
 */
class ThumbnailSizingTest {

    // ------------------------------------------------------------------
    // maxWidth
    // ------------------------------------------------------------------

    @Test
    fun `maxWidth defaults to the contract value`() {
        assertEquals(320, ThumbnailSizing.effectiveMaxWidth(null))
        assertEquals(ThumbnailSizing.DEFAULT_MAX_WIDTH, ThumbnailSizing.effectiveMaxWidth(null))
    }

    @Test
    fun `maxWidth passes through a usable value`() {
        assertEquals(640, ThumbnailSizing.effectiveMaxWidth(640))
        assertEquals(ThumbnailSizing.MIN_MAX_WIDTH, ThumbnailSizing.effectiveMaxWidth(16))
        assertEquals(ThumbnailSizing.MAX_MAX_WIDTH, ThumbnailSizing.effectiveMaxWidth(4096))
    }

    @Test
    fun `maxWidth is clamped on both ends`() {
        assertEquals(ThumbnailSizing.MIN_MAX_WIDTH, ThumbnailSizing.effectiveMaxWidth(0))
        assertEquals(ThumbnailSizing.MIN_MAX_WIDTH, ThumbnailSizing.effectiveMaxWidth(-100))
        assertEquals(ThumbnailSizing.MIN_MAX_WIDTH, ThumbnailSizing.effectiveMaxWidth(1))
        assertEquals(ThumbnailSizing.MAX_MAX_WIDTH, ThumbnailSizing.effectiveMaxWidth(100_000))
    }

    // ------------------------------------------------------------------
    // Target size
    // ------------------------------------------------------------------

    @Test
    fun `zero-size and negative-size views have no target`() {
        assertNull(ThumbnailSizing.targetSize(0, 0, 320))
        assertNull(ThumbnailSizing.targetSize(0, 1920, 320))
        assertNull(ThumbnailSizing.targetSize(1080, 0, 320))
        assertNull(ThumbnailSizing.targetSize(-1080, 1920, 320))
        assertNull(ThumbnailSizing.targetSize(1080, -1, 320))
    }

    @Test
    fun `a view narrower than maxWidth is not upscaled`() {
        assertEquals(ThumbnailSizing.Size(300, 200), ThumbnailSizing.targetSize(300, 200, 320))
        assertEquals(ThumbnailSizing.Size(320, 200), ThumbnailSizing.targetSize(320, 200, 320))
    }

    @Test
    fun `scaling preserves the aspect ratio`() {
        // 1080x1920 -> 320 wide: 1920 * 320 / 1080 = 568.9 -> 569, i.e. the top
        // of the page, which is what a square bookmark tile shows.
        assertEquals(ThumbnailSizing.Size(320, 569), ThumbnailSizing.targetSize(1080, 1920, 320))
        assertEquals(ThumbnailSizing.Size(320, 320), ThumbnailSizing.targetSize(1000, 1000, 320))
        // Landscape: 2000x1000 -> 320x160.
        assertEquals(ThumbnailSizing.Size(320, 160), ThumbnailSizing.targetSize(2000, 1000, 320))
    }

    @Test
    fun `the scaled height never collapses to zero`() {
        // A 1000x1 view at 320 wide rounds to 0.32 px; one row is kept.
        assertEquals(ThumbnailSizing.Size(320, 1), ThumbnailSizing.targetSize(1000, 1, 320))
        assertEquals(ThumbnailSizing.Size(320, 1), ThumbnailSizing.targetSize(10000, 3, 320))
    }

    @Test
    fun `scaling is exact when the ratio divides evenly`() {
        assertEquals(ThumbnailSizing.Size(320, 240), ThumbnailSizing.targetSize(640, 480, 320))
        assertEquals(ThumbnailSizing.Size(160, 120), ThumbnailSizing.targetSize(640, 480, 160))
    }

    @Test
    fun `height is rounded to nearest, not truncated`() {
        // 3x100 -> 2 wide: 100 * 2 / 3 = 66.67 -> 67.
        assertEquals(ThumbnailSizing.Size(2, 67), ThumbnailSizing.targetSize(3, 100, 2))
        // 3x101 -> 2 wide: 101 * 2 / 3 = 67.33 -> 67.
        assertEquals(ThumbnailSizing.Size(2, 67), ThumbnailSizing.targetSize(3, 101, 2))
    }

    @Test
    fun `a degenerate maxWidth still produces a usable target`() {
        assertEquals(ThumbnailSizing.Size(1, 100), ThumbnailSizing.targetSize(10, 1000, 0))
        assertEquals(ThumbnailSizing.Size(1, 1000), ThumbnailSizing.targetSize(1, 1000, 320))
    }

    // ------------------------------------------------------------------
    // Blank detection
    // ------------------------------------------------------------------

    @Test
    fun `an empty sample is blank`() {
        assertTrue(ThumbnailSizing.isBlankSample(IntArray(0)))
    }

    @Test
    fun `any painted pixel makes a capture usable`() {
        val samples = IntArray(64)
        samples[37] = 0xFFFFFFFF.toInt()
        assertFalse(ThumbnailSizing.isBlankSample(samples))
    }

    @Test
    fun `a translucent pixel counts as painted`() {
        val samples = IntArray(16)
        samples[0] = 0x01FFFFFF
        assertFalse(ThumbnailSizing.isBlankSample(samples))
    }

    @Test
    fun `painted pages are never blank, whatever their colour`() {
        // Fully transparent means "nothing rendered"; a white — or black —
        // page has opaque pixels and must still be captured.
        assertFalse(ThumbnailSizing.isBlankSample(IntArray(64) { 0xFFFFFFFF.toInt() }))
        assertFalse(ThumbnailSizing.isBlankSample(IntArray(64) { 0xFF000000.toInt() }))
    }

    @Test
    fun `an all transparent page is blank`() {
        assertTrue(ThumbnailSizing.isBlankSample(IntArray(64) { 0x00000000 }))
    }
}
