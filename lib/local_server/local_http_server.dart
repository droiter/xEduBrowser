import 'dart:async';
import 'dart:io';

import '../policy/policy_engine.dart';

/// Serves a local directory over `http://127.0.0.1:<port>` so that local
/// *dynamic* pages work properly.
///
/// Why a server instead of plain `file://`: browser security rules make
/// `fetch`, `XMLHttpRequest`, ES modules and web workers unreliable or
/// impossible from `file://` origins. Serving the same directory from
/// loopback gives those pages a normal http origin, so interactive local apps
/// (dashboards, offline courseware, test harnesses) behave the way they do on
/// a real site — while still being fully offline.
///
/// Every request is authorised by the same [PolicyEngine] that governs online
/// browsing: a local URL is mapped to the file path it represents, so one set
/// of file rules covers both `file://` browsing and locally served pages.
class LocalHttpServer {
  /// Default port. Chosen to be uncommon to avoid clashes with other apps.
  static const int defaultPort = 8787;

  final PolicyEngine Function() policyProvider;
  final void Function(Map<String, dynamic> event)? onEvent;

  HttpServer? _server;
  int _port;

  /// Directory being served. Changing it takes effect on the next request.
  String rootPath;

  LocalHttpServer({
    required this.policyProvider,
    required this.rootPath,
    int port = defaultPort,
    this.onEvent,
    // A named parameter cannot be private, and the port is only writable from
    // start(), once the real bound port is known.
    // ignore: prefer_initializing_formals
  }) : _port = port;

  bool get isRunning => _server != null;

  int get port => _port;

  /// The base URL pages are reached at, or null when not running.
  String? get baseUrl => _server == null ? null : 'http://127.0.0.1:$_port';

  /// Starts the server. Returns the bound port, or null when the bind failed
  /// (for example the port is taken — then the next free port is tried).
  Future<int?> start({int? port}) async {
    if (_server != null) return _port;
    final preferred = port ?? _port;
    for (var candidate = preferred; candidate < preferred + 10; candidate++) {
      try {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, candidate, shared: false);
        _server = server;
        // The bind may have picked an ephemeral port (candidate == 0), so
        // always report the port actually bound.
        _port = server.port;
        unawaited(_serve(server));
        onEvent?.call({'type': 'localServerStarted', 'port': _port, 'root': rootPath});
        return _port;
      } on SocketException {
        continue;
      }
    }
    onEvent?.call({'type': 'localServerFailed', 'port': preferred});
    return null;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    onEvent?.call({'type': 'localServerStopped'});
  }

  /// Maps a loopback URL back to the file URL it represents, or null when the
  /// URL does not belong to this server.
  String? fileUrlFor(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.host != '127.0.0.1' && uri.host != 'localhost') return null;
    if (uri.port != _port) return null;
    final path = uri.path.isEmpty ? '/' : uri.path;
    final root = rootPath.endsWith('/')
        ? rootPath.substring(0, rootPath.length - 1)
        : rootPath;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    return 'file://$root$path$query';
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      try {
        await _handle(request);
      } catch (error) {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.headers.contentType = ContentType.text;
          request.response.write('本地服务器错误：$error');
          await request.response.close();
        } catch (_) {
          // client already gone
        }
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final method = request.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }

    final relative = _sanitize(request.uri.path);
    if (relative == null) {
      response.statusCode = HttpStatus.forbidden;
      response.headers.contentType = ContentType.text;
      response.write('路径越界，已拒绝。');
      await response.close();
      return;
    }

    final fullPath = relative.isEmpty ? rootPath : '$rootPath/$relative';
    final fileUrl = 'file://$fullPath';

    // Local pages are filtered exactly like remote ones. The decision is made
    // against the *file* URL so that rules written as file paths govern both
    // `file://` browsing and locally served pages.
    final decision = policyProvider().decide(fileUrl);
    if (!decision.allowed) {
      response.statusCode = HttpStatus.forbidden;
      response.headers.contentType = ContentType.html;
      response.write(_blockedHtml(fileUrl, decision));
      await response.close();
      onEvent?.call({
        'type': 'requestBlocked',
        'url': 'http://127.0.0.1:$_port/${request.uri.path}',
        'resourceType': 'localServer',
        'reason': decision.reason.name,
        'explanation': decision.explanation,
        'matched': [for (final m in decision.decisiveRules) m.rule.pattern],
      });
      return;
    }

    var target = fullPath;
    if (await FileSystemEntity.isDirectory(target)) {
      final candidate = '$target/index.html';
      if (await File(candidate).exists()) {
        target = candidate;
      } else {
        response.headers.contentType = ContentType.html;
        response.write(await _directoryListing(relative, target));
        await response.close();
        return;
      }
    }

    final file = File(target);
    if (!await file.exists()) {
      response.statusCode = HttpStatus.notFound;
      response.headers.contentType = ContentType.html;
      response.write(_notFoundHtml(relative));
      await response.close();
      return;
    }

    response.headers.contentType = _mimeType(target);
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    if (method == 'HEAD') {
      response.headers.contentLength = await file.length();
      await response.close();
      return;
    }
    await response.addStream(file.openRead());
    await response.close();
  }

  /// Normalises a request path into a relative path inside the root, or null
  /// when it escapes the root.
  String? _sanitize(String rawPath) {
    final decoded = Uri.decodeComponent(rawPath);
    final segments = <String>[];
    for (final segment in decoded.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isEmpty) return null;
        segments.removeLast();
        continue;
      }
      if (segment.contains('\u0000')) return null;
      segments.add(segment);
    }
    final joined = segments.join('/');
    return joined;
  }

  Future<String> _directoryListing(String relative, String directoryPath) async {
    final directory = Directory(directoryPath);
    final entries = await directory.list(followLinks: false).toList()
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    final buffer = StringBuffer()
      ..write('<!doctype html><html lang="zh"><head><meta charset="utf-8">')
      ..write('<meta name="viewport" content="width=device-width,initial-scale=1">')
      ..write('<title>本地文件 · /$relative</title>')
      ..write('<style>body{font-family:system-ui,-apple-system,"Noto Sans SC",sans-serif;'
          'margin:0;padding:24px;background:#faf9f7;color:#1c1b1a}'
          'h1{font-size:18px;margin:0 0 16px}a{display:block;padding:10px 12px;'
          'border-radius:8px;color:#1c1b1a;text-decoration:none}'
          'a:hover{background:#eee9e3}code{color:#6b6560;font-size:12px}</style></head><body>')
      ..write('<h1>目录：/${_escapeHtml(relative)}</h1>');
    final parent = relative.contains('/')
        ? relative.substring(0, relative.lastIndexOf('/'))
        : '';
    if (relative.isNotEmpty) {
      buffer.write('<a href="/${_escapeHtml(parent)}">⬆️ 返回上级</a>');
    }
    for (final entity in entries) {
      final name = entity.path.split('/').last;
      final isDir = entity is Directory;
      final href = relative.isEmpty ? name : '$relative/$name';
      buffer.write(
        '<a href="/${_escapeHtml(href)}${isDir ? '/' : ''}">'
        '${isDir ? '📁' : '📄'} ${_escapeHtml(name)}</a>',
      );
    }
    buffer.write('</body></html>');
    return buffer.toString();
  }

  String _blockedHtml(String fileUrl, PolicyDecision decision) {
    final matched = decision.decisiveRules.isEmpty
        ? '—'
        : decision.decisiveRules.map((m) => m.rule.pattern).join('、');
    return '<!doctype html><html lang="zh"><head><meta charset="utf-8">'
        '<title>已拦截</title></head><body style="font-family:system-ui,sans-serif;padding:24px">'
        '<h1>403 · 本地页面被名单拦截</h1>'
        '<p><b>地址</b>：${_escapeHtml(fileUrl)}</p>'
        '<p><b>原因</b>：${_escapeHtml(decision.explanation)}</p>'
        '<p><b>命中名单</b>：${_escapeHtml(matched)}</p>'
        '</body></html>';
  }

  String _notFoundHtml(String relative) => '<!doctype html><html lang="zh"><head>'
      '<meta charset="utf-8"><title>404</title></head><body '
      'style="font-family:system-ui,sans-serif;padding:24px">'
      '<h1>404 · 本地文件不存在</h1><p>/${_escapeHtml(relative)}</p>'
      '<p>根目录：${_escapeHtml(rootPath)}</p></body></html>';

  String _escapeHtml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static ContentType _mimeType(String path) {
    final name = path.toLowerCase();
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1);
    switch (extension) {
      case 'html':
      case 'htm':
        return ContentType.html;
      case 'js':
      case 'mjs':
        return ContentType('text', 'javascript', charset: 'utf-8');
      case 'css':
        return ContentType('text', 'css', charset: 'utf-8');
      case 'json':
      case 'map':
        return ContentType('application', 'json', charset: 'utf-8');
      case 'wasm':
        return ContentType('application', 'wasm');
      case 'svg':
        return ContentType('image', 'svg+xml');
      case 'png':
        return ContentType('image', 'png');
      case 'jpg':
      case 'jpeg':
        return ContentType('image', 'jpeg');
      case 'gif':
        return ContentType('image', 'gif');
      case 'webp':
        return ContentType('image', 'webp');
      case 'ico':
        return ContentType('image', 'x-icon');
      case 'woff':
        return ContentType('font', 'woff');
      case 'woff2':
        return ContentType('font', 'woff2');
      case 'ttf':
        return ContentType('font', 'ttf');
      case 'txt':
      case 'md':
      case 'csv':
        return ContentType.text;
      case 'xml':
        return ContentType('application', 'xml', charset: 'utf-8');
      case 'pdf':
        return ContentType('application', 'pdf');
      case 'mp4':
        return ContentType('video', 'mp4');
      case 'webm':
        return ContentType('video', 'webm');
      case 'mp3':
        return ContentType('audio', 'mpeg');
      default:
        return ContentType.binary;
    }
  }
}

/// The JSON form shared with the native layer, so it can apply the identical
/// loopback-to-file mapping when gating subresource requests.
Map<String, dynamic> localServerDescriptor(LocalHttpServer? server) => {
      'port': server?.port ?? -1,
      'rootPath': server?.rootPath ?? '',
    };

/// Encodes the mapping rule once, for Dart-side decision making.
String? mapLoopbackToFileUrl(String url, Map<String, dynamic> localServer) {
  final port = localServer['port'];
  final root = localServer['rootPath'];
  if (port is! int || port <= 0 || root is! String || root.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (uri.host != '127.0.0.1' && uri.host != 'localhost') return null;
  if (uri.port != port) return null;
  final trimmedRoot = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  final query = uri.hasQuery ? '?${uri.query}' : '';
  return 'file://$trimmedRoot${uri.path.isEmpty ? '/' : uri.path}$query';
}
