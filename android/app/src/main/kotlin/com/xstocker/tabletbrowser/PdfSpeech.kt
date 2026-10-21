package com.xstocker.tabletbrowser

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.UUID

/**
 * Speaks the text the PDF reader hands us through the platform TextToSpeech
 * engine.
 *
 * The reader uses its own channel because speech is bidirectional: `speak` /
 * `stop` / `setRate` come from Dart, and `onStart` / `onDone` / `onError` go back
 * so the highlight can follow the utterance. Each utterance carries an id; the
 * reader ignores callbacks for an older one after the user taps another line.
 */
class PdfSpeech(context: Context, messenger: BinaryMessenger) : TextToSpeech.OnInitListener {

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())

    private var engine: TextToSpeech? = null
    private var ready = false
    private var failed = false
    private var failure = "系统没有可用的语音引擎"
    private var rate = 1.0f
    private var language: Locale? = null

    /** Replaces any previous one: only the latest tap before init should speak. */
    private var pending: Pending? = null

    private data class Pending(val id: String, val text: String, val rate: Float)

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> speak(call, result)
                "setRate" -> setRate(call, result)
                "stop" -> {
                    pending = null
                    try {
                        engine?.stop()
                    } catch (t: Throwable) {
                        Log.d(TAG, "stop failed", t)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        try {
            engine = TextToSpeech(context.applicationContext, this)
        } catch (t: Throwable) {
            failed = true
            failure = t.message ?: failure
            Log.w(TAG, "TextToSpeech could not be created", t)
        }
    }

    override fun onInit(status: Int) {
        if (status != TextToSpeech.SUCCESS) {
            failed = true
            failure = "系统没有可用的语音引擎（初始化失败 $status）"
            pending?.let { emit("onError", it.id) }
            pending = null
            Log.w(TAG, "TextToSpeech init failed: $status")
            return
        }
        ready = true
        try {
            engine?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {
                    emit("onStart", utteranceId.orEmpty())
                }

                override fun onDone(utteranceId: String?) {
                    emit("onDone", utteranceId.orEmpty())
                }

                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) {
                    emit("onError", utteranceId.orEmpty())
                }

                override fun onStop(utteranceId: String?, interrupted: Boolean) {
                    // A tap on another line stops the old utterance; the reader
                    // already switched its highlight to the new id, so "done" is
                    // the honest terminal state for the old one.
                    emit("onDone", utteranceId.orEmpty())
                }
            })
            engine?.setSpeechRate(rate)
        } catch (t: Throwable) {
            failed = true
            failure = t.message ?: failure
            Log.w(TAG, "configuring TextToSpeech failed", t)
            return
        }
        val queued = pending
        pending = null
        if (queued != null) speakNow(queued)
    }

    private fun speak(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text")?.trim().orEmpty()
        if (text.isEmpty()) {
            result.error("invalid_args", "speak requires non-empty 'text'", null)
            return
        }
        val requested = (call.argument<Any?>("rate") as? Number)?.toFloat() ?: rate
        rate = requested.coerceIn(MIN_RATE, MAX_RATE)
        if (failed) {
            result.error("tts_unavailable", failure, null)
            return
        }
        val utterance = Pending(UUID.randomUUID().toString(), text, rate)
        if (!ready) {
            pending = utterance
            result.success(utterance.id)
            return
        }
        pending = null
        speakNow(utterance)
        result.success(utterance.id)
    }

    private fun speakNow(utterance: Pending) {
        val tts = engine
        if (tts == null) {
            emit("onError", utterance.id)
            return
        }
        try {
            applyLanguage(tts, utterance.text)
            tts.setSpeechRate(utterance.rate)
            val queued = tts.speak(
                utterance.text,
                TextToSpeech.QUEUE_FLUSH,
                null,
                utterance.id,
            )
            if (queued == TextToSpeech.ERROR) {
                emit("onError", utterance.id)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "speak failed", t)
            emit("onError", utterance.id)
        }
    }

    /** Picks Chinese for CJK text, otherwise the device language. */
    private fun applyLanguage(tts: TextToSpeech, text: String) {
        val wanted = if (text.any(::isCjk)) Locale.CHINESE else Locale.getDefault()
        if (wanted == language) return
        val status = tts.setLanguage(wanted)
        if (status == TextToSpeech.LANG_MISSING_DATA || status == TextToSpeech.LANG_NOT_SUPPORTED) {
            // Fall back to whatever the engine already uses; speaking with the
            // wrong locale is better than refusing, and a real failure still
            // arrives as onError.
            tts.setLanguage(Locale.getDefault())
        }
        language = wanted
    }

    private fun setRate(call: MethodCall, result: MethodChannel.Result) {
        val requested = (call.argument<Any?>("rate") as? Number)?.toFloat() ?: rate
        rate = requested.coerceIn(MIN_RATE, MAX_RATE)
        pending = pending?.copy(rate = rate)
        try {
            if (ready) engine?.setSpeechRate(rate)
            result.success(rate)
        } catch (t: Throwable) {
            Log.w(TAG, "setSpeechRate failed", t)
            result.success(rate)
        }
    }

    fun release() {
        pending = null
        try {
            channel.setMethodCallHandler(null)
            engine?.stop()
            engine?.shutdown()
        } catch (t: Throwable) {
            Log.d(TAG, "releasing TextToSpeech failed", t)
        }
        engine = null
    }

    private fun emit(method: String, id: String) {
        main.post {
            try {
                channel.invokeMethod(method, mapOf("id" to id))
            } catch (t: Throwable) {
                Log.d(TAG, "speech callback $method/$id failed", t)
            }
        }
    }

    companion object {
        private const val TAG = "PdfSpeech"
        const val CHANNEL = "tablet_browser/pdf_tts"
        private const val MIN_RATE = 0.3f
        private const val MAX_RATE = 3.0f

        private fun isCjk(c: Char): Boolean {
            val code = c.code
            return code in 0x3400..0x9FFF ||
                code in 0xF900..0xFAFF ||
                code in 0x3040..0x30FF ||
                code in 0xAC00..0xD7AF
        }
    }
}
