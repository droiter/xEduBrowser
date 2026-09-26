import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../browser/block_page_template.dart';
import '../browser/browser_bridge.dart';
import '../browser/policy_webview.dart';
import '../browser/url_input.dart';
import '../pdf/pdf_document.dart';
import '../state/app_scope.dart';

/// Test hook for the capture screen.
const Key thumbnailCaptureScreenKey = ValueKey<String>('thumbnail-capture-screen');

/// Captures a preview image for [url] by loading it in a throwaway WebView.
///
/// Returns PNG bytes, or null when nothing could be captured.
///
/// A bookmark is usually added from the settings screen, where the page itself
/// is not on screen to photograph. This opens the page in a hidden capture
/// route just long enough for one screenshot, so the home tile can show the real
/// page instead of the generated monogram. Nothing is written here: the caller
/// decides what to do with the bytes.
Future<Uint8List?> captureThumbnailFor(
  BuildContext context, {
  required String url,
  Duration timeout = const Duration(seconds: 20),
}) {
  final target = url.trim();
  // Nothing to photograph, and each case would leave a blank frame behind: the
  // start page is not a document, an empty address has nothing to load, and a
  // PDF is rendered by the built-in reader because Android's WebView cannot
  // display one.
  if (target.isEmpty || target == UrlResolver.homeUrl) {
    return Future<Uint8List?>.value();
  }
  if (PdfDocuments.localPathOf(target) != null) {
    return Future<Uint8List?>.value();
  }
  return Navigator.of(context).push<Uint8List?>(
    MaterialPageRoute<Uint8List?>(
      fullscreenDialog: true,
      builder: (_) => _ThumbnailCaptureScreen(url: target, timeout: timeout),
    ),
  );
}

/// Loads [url] once, screenshots it and pops the PNG (or null on failure).
class _ThumbnailCaptureScreen extends StatefulWidget {
  const _ThumbnailCaptureScreen({required this.url, required this.timeout});

  final String url;

  /// Deadline for the whole capture; the caller must never wait forever for a
  /// page that keeps loading.
  final Duration timeout;

  @override
  State<_ThumbnailCaptureScreen> createState() => _ThumbnailCaptureScreenState();
}

class _ThumbnailCaptureScreenState extends State<_ThumbnailCaptureScreen> {
  late final int _viewId = nextPlatformViewId();
  late final BrowserViewController _controller = BrowserViewController(
    viewId: _viewId,
  );
  StreamSubscription<BrowserEvent>? _events;
  Timer? _timeout;

  /// Set by whichever finishes first — a capture or the timeout — so the route
  /// is never popped twice.
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // The controller queues the load until `markCreated` fires, which happens
    // once the native view actually exists; sending it earlier would be dropped
    // and the frame would stay blank.
    unawaited(_controller.loadUrl(widget.url));
    _timeout = Timer(widget.timeout, () => _finish(null));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _events ??= BrowserBridge.eventStream()
        .map(BrowserEvent.fromMap)
        .listen(_onEvent);
  }

  @override
  void dispose() {
    _timeout?.cancel();
    unawaited(_events?.cancel());
    unawaited(BrowserBridge.disposeView(_viewId));
    super.dispose();
  }

  void _onEvent(BrowserEvent event) {
    if (event.viewId != _viewId || event.type != 'pageFinished') return;
    unawaited(_capture());
  }

  Future<void> _capture() async {
    // `pageFinished` fires while the first frame can still be blank, so the
    // screenshot is taken a moment later — the same delay the browser shell uses
    // when it refreshes a bookmark tile.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted || _done) return;
    final first = await BrowserBridge.captureThumbnail(_viewId, maxWidth: 480);
    if (!mounted || _done) return;

    // And once more a few seconds later: a local flipbook's shell reports
    // "finished" immediately while its player paints the cover seconds later, so
    // the early frame is the player's loading screen. The later frame wins when
    // it produced anything at all.
    await Future<void>.delayed(const Duration(milliseconds: 2800));
    if (!mounted || _done) return;
    final second = await BrowserBridge.captureThumbnail(_viewId, maxWidth: 480);
    if (!mounted || _done) return;

    final bytes = (second != null && second.isNotEmpty) ? second : first;
    // A blank or failed capture is not a result: leaving the route open lets the
    // timeout decide, and the caller falls back to the generated tile.
    if (bytes == null || bytes.isEmpty) return;
    _finish(bytes);
  }

  void _finish(Uint8List? bytes) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pop(bytes);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    return Scaffold(
      key: thumbnailCaptureScreenKey,
      backgroundColor: Colors.white,
      body: Stack(
        fit: StackFit.expand,
        children: [
          PolicyWebView(
            viewId: _viewId,
            settings: {
              ...state.settings.toNativeSettings(),
              'blockPageHtml': BlockPageTemplate.html,
            },
            policy: state.nativePolicyPayload(),
            // Unfiltered on purpose: the page was just bookmarked and is usually
            // not allowed yet — the whole point of grabbing its cover. That is
            // why this flow is only reachable from the settings screen, which
            // sits behind the parental gate.
            previewPolicy: const {'enabled': false},
            onCreated: (_) => _controller.markCreated(),
            onDisposed: _controller.markDisposed,
          ),
          const _CaptureProgress(),
        ],
      ),
    );
  }
}

/// Says that the screenshot is on its way, so a parent does not read a slow page
/// as a frozen screen.
class _CaptureProgress extends StatelessWidget {
  const _CaptureProgress();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 14),
              Text('正在生成预览图…', style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}
