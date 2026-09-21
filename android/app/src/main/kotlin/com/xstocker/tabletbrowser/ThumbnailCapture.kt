package com.xstocker.tabletbrowser

import android.graphics.Bitmap
import android.graphics.Canvas
import android.util.Log
import android.webkit.WebView
import java.io.ByteArrayOutputStream
import kotlin.math.min

/**
 * Pure integer maths behind `captureThumbnail` (CONTRACT.md section 4).
 *
 * Deliberately free of every Android framework class so it runs unchanged in
 * the JVM unit-test suite: the sizing rules and the "is this capture blank"
 * rule are the parts worth testing, and they do not need a device.
 */
object ThumbnailSizing {

    /** `maxWidth` used when Dart does not send one. */
    const val DEFAULT_MAX_WIDTH = 320

    /** Guards against a caller asking for a useless or absurd bitmap. */
    const val MIN_MAX_WIDTH = 16
    const val MAX_MAX_WIDTH = 4096

    /** A scaled capture target, in pixels. */
    data class Size(val width: Int, val height: Int)

    /** Clamps a requested `maxWidth` into the range the capture can honour. */
    @JvmStatic
    fun effectiveMaxWidth(requested: Int?): Int =
        (requested ?: DEFAULT_MAX_WIDTH).coerceIn(MIN_MAX_WIDTH, MAX_MAX_WIDTH)

    /**
     * The size of the scaled thumbnail for a `width` x `height` view, or `null`
     * when the view has nothing to capture (a zero-size or not-yet-laid-out
     * view).
     *
     * The aspect ratio is preserved and the width is never increased: a view
     * narrower than `maxWidth` is captured at its own size. The result is
     * rounded to nearest, never below 1 pixel.
     */
    @JvmStatic
    fun targetSize(width: Int, height: Int, maxWidth: Int): Size? {
        if (width <= 0 || height <= 0) return null
        val limit = maxWidth.coerceAtLeast(1)
        if (width <= limit) return Size(width, height)
        val targetHeight = ((height.toLong() * limit + width / 2L) / width)
            .toInt()
            .coerceAtLeast(1)
        return Size(limit, targetHeight)
    }

    /**
     * True when a sampled capture painted nothing at all: every sample is fully
     * transparent. A page that merely happens to be white is *not* blank — its
     * pixels are opaque — so it is still captured.
     */
    @JvmStatic
    fun isBlankSample(argbPixels: IntArray): Boolean {
        if (argbPixels.isEmpty()) return true
        for (pixel in argbPixels) {
            val alpha = (pixel ushr 24) and 0xFF
            if (alpha != 0) return false
        }
        return true
    }
}

/**
 * Captures the frame a [WebView] is currently showing as PNG bytes.
 *
 * The work is deliberately cheap and side-effect free: nothing is re-laid out,
 * nothing is reloaded and no drawing-cache API is touched, so the capture costs
 * one `draw` of the frame that is already rendered. Every failure mode in
 * CONTRACT.md section 4 (unknown/disposed view, zero-size view, allocation
 * failure, blank capture, any thrown `Throwable`) is reported as `null` — this
 * object never throws and never signals an error, because a missing thumbnail
 * must degrade to Flutter's generated tile.
 *
 * Threading: [capture] performs view operations and must run on the UI thread.
 */
internal object ThumbnailCapture {

    private const val TAG = "ThumbnailCapture"

    /** At most 8x8 sample points are read when deciding whether a capture is blank. */
    private const val SAMPLE_GRID = 8

    /**
     * Renders `view` into an `ARGB_8888` bitmap, scales it to `maxWidth`
     * preserving the aspect ratio, and returns the PNG bytes.
     *
     * UI thread only. Returns `null` when the capture is unusable.
     */
    fun capture(view: WebView, maxWidth: Int): ByteArray? {
        val width = view.width
        val height = view.height
        val target = ThumbnailSizing.targetSize(
            width,
            height,
            ThumbnailSizing.effectiveMaxWidth(maxWidth),
        )
        if (target == null) {
            Log.d(TAG, "nothing to capture: view is ${width}x$height")
            return null
        }

        var source: Bitmap? = null
        var scaled: Bitmap? = null
        try {
            source = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            // The rendered frame only: no re-layout, no invalidate, no
            // deprecated drawing-cache calls.
            view.draw(Canvas(source))

            if (ThumbnailSizing.isBlankSample(samplePixels(source))) {
                Log.d(TAG, "capture is blank for a ${width}x$height view")
                return null
            }

            scaled = if (source.width == target.width && source.height == target.height) {
                source
            } else {
                Bitmap.createScaledBitmap(source, target.width, target.height, true)
            }

            val bytes = ByteArrayOutputStream().use { out ->
                if (!scaled.compress(Bitmap.CompressFormat.PNG, 100, out)) return null
                out.toByteArray()
            }
            return bytes.takeIf { it.isNotEmpty() }
        } catch (t: Throwable) {
            // Bitmap allocation failures surface as OutOfMemoryError, which is
            // an Error and not an Exception.
            Log.d(TAG, "capture failed for a ${width}x$height view", t)
            return null
        } finally {
            recycleQuietly(scaled)
            if (scaled !== source) recycleQuietly(source)
        }
    }

    /** Reads up to [SAMPLE_GRID]^2 pixels spread over the whole capture. */
    private fun samplePixels(bitmap: Bitmap): IntArray {
        val width = bitmap.width
        val height = bitmap.height
        val columns = min(SAMPLE_GRID, width).coerceAtLeast(1)
        val rows = min(SAMPLE_GRID, height).coerceAtLeast(1)
        val samples = IntArray(columns * rows)
        var index = 0
        for (row in 0 until rows) {
            val y = row * height / rows
            for (column in 0 until columns) {
                samples[index++] = bitmap.getPixel(column * width / columns, y)
            }
        }
        return samples
    }

    private fun recycleQuietly(bitmap: Bitmap?) {
        if (bitmap == null || bitmap.isRecycled) return
        try {
            bitmap.recycle()
        } catch (t: Throwable) {
            Log.d(TAG, "bitmap recycle failed", t)
        }
    }
}
