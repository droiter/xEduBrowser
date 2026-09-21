# Android native layer — implementation notes

Companion to [`CONTRACT.md`](CONTRACT.md) section 2. Everything below lives in
`android/app/src/main/kotlin/com/xstocker/tabletbrowser/`.

## Files

| File | Purpose |
|---|---|
| `policy/Glob.kt` | Glob NFA (`*`, `?`, `\x`, implicit trailing `*`) and exact language containment (`GlobContainment.isSubset`). Pure JVM. |
| `policy/PolicyEngine.kt` | Config model, `PatternNormalizer`, `CompiledRule`, `PolicyEngine.decide/trace/relationBetween/shadowedRules`, `DecisionReason` wire names, loopback → `file://` mapping. Pure JVM. |
| `PolicyBridge.kt` | Shared state: the `@Volatile` engine snapshot, the `tablet_browser/events` sink, the `viewId` registry, global cache/cookie/history commands. |
| `PolicyWebView.kt` | The `WebView` platform view, its settings snapshot, the block-page renderer, and every enforcement point. |
| `ThumbnailCapture.kt` | `captureThumbnail` (CONTRACT.md section 4): `ThumbnailSizing` is the pure-JVM sizing/blank rule, `ThumbnailCapture` renders the current frame to a scaled PNG. |
| `PolicyWebViewFactory.kt` | `tablet_browser/webview` factory: decodes `viewId` / `settings` / `policy`. |
| `MainActivity.kt` | Registers the factory, creates both channels, dispatches `tablet_browser/commands` on the platform thread. |

## Threading

* `PolicyEngine` configuration is immutable; `PolicyBridge` swaps whole engines
  through a `@Volatile` field, so a decision never sees a half-applied policy.
* `WebViewClient.shouldInterceptRequest` runs on a WebView worker thread. It
  decides synchronously against that snapshot, never touches the `WebView`, and
  never posts-and-waits on the platform thread. Events produced there are
  handed to `PolicyBridge.emit`, which marshals `EventSink.success` onto the
  main looper.
* Every `tablet_browser/commands` call is handled on the platform thread;
  `evaluateJavascript` answers asynchronously from the WebView's own callback.
* `captureThumbnail` is the one command that is *posted* to the main looper
  rather than run inline, because `WebView.draw(Canvas)` is a view operation.
  The post is fire-and-forget — nothing ever waits on the platform thread — and
  the `MethodChannel.Result` is answered from inside the posted runnable, behind
  an `AtomicBoolean` guard (in `MainActivity` and again in `PolicyBridge`) so a
  result can never be delivered twice.
* The engine memoises containment results in a `ConcurrentHashMap`.

## Enforcement points

| # | Callback | Behaviour |
|---|---|---|
| 1 | `shouldOverrideUrlLoading` (new + legacy overloads) | Main-frame **and** subframe navigations are decided. A denial cancels the load (`true`), emits `navigationBlocked`, and — for main frames only — renders the block page. Denying a subframe only cancels that frame: replacing the main document would destroy the page around it. |
| 2 | `shouldInterceptRequest` | Every gated request (`http`, `https`, `file`) is decided; a denial returns `WebResourceResponse("text/plain", "utf-8", 403, …, empty body)` and emits `requestBlocked` with `resourceType` `mainFrame`/`subresource`. Other schemes (`data:`, `blob:`, `about:`, `javascript:`, `content:`) pass through untouched. |
| 3 | `onCreateWindow` | The popup is never displayed. `<a target="_blank">` supplies its href via `hitTestResult`; `window.open(...)` is captured with a throwaway `WebView` fed from the `WebViewTransport`. Either way exactly one `newWindow` event is emitted, with an `about:blank` fallback after 750 ms if the URL cannot be captured. |
| 4 | `DownloadListener.onDownloadStart` | Always emits `downloadRequested` (contract fields plus `allowed`/`reason`); a denied URL additionally emits `requestBlocked` with `resourceType: "download"` and is never handed to `DownloadManager`. An allowed URL is enqueued into the app-private external downloads directory, with the page's cookies attached. |
| — | `loadUrl` command | Flutter-initiated navigations go through the same gate as in-page ones. |

## Settings

Creation params and `updateSettings` feed one `WebViewSettings` snapshot, applied
with `WebSettings`: `javaScript`, `domStorage`, `databaseEnabled = true`,
`fileAccess`, `allowFileUrlCrossAccess` → `allowFileAccessFromFileURLs` +
`allowUniversalAccessFromFileURLs`, `mediaAutoplay` →
`mediaPlaybackRequiresUserGesture = !mediaAutoplay`, `userAgent` (blank restores
the platform default), `textZoom` (clamped to 1..1000), images always loaded,
`setGeolocationEnabled(false)`, `saveFormData = false`,
`setSupportMultipleWindows(true)` (required for enforcement point 3), and
`mixedContentMode = MIXED_CONTENT_COMPATIBILITY_MODE`.
Geolocation prompts and `getUserMedia` requests are denied.

## Block page

`settings.blockPageHtml` is a template rendered by `BlockPageRenderer` with
`{{URL}}`, `{{REASON}}`, `{{MATCHED}}` and `{{TIME}}`; every substituted value is
HTML-escaped (`& < > " '`) before insertion, and the result is loaded with
`loadDataWithBaseURL(null, …)`. With no template the renderer emits a built-in
`prefers-color-scheme` aware page (light and dark).

## Loopback mapping

`PolicyConfig.localServer {port, rootPath}` maps
`http://127.0.0.1:<port>/<path>[?query]` (also `localhost`, `[::1]`, and the
schemeless `127.0.0.1:…` / `localhost:…` forms) to
`file://<rootPath><path>[?query]` before normalisation, so one set of file-path
rules governs both `file://` browsing and locally served pages. Fragments are
dropped, queries kept. Without a `localServer` entry nothing is mapped.

## Commands

Every method of CONTRACT.md section 2 is implemented, with the documented return
types (`canGoBack`/`canGoForward` → `bool`, `currentUrl`/`pageTitle`/`userAgent`
→ `String?`, `evaluateJavascript` → `String?`, everything else → `Map`).
`setPolicy` accepts the whole payload (`PolicyConfig.toJson()` plus
`localServer`). One extra method, `openManageStorageSettings`, is handled because
the Dart bridge already calls it: it opens the system screen that grants
`MANAGE_EXTERNAL_STORAGE`.

Note for the Dart side: `BrowserBridge._call` casts every result to
`Map<dynamic, dynamic>`, so the four non-map methods above must be invoked with a
plain `invokeMethod` when they are first used (`evaluateJavascript` is currently
declared but never called).

A `policy` supplied at platform-view creation replaces the shared engine, i.e.
views share one policy — matching a policy that is global in the app.

## Thumbnail capture

`captureThumbnail` (CONTRACT.md section 4) implements the bookmark tiles:

| Method | Args | Returns |
|---|---|---|
| `captureThumbnail` | `viewId` (int), `maxWidth` (int, default 320) | PNG `ByteArray`, or `null` |

Sequence: the command handler reads `viewId` and `maxWidth`, then
`PolicyBridge.captureThumbnail` posts one runnable to the main looper. The
runnable looks the view up in the registry and calls
`PolicyWebView.captureThumbnail` → `ThumbnailCapture.capture`, which

1. returns `null` when the view is disposed or is `0` in either dimension;
2. allocates one `ARGB_8888` bitmap the size of the view and `draw`s the frame
   the WebView is *already* showing — no re-layout, no invalidate, and no
   deprecated drawing-cache calls;
3. reads at most 8×8 sampled pixels; if every sample is fully transparent
   (nothing was rendered) the capture is treated as blank and `null` is
   returned. A white or black page is opaque and therefore captured normally;
4. scales with `Bitmap.createScaledBitmap` to `maxWidth`, preserving the aspect
   ratio and rounding the height to nearest (never below 1 px), then compresses
   with `CompressFormat.PNG` at quality 100 into a `ByteArrayOutputStream`;
5. recycles the scaled and source bitmaps (skipping the second recycle when
   scaling returned the source itself) and returns the bytes.

`maxWidth` is clamped to 16..4096 by `ThumbnailSizing.effectiveMaxWidth`, so a
stray value cannot ask for a useless or absurd bitmap.

Failures never cross the channel: unknown `viewId`, a disposed view, a
zero-size view, a failed bitmap allocation (`OutOfMemoryError` is an `Error`,
not an `Exception`), a blank capture and any other `Throwable` all answer
`null` — including a `viewId` argument that is missing or not a number, which
is the single deviation from the `invalid_args` / `unknown_view` errors the
other per-view commands raise. The Flutter side always has a generated fallback
tile, so a `null` must never surface as an error. Only debug-level `Log.d`
lines are emitted. The block page is captured like any other document.

Note for the Dart side: `captureThumbnail` answers raw bytes rather than a map,
so it must be invoked through the untyped `BrowserBridge._invoke<Uint8List>`
path (exactly as CONTRACT.md section 4 declares it) — a helper that casts the
result to `Map` would throw on the PNG payload.

## Tests

`android/app/src/test/kotlin/com/xstocker/tabletbrowser/PolicyVectorsTest.kt`
asserts every vector of `assets/policy_test_vectors.json` (copied byte-identically
to `android/app/src/test/resources/`): one JUnit case per `cases` entry
(`allowed` **and** the `reason` wire name) and one per `relations` entry
(`a ⊆ b` via `GlobContainment`). `LoopbackMappingTest` covers the loopback
mapping.

`ThumbnailSizingTest.kt` covers the `captureThumbnail` maths: `maxWidth`
defaulting and clamping, the scaled size (aspect ratio preserved, no upscaling,
height rounded to nearest and never below 1 px, `null` for a zero-size view) and
the blank rule. `ThumbnailSizing` is pure JVM on purpose, so these run with the
rest of the suite; the `Bitmap`/`WebView` plumbing around it needs a device.
`:app:testDebugUnitTest` after this change: 642 tests (627 before), 0 failures.

`DartCrossCheckTest.kt` is a differential test against the authoritative Dart
engine: `src/test/resources/dart_cross_check.json` holds 14 configurations × 40
URLs (560 cases) with the `allowed`, `reason` and `normalizedUrl` the Dart engine
produced, so matching, URL normalisation and the containment-driven specificity
resolution are all checked, not just the final verdict. Regenerate the fixture
with a throwaway Dart script whenever `lib/policy` changes:

```dart
import 'dart:convert';
import 'dart:io';
import 'file:///root/tablet_browser/lib/policy/policy_config.dart';
import 'file:///root/tablet_browser/lib/policy/policy_engine.dart';

void main() {
  final configs = <String, Map<String, dynamic>>{ /* config name -> config json */ };
  final urls = <String>[ /* urls */ ];
  final cases = <Map<String, dynamic>>[];
  configs.forEach((name, cfg) {
    final engine = PolicyEngine(PolicyConfig.fromJson(cfg));
    for (final url in urls) {
      final d = engine.decide(url);
      cases.add({'config': name, 'url': url, 'allowed': d.allowed,
                 'reason': d.reason.name, 'normalizedUrl': d.normalizedUrl});
    }
  });
  File('android/app/src/test/resources/dart_cross_check.json').writeAsStringSync(
      JsonEncoder().convert({'configs': configs, 'cases': cases}));
}
```

```
cd android && ./gradlew :app:testDebugUnitTest --console=plain
```

## Build configuration

* `minSdk 24`, `compileSdk/targetSdk 36`, `applicationId`/`namespace`
  `com.xstocker.tabletbrowser` (CONTRACT.md).
* `testOptions.unitTests` enables `src/test/resources`, and
  `org.json:json:20240303` + `junit:junit:4.13.2` are on the unit-test classpath
  (android.jar only ships stubs of `org.json`).
* `android/build.gradle.kts` normalises every Android subproject to
  `compileSdk 36`: some Flutter plugins (`jni`, `jni_flutter`) pin 35, which this
  SDK installation does not contain.
* `app/build.gradle.kts` declares the missing `copyFlutterAssets<Variant>`
  dependency of the unit-test packaging tasks, which Gradle 9 otherwise rejects.
* `gradle.properties` pins `-Dfile.encoding=UTF-8` for the Gradle JVM so test
  reports can be written on hosts with a non-UTF-8 default locale.
