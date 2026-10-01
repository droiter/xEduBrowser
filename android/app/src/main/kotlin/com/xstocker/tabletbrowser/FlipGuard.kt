package com.xstocker.tabletbrowser

import android.util.Log
import android.webkit.WebView
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature

/**
 * 防翻页 — the transparent mask that swallows the *next* flip after a page turn.
 *
 * The host cannot know that "the page turned": a reader may swap an `<img>`, draw
 * into a `<canvas>`, translate existing pages with a CSS transform, jump the
 * scroll position or push a `#page=7` hash. So the guard does not try to *stop*
 * the turn — it lets the turn happen, notices the symptom it can observe, and
 * then blocks input for a short cool-down, which is what a child actually needs
 * (one page per few seconds, not twelve).
 *
 * Injected **before the page's own scripts run** (document-start), so a reader
 * that binds its handlers on load is still behind the mask. Three parts:
 *
 *  1. **IDLE** — `pointer-events: none` on a fixed, transparent, full-viewport
 *     layer: every tap, swipe and key goes straight to the page, including the
 *     gesture that turns the page.
 *  2. **TURNING** — as soon as a turn is detected the layer flips to
 *     `pointer-events: auto` and eats taps/swipes/clicks/keys. Detection is
 *     deliberately conservative because the mask is a blunt instrument:
 *     * a picture swap — an `img`/`canvas`/`video`/`svg`/`picture` or a
 *       `background-image` element covering at least 55% of the viewport being
 *       added, removed, or having its `src` changed (a picture book replaces the
 *       whole page; a quiz updating a score does not),
 *     * a `hashchange`/`popstate` (`#page=…` readers),
 *     * a turn-ish gesture: a horizontal swipe (≥ 40 px, twice the vertical
 *       movement) locks immediately, and a tap in the outer 12% band locks for a
 *       short *provisional* window (`provisionalMs`) — that window is what stops
 *       the second tap of a fast double tap, and it is what a game loses if the
 *       tap was really a game control instead of a page turn,
 *     * a tap in the outer 26% band or an arrow key *arms* a 1.5 s latch that a
 *       picture of any size appearing/going away, a page-sized scroll jump or a
 *       hash change can confirm — so a mis-tap alone never locks anything and
 *       plain scrolling on a text page stays free; inside a provisional window
 *       the same symptom promotes it to the full cool-down.
 *     The gesture that caused the turn is allowed to finish (a drag-to-turn book
 *     flips on the tail of it); only the *next* gesture is eaten.
 *     Touch/typing inside a focused input is never locked.
 *  3. **COOLING** — the layer stays armed for `flipGuardSeconds` (the mask keeps
 *     re-arming itself in case the page replaces `document.body`), and a small
 *     🔒 chip appears under a blocked gesture so the child sees *why* nothing
 *     happened. Afterwards the layer goes back to `pointer-events: none`.
 *
 * Facts this cannot change: events a page registered on `window` in the capture
 * phase still fire (they are dispatched before hit-testing picks our layer), and
 * audio is not used as a signal because games play sounds for everything.
 */
internal object FlipGuard {

    /** `window.__dshFlipGuard` state key; also the CSS marker of our own nodes. */
    const val MARKER = "data-dsh-flip"

    /** Prefix of the console line the script emits per detected turn (see logcat). */
    const val LOG_PREFIX = "[flipguard]"

    /**
     * Builds the script with the cool-down baked in.
     *
     * [seconds] is the operator's setting (1–600). It is inlined rather than
     * read from the app because the script runs inside the page's world.
     */
    @JvmStatic
    fun scriptFor(seconds: Int): String {
        val ms = seconds.coerceIn(1, 600) * 1000
        return SCRIPT.replace("__COOLDOWN_MS__", ms.toString())
    }

    /**
     * Registers the guard for documents that have not been parsed yet.
     *
     * Returns the handler to keep so the guard can be removed when the setting is
     * switched off, or **null** when this WebView is too old for document-start
     * injection — the caller then falls back to `onPageStarted`. Never throws.
     */
    @JvmStatic
    fun install(webView: WebView, seconds: Int): ScriptHandler? {
        if (!isSupported()) return null
        return try {
            WebViewCompat.addDocumentStartJavaScript(webView, scriptFor(seconds), setOf("*"))
        } catch (t: Throwable) {
            Log.w(TAG, "document-start flip guard could not be installed", t)
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

    /**
     * Rewrites the cool-down of an *already loaded* document (the operator moved
     * the slider). Returns the snippet to evaluate; harmless on a page whose
     * script never ran.
     */
    @JvmStatic
    fun cooldownSnippet(seconds: Int): String =
        "(function(){var g=window.__dshFlipGuard;if(g&&g.setCooldown)g.setCooldown(${seconds.coerceIn(1, 600) * 1000});})()"

    /**
     * Switches a guard that is **already running in the loaded document** on or
     * off, so the toolbar switch takes effect on the page the child is looking at
     * instead of only after the next navigation. Harmless when the script never
     * ran there.
     */
    @JvmStatic
    fun enableSnippet(on: Boolean): String =
        "(function(){var g=window.__dshFlipGuard;if(g&&g.setEnabled)g.setEnabled($on);})()"

    private const val TAG = "FlipGuard"

    /**
     * The injected script. `__COOLDOWN_MS__` is replaced by [scriptFor].
     *
     * Kept ES5 (no template literals, no arrow functions, no `let`) so it also
     * survives an old WebView, and it no-ops on a second injection.
     */
    private val SCRIPT = """
(function () {
  'use strict';
  var CFG = {
    cooldownMs: __COOLDOWN_MS__,
    areaRatio: 0.55,
    scrollRatio: 0.5,
    latchMs: 1500,
    edgeBand: 0.26,
    quickBand: 0.12,
    swipePx: 40,
    tapSlopPx: 12,
    provisionalMs: 700,
    chipMs: 700,
    chipMaxMs: 4000
  };
  if (window.__dshFlipGuard) {
    if (window.__dshFlipGuard.setCooldown) { window.__dshFlipGuard.setCooldown(CFG.cooldownMs); }
    return;
  }

  // Switched from the host: turning the guard off has to take effect in the page
  // that is already open, not only in the next document.
  var enabled = true;
  var coolingUntil = 0;
  var latchUntil = 0;
  var coolTimer = null;
  var ensureTimer = null;
  var chipTimer = null;
  var mask = null;
  var chip = null;
  var start = null;
  var gestureKind = null;
  var passThrough = false;
  var gestureInFlight = false;
  var blockedLogged = false;
  var provisional = false;
  var lastReason = '';

  function mark(el) { try { el.setAttribute('data-dsh-flip', '1'); } catch (e) {} return el; }

  function isOurs(node) {
    if (!node) { return false; }
    var el = node.nodeType === 1 ? node : node.parentElement;
    while (el) {
      if (el.hasAttribute && el.hasAttribute('data-dsh-flip')) { return true; }
      el = el.parentElement;
    }
    return false;
  }

  function vw() {
    return window.innerWidth || (document.documentElement && document.documentElement.clientWidth) || 0;
  }
  function vh() {
    return window.innerHeight || (document.documentElement && document.documentElement.clientHeight) || 0;
  }
  function areaOf(el) {
    try {
      var r = el.getBoundingClientRect();
      if (!r || r.width <= 1 || r.height <= 1) { return 0; }
      return r.width * r.height;
    } catch (e) { return 0; }
  }
  function isPicture(el) {
    if (!el || el.nodeType !== 1) { return false; }
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'img' || tag === 'canvas' || tag === 'video' || tag === 'svg' || tag === 'picture') { return true; }
    try {
      var bg = window.getComputedStyle(el).backgroundImage;
      if (bg && bg !== 'none' && bg.indexOf('url(') >= 0) { return true; }
    } catch (e) {}
    return false;
  }
  /** An element that is (or holds) a page-sized picture. */
  function bigPicture(node) {
    if (!node || node.nodeType !== 1 || isOurs(node)) { return false; }
    var limit = CFG.areaRatio * vw() * vh();
    if (limit <= 0) { return false; }
    if (isPicture(node) && areaOf(node) >= limit) { return true; }
    if (!node.querySelectorAll) { return false; }
    var list = node.querySelectorAll('img,canvas,video,svg,picture');
    for (var i = 0; i < list.length; i++) {
      if (areaOf(list[i]) >= limit) { return true; }
    }
    return false;
  }
  /** Is there a picture of *any* size in this subtree (no area test)? */
  function anyPicture(node) {
    if (!node || node.nodeType !== 1 || isOurs(node)) { return false; }
    if (isPicture(node)) { return true; }
    if (!node.querySelectorAll) { return false; }
    return node.querySelectorAll('img,canvas,video,svg,picture').length > 0;
  }

  /** Typing and dragging a slider must never be interrupted by the mask. */
  function editableFocused() {
    var el = document.activeElement;
    if (!el || el.nodeType !== 1) { return false; }
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'input' || tag === 'textarea' || tag === 'select') { return true; }
    return el.isContentEditable === true;
  }

  function cooling() { return Date.now() < coolingUntil; }
  function latched() { return Date.now() < latchUntil; }
  function latch() { latchUntil = Date.now() + CFG.latchMs; }

  // <html> rather than <body>: position:fixed inside a transformed ancestor is
  // positioned against that ancestor, and reader pages do transform <body>.
  function host() { return document.documentElement || document.body; }

  function block(e) {
    if (!enabled) { return; }
    var t = e.type;
    if (passThrough) {
      // The gesture that *caused* the turn is still in flight: a drag-to-turn
      // book flips on the tail of it, so cutting it off would abort the very
      // turn we allowed. A brand-new gesture is not part of it and gets eaten.
      if (t === 'touchstart' || t === 'pointerdown' || t === 'mousedown') {
        passThrough = false;
        gestureKind = null;
        gestureInFlight = false;
      } else {
        var end = t === 'touchend' || t === 'touchcancel';
        if (gestureKind === 'mouse') {
          end = end || t === 'pointerup' || t === 'pointercancel' || t === 'mouseup';
        }
        if (end) { passThrough = false; gestureKind = null; gestureInFlight = false; }
        return;
      }
    }
    if (!cooling()) { return; }
    try { e.preventDefault(); } catch (x) {}
    try { e.stopImmediatePropagation(); } catch (x) {}
    try { e.stopPropagation(); } catch (x) {}
    if (!blockedLogged && (t === 'touchstart' || t === 'pointerdown' || t === 'mousedown' ||
        t === 'click' || t === 'keydown')) {
      blockedLogged = true;
      showChip();
      say('blocked ' + t);
    }
  }

  function buildMask() {
    var m = document.createElement('div');
    mark(m);
    m.style.cssText = 'position:fixed;left:0;top:0;right:0;bottom:0;width:100%;height:100%;' +
      'margin:0;padding:0;border:0;z-index:2147483647;background:transparent;' +
      'pointer-events:none;touch-action:none;-webkit-user-select:none;user-select:none;' +
      '-webkit-tap-highlight-color:transparent;';
    var types = ['touchstart', 'touchmove', 'touchend', 'touchcancel',
                 'pointerdown', 'pointermove', 'pointerup', 'pointercancel',
                 'mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu',
                 'wheel', 'keydown', 'keypress', 'keyup'];
    for (var i = 0; i < types.length; i++) { m.addEventListener(types[i], block, true); }
    return m;
  }

  function ensureMask() {
    if (!mask || !mask.isConnected) {
      mask = buildMask();
      var h = host();
      if (h) { h.appendChild(mask); }
    }
    return mask;
  }

  function ensureChip() {
    if (!chip || !chip.isConnected) {
      chip = document.createElement('div');
      mark(chip);
      chip.textContent = '🔒 慢一点';
      // Two-tone on purpose: a white pill disappears on the white page of a
      // reader and a black one disappears on its black letterbox (both seen on
      // device). A dark pill with a light ring reads on either background.
      chip.style.cssText = 'position:fixed;left:50%;bottom:28px;transform:translateX(-50%);' +
        'z-index:2147483647;padding:8px 16px;border-radius:18px;' +
        'background:rgba(24,24,24,0.86);color:#fff;' +
        'font:14px/1.2 sans-serif;pointer-events:none;opacity:0;' +
        'border:2px solid rgba(255,255,255,0.92);' +
        'box-shadow:0 2px 12px rgba(0,0,0,0.55);' +
        'transition:opacity .18s;-webkit-user-select:none;user-select:none;';
      var h = host();
      if (h) { h.appendChild(chip); }
    }
    return chip;
  }

  function hideChip() {
    if (chipTimer !== null) { clearTimeout(chipTimer); chipTimer = null; }
    if (chip) { chip.style.opacity = '0'; }
  }

  function showChip() {
    var c = ensureChip();
    if (!c) { return; }
    c.style.opacity = '1';
    if (chipTimer !== null) { clearTimeout(chipTimer); }
    // Old browsers may not know Math.min/max on numbers? They do; keep it simple.
    var left = coolingUntil - Date.now();
    var span = left > CFG.chipMs ? left : CFG.chipMs;
    if (span > CFG.chipMaxMs) { span = CFG.chipMaxMs; }
    chipTimer = setTimeout(hideChip, span);
  }

  function armMask(on) {
    var m = ensureMask();
    if (m) { m.style.pointerEvents = on ? 'auto' : 'none'; }
  }

  function endCooling() {
    coolTimer = null;
    if (cooling()) { coolTimer = setTimeout(endCooling, 60); return; }
    armMask(false);
    hideChip();
    if (ensureTimer !== null) { clearInterval(ensureTimer); ensureTimer = null; }
    say('release');
  }

  /** Turn narration for logcat; the app filters on LOG_PREFIX. */
  function say(msg) {
    try { console.log('[flipguard] ' + msg); } catch (e) {}
  }

  function startCooling(reason, spanMs) {
    if (!enabled) { return; }
    if (editableFocused()) { return; }
    var span = spanMs || CFG.cooldownMs;
    lastReason = reason;
    coolingUntil = Date.now() + span;
    latchUntil = 0;
    // A *provisional* lock is the short window that covers the moment before a
    // page has visibly changed: it stops the second tap of a double tap, but a
    // game whose edge control was pressed only loses that window, not the whole
    // cool-down — unless the page really turned, which promotes it below.
    provisional = span < CFG.cooldownMs;
    blockedLogged = false;
    // Let the gesture that is still on the glass finish (see block()).
    if (gestureInFlight) { passThrough = true; }
    armMask(true);
    if (ensureTimer === null) {
      // The page may replace document.body mid-turn and take the mask with it.
      ensureTimer = setInterval(function () {
        if (!cooling()) { return; }
        armMask(true);
        ensureChip();
      }, 200);
    }
    if (coolTimer !== null) { clearTimeout(coolTimer); }
    coolTimer = setTimeout(endCooling, span + 20);
    say('cool ' + span + 'ms ' + reason);
  }

  /**
   * A turn symptom was observed. Outside a lock it starts the full cool-down;
   * inside a provisional one it promotes that window to the full cool-down.
   */
  function confirm(reason) {
    if (cooling() && !provisional) { return; }
    startCooling(reason, CFG.cooldownMs);
  }

  // --- detection -----------------------------------------------------------

  function onMutation(records) {
    if (!enabled) { return; }
    if (editableFocused()) { return; }
    if (cooling() && !provisional) { return; }
    for (var i = 0; i < records.length; i++) {
      var r = records[i];
      if (isOurs(r.target)) { continue; }
      if (r.type === 'attributes') {
        if (r.attributeName === 'src' && bigPicture(r.target)) { confirm('picture-src'); return; }
        continue;
      }
      var n;
      for (n = 0; r.addedNodes && n < r.addedNodes.length; n++) {
        if (bigPicture(r.addedNodes[n])) { confirm('picture-added'); return; }
        if (latched() && anyPicture(r.addedNodes[n])) { confirm('latch-picture'); return; }
      }
      for (n = 0; r.removedNodes && n < r.removedNodes.length; n++) {
        if (bigPicture(r.removedNodes[n])) { confirm('picture-removed'); return; }
        if (latched() && anyPicture(r.removedNodes[n])) { confirm('latch-picture'); return; }
      }
    }
  }

  var lastScroll = -1;

  function onScroll() {
    if (!enabled) { return; }
    var moved = Math.abs(window.scrollY || 0) + Math.abs(window.scrollX || 0);
    if (lastScroll < 0) { lastScroll = moved; return; }
    var delta = Math.abs(moved - lastScroll);
    lastScroll = moved;
    if (delta < CFG.scrollRatio * vh()) { return; }
    // Only ever *confirms* an armed turn-ish gesture: plain scrolling a text page
    // must not lock the next swipe.
    if (!latched()) { return; }
    confirm('scroll-jump');
  }

  function onHash() {
    if (!enabled) { return; }
    confirm('hash');
  }

  function pointOf(e) {
    if (e.touches && e.touches.length) { return { x: e.touches[0].clientX, y: e.touches[0].clientY }; }
    if (e.changedTouches && e.changedTouches.length) {
      return { x: e.changedTouches[0].clientX, y: e.changedTouches[0].clientY };
    }
    return { x: e.clientX, y: e.clientY };
  }

  function onDown(e) {
    if (!enabled || cooling()) { return; }
    if (gestureKind === null) {
      var t = e.type;
      gestureKind = (t.indexOf('touch') === 0 || e.pointerType === 'touch') ? 'touch' : 'mouse';
    }
    gestureInFlight = true;
    var p = pointOf(e);
    start = { x: p.x, y: p.y, y0: p.y, moved: 0 };
  }

  function horizontal(p, dx, dy) {
    return Math.abs(dx) >= CFG.swipePx && Math.abs(dx) >= 2 * Math.abs(dy);
  }

  function onMove(e) {
    if (!enabled || cooling() || !start) { return; }
    var p = pointOf(e);
    var dx = p.x - start.x;
    var dy = p.y - start.y;
    start.moved = Math.max(start.moved, Math.abs(dx) + Math.abs(dy));
    if (horizontal(p, dx, dy)) { start = null; startCooling('swipe', CFG.cooldownMs); }
  }

  function onUp(e) {
    if (!enabled || cooling()) { return; }
    var p = pointOf(e);
    var s = start;
    start = null;
    gestureInFlight = false;
    if (!passThrough) { gestureKind = null; }
    if (s && !(s.moved < CFG.tapSlopPx)) {
      if (horizontal(p, p.x - s.x, p.y - s.y)) { startCooling('swipe', CFG.cooldownMs); }
      return;
    }
    var w = vw();
    if (w <= 0) { return; }
    var x = p.x;
    if (x <= w * CFG.quickBand || x >= w * (1 - CFG.quickBand)) {
      latch();
      startCooling('edge-tap', CFG.provisionalMs);
      return;
    }
    if (x <= w * CFG.edgeBand || x >= w * (1 - CFG.edgeBand)) { latch(); }
  }

  function onKey(e) {
    if (!enabled || cooling()) { return; }
    var k = e.key || '';
    if (k === 'PageUp' || k === 'PageDown' || k === 'Home' || k === 'End') { confirm('page-key'); return; }
    if (k === 'ArrowLeft' || k === 'ArrowRight' || k === ' ' || k === 'Enter') { latch(); }
  }

  function listen(target, type, fn, opts) {
    try { target.addEventListener(type, fn, opts); } catch (e) {}
  }

  listen(document, 'touchstart', onDown, true);
  listen(document, 'pointerdown', onDown, true);
  listen(document, 'mousedown', onDown, true);
  listen(document, 'touchmove', onMove, true);
  listen(document, 'pointermove', onMove, true);
  listen(document, 'touchcancel', function () { gestureInFlight = false; start = null; }, true);
  listen(document, 'touchend', onUp, true);
  listen(document, 'pointerup', onUp, true);
  listen(document, 'mouseup', onUp, true);
  listen(document, 'keydown', onKey, true);
  listen(window, 'scroll', onScroll, true);
  listen(window, 'hashchange', onHash, false);
  listen(window, 'popstate', onHash, false);
  listen(window, 'touchstart', block, true);
  listen(window, 'touchmove', block, true);
  listen(window, 'touchend', block, true);
  listen(window, 'pointerdown', block, true);
  listen(window, 'pointerup', block, true);
  listen(window, 'click', block, true);
  listen(window, 'keydown', block, true);

  try {
    var observer = new MutationObserver(onMutation);
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src']
    });
  } catch (e) {}

  window.__dshFlipGuard = {
    version: 1,
    script: 'flipguard',
    cooling: cooling,
    latched: latched,
    lastReason: function () { return lastReason; },
    remainingMs: function () { return Math.max(0, coolingUntil - Date.now()); },
    setCooldown: function (ms) { CFG.cooldownMs = ms; },
    enabled: function () { return enabled; },
    setEnabled: function (on) {
      var want = on !== false;
      if (want === enabled) { return; }
      enabled = want;
      if (!enabled) {
        // Let go of everything at once: a page that keeps blocking after the
        // switch was turned off looks like a broken page.
        coolingUntil = 0;
        latchUntil = 0;
        provisional = false;
        passThrough = false;
        gestureInFlight = false;
        if (coolTimer !== null) { clearTimeout(coolTimer); coolTimer = null; }
        if (ensureTimer !== null) { clearInterval(ensureTimer); ensureTimer = null; }
        armMask(false);
        hideChip();
        say('disabled');
      } else {
        say('enabled');
      }
    },
    turn: function (reason) { startCooling(reason || 'manual'); },
    config: CFG
  };
})();
""".trimIndent()
}
