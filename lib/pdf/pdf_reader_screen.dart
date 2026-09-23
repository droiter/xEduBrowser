import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../browser/browser_bridge.dart';
import 'pdf_document.dart';

/// Test hooks.
const Key pdfPreviousButtonKey = ValueKey<String>('pdf-previous');
const Key pdfNextButtonKey = ValueKey<String>('pdf-next');
const Key pdfPageIndicatorKey = ValueKey<String>('pdf-page-indicator');

/// A PDF bookmark, read page by page.
///
/// Android's WebView cannot display a PDF, so the native side renders one page
/// at a time (`renderPdfPage`) and this screen pages through them:
///
///  * tap the left third → previous page, right third → next page, middle →
///    show/hide the reading chrome;
///  * swipe (or drag) left/right to turn the page;
///  * the bar at the bottom shows `当前页 / 总页数` and has explicit
///    previous/next buttons for accessibility.
///
/// Rendering happens off the platform thread; a page that fails to render shows
/// a message instead of an empty area, and nothing here writes to the document.
class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({super.key, required this.url, this.title = ''});

  /// The bookmark address (`file://…/x.pdf` or a plain path).
  final String url;

  /// Bookmark title, shown when it is not empty.
  final String title;

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  /// How many rendered pages are kept around, so back-and-forth stays instant.
  static const int _cacheLimit = 4;

  /// Rendered page width in pixels; the platform renderer caps this too.
  static const int _renderWidth = 1400;

  late final String _path = PdfDocuments.localPathOf(widget.url) ?? widget.url;

  final PageController _pages = PageController();
  final Map<int, Uint8List> _images = {};
  final List<int> _cacheOrder = [];
  final Set<int> _inFlight = {};

  /// Pages the platform could not render (corrupt page, out of memory): shown
  /// with a retry instead of an endless spinner.
  final Set<int> _failed = {};

  PdfPager _pager = PdfPager(pageCount: 0);
  bool _loadingDocument = true;
  String? _documentError;
  bool _chromeVisible = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDocument());
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _loadDocument() async {
    final count = await BrowserBridge.pdfPageCount(_path);
    if (!mounted) return;
    setState(() {
      _loadingDocument = false;
      if (count <= 0) {
        _documentError = '这个 PDF 打不开：文件可能不存在、已损坏或需要密码。';
        return;
      }
      _pager = PdfPager(pageCount: count);
    });
    if (count > 0) _prefetch(0);
  }

  /// Renders [index] if it is not cached yet, and remembers it.
  void _prefetch(int index) {
    if (index < 0 || index >= _pager.pageCount) return;
    if (_images.containsKey(index) || !_inFlight.add(index)) return;
    unawaited(() async {
      try {
        final bytes = await BrowserBridge.renderPdfPage(
          _path,
          index,
          maxWidth: _renderWidth,
        );
        if (!mounted) return;
        if (bytes == null || bytes.isEmpty) {
          setState(() => _failed.add(index));
          return;
        }
        setState(() {
          _failed.remove(index);
          _putImage(index, bytes);
        });
      } finally {
        _inFlight.remove(index);
      }
    }());
  }

  /// Stores a rendered page, dropping the oldest ones beyond [_cacheLimit].
  void _putImage(int index, Uint8List bytes) {
    _images[index] = bytes;
    _cacheOrder
      ..remove(index)
      ..add(index);
    while (_cacheOrder.length > _cacheLimit) {
      final dropped = _cacheOrder.removeAt(0);
      _images.remove(dropped);
    }
  }

  void _goTo(int target) {
    if (!_pager.goTo(target)) return;
    setState(() {});
    if (_pages.hasClients) {
      _pages.animateToPage(
        _pager.index,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  void _onPageChanged(int index) {
    _pager.goTo(index);
    setState(() {});
    _prefetch(index);
    _prefetch(index + 1);
    _prefetch(index - 1);
  }

  void _onTapUp(TapUpDetails details, double width) {
    switch (PdfPager.zoneForTap(details.localPosition.dx, width)) {
      case PdfTapZone.previous:
        _goTo(_pager.index - 1);
      case PdfTapZone.next:
        _goTo(_pager.index + 1);
      case PdfTapZone.toggleChrome:
        setState(() => _chromeVisible = !_chromeVisible);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _chromeVisible ? AppBar(title: Text(_titleLine)) : null,
      body: SafeArea(child: _body(context)),
      bottomNavigationBar: _chromeVisible ? _bottomBar(context) : null,
    );
  }

  String get _titleLine {
    final named = widget.title.trim();
    if (named.isNotEmpty) return named;
    return PdfDocuments.titleFor(widget.url);
  }

  Widget _body(BuildContext context) {
    if (_loadingDocument) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _documentError;
    if (error != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.picture_as_pdf_outlined, color: Colors.white70, size: 40),
                const SizedBox(height: 12),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  _path,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final width = MediaQuery.of(context).size.width;
    return PageView.builder(
      controller: _pages,
      itemCount: _pager.pageCount,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, index) {
        final bytes = _images[index];
        final Widget page;
        if (_failed.contains(index)) {
          page = _FailedPage(
            index: index,
            onRetry: () {
              setState(() => _failed.remove(index));
              _prefetch(index);
            },
          );
        } else if (bytes == null) {
          page = _Rendering(index: index);
        } else {
          // No InteractiveViewer here: it would compete with the PageView for
          // horizontal drags, and swiping is how pages are turned.
          page = Center(
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          );
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _onTapUp(details, width),
          child: page,
        );
      },
    );
  }

  Widget _bottomBar(BuildContext context) {
    return BottomAppBar(
      color: Colors.black87,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            key: pdfPreviousButtonKey,
            tooltip: '上一页',
            color: Colors.white,
            onPressed: _pager.canGoPrevious ? () => _goTo(_pager.index - 1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _pager.label,
              key: pdfPageIndicatorKey,
              style: const TextStyle(color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          IconButton(
            key: pdfNextButtonKey,
            tooltip: '下一页',
            color: Colors.white,
            onPressed: _pager.canGoNext ? () => _goTo(_pager.index + 1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text(
              '点左侧/右侧翻页，中间显示或隐藏工具栏',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder while a page is being rendered.
class _Rendering extends StatelessWidget {
  const _Rendering({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Colors.white54),
          const SizedBox(height: 16),
          Text(
            '正在渲染第 ${index + 1} 页…',
            style: const TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

/// A page the renderer could not produce.
class _FailedPage extends StatelessWidget {
  const _FailedPage({required this.index, required this.onRetry});

  final int index;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 36),
          const SizedBox(height: 12),
          Text(
            '第 ${index + 1} 页渲染失败',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
