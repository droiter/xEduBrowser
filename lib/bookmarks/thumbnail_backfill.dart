import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../browser/block_page_template.dart';
import '../browser/browser_bridge.dart';
import '../browser/policy_webview.dart';
import '../browser/url_input.dart';
import '../pdf/pdf_document.dart';
import '../state/app_scope.dart';
import 'bookmark.dart';

/// One page the backfill wants a screenshot of.
@immutable
class ThumbnailCaptureRequest {
  const ThumbnailCaptureRequest({
    required this.viewId,
    required this.bookmarkId,
    required this.url,
  });

  /// Platform view id for the throwaway WebView; taken from the shared counter so
  /// it can never collide with a tab or the bookmark-preview view.
  final int viewId;
  final String bookmarkId;
  final String url;
}

/// Gives the bookmarks that never got a cover their cover — slowly, in the
/// background.
///
/// A bookmark only gets a preview when its page happens to be opened (or added
/// through the settings dialog), so a library imported in one go stays a wall of
/// letter tiles until someone visits every page. This walks the missing ones
/// **one at a time**: a single capture, then a long gap, and never while the
/// child has just been touching the screen — the foreground keeps the machine to
/// itself, and the wall fills in over minutes rather than in one burst.
///
/// The service itself never touches a WebView. It publishes [request] and the
/// shell mounts [ThumbnailCaptureHost] for it; when that host reports back,
/// [complete] stores the image and schedules the next round. That split is what
/// keeps this testable: the decisions live here, the pixels live in the host.
class ThumbnailBackfill extends ChangeNotifier {
  ThumbnailBackfill({
    required this.candidates,
    required this.save,
    required this.log,
    required this.isEnabled,
    this.gap = const Duration(seconds: 45),
    this.idleBeforeStart = const Duration(seconds: 20),
    this.retryCooldown = const Duration(minutes: 30),
    this.captureTimeout = const Duration(seconds: 20),
    int Function()? allocateViewId,
    Timer Function(Duration, void Function())? scheduleTimer,
    DateTime Function()? clock,
  })  : _allocateViewId = allocateViewId ?? nextPlatformViewId,
        _scheduleTimer = scheduleTimer ?? ((delay, callback) => Timer(delay, callback)),
        _clock = clock ?? DateTime.now;

  /// Whether a one-click batch is running right now.
  ///
  /// False once it finished, but the counts below keep the finished run's numbers
  /// so the button can say "完成 3/3" instead of blanking out.
  bool get batchRunning => _batch != null && !_batch!.finished;

  /// How many bookmarks the current batch set out to do (0 when idle).
  int get batchTotal => _batch?.total ?? 0;

  /// How many of them have been processed (success or failure).
  int get batchDone => _batch?.done ?? 0;

  /// Set by [startBatch]: a one-click run uses a short gap and ignores the idle
  /// rule, because the user asked for it *now*.
  _Batch? _batch;

  /// Starts the background pass. Idempotent, and deliberately explicit: creating
  /// the service must not schedule anything (a test that only reads
  /// `pendingCount` should not leave a timer behind).
  void start() {
    if (_disposed) return;
    if (_timer != null) return;
    if (_request != null) return;
    if (!_foreground) return;
    // First look one gap from now: start-up is busy, and nothing here is urgent.
    _schedule(gap);
  }

  /// Starts a one-click batch over everything that is missing a preview now.
  ///
  /// Unlike the background pass this does not wait for the child to stop
  /// touching the screen — the button *is* the request — but it still runs one
  /// capture at a time with [batchGap] between them, so the app stays usable
  /// while the wall fills in.
  void startBatch() {
    if (_disposed || batchRunning) return;
    final pending = _pending();
    _batch = _Batch(total: pending.length);
    if (pending.isEmpty) {
      log('capture', '一键补图：没有缺图的书签');
      _batch = null;
      return;
    }
    log('capture', '一键补图开始：共 ${pending.length} 个待补');
    _batchGap = batchGap;
    _schedule(const Duration(milliseconds: 200));
    _notify();
  }

  /// Stops a running batch after the capture in flight (if any) finishes.
  void stopBatch() {
    if (_batch == null || _batch!.finished) return;
    log('capture', '一键补图已停止：完成 ${_batch!.done}/${_batch!.total} 个');
    _batch = null;
    _batchGap = null;
    _schedule(gap);
    _notify();
  }

  /// How long between the captures of a one-click batch.
  Duration batchGap = const Duration(seconds: 2);

  Duration? _batchGap;

  /// Bookmarks that still have no preview, in the order they should be tried.
  final List<Bookmark> Function() candidates;

  /// Stores a finished screenshot (AppState.setBookmarkThumbnail).
  final Future<void> Function(Bookmark bookmark, Uint8List bytes) save;

  /// One line for the diagnostic log.
  final void Function(String tag, String message, {bool warn}) log;

  /// Read on every tick, so the settings switch takes effect without rewiring.
  final bool Function() isEnabled;

  /// How long to wait *between* captures: the "gradually" knob.
  final Duration gap;

  /// How long the child must have been idle before a capture may start.
  final Duration idleBeforeStart;

  /// How long a bookmark that produced nothing is left alone.
  final Duration retryCooldown;

  /// Deadline for one capture, so a page that never finishes cannot wedge the
  /// queue.
  final Duration captureTimeout;

  final int Function() _allocateViewId;
  final Timer Function(Duration, void Function()) _scheduleTimer;
  final DateTime Function() _clock;

  Timer? _timer;
  ThumbnailCaptureRequest? _request;
  bool _foreground = true;
  bool _disposed = false;

  /// The last time the child touched the screen.
  DateTime? _lastActivity;

  /// Bookmarks that failed, and when they may be tried again.
  final Map<String, DateTime> _cooldownUntil = <String, DateTime>{};

  /// Set once the "nothing left to do" line has been logged, so an idle app does
  /// not repeat it every gap.
  bool _loggedIdle = false;

  int _done = 0;
  int _failed = 0;

  /// The capture the shell should mount right now, or null.
  ThumbnailCaptureRequest? get request => _request;

  /// How many bookmarks are still missing a preview.
  int get pendingCount => _pending().length;

  /// How many the service has filled in this session.
  int get capturedCount => _done;

  /// How many it gave up on this session (they are retried after the cooldown).
  int get failedCount => _failed;

  /// Reports that the child just touched the screen: no new capture may start
  /// until [idleBeforeStart] has passed again.
  void noteUserActivity() {
    _lastActivity = _clock();
  }

  /// The app went to the background (or came back).
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (foreground) {
      if (_batch != null) {
        _schedule(const Duration(milliseconds: 200));
      } else {
        _schedule(idleBeforeStart);
      }
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Called by the host with the screenshot, or null when it got nothing.
  Future<void> complete(Uint8List? bytes) async {
    final request = _request;
    if (request == null) return;
    _request = null;
    _notify();
    if (_disposed) return;
    _batch?.done++;
    _notify();

    final bookmark = _bookmarkById(request.bookmarkId);
    if (bookmark == null) {
      // Deleted while the capture was in flight: nothing to store.
      _scheduleNext();
      return;
    }
    if (bytes == null || bytes.isEmpty) {
      _failed++;
      _cooldownUntil[request.bookmarkId] = _clock().add(retryCooldown);
      log(
        'capture',
        '后台补预览图失败：「${bookmark.displayTitle}」截图为空，'
        '${retryCooldown.inMinutes} 分钟后再试'
        '（本轮成功 $_done 张，失败 $_failed 张）',
        warn: true,
      );
      _scheduleNext();
      return;
    }
    try {
      await save(bookmark, bytes);
      _done++;
      _cooldownUntil.remove(request.bookmarkId);
      log(
        'capture',
        '后台补预览图完成：「${bookmark.displayTitle}」'
        '${bytes.length ~/ 1024} KB，还剩 $pendingCount 个待补',
      );
    } catch (error) {
      _failed++;
      _cooldownUntil[request.bookmarkId] = _clock().add(retryCooldown);
      log('capture', '后台补预览图写入失败：「${bookmark.displayTitle}」$error', warn: true);
    }
    _scheduleNext();
  }

  /// Wait out the gap that fits the current mode, then look again.
  void _scheduleNext() {
    final batchDelay = _batchGap;
    _schedule(batchDelay ?? gap);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  // ------------------------------------------------------------------ 内部

  Bookmark? _bookmarkById(String id) {
    for (final bookmark in candidates.call()) {
      if (bookmark.id == id) return bookmark;
    }
    // It may have got a thumbnail from elsewhere in the meantime; the caller
    // only needs a bookmark object to store into, so look wider.
    return null;
  }

  /// Bookmarks that still need a preview and are not being cooled down.
  List<Bookmark> _pending() {
    final now = _clock();
    final out = <Bookmark>[];
    for (final bookmark in candidates.call()) {
      if (!_capturable(bookmark.url)) continue;
      final until = _cooldownUntil[bookmark.id];
      if (until != null && until.isAfter(now)) continue;
      out.add(bookmark);
    }
    return out;
  }

  /// Whether a URL can be photographed at all by the WebView.
  ///
  /// The start page is not a document, an empty address has nothing to load, and
  /// a PDF is drawn by the built-in reader — Android's WebView cannot show one,
  /// so a capture would only ever produce a blank frame. Those tiles keep their
  /// letter monogram, exactly as before this background pass existed.
  bool _capturable(String url) {
    final target = url.trim();
    if (target.isEmpty || target == UrlResolver.homeUrl) return false;
    if (PdfDocuments.localPathOf(target) != null) return false;
    return true;
  }

  void _schedule(Duration delay) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = _scheduleTimer(delay, _tick);
  }

  void _tick() {
    _timer = null;
    if (_disposed) return;
    if (_request != null) {
      // A capture is still in flight; the host will call complete().
      return;
    }
    if (!_foreground) return;
    final batch = _batch;
    if (batch == null && !isEnabled()) {
      _schedule(gap);
      return;
    }
    if (batch == null) {
      final idleFor = _clock().difference(_lastActivity ?? DateTime.fromMillisecondsSinceEpoch(0));
      if (_lastActivity != null && idleFor < idleBeforeStart) {
        _schedule(idleBeforeStart - idleFor);
        return;
      }
    }
    final pending = _pending();
    if (pending.isEmpty) {
      if (batch != null && !batch.finished) {
        batch.finished = true;
        log('capture', '一键补图完成：共处理 ${batch.done}/${batch.total} 个');
        _batchGap = null;
        _notify();
        _schedule(gap);
        return;
      }
      if (!_loggedIdle) {
        _loggedIdle = true;
        log('capture', '后台补预览图：没有缺图的书签（本轮共补 $_done 张）');
      }
      _schedule(const Duration(minutes: 10));
      return;
    }
    _loggedIdle = false;
    final next = pending.first;
    _request = ThumbnailCaptureRequest(
      viewId: _allocateViewId(),
      bookmarkId: next.id,
      url: next.url,
    );
    log(
      'capture',
      '${batch != null ? '一键补图' : '后台补预览图'}开始：「${next.displayTitle}」'
      '（待补 ${pending.length} 个，已完成 $_done 个，失败的 $_failed 个）',
    );
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}

/// Progress of a one-click batch.
class _Batch {
  _Batch({required this.total});

  final int total;
  int done = 0;
  bool finished = false;
}

/// Hosts the off-screen WebView for one [ThumbnailCaptureRequest].
///
/// The view is laid out **outside the window** (so a background capture is never
/// something the child can see) and wrapped in [IgnorePointer] (so it can never
/// take a touch). It loads the page, waits for it the same way the visible
/// capture does — one frame shortly after `pageFinished`, one several seconds
/// later, because a local flipbook paints its cover only after its player has
/// started — and hands the bytes to [onDone].
class ThumbnailCaptureHost extends StatefulWidget {
  const ThumbnailCaptureHost({
    super.key,
    required this.request,
    required this.onDone,
  });

  final ThumbnailCaptureRequest request;
  final ValueChanged<Uint8List?> onDone;

  @override
  State<ThumbnailCaptureHost> createState() => _ThumbnailCaptureHostState();
}

class _ThumbnailCaptureHostState extends State<ThumbnailCaptureHost> {
  late final BrowserViewController _controller =
      BrowserViewController(viewId: widget.request.viewId);
  StreamSubscription<BrowserEvent>? _events;
  Timer? _deadline;
  bool _done = false;

  /// Same "wait for a real frame, then wait again" rhythm as the visible capture.
  static const Duration _firstDelay = Duration(milliseconds: 900);
  static const Duration _secondDelay = Duration(milliseconds: 2800);
  static const Duration _deadlineAfter = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    unawaited(_controller.loadUrl(widget.request.url));
    _deadline = Timer(_deadlineAfter, () => _finish(null));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _events ??= BrowserBridge.eventStream().map(BrowserEvent.fromMap).listen(_onEvent);
  }

  @override
  void dispose() {
    _deadline?.cancel();
    unawaited(_events?.cancel());
    unawaited(BrowserBridge.disposeView(widget.request.viewId));
    super.dispose();
  }

  void _onEvent(BrowserEvent event) {
    if (event.viewId != widget.request.viewId || event.type != 'pageFinished') return;
    unawaited(_capture());
  }

  Future<void> _capture() async {
    await Future<void>.delayed(_firstDelay);
    if (!mounted || _done) return;
    final first = await BrowserBridge.captureThumbnail(widget.request.viewId, maxWidth: 480);
    if (!mounted || _done) return;
    await Future<void>.delayed(_secondDelay);
    if (!mounted || _done) return;
    final second = await BrowserBridge.captureThumbnail(widget.request.viewId, maxWidth: 480);
    if (!mounted || _done) return;
    final bytes = (second != null && second.isNotEmpty) ? second : first;
    if (bytes == null || bytes.isEmpty) {
      // A blank frame is not a result: the deadline decides, and the service
      // cools the bookmark down rather than storing a grey tile.
      return;
    }
    _finish(bytes);
  }

  void _finish(Uint8List? bytes) {
    if (_done || !mounted) return;
    _done = true;
    widget.onDone(bytes);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    final size = MediaQuery.sizeOf(context);
    // Parked just outside the window: laid out (so the WebView really renders)
    // but never on screen.
    return Positioned(
      left: -size.width - 40,
      top: 0,
      width: size.width,
      height: size.height,
      child: IgnorePointer(
        child: PolicyWebView(
          viewId: widget.request.viewId,
          settings: {
            ...state.settings.toNativeSettings(),
            'blockPageHtml': BlockPageTemplate.html,
          },
          policy: state.nativePolicyPayload(),
          // Unfiltered on purpose, exactly like the capture route in
          // thumbnail_capture.dart: filling in a cover must not depend on the
          // page already being allowed.
          previewPolicy: const {'enabled': false},
          onCreated: (_) => _controller.markCreated(),
          onDisposed: _controller.markDisposed,
        ),
      ),
    );
  }
}
