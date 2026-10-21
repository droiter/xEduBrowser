package com.xstocker.tabletbrowser

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min

/**
 * Extracts the text layer of a PDF page, with line coordinates, for the reader's
 * tap-to-speak feature.
 *
 * [android.graphics.pdf.PdfRenderer] can only produce bitmaps, so PDFBox-Android
 * (the AWT-free Android port of PDFBox 2.0) parses the same file and hands back
 * one entry per rendered line. Coordinates are normalised to 0..1 in display
 * orientation (top-left origin, page rotation already applied), which is exactly
 * what Flutter needs to hit-test a tap and paint the highlight over the bitmap.
 *
 * Everything runs off the platform thread. Any failure — missing file, password,
 * malformed document, a PDFBox limitation — answers `null`, and the reader simply
 * has no spoken text for that page; it never crashes.
 */
object PdfTextExtractor {

    private const val TAG = "PdfTextExtractor"

    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "pdf-text").apply { isDaemon = true }
    }

    @Volatile
    private var resourcesReady = false

    /** One parsed document, reused for every page of the same file. */
    private var loadedPath: String? = null
    private var loadedDocument: PDDocument? = null

    /** PDFBox-Android reads glyph/cmap resources from the APK's assets. */
    fun init(context: Context) {
        if (resourcesReady) return
        try {
            PDFBoxResourceLoader.init(context.applicationContext)
            resourcesReady = true
        } catch (t: Throwable) {
            Log.w(TAG, "PDFBox resource loader init failed", t)
        }
    }

    /**
     * Extracts page [index] (0-based) of [path] and answers on the platform
     * thread with `{width, height, lines}` or null.
     */
    fun pageText(path: String, index: Int, onDone: (Map<String, Any?>?) -> Unit) {
        val answered = AtomicBoolean(false)
        val answer: (Map<String, Any?>?) -> Unit = { value ->
            if (answered.compareAndSet(false, true)) main.post { onDone(value) }
        }
        if (path.isEmpty() || index < 0) {
            answer(null)
            return
        }
        val submitted = try {
            executor.execute {
                val value = try {
                    extract(path, index)
                } catch (t: Throwable) {
                    Log.w(TAG, "text extraction failed for $path page $index", t)
                    closeDocument()
                    null
                }
                answer(value)
            }
            true
        } catch (t: Throwable) {
            Log.w(TAG, "text extraction could not be queued for $path", t)
            false
        }
        if (!submitted) answer(null)
    }

    private fun extract(path: String, index: Int): Map<String, Any?>? {
        val document = documentFor(path) ?: return null
        if (index < 0 || index >= document.numberOfPages) return null
        val page = document.getPage(index)

        // The display size: TextPosition x/y already run along the rotated
        // page, so width/height swap for 90/270.
        val rotation = ((page.rotation % 360) + 360) % 360
        val crop = page.cropBox
        val rawWidth = crop.width.toDouble()
        val rawHeight = crop.height.toDouble()
        val rotated = rotation == 90 || rotation == 270
        val displayWidth = if (rotated) rawHeight else rawWidth
        val displayHeight = if (rotated) rawWidth else rawHeight
        if (displayWidth <= 0.0 || displayHeight <= 0.0) return null

        val stripper = LineStripper()
        stripper.setSortByPosition(true)
        stripper.startPage = index + 1
        stripper.endPage = index + 1
        stripper.getText(document)

        val lines = stripper.lines
            .mapNotNull { line ->
                val left = (line.left / displayWidth).coerceIn(0.0, 1.0)
                val top = (line.top / displayHeight).coerceIn(0.0, 1.0)
                val right = (line.right / displayWidth).coerceIn(0.0, 1.0)
                val bottom = (line.bottom / displayHeight).coerceIn(0.0, 1.0)
                if (right <= left || bottom <= top) return@mapNotNull null
                mapOf<String, Any?>(
                    "text" to line.text,
                    "left" to left,
                    "top" to top,
                    "right" to right,
                    "bottom" to bottom,
                )
            }
            .sortedWith(compareBy({ it["top"] as Double }, { it["left"] as Double }))

        return mapOf(
            "width" to displayWidth,
            "height" to displayHeight,
            "lines" to lines,
        )
    }

    /** Loads [path] once and keeps it for the following pages. */
    private fun documentFor(path: String): PDDocument? {
        if (loadedPath == path && loadedDocument != null) return loadedDocument
        closeDocument()
        val document = PDDocument.load(File(path))
        loadedPath = path
        loadedDocument = document
        return document
    }

    /** Closes the cached document; queued on the extraction thread. */
    fun close() {
        try {
            executor.execute { closeDocument() }
        } catch (t: Throwable) {
            Log.d(TAG, "could not queue document close", t)
        }
    }

    private fun closeDocument() {
        try {
            loadedDocument?.close()
        } catch (t: Throwable) {
            Log.d(TAG, "closing PDF document failed", t)
        }
        loadedDocument = null
        loadedPath = null
    }

    private data class Line(
        val text: String,
        val left: Float,
        val top: Float,
        val right: Float,
        val bottom: Float,
    )

    /** Collects one bounding box per line PDFBox writes out. */
    private class LineStripper : PDFTextStripper() {
        val lines = mutableListOf<Line>()

        @Throws(IOException::class)
        override fun writeString(text: String?, textPositions: List<TextPosition>?) {
            val value = text?.trim().orEmpty()
            if (value.isEmpty() || textPositions.isNullOrEmpty()) return
            var left = Float.MAX_VALUE
            var top = Float.MAX_VALUE
            var right = -Float.MAX_VALUE
            var bottom = -Float.MAX_VALUE
            for (position in textPositions) {
                left = min(left, position.xDirAdj)
                top = min(top, position.yDirAdj)
                right = max(right, position.xDirAdj + position.widthDirAdj)
                bottom = max(bottom, position.yDirAdj + position.heightDir)
            }
            if (right > left && bottom > top) {
                lines.add(Line(value, left, top, right, bottom))
            }
        }
    }
}
