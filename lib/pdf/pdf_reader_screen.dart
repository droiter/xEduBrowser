import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../browser/browser_bridge.dart';
import 'pdf_document.dart';
import 'pdf_speech.dart';

/// Test hooks.
const Key pdfPreviousButtonKey = ValueKey<String>('pdf-previous');
const Key pdfNextButtonKey = ValueKey<String>('pdf-next');
const Key pdfPageIndicatorKey = ValueKey<String>('pdf-page-indicator');
const Key pdfSpeechHighlightKey = ValueKey<String>('pdf-speech-highlight');

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

  /// The page whose bytes the platform is rendering right now, if any.
  ///
  /// Requests go out **one at a time**. The platform renderer is a single
  /// worker, so queueing every page the reader flips past built a backlog that
  /// the page on screen had to wait behind: the reader then sat on 「正在渲染
  /// 第 N 页」 for as long as the backlog took, and going away and back worked
  /// only because the page had been rendered in the meantime.
  int? _rendering;

  /// Pages to render after [_rendering], most wanted first.
  ///
  /// Never more than the page on screen and its two neighbours: a page change
  /// rebuilds this list, dropping whatever the reader has already left behind.
  final List<int> _renderQueue = [];

  /// Renders started so far. A reply from a request the reader has given up on
  /// (see [_renderTimeout]) carries an older token and is ignored.
  int _renderSeq = 0;

  Timer? _renderWatchdog;

  /// How long a render may stay unanswered before it is treated as failed.
  ///
  /// A healthy render takes well under a second, and opening a very large
  /// document is the slow part on the platform side; this only catches a wedged
  /// renderer, turning an endless spinner into a 重试 button.
  static const Duration _renderTimeout = Duration(seconds: 20);

  /// A frame post-callback that re-requests the page on screen is already
  /// scheduled (see [_healCurrentPage]), so build never schedules two.
  bool _healScheduled = false;

  /// Pages the platform could not render (corrupt page, out of memory): shown
  /// with a retry instead of an endless spinner.
  final Set<int> _failed = {};

  /// Text layers, extracted per page on demand. A page with no text (a scan)
  /// simply has no entry, and taps fall back to the page-turn zones.
  final Map<int, PdfPageText> _pageTexts = {};
  final Set<int> _textInFlight = {};
  final Set<int> _textFailed = {};

  /// Rendered bitmap aspect ratios (height / width), used to place the text
  /// highlight even before the text layer has loaded.
  final Map<int, double> _aspects = {};

  /// Reader speech settings and the line currently being spoken.
  double _speechRate = 1.0;
  int? _speakingPage;
  PdfTextLine? _speakingLine;
  String? _utteranceId;

  PdfPager _pager = PdfPager(pageCount: 0);
  bool _loadingDocument = true;
  String? _documentError;
  bool _chromeVisible = true;

  @override
  void initState() {
    super.initState();
    PdfSpeech.onEvent = _onSpeechEvent;
    unawaited(_loadDocument());
  }

  @override
  void dispose() {
    _renderWatchdog?.cancel();
    _renderWatchdog = null;
    // Invalidate a reply that is still on its way: the widget is gone.
    _renderSeq++;
    PdfSpeech.onEvent = null;
    unawaited(PdfSpeech.stop());
    unawaited(BrowserBridge.closePdfText());
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
    if (count > 0) {
      _wantPage(0);
      _prefetchText(0);
    }
  }

  /// Asks for [index] to be rendered: at the front of the queue when [urgent].
  ///
  /// Cached, failed, queued and currently-rendering pages are left alone, so
  /// repeated calls (a rebuild, a page that is already on its way) cost nothing.
  void _requestRender(int index, {bool urgent = false}) {
    if (index < 0 || index >= _pager.pageCount) return;
    if (_images.containsKey(index) || _rendering == index) return;
    _renderQueue.remove(index);
    if (urgent) {
      _renderQueue.insert(0, index);
    } else {
      _renderQueue.add(index);
    }
    _pumpRenders();
  }

  /// Makes the pages around [index] the ones to render: [index] first, then its
  /// neighbours. Everything else queued is stale and dropped — that is what
  /// keeps a fast flip from stacking up a backlog.
  void _wantPage(int index) {
    _renderQueue.clear();
    for (final int page in <int>[index, index + 1, index - 1]) {
      if (page < 0 || page >= _pager.pageCount) continue;
      if (_images.containsKey(page) || _failed.contains(page)) continue;
      if (_rendering == page || _renderQueue.contains(page)) continue;
      _renderQueue.add(page);
    }
    _pumpRenders();
  }

  /// An explicit 重试 from the user: drop whatever is rendering and ask for
  /// [index] right away. The abandoned request's reply is ignored by its token,
  /// so a slow page cannot keep the retried one waiting.
  void _retryRender(int index) {
    setState(() => _failed.remove(index));
    if (_rendering != null) {
      _renderWatchdog?.cancel();
      _renderWatchdog = null;
      _renderSeq++;
      _rendering = null;
    }
    _renderQueue.remove(index);
    _requestRender(index, urgent: true);
  }

  /// Starts the next queued render, if the platform is idle.
  void _pumpRenders() {
    if (!mounted || _rendering != null) return;
    while (_renderQueue.isNotEmpty) {
      final int index = _renderQueue.removeAt(0);
      if (_images.containsKey(index) || _failed.contains(index)) continue;
      _startRender(index);
      return;
    }
  }

  /// Renders [index] and stores the result; never leaves the page in limbo.
  void _startRender(int index) {
    _rendering = index;
    final int token = ++_renderSeq;
    _renderWatchdog?.cancel();
    _renderWatchdog = Timer(_renderTimeout, () {
      if (!mounted || token != _renderSeq) return;
      // The platform never answered: show a retry instead of a spinner that can
      // never end, and let the next page render.
      _renderWatchdog = null;
      _rendering = null;
      _renderSeq++;
      setState(() => _failed.add(index));
      _pumpRenders();
    });
    unawaited(() async {
      Uint8List? rendered;
      try {
        rendered = await BrowserBridge.renderPdfPage(
          _path,
          index,
          maxWidth: _renderWidth,
        );
      } catch (_) {
        // A channel-level failure is the same "cannot render" as null.
        rendered = null;
      }
      // A reply that belongs to a request this reader has abandoned (or to a
      // reader that is gone) must not touch the state.
      if (!mounted || token != _renderSeq) return;
      _renderWatchdog?.cancel();
      _renderWatchdog = null;
      _rendering = null;
      final Uint8List? bytes = rendered;
      if (bytes == null || bytes.isEmpty) {
        setState(() => _failed.add(index));
      } else {
        setState(() {
          _failed.remove(index);
          _putImage(index, bytes);
        });
        _prefetchText(index);
        unawaited(_decodeAspect(index, bytes));
      }
      _pumpRenders();
    }());
  }

  /// Safety net for a page that is on screen without an image and without a
  /// pending request (the queue was rebuilt underneath it, a reply was lost):
  /// ask again after this frame instead of spinning forever. Build must not
  /// change state, so the request itself is deferred.
  void _healCurrentPage(int index) {
    if (index != _pager.index) return;
    if (_healScheduled) return;
    if (_images.containsKey(index) || _failed.contains(index)) return;
    if (_rendering == index || _renderQueue.contains(index)) return;
    _healScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _healScheduled = false;
      if (!mounted || _pager.pageCount == 0) return;
      _wantPage(_pager.index);
    });
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

  /// Loads the text layer of [index] once; failure means "no spoken text here".
  void _prefetchText(int index) {
    if (index < 0 || index >= _pager.pageCount) return;
    if (_pageTexts.containsKey(index) ||
        _textFailed.contains(index) ||
        !_textInFlight.add(index)) {
      return;
    }
    unawaited(() async {
      try {
        final text = await PdfDocuments.pageText(widget.url, index);
        if (!mounted) return;
        setState(() {
          if (text == null || !text.hasText) {
            _textFailed.add(index);
          } else {
            _pageTexts[index] = text;
          }
        });
      } catch (_) {
        if (mounted) setState(() => _textFailed.add(index));
      } finally {
        _textInFlight.remove(index);
      }
    }());
  }

  /// Remembers the bitmap's real aspect ratio, so the highlight can be placed
  /// even while the text layer is still loading.
  Future<void> _decodeAspect(int index, Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final int width = frame.image.width;
      final int height = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (!mounted || width <= 0 || height <= 0) return;
      if (_aspects.containsKey(index)) return;
      setState(() => _aspects[index] = height / width);
    } catch (_) {
      // The page still renders; the fallback aspect ratio is only a placement
      // guess until the image itself is laid out.
    }
  }

  double _aspectOf(int index) {
    final text = _pageTexts[index];
    if (text != null && text.width > 0 && text.height > 0) {
      return text.aspectRatio;
    }
    return _aspects[index] ?? 1.414;
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
    if (_speakingPage != null && _speakingPage != index) _stopSpeech();
    _pager.goTo(index);
    setState(() {});
    // The page on screen is what matters now; whatever was queued for pages
    // already flipped past is dropped inside [_wantPage].
    _wantPage(index);
    _prefetchText(index);
    _prefetchText(index + 1);
    _prefetchText(index - 1);
  }

  /// A tap on a text line speaks it; everywhere else keeps the page-turn zones.
  void _onPageTap(
    Offset local,
    Rect imageRect,
    PdfPageText? text,
    int index,
    double areaWidth,
  ) {
    if (text != null &&
        imageRect.width > 0 &&
        imageRect.height > 0 &&
        imageRect.contains(local)) {
      final double x = (local.dx - imageRect.left) / imageRect.width;
      final double y = (local.dy - imageRect.top) / imageRect.height;
      final PdfTextLine? line = text.lineAt(x, y);
      if (line != null) {
        unawaited(_speakLine(index, line));
        return;
      }
    }
    switch (PdfPager.zoneForTap(local.dx, areaWidth)) {
      case PdfTapZone.previous:
        _goTo(_pager.index - 1);
      case PdfTapZone.next:
        _goTo(_pager.index + 1);
      case PdfTapZone.toggleChrome:
        setState(() => _chromeVisible = !_chromeVisible);
    }
  }

  // ------------------------------------------------------------- speech

  /// Incremented for every new utterance so a late `speak` reply cannot install
  /// an id for a line that was replaced in the meantime.
  int _speechRequest = 0;

  /// Utterances the reader no longer cares about; their callbacks are ignored.
  final Set<String> _retiredUtterances = <String>{};

  Future<void> _speakLine(int index, PdfTextLine line) async {
    final int request = ++_speechRequest;
    final String? previous = _utteranceId;
    if (previous != null) _retiredUtterances.add(previous);
    if (_retiredUtterances.length > 20) _retiredUtterances.clear();
    setState(() {
      _speakingPage = index;
      _speakingLine = line;
      _utteranceId = null;
    });
    try {
      final String id = await PdfSpeech.speak(line.text, rate: _speechRate);
      if (!mounted || request != _speechRequest) return;
      setState(() => _utteranceId = id);
    } on PlatformException catch (error) {
      if (!mounted || request != _speechRequest) return;
      _clearSpeech();
      _speechError(error.message ?? '语音播放失败，请检查系统的语音引擎');
    } on MissingPluginException {
      if (!mounted || request != _speechRequest) return;
      _clearSpeech();
      _speechError('当前设备没有语音引擎，无法朗读');
    }
  }

  void _onSpeechEvent(String id, PdfSpeechState state) {
    if (!mounted || state == PdfSpeechState.started) return;
    if (_retiredUtterances.remove(id)) return;
    if (_utteranceId != null && id.isNotEmpty && id != _utteranceId) return;
    _speechRequest++;
    _clearSpeech();
    if (state == PdfSpeechState.error) {
      _speechError('语音播放失败，请检查系统的语音引擎');
    }
  }

  void _clearSpeech() {
    if (_speakingLine == null && _utteranceId == null) return;
    setState(() {
      _speakingLine = null;
      _speakingPage = null;
      _utteranceId = null;
    });
  }

  void _stopSpeech() {
    final String? current = _utteranceId;
    if (current != null) _retiredUtterances.add(current);
    _speechRequest++;
    _clearSpeech();
    unawaited(PdfSpeech.stop());
  }

  void _speechError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _onSpeechRateChanged(double value) {
    setState(() => _speechRate = value);
  }

  Future<void> _onSpeechRateCommitted(double value) async {
    try {
      await PdfSpeech.setRate(value);
    } catch (_) {
      // The rate is only a preference; the next speak() passes it again.
    }
    final PdfTextLine? line = _speakingLine;
    final int? page = _speakingPage;
    if (line != null && page != null) unawaited(_speakLine(page, line));
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
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Size area = Size(constraints.maxWidth, constraints.maxHeight);
            final Uint8List? bytes = _images[index];
            final PdfPageText? text = _pageTexts[index];
            final Widget page;
            Rect imageRect = Rect.zero;
            if (_failed.contains(index)) {
              page = _FailedPage(
                index: index,
                onRetry: () => _retryRender(index),
              );
            } else if (bytes == null) {
              _healCurrentPage(index);
              page = _Rendering(index: index);
            } else {
              // No InteractiveViewer here: it would compete with the PageView
              // for horizontal drags, and swiping is how pages are turned.
              imageRect = _containRect(area, _aspectOf(index));
              page = Stack(
                children: <Widget>[
                  Positioned.fromRect(
                    rect: imageRect,
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    ),
                  ),
                  if (_speakingPage == index && _speakingLine != null)
                    _highlightFor(_speakingLine!, imageRect),
                ],
              );
            }
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (TapUpDetails details) => _onPageTap(
                details.localPosition,
                imageRect,
                text,
                index,
                width,
              ),
              child: page,
            );
          },
        );
      },
    );
  }

  /// Where a page of [aspectRatio] (height / width) sits inside [area] when
  /// fitted with `BoxFit.contain`.
  Rect _containRect(Size area, double aspectRatio) {
    if (area.width <= 0 || area.height <= 0) return Rect.zero;
    final double aspect = aspectRatio > 0 ? aspectRatio : 1.414;
    double width = area.width;
    double height = width * aspect;
    if (height > area.height) {
      height = area.height;
      width = height / aspect;
    }
    return Rect.fromLTWH(
      (area.width - width) / 2,
      (area.height - height) / 2,
      width,
      height,
    );
  }

  /// Paints the yellow highlight over the line being spoken.
  Widget _highlightFor(PdfTextLine line, Rect imageRect) {
    final Rect rect = Rect.fromLTWH(
      imageRect.left + line.left * imageRect.width,
      imageRect.top + line.top * imageRect.height,
      line.width * imageRect.width,
      line.height * imageRect.height,
    );
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: DecoratedBox(
          key: pdfSpeechHighlightKey,
          decoration: BoxDecoration(
            color: const Color(0xFFFFD54F).withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    final bool noText = _textFailed.contains(_pager.index);
    return Material(
      color: Colors.black87,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  IconButton(
                    key: pdfPreviousButtonKey,
                    tooltip: '上一页',
                    color: Colors.white,
                    onPressed:
                        _pager.canGoPrevious ? () => _goTo(_pager.index - 1) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      _pager.label,
                      key: pdfPageIndicatorKey,
                      style: const TextStyle(
                        color: Colors.white,
                        fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  IconButton(
                    key: pdfNextButtonKey,
                    tooltip: '下一页',
                    color: Colors.white,
                    onPressed:
                        _pager.canGoNext ? () => _goTo(_pager.index + 1) : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Text(
                        noText
                            ? '本页没有可朗读的文字；左右两侧翻页'
                            : '点文字朗读；左右两侧翻页，中间空白处显示或隐藏工具栏',
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              Row(
                children: <Widget>[
                  const SizedBox(width: 14),
                  const Icon(
                    Icons.record_voice_over_outlined,
                    color: Colors.white70,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '朗读语速',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        activeTrackColor: Colors.white70,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: Colors.white,
                        overlayColor: Colors.white12,
                      ),
                      child: Slider(
                        value: _speechRate,
                        min: 0.5,
                        max: 2.0,
                        divisions: 6,
                        label: '${_speechRate.toStringAsFixed(2)}x',
                        onChanged: _onSpeechRateChanged,
                        onChangeEnd: (double value) =>
                            unawaited(_onSpeechRateCommitted(value)),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 46,
                    child: Text(
                      '${_speechRate.toStringAsFixed(2)}x',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                  IconButton(
                    tooltip: '停止朗读',
                    color: Colors.white,
                    onPressed: _speakingLine == null ? null : _stopSpeech,
                    icon: const Icon(Icons.stop_circle_outlined),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ],
          ),
        ),
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
