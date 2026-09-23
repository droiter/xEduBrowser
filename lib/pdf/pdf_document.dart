import '../files/local_file_url.dart';

/// Where a page tap lands.
enum PdfTapZone {
  /// Left third: go to the previous page.
  previous,

  /// Right third: go to the next page.
  next,

  /// Middle third: show or hide the reading chrome.
  toggleChrome,
}

/// The page maths of the PDF reader, kept free of Flutter so it is unit
/// testable: which page is current, where a tap lands, and what the indicator
/// says.
class PdfPager {
  PdfPager({required this.pageCount, int index = 0})
      : assert(pageCount >= 0),
        _index = pageCount == 0 ? 0 : index.clamp(0, pageCount - 1);

  final int pageCount;
  int _index;

  /// 0-based index of the page on screen.
  int get index => _index;

  /// 1-based number shown to the reader.
  int get pageNumber => _index + 1;

  bool get isEmpty => pageCount == 0;

  bool get canGoPrevious => _index > 0;

  bool get canGoNext => _index < pageCount - 1;

  /// `3 / 12`, or a placeholder for an unreadable document.
  String get label => isEmpty ? '- / -' : '$pageNumber / $pageCount';

  /// Moves one page back; false when there is nothing to do.
  bool previous() => goTo(_index - 1);

  /// Moves one page forward; false when there is nothing to do.
  bool next() => goTo(_index + 1);

  /// Moves to [target], clamped to the document; false when it changes nothing.
  bool goTo(int target) {
    final clamped = pageCount == 0 ? 0 : target.clamp(0, pageCount - 1);
    if (clamped == _index) return false;
    _index = clamped;
    return true;
  }

  /// Which zone a tap at [dx] of a [width] wide page falls in.
  ///
  /// The outer thirds turn the page, the middle keeps the controls reachable.
  static PdfTapZone zoneForTap(double dx, double width) {
    if (width <= 0) return PdfTapZone.toggleChrome;
    final left = width / 3;
    if (dx < left) return PdfTapZone.previous;
    if (dx > width - left) return PdfTapZone.next;
    return PdfTapZone.toggleChrome;
  }

  /// How far a horizontal drag must travel to count as a page turn.
  static const double swipeThreshold = 48;
}

/// Locates the PDF behind a bookmark address.
abstract final class PdfDocuments {
  /// The local file path of [url] when it names a PDF on this device.
  ///
  /// Returns null for anything else (a remote address, a directory, a page), so
  /// the caller can fall back to the normal WebView.
  static String? localPathOf(String url) {
    if (!LocalFileUrl.isPdf(url)) return null;
    final path = LocalFileUrl.pathOf(url);
    if (path == null || path.isEmpty) return null;
    return path;
  }

  /// The title to show when nothing better is known: the file name.
  static String titleFor(String url, {String fallback = 'PDF'}) {
    final path = localPathOf(url) ?? url;
    final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final slash = trimmed.lastIndexOf('/');
    final name = slash < 0 ? trimmed : trimmed.substring(slash + 1);
    if (name.isEmpty) return fallback;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}
