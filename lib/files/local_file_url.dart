import 'dart:io';

/// Canonical `file://` URLs.
///
/// The filter compares strings, so a local page must be written down exactly the
/// way the WebView reports it back. The WebView percent-encodes the spaces and
/// the non-ASCII characters of a file path (`/sdcard/课件/第 1 课.html` becomes
/// `/sdcard/%E8%AF%BE%E4%BB%B6/%E7%AC%AC%201%20%E8%AF%BE.html`), so a bookmark or
/// a whitelist rule holding the raw path never matches the request it was meant
/// to allow — the page opens blocked no matter how it was whitelisted.
///
/// Everything that turns a filesystem path into a URL goes through
/// [canonical], so the rule and the navigation always agree.
abstract final class LocalFileUrl {
  static const String _scheme = 'file://';

  /// Whether [text] is a `file://` URL.
  static bool isFileUrl(String text) => text.startsWith(_scheme);

  /// The absolute filesystem path behind a `file://` URL (or behind a bare
  /// absolute path), decoded. Returns null when [text] is not a local path.
  static String? pathOf(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    if (!isFileUrl(trimmed)) return trimmed.startsWith('/') ? trimmed : null;
    final rest = trimmed.substring(_scheme.length);
    // `file://host/path` is not a local path on Android; only the plain
    // `file:///path` (empty authority) form is.
    if (!rest.startsWith('/')) return null;
    try {
      return Uri.decodeComponent(rest);
    } catch (_) {
      // A stray `%` is a literal percent sign, not an escape.
      return rest;
    }
  }

  /// The canonical URL for a path or an existing `file://` URL, keeping any
  /// `?query` (a query names a different resource, and the local server maps it
  /// through unchanged).
  ///
  /// Idempotent: an already canonical URL comes back byte-identical, so it is
  /// safe to apply wherever a value might have been canonicalised before.
  static String canonical(String pathOrUrl) {
    final trimmed = pathOrUrl.trim();
    // Split the query off *before* decoding: the separating `?` is a literal
    // one, while a `%3F` inside the path belongs to the file name.
    final queryStart = trimmed.indexOf('?');
    final beforeQuery =
        queryStart < 0 ? trimmed : trimmed.substring(0, queryStart);
    final query = queryStart < 0 ? '' : trimmed.substring(queryStart);
    final path = pathOf(beforeQuery) ?? beforeQuery;
    final withSlash = path.startsWith('/') ? path : '/$path';
    return '${Uri.file(withSlash)}$query';
  }

  /// Whether [pathOrUrl] names a PDF file.
  ///
  /// PDFs are not shown in a WebView (Android's WebView has no PDF viewer), so
  /// the caller opens them in the built-in page-by-page reader instead.
  static bool isPdf(String pathOrUrl) {
    final path = pathOf(pathOrUrl) ?? pathOrUrl.trim();
    return path.toLowerCase().endsWith('.pdf');
  }

  /// Whether [url] points at a directory on this device.
  static bool isDirectory(String url) {
    final path = pathOf(url);
    return path != null && path.isNotEmpty && Directory(path).existsSync();
  }

  /// The `index.html` of a local directory, or null when it has none.
  ///
  /// The same rule the built-in local server applies, so "open this folder"
  /// means the same thing in the preview, in the add dialog and over loopback.
  static String? indexHtmlFor(String url) {
    final path = pathOf(url);
    if (path == null || path.isEmpty) return null;
    final base = path.endsWith('/') ? path : '$path/';
    final index = File('${base}index.html');
    return index.existsSync() ? canonical(index.path) : null;
  }

  /// A whole directory as a prefix rule, with the trailing slash that keeps it
  /// from matching a sibling directory whose name merely starts the same way.
  static String directoryPattern(String directoryPath) {
    final canonical = LocalFileUrl.canonical(directoryPath);
    return canonical.endsWith('/') ? canonical : '$canonical/';
  }
}
