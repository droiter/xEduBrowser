/// The HTML rendered by the native layer when a navigation is denied.
///
/// Kept in Dart so the look matches the app and can be changed without
/// touching Kotlin. The native side substitutes the placeholders after
/// HTML-escaping every value.
abstract final class BlockPageTemplate {
  static const String html = r'''<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>访问被拦截</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
         font-family: system-ui,-apple-system,"Noto Sans SC","Segoe UI",sans-serif;
         background:#faf9f7; color:#1c1b1a; padding:32px; }
  @media (prefers-color-scheme: dark) {
    body { background:#141414; color:#ececec; }
    .card { background:#1e1e1e !important; border-color:#2e2e2e !important; }
    .url { background:#262626 !important; color:#d8d8d8 !important; }
    .hint { color:#9a9a9a !important; }
  }
  .card { max-width:720px; width:100%; background:#fff; border:1px solid #e6e1db;
          border-radius:20px; padding:36px 40px; box-shadow:0 1px 3px rgba(0,0,0,.04); }
  .badge { display:inline-flex; align-items:center; gap:8px; font-size:13px; font-weight:600;
           letter-spacing:.02em; color:#b3261e; background:#fdeceb;
           border-radius:999px; padding:6px 12px; }
  h1 { font-size:26px; margin:20px 0 8px; letter-spacing:-.01em; }
  .hint { color:#6b6560; font-size:15px; line-height:1.7; margin:0 0 24px; }
  .field { margin:0 0 14px; }
  .label { font-size:12px; text-transform:uppercase; letter-spacing:.06em; color:#8a837c;
           margin-bottom:6px; }
  .url { display:block; background:#f4f1ed; border-radius:10px; padding:12px 14px;
         font-family: ui-monospace,SFMono-Regular,Menlo,monospace; font-size:13px;
         word-break:break-all; color:#2b2926; }
  .reason { font-size:15px; line-height:1.7; }
  .matched { display:flex; flex-wrap:wrap; gap:8px; margin-top:6px; }
  .chip { font-family: ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px;
          background:#eef2f6; color:#26374a; border-radius:8px; padding:6px 10px;
          word-break:break-all; }
  .chip.blacklist { background:#fdeceb; color:#8c1d18; }
  .chip.whitelist { background:#e7f4ec; color:#1c5b34; }
  .foot { margin-top:28px; padding-top:20px; border-top:1px solid #eee9e3;
          font-size:12px; color:#8a837c; display:flex; justify-content:space-between; gap:16px;
          flex-wrap:wrap; }
</style>
</head>
<body>
  <main class="card">
    <span class="badge">⛔ 已按名单策略拦截</span>
    <h1>这个页面不允许访问</h1>
    <p class="hint">当前设备启用了网址黑白名单。该地址命中了一条黑名单规则，或未被任何白名单规则覆盖。</p>

    <div class="field">
      <div class="label">请求地址</div>
      <code class="url">{{URL}}</code>
    </div>

    <div class="field">
      <div class="label">判定结果</div>
      <div class="reason">{{REASON}}</div>
    </div>

    <div class="field">
      <div class="label">命中名单</div>
      <div class="matched">{{MATCHED}}</div>
    </div>

    <div class="foot">
      <span>判定时间：{{TIME}}</span>
      <span>如需访问，请联系管理员调整黑白名单。</span>
    </div>
  </main>
</body>
</html>''';
}
