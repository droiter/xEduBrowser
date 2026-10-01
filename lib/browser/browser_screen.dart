import 'dart:async';

import 'package:flutter/material.dart';

import '../bookmarks/bookmark.dart';
import '../bookmarks/bookmark_dialog.dart';
import '../files/local_files_screen.dart';
import '../parental/parental_password_prompt.dart';
import '../log/request_log_screen.dart';
import '../pdf/pdf_document.dart';
import '../pdf/pdf_reader_screen.dart';
import '../policy/policy_engine.dart';
import '../rules/policy_tester_screen.dart';
import '../rules/rules_screen.dart';
import '../settings/settings_screen.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'block_page_template.dart';
import 'browser_bridge.dart';
import 'policy_webview.dart';
import 'start_view.dart';
import 'url_input.dart';

/// One browser tab. Each tab owns a native WebView and its own navigation
/// history, so switching tabs never reloads a page.
class BrowserTab {
  BrowserTab._(this.viewId, this.controller, this.url);

  factory BrowserTab.create({required int viewId, String? url}) => BrowserTab._(
    viewId,
    BrowserViewController(viewId: viewId),
    url ?? UrlResolver.homeUrl,
  );

  final int viewId;
  final BrowserViewController controller;
  String url;
  String title = '新标签页';
  int progress = 0;
  bool loading = false;
  bool canGoBack = false;
  bool canGoForward = false;

  /// How many load commands this tab has sent for its current URL, including the
  /// automatic retries from the shell's watchdog.
  int loadAttempts = 0;

  /// The URL the shell is still waiting for a verdict on (finished, failed or
  /// blocked); null when nothing is outstanding. Drives the retry watchdog —
  /// deliberately separate from [loading], which follows the native events and
  /// only turns on once the page reports that it actually started.
  String? awaitingUrl;

  /// Set when the policy refused this navigation; the body shows the block
  /// panel instead of the WebView until the tab navigates somewhere else.
  PolicyDecision? blocked;

  bool get showsStartView => url == UrlResolver.homeUrl && blocked == null;
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

/// Test hook for 固定桌面's top-bar switch.
const Key lockTaskToggleKey = ValueKey<String>('lock-task-toggle');

/// Test hook for 防翻页's top-bar switch (sits next to 固定桌面).
const Key flipGuardToggleKey = ValueKey<String>('flip-guard-toggle');

/// Test hook for 防反复看's top-bar switch (next to 防翻页).
const Key antiRepeatToggleKey = ValueKey<String>('anti-repeat-toggle');

/// Test hook for the seconds badge 防翻页 shows **inside the top bar** while it
/// holds the page (it used to be a strip under the bar, which cost page space).
const Key flipGuardCountdownKey = ValueKey<String>('flip-guard-countdown');

class _BrowserScreenState extends State<BrowserScreen> {
  final List<BrowserTab> _tabs = [];
  StreamSubscription<BrowserEvent>? _eventSubscription;
  AppState? _state;
  bool _wired = false;
  int _activeIndex = 0;

  /// 固定桌面 的**意图**（设置里的值）。按钮显示的是它：按下立刻翻转，不需要等系统。
  bool _pinWanted = false;

  /// 系统**真实**的锁定任务状态。进入/退出不是同步的（未白名单时还要等用户确认
  /// 系统弹框），所以它只用于提示与复核，绝不用来决定"下一次按下去该开还是该关"。
  bool _pinActive = false;

  /// 追踪锁定任务是否已经跟上意图（每 400ms 读一次，最多 6 次）。
  Timer? _pinSettleTimer;
  int _pinSettleTicks = 0;

  /// 防翻页 的**意图**（设置里的值），跟 [_pinWanted] 一样按下即翻。
  bool _flipGuardWanted = false;

  /// 防反复看 的开关（同一排的第三个按钮）。
  bool _antiRepeatWanted = true;

  /// 页面里的遮罩此刻还剩多少毫秒。由页面自己的 `[flipguard]` 控制台消息驱动
  /// （`cool <ms> <reason>` / `release`）——那是"页面真的翻过去了"的唯一可靠来源，
  /// 宿主看不见这件事。倒计时只是把它显示出来，真正拦输入的是页面里的遮罩；
  /// 所以这里用"每 250ms 减一次"的本地计时（页面 `release` 一到就归零），
  /// 而不是跟墙上时钟对表。
  int _guardRemainingMs = 0;

  /// 这一轮锁定是哪条信号触发的，已翻成中文（写进诊断日志、也进按钮提示，
  /// 方便家长分辨"真的翻页了"还是误判）。
  String _guardReason = '';

  /// 每 250ms 重画一次倒计时；没有锁定时为空。
  Timer? _guardTimer;

  /// Bookmark ids whose preview was already refreshed during this app run, so a
  /// page that reloads (or is opened twice) is not re-screenshotted every time.
  final Set<String> _thumbnailRefreshed = <String>{};

  /// Views with a capture in flight, so one slow screenshot is not queued twice.
  final Set<int> _thumbnailInFlight = <int>{};

  /// One load watchdog per tab with a load in flight; see [_issueLoad].
  final Map<int, Timer> _loadWatchdogs = <int, Timer>{};

  /// How long a load may stay unfinished before it is sent again.
  static const Duration _loadRetryAfter = Duration(seconds: 4);

  /// Total load commands per navigation: the first one plus two retries.
  static const int _maxLoadAttempts = 3;

  BrowserTab? get _active => _activeIndex >= 0 && _activeIndex < _tabs.length
      ? _tabs[_activeIndex]
      : null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_wired) {
      _syncSwitchesFromSettings();
      return;
    }
    _wired = true;
    _state = state;

    // Keep the native engine in sync with the policy, and the live WebViews in
    // sync with the settings.
    state.onPolicyChanged = (policy) => BrowserBridge.setPolicy(policy);
    state.onSettingsChanged = (settings) {
      for (final tab in _tabs) {
        unawaited(tab.controller.openSettings(_nativeSettings(settings)));
      }
    };
    unawaited(BrowserBridge.setPolicy(state.nativePolicyPayload()));

    _eventSubscription = BrowserBridge.eventStream()
        .map(BrowserEvent.fromMap)
        .listen(_onNativeEvent);
    _pinWanted = _state?.settings.lockTaskEnabled ?? false;
    _flipGuardWanted = _state?.settings.flipGuardEnabled ?? false;
    _antiRepeatWanted = _state?.settings.antiRepeatEnabled ?? true;
    unawaited(_refreshPinActive());
    _addTab(activate: true);
  }

  /// Re-reads the two switches from the settings on every notification.
  ///
  /// They are also settable from 设置 →「书签默认行为」, and the toolbar is the
  /// child-facing mirror of that: a button that keeps showing the state it had
  /// when the app started is how a switch ends up looking on while the setting
  /// behind it says otherwise.
  void _syncSwitchesFromSettings() {
    final AppSettings? settings = _state?.settings;
    if (settings == null) return;
    // No setState: didChangeDependencies is always followed by a build.
    if (_pinWanted != settings.lockTaskEnabled) {
      _pinWanted = settings.lockTaskEnabled;
    }
    if (_flipGuardWanted != settings.flipGuardEnabled) {
      _flipGuardWanted = settings.flipGuardEnabled;
      if (!_flipGuardWanted) _endGuardHold();
    }
    if (_antiRepeatWanted != settings.antiRepeatEnabled) {
      _antiRepeatWanted = settings.antiRepeatEnabled;
    }
  }

  @override
  void dispose() {
    _pinSettleTimer?.cancel();
    _guardTimer?.cancel();
    unawaited(_eventSubscription?.cancel());
    for (final timer in _loadWatchdogs.values) {
      timer.cancel();
    }
    _loadWatchdogs.clear();
    super.dispose();
  }

  Map<String, dynamic> _nativeSettings(Map<String, dynamic> settings) => {
    ...settings,
    'blockPageHtml': BlockPageTemplate.html,
  };

  // ---------------------------------------------------------- loading

  /// Sends a load command for [tab] and arms a watchdog for it.
  ///
  /// A page that is never reported finished used to leave the shell spinning
  /// forever, with a blank body that only appeared after switching tabs. Two
  /// things guard against that now: the first load is replayed by the controller
  /// once the platform view actually exists (and has been laid out), and if
  /// nothing comes back within [_loadRetryAfter] the load is sent again — which
  /// also forces a relayout of the platform view, exactly what the tab switch
  /// did by hand. After [_maxLoadAttempts] the spinner is cleared and the user is
  /// told, instead of being left with a page that never arrives.
  void _issueLoad(BrowserTab tab, String url, {bool reset = false}) {
    if (reset) tab.loadAttempts = 0;
    tab.loadAttempts++;
    tab.awaitingUrl = url;
    final int attempt = tab.loadAttempts;
    _state?.logEvent(
      'browser',
      '${attempt == 1 ? '加载' : '重新加载（第 ${attempt - 1} 次重试）'}'
          '视图 ${tab.viewId}：$url',
      level: attempt == 1 ? LogLevel.info : LogLevel.warn,
    );

    unawaited(tab.controller.loadUrl(url));

    _loadWatchdogs.remove(tab.viewId)?.cancel();
    _loadWatchdogs[tab.viewId] = Timer(_loadRetryAfter, () {
      _loadWatchdogs.remove(tab.viewId);
      if (!mounted || tab.awaitingUrl != url) return;
      if (tab.loadAttempts >= _maxLoadAttempts) {
        _state?.logEvent(
          'browser',
          '视图 ${tab.viewId} 加载超时，已重试 ${tab.loadAttempts - 1} 次：$url',
          level: LogLevel.error,
        );
        tab.awaitingUrl = null;
        setState(() => tab.loading = false);
        _snack('页面加载超时，请点刷新重试');
        return;
      }
      _issueLoad(tab, url);
    });
  }

  /// The page answered (finished, failed or was blocked): stop retrying.
  void _clearLoadWatchdog(BrowserTab tab) {
    _loadWatchdogs.remove(tab.viewId)?.cancel();
    tab.loadAttempts = 0;
    tab.awaitingUrl = null;
  }

  // ------------------------------------------------------------- tabs

  /// The configured start page, falling back to the internal `about:home`.
  String get _homeUrl {
    final configured = _state?.settings.homeUrl.trim() ?? '';
    return configured.isEmpty ? UrlResolver.homeUrl : configured;
  }

  BrowserTab _addTab({bool activate = true, String? url}) {
    final tab = BrowserTab.create(viewId: nextPlatformViewId(), url: url ?? _homeUrl);
    _tabs.add(tab);
    if (activate) _activeIndex = _tabs.length - 1;
    setState(() {});
    if (tab.url != UrlResolver.homeUrl) {
      // Queued until the platform view exists; see BrowserViewController.
      _issueLoad(tab, tab.url, reset: true);
    }
    return tab;
  }

  Future<void> _closeTab(int index) async {
    // Closing the last tab lands on the start page, i.e. it is one more way
    // home, so 防翻页 holds it too.
    if (_guardBlocksNavigation()) return;
    if (_tabs.length == 1) {
      // Never leave the app with zero tabs: reset the last one to the start page.
      _navigate(_homeUrl);
      return;
    }
    final tab = _tabs.removeAt(index);
    _clearLoadWatchdog(tab);
    unawaited(BrowserBridge.disposeView(tab.viewId));
    _state?.logEvent('browser', '关闭标签页：${tab.url}');
    if (_activeIndex >= _tabs.length) _activeIndex = _tabs.length - 1;
    setState(() {});
  }

  void _selectTab(int index) {
    // Switching to the start page is another way back to the wall.
    if (index >= 0 && index < _tabs.length && _tabs[index].showsStartView) {
      if (_guardBlocksNavigation()) return;
    }
    setState(() => _activeIndex = index);
  }

  // --------------------------------------------------------- navigation

  /// Every user-initiated navigation goes through here: resolve, then decide.
  ///
  /// There is no address bar — the only ways in are a bookmark tile, the
  /// start-page buttons and the "allow it" action on the block page — but the
  /// gate stays the same for all of them.
  void _navigate(String input) {
    final state = _state;
    final tab = _active;
    if (state == null || tab == null) return;

    final resolved = UrlResolver.resolve(
      input,
      localServerBase: state.localServer?.baseUrl,
      localRoot: state.localServerRunning ? state.effectiveLocalRoot : null,
    );
    if (resolved.url.isEmpty) {
      _snack(resolved.error ?? '无法识别的地址');
      return;
    }
    if (resolved.url == UrlResolver.homeUrl) {
      setState(() {
        tab.url = UrlResolver.homeUrl;
        tab.blocked = null;
        tab.title = '新标签页';
      });
      return;
    }

    // The native layer also enforces the policy; deciding here as well gives
    // an immediate, consistent answer and avoids loading a page we know is
    // refused. Both decide on the *policy* URL: a loopback page is judged as
    // the file it stands for, exactly like the native engine does.
    final decision = state.decideUrl(resolved.url);
    state.logDecision(resolved.url, decision);

    // A PDF cannot be shown in a WebView, so an allowed local PDF bookmark is
    // read page by page in its own screen. The tab is left untouched (it stays
    // on the start page) instead of pointing at a page it cannot render.
    final pdfPath = decision.allowed
        ? PdfDocuments.localPathOf(state.policyUrl(resolved.url))
        : null;
    if (pdfPath != null) {
      unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PdfReaderScreen(url: pdfPath),
      )));
      return;
    }

    setState(() {
      tab.url = resolved.url;
      tab.blocked = decision.allowed ? null : decision;
    });

    if (decision.allowed) {
      _issueLoad(tab, resolved.url, reset: true);
    } else {
      _clearLoadWatchdog(tab);
      _snack('已拦截：${decision.explanation}');
    }
  }

  Future<void> _openLocalFile() async {
    final url = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const LocalFilesScreen()));
    if (url == null || !mounted) return;
    _navigate(url);
  }

  // ----------------------------------------------------------- bookmarks

  /// Bookmarks a page the policy refused and retries it.
  ///
  /// This is the block page's "加为书签并允许访问" action. The address joins the
  /// whitelist together with the site (or local folder) holding it, which is
  /// what makes the page reachable, and then the page is loaded again.
  Future<void> _allowBlockedPage() async {
    final state = _state;
    final tab = _active;
    if (state == null || tab == null || tab.blocked == null) return;

    final url = tab.url;
    final result = await showBookmarkDialog(
      context,
      url: url,
      initialTitle: '',
      whitelistDefault: state.settings.bookmarkWhitelistByDefault,
    );
    if (result == null || !mounted) return;

    final bookmark = await state.addBookmark(
      url: url,
      title: result.title,
      addToWhitelist: result.grantWhitelist,
      categoryId: result.categoryId,
    );
    if (!mounted) return;
    _snack(
      result.grantWhitelist
          ? '已添加书签「${bookmark.displayTitle}」并加入白名单（网址 + 所在站点）'
          : '已添加书签「${bookmark.displayTitle}」（未加入白名单）',
    );

    _navigate(url);
  }

  // ------------------------------------------------------------- previews

  /// Fills in the tile preview of a bookmarked page that does not have one yet.
  ///
  /// A bookmark that is imported in bulk has no cover at first, so the picture is
  /// taken the first time the page is actually opened in the browser, and the home
  /// page then shows the real page instead of the generated monogram.
  ///
  /// **Deliberately one-shot**: a bookmark that already has a picture keeps it.
  /// Opening the page again — days later, after the site changed — must not
  /// silently replace the cover the parent picked; "生成后就不要再变" is the rule.
  /// Replacing an existing picture is an explicit action: 首页编辑模式的
  /// 「重新生成预览图」, or the ⋮ menu's 「更新当前页预览图」.
  void _maybeRefreshPreview(BrowserTab tab) {
    final state = _state;
    if (state == null || tab != _active) return;
    if (tab.blocked != null || tab.url == UrlResolver.homeUrl) return;
    final bookmark = state.bookmarkFor(tab.url);
    if (bookmark == null) return;
    final String? thumbnail = bookmark.thumbnailPath;
    if (thumbnail != null && thumbnail.isNotEmpty) return;
    if (!_thumbnailRefreshed.add(bookmark.id)) return;
    unawaited(_refinePreview(tab, bookmark));
  }

  /// Photographs a bookmark that has no cover: once, then again as the page
  /// settles — still only while it has no cover of its own.
  ///
  /// A heavy local page is the reason this exists: a flipbook's shell reports
  /// "finished" in milliseconds while its player keeps painting for seconds, so
  /// the 900 ms picture was the player's **loading screen**, and that is what the
  /// home tile kept showing. The early frame is still stored (the tile is never
  /// left empty) and later frames replace it, so what stays on the home page is
  /// the page as it really looks once it has finished drawing. Every frame is
  /// taken in the same visit: once the bookmark has a picture at all it is never
  /// touched again by this path.
  Future<void> _refinePreview(BrowserTab tab, Bookmark bookmark) async {
    for (final delay in const [
      Duration(milliseconds: 900),
      Duration(seconds: 4),
      Duration(seconds: 9),
    ]) {
      await Future<void>.delayed(delay);
      if (!mounted || tab.blocked != null || tab.url == UrlResolver.homeUrl) return;
      final state = _state;
      if (state == null) return;
      // The tab may have navigated on, or the bookmark been deleted.
      final current = state.bookmarkFor(tab.url);
      if (current == null || current.id != bookmark.id) return;
      await _capturePreview(tab, bookmark);
    }
  }

  /// The ⋮ menu action: force a fresh screenshot of the current page.
  Future<void> _refreshActivePreview() async {
    final state = _state;
    final tab = _active;
    if (state == null || tab == null) return;
    final bookmark = state.bookmarkFor(tab.url);
    if (bookmark == null) {
      _snack('这个页面还没有加入书签');
      return;
    }
    _thumbnailRefreshed.add(bookmark.id);
    final updated = await _capturePreview(tab, bookmark);
    if (!mounted) return;
    _snack(
      updated ? '已更新「${bookmark.displayTitle}」的预览图' : '暂时截不到图，请等页面显示完整后再试',
    );
  }

  /// Screenshots [tab] and stores the result as [bookmark]'s preview.
  ///
  /// Returns false when there was nothing to capture (blank frame, view not
  /// ready, page navigated away): a failed capture must never replace a good
  /// preview, so nothing is written in that case.
  Future<bool> _capturePreview(BrowserTab tab, Bookmark bookmark) async {
    final state = _state;
    if (state == null) return false;
    if (!_thumbnailInFlight.add(tab.viewId)) return false;
    try {
      // Give the page a moment to finish painting: pageFinished fires while the
      // first frame can still be empty.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted || tab.blocked != null || tab.url == UrlResolver.homeUrl) {
        return false;
      }
      final bytes = await BrowserBridge.captureThumbnail(
        tab.viewId,
        maxWidth: 480,
      );
      if (bytes == null || bytes.isEmpty || !mounted) return false;
      // The tab may have navigated on while the capture was in flight.
      final current = state.bookmarkFor(tab.url);
      if (current == null || current.id != bookmark.id) return false;
      await state.setBookmarkThumbnail(current, bytes);
      return true;
    } finally {
      _thumbnailInFlight.remove(tab.viewId);
    }
  }

  // ------------------------------------------------------------- events

  void _onNativeEvent(BrowserEvent event) {
    final state = _state;
    if (state == null) return;

    BrowserTab? tab;
    for (final candidate in _tabs) {
      if (candidate.viewId == event.viewId) tab = candidate;
    }

    switch (event.type) {
      case 'pageStarted':
        state.logEvent('browser', '页面开始加载（视图 ${event.viewId}）：${event.url}');
        setState(() {
          tab?.loading = true;
          tab?.progress = 0;
          tab?.url = event.url;
          tab?.blocked = null;
        });
      case 'pageFinished':
        state.logEvent('browser', '页面加载完成（视图 ${event.viewId}）：${event.url}');
        if (tab != null) _clearLoadWatchdog(tab);
        setState(() {
          tab?.loading = false;
          tab?.progress = 100;
          tab?.url = event.url;
          if (event.title.isNotEmpty) tab?.title = event.title;
        });
        if (tab != null) _maybeRefreshPreview(tab);
      case 'progress':
        setState(() => tab?.progress = event.progress);
      case 'titleChanged':
        setState(() {
          if (event.title.isNotEmpty) tab?.title = event.title;
        });
      case 'urlChanged':
        setState(() {
          tab?.url = event.url;
          tab?.canGoBack = event.canGoBack;
          tab?.canGoForward = event.canGoForward;
        });
      case 'navigationBlocked':
        state.handleNativeEvent(event.raw);
        if (tab != null) _clearLoadWatchdog(tab);
        setState(() => tab?.loading = false);
        _snack('已按名单拦截：${event.explanation}');
      case 'requestBlocked':
        state.handleNativeEvent(event.raw);
      case 'newWindow':
        if (event.url.isNotEmpty) {
          state.logEvent('browser', '页面请求新窗口：${event.url}');
          _addTab(url: event.url);
        }
      case 'consoleMessage':
        // 防翻页 narrates arming/releasing the mask on this channel; only the
        // tab the child is looking at may drive the countdown.
        if (tab != null && tab.viewId == _active?.viewId) {
          _handleGuardConsole(event);
        }
        // A page that dies inside its own script still reports a finished load,
        // so this is the only report of it — and the only clue that explains a
        // page which rendered nothing. Level filtering lives in AppState.
        state.logPageConsoleError(
          viewId: event.viewId,
          message: event.message,
          level: event.level,
          source: event.source,
          line: event.line,
        );
      case 'pageError':
        state.logEvent(
          'browser',
          '页面加载失败（视图 ${event.viewId}，code=${event.errorCode}）：'
              '${event.url} ${event.message}',
          level: LogLevel.error,
        );
        if (tab != null) _clearLoadWatchdog(tab);
        setState(() => tab?.loading = false);
        if (event.message.isNotEmpty) {
          _snack('页面加载失败（${event.errorCode}）：${event.message}');
        }
      case 'downloadRequested':
        // The native layer only hands allowed URLs to the download manager,
        // and additionally emits requestBlocked for refused ones.
        state.logEvent('browser', '下载请求：${event.url}（${event.allowed ? '允许' : '拦截'}）');
        _snack(event.allowed ? '开始下载：${event.url}' : '下载被名单拦截：${event.url}');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
          duration: const Duration(seconds: 4),
        ),
      );
  }

  // ------------------------------------------------------------- system back

  /// Whether the Android back button should leave the app.
  ///
  /// It only does so from the start page. While a page is displayed back closes
  /// the tab instead — with a single tab that lands on the start page — so a
  /// child cannot drop straight to the launcher from inside a page, and the
  /// browser never disappears by accident.
  bool get _canLeaveApp {
    final tab = _active;
    return tab == null || tab.showsStartView;
  }

  /// Closes the tab that is showing a page, which returns to the start page
  /// when it was the last one.
  void _handleSystemBack() {
    if (_tabs.isEmpty) return;
    // 防翻页: leaving the page is exactly what the hold is for.
    if (_guardBlocksNavigation()) return;
    _closeTab(_activeIndex);
  }

  // ------------------------------------------------------------- 防翻页（FlipGuard）

  /// Whether the page's mask is holding input right now.
  bool get _guardCooling => _guardRemainingMs > 0;

  /// Whole seconds left in the current hold (rounded up, so it never shows 0
  /// while the page is still blocking).
  int get _guardRemainingSeconds => (_guardRemainingMs / 1000).ceil();

  /// One tick of the strip; how often the seconds are redrawn.
  static const Duration _guardTick = Duration(milliseconds: 250);

  /// Starts holding the page and the navigation that would leave it.
  void _startGuardHold(int ms, String reason) {
    setState(() {
      _guardRemainingMs = ms;
      _guardReason = reason;
    });
    _guardTimer?.cancel();
    _guardTimer = Timer.periodic(_guardTick, (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _guardRemainingMs -= _guardTick.inMilliseconds;
        if (_guardRemainingMs <= 0) {
          _guardRemainingMs = 0;
          timer.cancel();
          _guardTimer = null;
        }
      });
    });
  }

  void _endGuardHold() {
    _guardTimer?.cancel();
    _guardTimer = null;
    if (_guardRemainingMs == 0) return;
    setState(() => _guardRemainingMs = 0);
  }

  /// Turns the page's console narration of the mask into app state.
  ///
  /// The script prints `[flipguard] cool <ms> <reason>` when it arms and
  /// `[flipguard] release` when the hold ends; the 700 ms provisional window is
  /// ignored because a countdown for it would only flicker.
  void _handleGuardConsole(BrowserEvent event) {
    const String prefix = '[flipguard] ';
    if (!event.message.startsWith(prefix)) return;
    // A page that was loaded while the switch was on can still narrate after it
    // was switched off; the switch is the authority, so ignore it then.
    if (!_flipGuardWanted) return;
    final String rest = event.message.substring(prefix.length).trim();
    if (rest == 'release' || rest == 'disabled') {
      // 'disabled' means the host switched the guard off in this very document;
      // a countdown left running after that would be a lie.
      _endGuardHold();
      return;
    }
    final RegExpMatch? cool = RegExp(r'^cool (\d+)ms (\S+)$').firstMatch(rest);
    if (cool == null) return;
    final int ms = int.tryParse(cool.group(1)!) ?? 0;
    if (ms < 1000) return;
    final String reason = cool.group(2)!;
    final String label = _guardReasonLabel(reason);
    _state?.logEvent(
      'browser',
      '防翻页：锁住 ${(ms / 1000).round()} 秒（触发信号：$label）',
    );
    _startGuardHold(ms, label);
  }

  /// The script's signal names, in the operator's language.
  static String _guardReasonLabel(String reason) {
    switch (reason) {
      case 'swipe':
        return '横向滑动';
      case 'edge-tap':
        return '边缘点击';
      case 'picture-added':
      case 'picture-removed':
      case 'picture-src':
        return '整屏换图';
      case 'latch-picture':
        return '边缘点击后换图';
      case 'scroll-jump':
        return '整页滚动';
      case 'hash':
        return '地址变化';
      case 'page-key':
        return '翻页键';
      default:
        return reason;
    }
  }

  /// Toggles 防翻页 from the top bar and stores the choice.
  Future<void> _toggleFlipGuard() async {
    final state = _state;
    // 防翻页 会限制孩子的翻页并挡住返回，同样先问密码。
    final bool want = !_flipGuardWanted;
    final bool allowed = await _confirmSwitch(
      '关闭防翻页',
      '关闭防翻页需要家长密码（打开不需要）。关掉之后孩子可以随意翻页。',
      turningOn: want,
    );
    if (!allowed) return;
    setState(() => _flipGuardWanted = want);
    if (!want) _endGuardHold();
    final int seconds = state?.settings.flipGuardSeconds ?? 10;
    _snack(want ? '防翻页：已开启（翻页后锁 $seconds 秒）' : '防翻页：已关闭');
    if (state == null) return;
    await state.updateSettings(
      state.settings.copyWith(flipGuardEnabled: want),
    );
  }

  /// Toggles 防反复看 from the top bar (same row as 防翻页).
  Future<void> _toggleAntiRepeat() async {
    final state = _state;
    final bool want = !_antiRepeatWanted;
    final bool allowed = await _confirmSwitch(
      '关闭防反复看',
      '关闭防反复看需要家长密码（打开不需要）。关掉之后看过的书签不再变灰，可以反复打开。',
      turningOn: want,
    );
    if (!allowed) return;
    setState(() => _antiRepeatWanted = want);
    final int minutes = state?.settings.antiRepeatMinutes ?? 10;
    _snack(want ? '防反复看：已开启（看过 $minutes 分钟后才能再看）' : '防反复看：已关闭');
    if (state == null) return;
    await state.updateSettings(
      state.settings.copyWith(antiRepeatEnabled: want),
    );
  }

  /// Refuses a way out of the page while the hold is running.
  ///
  /// 防翻页 only paces page turns, so this is deliberately narrow: it blocks
  /// going *back* and going *home* (the two ways the child leaves the page),
  /// and says how long is left instead of silently ignoring the press.
  bool _guardBlocksNavigation() {
    if (!_guardCooling) return false;
    _snack('防翻页：还有 $_guardRemainingSeconds 秒');
    return true;
  }

  // ------------------------------------------------------- 固定桌面（LockTask）

  /// Reads the platform's real lock task state into [_pinActive].
  ///
  /// Only ever *reports*; it never rewrites [_pinWanted], because "the system has
  /// not switched yet" is not the same as "the user changed their mind".
  Future<void> _refreshPinActive() async {
    final String result = await BrowserBridge.lockTaskState();
    if (!mounted) return;
    final bool active = result != 'none';
    if (active == _pinActive) return;
    setState(() => _pinActive = active);
  }

  /// The rule for the protection switches: **turning one on needs no password,
  /// turning it off does.**
  ///
  /// A child flipping a protection on only makes the tablet stricter (and is easy
  /// to undo), while switching one off is exactly what the protection exists to
  /// prevent — so the password guards only that direction.
  Future<bool> _confirmSwitch(
    String title,
    String reason, {
    required bool turningOn,
  }) async {
    if (turningOn) return true;
    return _confirmParent(title, reason);
  }

  /// Asks for the parental password before a parent-only switch is touched.
  ///
  /// Both top-bar switches sit in the child-facing chrome, so without this a
  /// child could turn the device's controls off (or on) with one tap. There is
  /// nothing to check when the parental gate is switched off entirely, or when
  /// no password has been set yet — in the latter case the switch works and says
  /// so, exactly like the home page's edit mode.
  Future<bool> _confirmParent(String title, String reason) async {
    final state = _state;
    if (state == null) return false;
    if (!state.settings.parentalGateEnabled) return true;
    final bool unlocked = await showParentalPasswordPrompt(
      context,
      title: title,
      reason: reason,
      confirmLabel: '确认',
    );
    if (!mounted || !unlocked) return false;
    if (!state.settings.hasParentalPassword) {
      _snack('还没有设置家长密码，已直接切换（可在 设置 → 家长验证 里设置）');
    }
    return true;
  }

  /// Toggles 固定桌面.
  ///
  /// The button follows the **intent**, which flips the moment it is pressed and
  /// is stored for the next launch. That is what a switch has to do: reading the
  /// platform back first made the button lag one press behind, because Android
  /// enters lock task *after* the system confirmation — the first press pinned
  /// while the icon still looked off, the second then "turned it on" again
  /// without unpinning anything.
  ///
  /// Whether the device actually obliged is a separate matter, so it is polled
  /// ([_startPinSettle]) and reported; a refusal never silently flips the switch
  /// back, it says so.
  Future<void> _togglePinned() async {
    final state = _state;
    final bool want = !_pinWanted;
    // 跟另外两个保护开关同一条规则：打开不用密码（只是把平板锁得更紧，随时能再关），
    // 关闭要家长密码——那一下才是"放孩子出去"。
    final bool allowed = await _confirmSwitch(
      '关闭固定桌面',
      '关闭固定桌面需要家长密码（打开不需要）。关掉之后 Home 与最近任务键会恢复，'
          '孩子可以离开本应用。',
      turningOn: want,
    );
    if (!allowed) return;
    setState(() => _pinWanted = want);
    // 先落一份"想要的状态"（不阻塞下面真正的动作：写盘是真实 I/O，会慢一拍），
    // 然后立刻去请求系统——按钮的反馈不该排在磁盘后面。
    final Future<void> persisted = state == null
        ? Future<void>.value()
        : state.updateSettings(state.settings.copyWith(lockTaskEnabled: want));
    final String result = await BrowserBridge.syncDesktopPin(wanted: want);
    if (!mounted) return;
    final bool activeNow = result != 'none';
    if (activeNow != _pinActive) setState(() => _pinActive = activeNow);
    _startPinSettle(want);
    _snack(
      want
          ? '固定桌面：已请求固定（系统若弹框请确认；生效后 Home 与最近任务键不再响应）'
          : '固定桌面：已请求解除固定',
    );
    await persisted;
  }

  /// Polls the platform until lock task matches [want] (or gives up after ~2.4s).
  ///
  /// Entering lock task is asynchronous — the state changes only after the system
  /// confirmation — so the immediate read after the request is usually still
  /// `none`. Each tick only rebuilds when the value really changed, so a settled
  /// wall is not kept awake.
  void _startPinSettle(bool want) {
    _pinSettleTimer?.cancel();
    _pinSettleTicks = 0;
    _pinSettleTimer = Timer.periodic(const Duration(milliseconds: 400), (timer) async {
      _pinSettleTicks += 1;
      final String result = await BrowserBridge.lockTaskState();
      if (!mounted) {
        timer.cancel();
        return;
      }
      final bool active = result != 'none';
      if (active != _pinActive) setState(() => _pinActive = active);
      final bool settled = active == want;
      if (!settled && _pinSettleTicks < 6) return;
      timer.cancel();
      _pinSettleTimer = null;
      if (!settled && want) {
        _snack('系统还没有进入固定桌面：若弹了确认框请确认；一直没有的话，请在系统设置里开启「固定窗口」');
      }
    });
  }

  // --------------------------------------------------------- top-bar 后退

  /// The ⟵ button: page history first, then the wall.
  ///
  /// A page opened straight from a bookmark (or from the block panel) has no
  /// in-page history, so the browser's own goBack would do nothing and the
  /// button used to sit disabled — the only way home was the 起始页 button. It
  /// now falls back to the start page instead. Either way the wall comes back
  /// at the offset it was left at (see [StartView]), i.e. the child sees the
  /// screen from before the page was opened, not its top.
  void _handleBackButton() {
    final tab = _active;
    if (tab == null || tab.showsStartView) return;
    if (_guardBlocksNavigation()) return;
    if (tab.canGoBack) {
      unawaited(tab.controller.goBack());
      return;
    }
    _navigate(_homeUrl);
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final tab = _active;
    final theme = Theme.of(context);

    // No address bar: the page fills the screen and the only chrome is one thin
    // strip of navigation controls, the tab list and the menu.
    return PopScope(
      canPop: _canLeaveApp,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleSystemBack();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _BrowserTopBar(
                tabs: _tabs,
                activeIndex: _activeIndex,
                tab: tab,
                onSelect: _selectTab,
                onClose: _closeTab,
                onAddTab: () {
                  if (_guardBlocksNavigation()) return;
                  _addTab(activate: true);
                },
                pinWanted: _pinWanted,
                pinActive: _pinActive,
                onTogglePinned: _togglePinned,
                flipGuardWanted: _flipGuardWanted,
                onToggleFlipGuard: _toggleFlipGuard,
                antiRepeatWanted: _antiRepeatWanted,
                onToggleAntiRepeat: _toggleAntiRepeat,
                guardCooling: _guardCooling,
                guardRemaining: _guardRemainingSeconds,
                guardReason: _guardReason,
                onBack: _handleBackButton,
                onForward: () => tab?.controller.goForward(),
                onReload: () {
                  if (tab == null) return;
                  if (tab.loading) {
                    unawaited(tab.controller.stop());
                    _clearLoadWatchdog(tab);
                    setState(() => tab.loading = false);
                  } else if (tab.url != UrlResolver.homeUrl) {
                    // Reload, or re-load when the view went away (going to the
                    // start page destroys it) — a plain reload would be dropped.
                    _issueLoad(tab, tab.url, reset: true);
                  }
                },
                onHome: () {
                  if (_guardBlocksNavigation()) return;
                  _navigate(_homeUrl);
                },
                onRefreshPreview:
                    tab != null &&
                        tab.blocked == null &&
                        tab.url != UrlResolver.homeUrl &&
                        state.isBookmarked(tab.url)
                    ? _refreshActivePreview
                    : null,
                onOpenFile: _openLocalFile,
                onRules: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const RulesScreen()),
                ),
                onTester: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PolicyTesterScreen(),
                  ),
                ),
                onSettings: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                ),
                onLog: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const RequestLogScreen(),
                  ),
                ),
              ),
              if (tab != null && tab.loading)
                LinearProgressIndicator(
                  value: tab.progress <= 0 ? null : tab.progress / 100,
                  minHeight: 2,
                ),
              Expanded(
                child: _tabs.isEmpty
                    ? const SizedBox.shrink()
                    : IndexedStack(
                        index: _activeIndex,
                        children: [
                          for (final each in _tabs)
                            _buildTabBody(each, state, theme),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabBody(BrowserTab tab, AppState state, ThemeData theme) {
    if (tab.blocked != null) {
      return _BlockedView(
        url: tab.url,
        decision: tab.blocked!,
        onAllowAndBookmark: _allowBlockedPage,
        onBack: () {
          setState(() {
            tab.blocked = null;
            tab.url = _homeUrl;
          });
        },
        onEditRules: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => const RulesScreen())),
        onTest: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const PolicyTesterScreen()),
        ),
      );
    }
    if (tab.showsStartView) {
      return StartView(onNavigate: _navigate);
    }
    return PolicyWebView(
      viewId: tab.viewId,
      settings: _nativeSettings(state.settings.toNativeSettings()),
      policy: state.nativePolicyPayload(),
      onCreated: (_) => tab.controller.markCreated(),
      onDisposed: tab.controller.markDisposed,
    );
  }
}

/// The browser's only chrome: one thin strip holding the navigation buttons,
/// the tab list and the menu.
///
/// There is deliberately no address bar — the page is meant to fill the screen
/// and everything reachable is a bookmark, so nothing can be typed into the
/// browser itself. The menu on the right is where settings live.
class _BrowserTopBar extends StatelessWidget {
  const _BrowserTopBar({
    required this.tabs,
    required this.activeIndex,
    required this.tab,
    required this.onSelect,
    required this.onClose,
    required this.onAddTab,
    required this.pinWanted,
    required this.pinActive,
    required this.onTogglePinned,
    required this.flipGuardWanted,
    required this.onToggleFlipGuard,
    required this.antiRepeatWanted,
    required this.onToggleAntiRepeat,
    required this.guardCooling,
    required this.guardRemaining,
    required this.guardReason,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onHome,
    required this.onRefreshPreview,
    required this.onOpenFile,
    required this.onRules,
    required this.onTester,
    required this.onSettings,
    required this.onLog,
  });

  final List<BrowserTab> tabs;
  final int activeIndex;
  final BrowserTab? tab;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onAddTab;

  /// 固定桌面 的意图（开关状态）：按钮显示的就是它。
  final bool pinWanted;

  /// 系统是否真的固定住了（用来在提示里如实说明）。
  final bool pinActive;

  /// 切换「固定桌面」。
  final VoidCallback onTogglePinned;

  /// 防翻页 的开关状态（跟 [pinWanted] 一样是意图，按下即翻）。
  final bool flipGuardWanted;

  /// 切换「防翻页」。
  final VoidCallback onToggleFlipGuard;

  /// 防反复看 的开关状态，以及切换它（跟防翻页并排）。
  final bool antiRepeatWanted;
  final VoidCallback onToggleAntiRepeat;

  /// 页面正被防翻页锁着，还剩几秒、因为什么——用来提示"按了也没用"。
  final bool guardCooling;
  final int guardRemaining;
  final String guardReason;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onReload;
  final VoidCallback onHome;

  /// Null unless the current page belongs to a bookmark (nothing to refresh).
  final Future<void> Function()? onRefreshPreview;

  final VoidCallback onOpenFile;
  final VoidCallback onRules;
  final VoidCallback onTester;
  final VoidCallback onSettings;
  final VoidCallback onLog;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 显示着网页（或拦截面板）时后退键总能按：页内有历史就退一页，
    // 没有就退回起始页——停在离开时的那一行。起始页上它没有去处，保持禁用。
    final bool backEnabled = tab != null && !tab!.showsStartView;
    return Container(
      height: 46,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Row(
        children: [
          IconButton(
            tooltip: guardCooling ? '防翻页：还有 $guardRemaining 秒' : '后退',
            visualDensity: VisualDensity.compact,
            onPressed: backEnabled ? onBack : null,
            icon: const Icon(Icons.arrow_back, size: 20),
          ),
          IconButton(
            tooltip: '前进',
            visualDensity: VisualDensity.compact,
            onPressed: (tab?.canGoForward ?? false) ? onForward : null,
            icon: const Icon(Icons.arrow_forward, size: 20),
          ),
          IconButton(
            tooltip: (tab?.loading ?? false) ? '停止' : '刷新',
            visualDensity: VisualDensity.compact,
            onPressed: onReload,
            icon: Icon(
              (tab?.loading ?? false) ? Icons.close : Icons.refresh,
              size: 20,
            ),
          ),
          IconButton(
            tooltip: guardCooling ? '防翻页：还有 $guardRemaining 秒' : '起始页',
            visualDensity: VisualDensity.compact,
            onPressed: onHome,
            icon: const Icon(Icons.home_outlined, size: 20),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              itemCount: tabs.length,
              itemBuilder: (context, index) {
                final each = tabs[index];
                final selected = index == activeIndex;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    onTap: () => onSelect(index),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      constraints: const BoxConstraints(
                        maxWidth: 200,
                        minWidth: 96,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: selected
                            ? theme.colorScheme.surface
                            : theme.colorScheme.surface.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected
                              ? theme.colorScheme.primary.withValues(alpha: 0.5)
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        children: [
                          if (each.loading)
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Icon(
                              each.blocked != null
                                  ? Icons.block
                                  : each.url.startsWith('file://')
                                  ? Icons.insert_drive_file_outlined
                                  : Icons.public,
                              size: 14,
                              color: each.blocked != null
                                  ? theme.colorScheme.error
                                  : null,
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              each.title,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          IconButton(
                            iconSize: 14,
                            visualDensity: VisualDensity.compact,
                            tooltip: '关闭标签页',
                            onPressed: () => onClose(index),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // 防反复看 + 防翻页：并排放在「固定桌面」左边（三个都是"管孩子"的开关）。
          IconButton(
            key: antiRepeatToggleKey,
            tooltip: antiRepeatWanted
                ? '防反复看：已开启（点一下需要家长密码）'
                : '防反复看：已关闭（点一下开启，不用密码）',
            visualDensity: VisualDensity.compact,
            onPressed: onToggleAntiRepeat,
            icon: Icon(
              antiRepeatWanted ? Icons.timer_outlined : Icons.timer_off_outlined,
              size: 20,
              color: antiRepeatWanted ? theme.colorScheme.primary : null,
            ),
          ),
          // The countdown lives **in the bar** as a badge on the lock icon: the
          // strip that used to sit under the bar pushed the page down for a few
          // seconds at a time, which is exactly the page space it must not cost.
          IconButton(
            key: flipGuardToggleKey,
            tooltip: flipGuardWanted
                ? (guardCooling
                    ? '防翻页：已开启，正在锁（还有 $guardRemaining 秒，$guardReason）'
                    : '防翻页：已开启（点一下需要家长密码）')
                : '防翻页：已关闭（点一下开启，不用密码）',
            visualDensity: VisualDensity.compact,
            onPressed: onToggleFlipGuard,
            icon: guardCooling
                ? Badge(
                    key: flipGuardCountdownKey,
                    label: Text('$guardRemaining'),
                    child: Icon(
                      Icons.lock_clock,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                  )
                : Icon(
                    flipGuardWanted ? Icons.lock_clock : Icons.lock_open_outlined,
                    size: 20,
                    color: flipGuardWanted ? theme.colorScheme.primary : null,
                  ),
          ),
          // 固定桌面：与「+」「⋮」同一排。图标跟着**开关意图**走（按下即翻），
          // 提示里如实写出系统那边的真实状态。
          IconButton(
            key: lockTaskToggleKey,
            tooltip: pinWanted
                ? (pinActive
                    ? '固定桌面：已固定（点一下需要家长密码）'
                    : '固定桌面：已开启，但系统还没固定（点一下需要家长密码）')
                : (pinActive
                    ? '固定桌面：已关闭，但系统仍在固定（点一下开启，不用密码）'
                    : '固定桌面：未固定（点一下开启，不用密码；屏蔽 Home 键）'),
            visualDensity: VisualDensity.compact,
            onPressed: onTogglePinned,
            icon: Icon(
              pinWanted ? Icons.push_pin : Icons.push_pin_outlined,
              size: 20,
              color: pinWanted ? theme.colorScheme.primary : null,
            ),
          ),
          IconButton(
            tooltip: '新建标签页',
            visualDensity: VisualDensity.compact,
            onPressed: onAddTab,
            icon: const Icon(Icons.add, size: 20),
          ),
          PopupMenuButton<String>(
            tooltip: '菜单',
            onSelected: (value) {
              switch (value) {
                case 'settings':
                  onSettings();
                case 'rules':
                  onRules();
                case 'tester':
                  onTester();
                case 'log':
                  onLog();
                case 'file':
                  onOpenFile();
                case 'preview':
                  onRefreshPreview?.call();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings_outlined, size: 18),
                    SizedBox(width: 12),
                    Text('设置'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'rules', child: Text('黑白名单')),
              const PopupMenuItem(value: 'tester', child: Text('策略测试器')),
              const PopupMenuItem(value: 'log', child: Text('访问日志')),
              const PopupMenuItem(value: 'file', child: Text('打开本地网页')),
              if (onRefreshPreview != null)
                const PopupMenuItem(value: 'preview', child: Text('更新当前页预览图')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shown instead of the WebView when the policy refused a navigation. The
/// native layer renders its own equivalent page for refusals it detects
/// itself (redirects, subresources, popups).
class _BlockedView extends StatelessWidget {
  const _BlockedView({
    required this.url,
    required this.decision,
    required this.onAllowAndBookmark,
    required this.onBack,
    required this.onEditRules,
    required this.onTest,
  });

  final String url;
  final PolicyDecision decision;
  final Future<void> Function() onAllowAndBookmark;
  final VoidCallback onBack;
  final VoidCallback onEditRules;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matched = decision.decisiveRules;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(32),
          children: [
            Row(
              children: [
                Icon(Icons.block, color: theme.colorScheme.error, size: 28),
                const SizedBox(width: 12),
                Text('访问被拦截', style: theme.textTheme.headlineSmall),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              decision.reason.labelZh,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 20),
            _BlockedField(label: '请求地址', value: url, mono: true),
            _BlockedField(
              label: '规范化地址',
              value: decision.normalizedUrl,
              mono: true,
            ),
            if (matched.isNotEmpty)
              _BlockedField(
                label: '决定性的名单条目（最具体者胜）',
                value: matched
                    .map((m) => '${m.kind.labelZh}：${m.rule.pattern}')
                    .join('\n'),
                mono: true,
              ),
            if (decision.conflictResolved)
              _BlockedField(
                label: '冲突解决',
                value:
                    '黑白名单均命中且互不包含，按当前设置「'
                    '${decision.reason.labelZh}」处理',
              ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () => onAllowAndBookmark(),
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('加为书签并允许访问'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onBack,
                  icon: const Icon(Icons.home_outlined),
                  label: const Text('返回起始页'),
                ),
                OutlinedButton.icon(
                  onPressed: onTest,
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('用策略测试器分析'),
                ),
                OutlinedButton.icon(
                  onPressed: onEditRules,
                  icon: const Icon(Icons.rule),
                  label: const Text('调整黑白名单'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BlockedField extends StatelessWidget {
  const _BlockedField({
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 4),
          SelectableText(
            value,
            style: mono
                ? theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')
                : theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
