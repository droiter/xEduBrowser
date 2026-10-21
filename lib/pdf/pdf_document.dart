import 'dart:typed_data';

import '../browser/browser_bridge.dart';
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

/// One line of text on a PDF page, in coordinates normalised to 0…1 with the
/// origin at the page's top-left corner (rotation already applied).
///
/// The native side groups glyphs into lines and hands back the line's bounding
/// box; the reader uses it both to hit-test a tap and to paint the highlight
/// while the line is being spoken.
class PdfTextLine {
  const PdfTextLine({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  bool contains(double x, double y) {
    // A couple of pixels of slack makes a finger tap on a short line feel
    // reliable without stealing taps from the page-turn zones.
    const double slack = 0.008;
    return x >= left - slack &&
        x <= right + slack &&
        y >= top - slack &&
        y <= bottom + slack;
  }

  static PdfTextLine? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final String text = (raw['text'] as String? ?? '').trim();
    if (text.isEmpty) return null;
    double coord(Object? value) =>
        ((value as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
    final left = coord(raw['left']);
    final top = coord(raw['top']);
    final right = coord(raw['right']);
    final bottom = coord(raw['bottom']);
    if (right <= left || bottom <= top) return null;
    return PdfTextLine(
      text: text,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
  }
}

/// The text layer of one PDF page: display size (rotation applied) and its lines.
class PdfPageText {
  const PdfPageText({
    required this.width,
    required this.height,
    required this.lines,
  });

  /// Page width/height in points, in display orientation. Used as the aspect
  /// ratio of the rendered bitmap.
  final double width;
  final double height;
  final List<PdfTextLine> lines;

  bool get hasText => lines.isNotEmpty;

  double get aspectRatio =>
      width > 0 && height > 0 ? height / width : 1.0;

  /// The line under a tap given in normalised page coordinates, if any.
  PdfTextLine? lineAt(double x, double y) {
    for (final line in lines) {
      if (line.contains(x, y)) return line;
    }
    return null;
  }

  static PdfPageText? fromMap(Map<String, dynamic> raw) {
    final width = (raw['width'] as num?)?.toDouble() ?? 0;
    final height = (raw['height'] as num?)?.toDouble() ?? 0;
    final lines = <PdfTextLine>[];
    for (final item in (raw['lines'] as List? ?? const <Object?>[])) {
      final line = PdfTextLine.fromMap(item);
      if (line != null) lines.add(line);
    }
    if (width <= 0 || height <= 0) {
      if (lines.isEmpty) return null;
      // The page size is only needed for the bitmap aspect ratio; a document
      // without it can still be spoken, so fall back to the line extents.
      double maxRight = 0;
      double maxBottom = 0;
      for (final line in lines) {
        if (line.right > maxRight) maxRight = line.right;
        if (line.bottom > maxBottom) maxBottom = line.bottom;
      }
      return PdfPageText(
        width: maxRight <= 0 ? 1 : maxRight,
        height: maxBottom <= 0 ? 1 : maxBottom,
        lines: lines,
      );
    }
    return PdfPageText(width: width, height: height, lines: lines);
  }
}

/// Locates the PDF behind a bookmark address.
abstract final class PdfDocuments {
  /// Width used for a PDF bookmark's first-page preview.
  static const int thumbnailWidth = 480;

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

  /// Renders page 0 of [url] as the bookmark tile's preview image.
  ///
  /// Android's WebView cannot show a PDF, so the same native page renderer the
  /// reader uses produces the PNG. Null means the document could not be read;
  /// the caller keeps the generated monogram.
  static Future<Uint8List?> captureThumbnail(
    String url, {
    int maxWidth = thumbnailWidth,
  }) async {
    final path = localPathOf(url);
    if (path == null) return null;
    return BrowserBridge.renderPdfPage(path, 0, maxWidth: maxWidth);
  }

  /// Extracts the text layer of page [index], or null when it has no readable
  /// text / the document cannot be parsed.
  static Future<PdfPageText?> pageText(String url, int index) async {
    final path = localPathOf(url);
    if (path == null || index < 0) return null;
    final raw = await BrowserBridge.pdfPageText(path, index);
    if (raw == null) return null;
    return PdfPageText.fromMap(raw);
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
