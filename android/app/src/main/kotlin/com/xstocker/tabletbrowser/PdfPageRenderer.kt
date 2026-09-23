package com.xstocker.tabletbrowser

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Pure integer/double maths behind the PDF page renderer.
 *
 * Deliberately free of every Android framework class so the sizing rules run in
 * the JVM unit-test suite: they are the part worth pinning down, and they do not
 * need a device.
 */
object PdfPageSizing {

    /** Width a page is rendered at when Dart does not ask for one. */
    const val DEFAULT_MAX_WIDTH = 1400

    /** Guards against a useless or absurd request. */
    const val MIN_MAX_WIDTH = 64
    const val MAX_MAX_WIDTH = 4096

    /** Upper bound on one rendered page, so a malformed page cannot exhaust memory. */
    const val MAX_PIXELS = 12_000_000L

    data class Size(val width: Int, val height: Int)

    /** Clamps a requested width into the range the renderer can honour. */
    @JvmStatic
    fun effectiveMaxWidth(requested: Int?): Int =
        (requested ?: DEFAULT_MAX_WIDTH).coerceIn(MIN_MAX_WIDTH, MAX_MAX_WIDTH)

    /**
     * The pixel size a page of [pageWidth] x [pageHeight] is rendered at, or
     * `null` when the page reports no usable size.
     *
     * The aspect ratio is preserved and a page narrower than [maxWidth] is never
     * upscaled — blowing up a 300 dpi scan only wastes memory. A page that would
     * exceed [MAX_PIXELS] is scaled down further.
     */
    @JvmStatic
    fun targetSize(pageWidth: Int, pageHeight: Int, maxWidth: Int): Size? {
        if (pageWidth <= 0 || pageHeight <= 0) return null
        val limit = maxWidth.coerceAtLeast(1)
        val scale = if (pageWidth <= limit) 1.0 else limit.toDouble() / pageWidth
        var width = max(1, (pageWidth * scale).roundToInt())
        var height = max(1, (pageHeight * scale).roundToInt())
        val pixels = width.toLong() * height.toLong()
        if (pixels > MAX_PIXELS) {
            val factor = sqrt(MAX_PIXELS.toDouble() / pixels.toDouble())
            width = max(1, (width * factor).roundToInt())
            height = max(1, (height * factor).roundToInt())
        }
        return Size(width, height)
    }
}

/**
 * Renders PDF pages to PNG bytes with the platform's [PdfRenderer].
 *
 * The app cannot show a PDF in a WebView (Android's WebView has no PDF viewer),
 * so a PDF bookmark is displayed page by page by this renderer plus a Flutter
 * pager. Everything runs off the platform thread and reports back on it, and
 * every failure mode (missing file, password-protected document, out-of-range
 * page, allocation failure, any thrown `Throwable`) arrives as `null` — the
 * caller shows an error message instead of crashing.
 */
object PdfPageRenderer {

    private const val TAG = "PdfPageRenderer"

    private val main = Handler(Looper.getMainLooper())

    /** One worker: PdfRenderer is not thread-safe and pages are requested in order. */
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "pdf-render").apply { isDaemon = true }
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    /** Wraps [answer] so it runs exactly once, on the platform thread. */
    private fun <T> once(answer: (T) -> Unit): (T) -> Unit {
        val done = AtomicBoolean(false)
        return { value ->
            if (done.compareAndSet(false, true)) {
                onMain { answer(value) }
            }
        }
    }

    /** Number of pages in [path], or 0 when the file cannot be read. */
    fun pageCount(path: String, onDone: (Int) -> Unit) {
        val answer = once(onDone)
        val submitted = try {
            executor.execute {
                var descriptor: ParcelFileDescriptor? = null
                var renderer: PdfRenderer? = null
                val count = try {
                    descriptor = ParcelFileDescriptor.open(
                        File(path),
                        ParcelFileDescriptor.MODE_READ_ONLY,
                    )
                    renderer = PdfRenderer(descriptor)
                    renderer.pageCount
                } catch (t: Throwable) {
                    Log.w(TAG, "pageCount failed for $path", t)
                    0
                } finally {
                    closeQuietly(renderer, descriptor)
                }
                answer(count)
            }
            true
        } catch (t: Throwable) {
            Log.w(TAG, "pageCount could not be queued for $path", t)
            false
        }
        if (!submitted) answer(0)
    }

    /**
     * Renders page [index] (0-based) of [path] at [maxWidth] pixels wide and
     * answers with PNG bytes, or null when it could not be rendered.
     */
    fun renderPage(path: String, index: Int, maxWidth: Int?, onDone: (ByteArray?) -> Unit) {
        val answer = once(onDone)
        if (index < 0) {
            answer(null)
            return
        }
        val submitted = try {
            executor.execute {
                val bytes = try {
                    renderSync(path, index, PdfPageSizing.effectiveMaxWidth(maxWidth))
                } catch (t: Throwable) {
                    Log.w(TAG, "renderPage failed for $path page $index", t)
                    null
                }
                answer(bytes)
            }
            true
        } catch (t: Throwable) {
            Log.w(TAG, "renderPage could not be queued for $path", t)
            false
        }
        if (!submitted) answer(null)
    }

    private fun renderSync(path: String, index: Int, maxWidth: Int): ByteArray? {
        var descriptor: ParcelFileDescriptor? = null
        var renderer: PdfRenderer? = null
        var bitmap: Bitmap? = null
        return try {
            descriptor = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
            renderer = PdfRenderer(descriptor)
            if (index >= renderer.pageCount) return null
            val page = renderer.openPage(index)
            try {
                val size = PdfPageSizing.targetSize(page.width, page.height, maxWidth) ?: return null
                bitmap = Bitmap.createBitmap(size.width, size.height, Bitmap.Config.ARGB_8888)
                // PDF pages are transparent where nothing is drawn; a reader wants
                // white paper, not the app's background.
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val out = ByteArrayOutputStream()
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) return null
                out.toByteArray()
            } finally {
                page.close()
            }
        } finally {
            bitmap?.recycle()
            closeQuietly(renderer, descriptor)
        }
    }

    private fun closeQuietly(renderer: PdfRenderer?, descriptor: ParcelFileDescriptor?) {
        try {
            renderer?.close()
        } catch (t: Throwable) {
            Log.d(TAG, "closing the renderer failed", t)
        }
        try {
            descriptor?.close()
        } catch (t: Throwable) {
            Log.d(TAG, "closing the descriptor failed", t)
        }
    }
}
