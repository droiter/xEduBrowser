package com.xstocker.tabletbrowser

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The sizing rules of the PDF page renderer (CONTRACT.md section 5). */
class PdfPageSizingTest {

    @Test
    fun `keeps a page that is already narrow enough`() {
        val size = PdfPageSizing.targetSize(600, 800, 1400)
        assertEquals(600, size!!.width)
        assertEquals(800, size.height)
    }

    @Test
    fun `scales a wide page down to the requested width`() {
        val size = PdfPageSizing.targetSize(2480, 3508, 1240) // A4 at 300dpi
        assertEquals(1240, size!!.width)
        assertEquals(1754, size.height) // 3508 * (1240/2480) = 1754
    }

    @Test
    fun `android graphics may report a page rotated`() {
        // A landscape page keeps its own aspect ratio.
        val size = PdfPageSizing.targetSize(3508, 2480, 1754)
        assertEquals(1754, size!!.width)
        assertEquals(1240, size.height)
    }

    @Test
    fun `a useless page size is refused`() {
        assertNull(PdfPageSizing.targetSize(0, 800, 1400))
        assertNull(PdfPageSizing.targetSize(600, 0, 1400))
        assertNull(PdfPageSizing.targetSize(-1, -1, 1400))
    }

    @Test
    fun `an absurd page is capped rather than allocated`() {
        val size = PdfPageSizing.targetSize(60000, 60000, 4096)!!
        assertTrue(
            "pixels=${size.width * size.height}",
            size.width.toLong() * size.height.toLong() <= PdfPageSizing.MAX_PIXELS,
        )
        assertTrue(size.width > 0 && size.height > 0)
    }

    @Test
    fun `the requested width is clamped`() {
        assertEquals(PdfPageSizing.MIN_MAX_WIDTH, PdfPageSizing.effectiveMaxWidth(1))
        assertEquals(PdfPageSizing.MAX_MAX_WIDTH, PdfPageSizing.effectiveMaxWidth(99999))
        assertEquals(PdfPageSizing.DEFAULT_MAX_WIDTH, PdfPageSizing.effectiveMaxWidth(null))
        assertEquals(1000, PdfPageSizing.effectiveMaxWidth(1000))
    }
}
