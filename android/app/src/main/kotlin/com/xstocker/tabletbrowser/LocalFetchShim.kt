package com.xstocker.tabletbrowser

import android.webkit.WebView
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import android.util.Log

/**
 * The opt-in `fetch` → XHR compatibility patch for local pages.
 *
 * Chromium refuses `fetch()` for `file:` URLs — the request is rejected before
 * it leaves the renderer — while an `XMLHttpRequest` for the very same file
 * succeeds (Android's `allowFileAccessFromFileURLs` covers XHR, not fetch). A
 * local page that loads its own data with `fetch` therefore renders nothing at
 * all, which is impossible to tell apart from "the page is broken".
 *
 * [SCRIPT] is injected **before the page's own scripts run**, so a page that
 * calls `fetch` at the top of its bundle still gets the patched version. It
 * patches nothing except `file:` URLs coming from a `file:` document: http(s)
 * requests are handed to the original `fetch` untouched, and a page loaded over
 * the loopback server is left completely alone.
 *
 * The patch is deliberately small and honest about what it cannot do: the
 * response body is produced from the whole XHR body, so `Response.body`
 * (a `ReadableStream`) and streaming/chunked progress are not reproduced, though
 * `text()`, `json()`, `arrayBuffer()` and `blob()` all work. It is off by
 * default (see `WebViewSettings.localFetchShim`).
 */
internal object LocalFetchShim {

    /**
     * Registers [SCRIPT] for documents that have not been parsed yet.
     *
     * Returns the handler to keep so the patch can be removed again when the
     * setting is switched off, or **null** when the installed WebView is too old
     * for document-start injection — the caller then falls back to injecting
     * [SCRIPT] from `onPageStarted`. Never throws: a WebView that cannot take the
     * script simply does not get it.
     */
    @JvmStatic
    fun install(webView: WebView): ScriptHandler? {
        if (!isSupported()) return null
        return try {
            WebViewCompat.addDocumentStartJavaScript(webView, SCRIPT, setOf("*"))
        } catch (t: Throwable) {
            Log.w(TAG, "document-start fetch shim could not be installed", t)
            null
        }
    }

    /** Whether document-start injection is available in the installed WebView. */
    @JvmStatic
    fun isSupported(): Boolean = try {
        WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
    } catch (t: Throwable) {
        false
    }

    private const val TAG = "LocalFetchShim"

    /**
     * The patch itself. Written to be safe to run in any frame:
     *
     * * it does nothing unless the document is `file:` and `fetch` exists;
     * * it marks the window so a second injection is a no-op;
     * * it only intercepts URLs whose scheme is `file:`, resolving relative ones
     *   against `document.baseURI` exactly like the native `fetch` would;
     * * it honours `method`, `headers`, `body` and `signal` (abort), and rebuilds
     *   `Response` — including status, status text and headers — from the XHR.
     */
    @JvmStatic
    val SCRIPT: String = """
(function () {
  if (window.__dshLocalFetchShim) return;
  if (location.protocol !== 'file:') return;
  if (typeof window.fetch !== 'function') return;
  var nativeFetch = window.fetch;
  window.__dshLocalFetchShim = true;
  window.fetch = function (input, init) {
    var url = '';
    try {
      url = (typeof input === 'string') ? input : ((input && input.url) || '');
      if (url) url = new URL(url, document.baseURI).href;
    } catch (e) {
      url = '';
    }
    if (url.indexOf('file:') !== 0) return nativeFetch.apply(this, arguments);

    init = init || {};
    var signal = init.signal;
    if (signal && signal.aborted) {
      return Promise.reject(new DOMException('The operation was aborted.', 'AbortError'));
    }
    var xhr = new XMLHttpRequest();
    xhr.open(init.method || 'GET', url, true);
    var headers = init.headers;
    if (headers) {
      if (typeof headers.forEach === 'function') {
        headers.forEach(function (value, name) { xhr.setRequestHeader(name, value); });
      } else {
        Object.keys(headers).forEach(function (name) { xhr.setRequestHeader(name, headers[name]); });
      }
    }
    xhr.responseType = 'arraybuffer';
    return new Promise(function (resolve, reject) {
      xhr.onload = function () {
        var out = new Headers();
        (xhr.getAllResponseHeaders() || '').trim().split(/[\r\n]+/).forEach(function (line) {
          var at = line.indexOf(':');
          if (at > 0) out.append(line.slice(0, at).trim(), line.slice(at + 1).trim());
        });
        resolve(new Response(xhr.response, {
          status: xhr.status || 200,
          statusText: xhr.statusText,
          headers: out
        }));
      };
      xhr.onerror = function () { reject(new TypeError('Failed to fetch')); };
      xhr.ontimeout = function () { reject(new TypeError('Failed to fetch')); };
      xhr.onabort = function () {
        reject(new DOMException('The operation was aborted.', 'AbortError'));
      };
      if (signal) signal.addEventListener('abort', function () { xhr.abort(); });
      try {
        xhr.send(init.body === undefined ? null : init.body);
      } catch (e) {
        reject(e);
      }
    });
  };
})();
""".trimIndent()
}
