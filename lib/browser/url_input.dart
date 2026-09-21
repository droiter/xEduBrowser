/// Turns whatever the user typed into a URL the browser can load.
///
/// Deliberately has no search-engine fallback: this is a managed browser, and
/// silently sending typed text to a third party would defeat the filtering.
class ResolvedInput {
  final String url;
  final String? error;
  final bool isLocalFile;

  const ResolvedInput(this.url, {this.error, this.isLocalFile = false});
}

abstract final class UrlResolver {
  static const String homeUrl = 'about:home';

  static bool hasScheme(String text) => RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:').hasMatch(text);

  /// Resolves [raw] into a loadable URL.
  ///
  /// [localServerBase] and [localRoot] let a local file be served over
  /// loopback instead of `file://`, which is what makes dynamic local pages
  /// (fetch/XHR/ES modules) work. They may be null when the server is off.
  static ResolvedInput resolve(
    String raw, {
    String? localServerBase,
    String? localRoot,
  }) {
    final text = raw.trim();
    if (text.isEmpty) return const ResolvedInput(homeUrl);

    if (text.startsWith('about:')) return ResolvedInput(text);

    // A file URL inside the served root is better reached over loopback, so
    // that local dynamic pages keep working.
    if (text.startsWith('file://')) {
      final served = localServerUrlFor(
        Uri.decodeComponent(text.substring('file://'.length)),
        base: localServerBase,
        root: localRoot,
      );
      return ResolvedInput(served ?? text, isLocalFile: true);
    }

    if (text.contains('://')) return ResolvedInput(text);

    // Absolute filesystem path.
    if (text.startsWith('/')) {
      final served = localServerUrlFor(text, base: localServerBase, root: localRoot);
      return ResolvedInput(served ?? 'file://$text', isLocalFile: true);
    }

    // A bare "host", "host:port" or "host/path".
    final looksLikeHost = RegExp(r'^[^\s/?#]+\.[^\s/?#]+').hasMatch(text) ||
        RegExp(r'^localhost(:\d+)?(/|$)').hasMatch(text) ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/|$)').hasMatch(text);
    if (looksLikeHost || text.contains('.')) {
      final scheme = _guessScheme(text);
      return ResolvedInput('$scheme://$text');
    }

    return ResolvedInput(
      '',
      error: '无法识别的地址：请输入完整网址（例如 example.com）或本地文件路径。',
    );
  }

  /// Maps a filesystem path inside the served root onto its loopback URL.
  static String? localServerUrlFor(
    String path, {
    String? base,
    String? root,
  }) {
    if (base == null || root == null || root.isEmpty) return null;
    final trimmedRoot = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    if (!path.startsWith(trimmedRoot)) return null;
    var rest = path.substring(trimmedRoot.length);
    if (!rest.startsWith('/')) rest = '/$rest';
    return '$base$rest';
  }

  static String _guessScheme(String text) {
    if (text.startsWith('localhost') || text.startsWith('127.0.0.1')) return 'http';
    final hostPart = text.split('/').first;
    if (hostPart.contains(':')) return 'http';
    return 'https';
  }

  /// What to display in the address bar for a loaded URL.
  static String displayFor(String url) {
    if (url == homeUrl) return '';
    if (url.startsWith('file://')) return Uri.decodeComponent(url.substring(7));
    return url;
  }
}
