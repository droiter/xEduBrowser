# Interface contract — tablet_browser

Frozen interfaces between the three parts of the app. Any change here must be
applied on both sides in the same commit.

Package name: `tablet_browser`
Android application id: `com.xstocker.tabletbrowser`

---

## 1. Dart policy engine (authoritative)

Files: `lib/policy/glob.dart`, `lib/policy/policy_config.dart`,
`lib/policy/policy_engine.dart`.

This is the source of truth for filtering semantics. The Kotlin engine is a
faithful port and must agree with it on every vector in
`assets/policy_test_vectors.json`.

Key entry points:

```dart
PolicyConfig.fromJson(Map<String, dynamic> json)
PolicyEngine(config).decide(url)   // -> PolicyDecision
PolicyDecision.allowed             // bool
PolicyDecision.reason.name         // DecisionReason enum name (stable wire name)
PolicyDecision.explanation         // zh-CN sentence for the UI / block page
PolicyEngine.trace(url)            // PolicyTrace, adds pairwise RuleRelation
PatternNormalizer.normalizeUrl(url)
PatternNormalizer.normalizeRulePattern(raw)
```

`DecisionReason` names are part of the wire format shared with Kotlin:
`policyDisabled, unmatchedAllow, unmatchedDeny, whitelistOnly, blacklistOnly,
whitelistMoreSpecific, blacklistMoreSpecific, conflictBlacklistWins,
conflictWhitelistWins, containmentBudgetExceeded`.

---

## 2. Native channel contract (Dart <-> Kotlin)

### Channels

| Channel | Type | Direction |
|---|---|---|
| `tablet_browser/events` | EventChannel | native -> Dart, all views, JSON maps |
| `tablet_browser/commands` | MethodChannel | Dart -> native |
| PlatformView `tablet_browser/webview` | PlatformViewFactory | creation params |

### PlatformView creation params (JSON map)

```json
{
  "viewId": 1,
  "settings": { "javaScript": true, "domStorage": true, "fileAccess": true,
                "allowFileUrlCrossAccess": true, "mediaAutoplay": false,
                "userAgent": null, "textZoom": 100, "blockPageHtml": "<html>..." },
  "policy": { "... PolicyConfig.toJson() ...",
              "localServer": { "port": 8787, "rootPath": "/data/user/0/.../files/site" } }
}
```

`settings.blockPageHtml` is a template rendered by native code for blocked
navigations. Placeholders: `{{URL}}`, `{{REASON}}`, `{{MATCHED}}`, `{{TIME}}`.
Native must HTML-escape substituted values.

### Dart -> native methods on `tablet_browser/commands`

All take a `viewId` (except the global ones) and return a `Map` or `bool`.

| Method | Args | Returns |
|---|---|---|
| `loadUrl` | `viewId`, `url` | `{ok: true}` |
| `goBack` / `goForward` | `viewId` | `{ok, canGoBack, canGoForward}` |
| `reload` / `stopLoading` | `viewId` | `{ok}` |
| `canGoBack` / `canGoForward` | `viewId` | `bool` |
| `currentUrl` / `pageTitle` | `viewId` | `String?` |
| `evaluateJavascript` | `viewId`, `script` | `String?` |
| `setPolicy` | `policy` (map, as above) | `{ok}` |
| `updateSettings` | `viewId`, `settings` (partial map) | `{ok}` |
| `disposeView` | `viewId` | `{ok}` |
| `clearCache` / `clearCookies` / `clearHistory` | — | `{ok}` |
| `userAgent` | `viewId` | `String?` |

### native -> Dart events on `tablet_browser/events`

Each event is a JSON map with a `type` and `viewId`:

| type | extra fields |
|---|---|
| `pageStarted` | `url` |
| `pageFinished` | `url`, `title` |
| `progress` | `progress` (0..100) |
| `titleChanged` | `title` |
| `urlChanged` | `url`, `canGoBack`, `canGoForward` |
| `navigationBlocked` | `url`, `allowed:false`, `reason` (DecisionReason name), `explanation`, `matched:[patterns]` |
| `requestBlocked` | `url`, `resourceType`, `reason`, `explanation`, `matched:[patterns]` |
| `newWindow` | `url` — Dart opens a new tab |
| `pageError` | `code`, `description`, `url` |
| `downloadRequested` | `url`, `userAgent`, `contentDisposition`, `mimeType`, `contentLength` |
| `consoleMessage` | `message`, `level` |

### Enforcement points in Kotlin

1. `WebViewClient.shouldOverrideUrlLoading` — main-frame and subframe
   navigations. When denied, return `true` (cancel) and render the block page
   via `loadDataWithBaseURL`, then emit `navigationBlocked`.
2. `WebViewClient.shouldInterceptRequest` — every subresource. Runs on a
   background thread and **must decide synchronously** with the local Kotlin
   engine; when denied return an empty 403 `WebResourceResponse` and emit
   `requestBlocked`.
3. `WebChromeClient.onCreateWindow` — popups: cancel, emit `newWindow`.
4. `DownloadListener.onDownloadStart` — emit `downloadRequested`, do not start
   the download unless the URL is allowed.

Before evaluating any URL, native applies the local-server mapping: a URL whose
host is `127.0.0.1`/`localhost` and whose port equals
`policy.localServer.port` is evaluated as
`file://<rootPath><pathAndQuery>` so that one set of file-path rules governs
both `file://` browsing and locally served pages.

Dart applies the same mapping (`AppState.policyUrl` / `AppState.decideUrl`,
`mapLoopbackToFileUrl` in `lib/local_server/local_http_server.dart`) before
deciding, and stores bookmark URLs and whitelist rules in that `file://` form.
Local paths are additionally percent-encoded (`lib/files/local_file_url.dart`),
because the filter compares strings and the WebView reports the encoded address.
A rule written in the loopback spelling therefore never matches: existing data
in that form is rewritten to `file://` on startup.

---

## 3. Local HTTP server

`lib/local_server/local_http_server.dart` serves a configured root directory on
`127.0.0.1:<port>` (default 8787). Every request is authorised by the same
`PolicyEngine` via the mapping above; a denied request returns HTTP 403.
Supports GET/HEAD, index.html, directory listing, correct MIME types including
ES modules and WASM, and refuses path traversal outside the root.

---

## 4. Thumbnail capture (added for bookmarks)

Home-page bookmark tiles show a real screenshot of the page, captured from the
native WebView.

| Method | Args | Returns |
|---|---|---|
| `captureThumbnail` | `viewId`, `maxWidth` (int, default 320) | `ByteArray` (PNG bytes) or `null` on failure |

Dart side (`BrowserBridge.captureThumbnail`):

```dart
static Future<Uint8List?> captureThumbnail(int viewId, {int maxWidth = 320}) =>
    _invoke<Uint8List>('captureThumbnail', {'viewId': viewId, 'maxWidth': maxWidth});
```

Requirements for the Kotlin implementation:

- Must run on the **main thread**: `WebView.draw(Canvas)` is a view operation.
  The MethodCallHandler for `captureThumbnail` must post to the main looper and
  answer the `MethodChannel.Result` from there.
- Capture the WebView into an `ARGB_8888` bitmap sized to the view, then scale
  so the width is `maxWidth` preserving aspect ratio (top-aligned crop is fine;
  a bookmark tile is square and shows the top of the page).
- Compress to PNG (`Bitmap.CompressFormat.PNG`, quality 100) and return the
  bytes. Return `null` — never throw — when: the view id is unknown, the view
  is disposed, the bitmap allocation fails, or the capture comes back blank.
- Must not be called off the UI thread by native code itself, and must not
  block the caller beyond the capture.
- The screenshot is a convenience: the Flutter side always has a generated
  fallback tile, so a `null` result must degrade gracefully and never surface
  an error to the user.
