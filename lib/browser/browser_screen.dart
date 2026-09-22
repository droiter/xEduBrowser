import 'dart:async';

import 'package:flutter/material.dart';

import '../bookmarks/bookmark.dart';
import '../bookmarks/bookmark_dialog.dart';
import '../files/local_files_screen.dart';
import '../log/request_log_screen.dart';
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

class _BrowserScreenState extends State<BrowserScreen> {
  final List<BrowserTab> _tabs = [];
  StreamSubscription<BrowserEvent>? _eventSubscription;
  AppState? _state;
  bool _wired = false;
  int _nextViewId = 1;
  int _activeIndex = 0;

  /// Bookmark ids whose preview was already refreshed during this app run, so a
  /// page that reloads (or is opened twice) is not re-screenshotted every time.
  final Set<String> _thumbnailRefreshed = <String>{};

  /// Views with a capture in flight, so one slow screenshot is not queued twice.
  final Set<int> _thumbnailInFlight = <int>{};

  BrowserTab? get _active =>
      _activeIndex >= 0 && _activeIndex < _tabs.length ? _tabs[_activeIndex] : null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_wired) return;
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

    _eventSubscription =
        BrowserBridge.eventStream().map(BrowserEvent.fromMap).listen(_onNativeEvent);
    _addTab(activate: true);
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    super.dispose();
  }

  Map<String, dynamic> _nativeSettings(Map<String, dynamic> settings) => {
        ...settings,
        'blockPageHtml': BlockPageTemplate.html,
      };

  // ------------------------------------------------------------- tabs

  /// The configured start page, falling back to the internal `about:home`.
  String get _homeUrl {
    final configured = _state?.settings.homeUrl.trim() ?? '';
    return configured.isEmpty ? UrlResolver.homeUrl : configured;
  }

  BrowserTab _addTab({bool activate = true, String? url}) {
    final tab = BrowserTab.create(viewId: _nextViewId++, url: url ?? _homeUrl);
    _tabs.add(tab);
    if (activate) _activeIndex = _tabs.length - 1;
    setState(() {});
    if (tab.url != UrlResolver.homeUrl) {
      // Queued until the platform view exists; see BrowserViewController.
      unawaited(tab.controller.loadUrl(tab.url));
    }
    return tab;
  }

  Future<void> _closeTab(int index) async {
    if (_tabs.length == 1) {
      // Never leave the app with zero tabs: reset the last one to the start page.
      _navigate(_homeUrl);
      return;
    }
    final tab = _tabs.removeAt(index);
    unawaited(BrowserBridge.disposeView(tab.viewId));
    if (_activeIndex >= _tabs.length) _activeIndex = _tabs.length - 1;
    setState(() {});
  }

  void _selectTab(int index) {
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
    setState(() {
      tab.url = resolved.url;
      tab.blocked = decision.allowed ? null : decision;
    });

    if (decision.allowed) {
      unawaited(tab.controller.loadUrl(resolved.url));
    } else {
      _snack('已拦截：${decision.explanation}');
    }
  }

  Future<void> _openLocalFile() async {
    final url = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const LocalFilesScreen()),
    );
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
    _snack(result.grantWhitelist
        ? '已添加书签「${bookmark.displayTitle}」并加入白名单（网址 + 所在站点）'
        : '已添加书签「${bookmark.displayTitle}」（未加入白名单）');

    _navigate(url);
  }

  // ------------------------------------------------------------- previews

  /// Refreshes the tile preview of a bookmarked page once it has been shown.
  ///
  /// A bookmark is added from the settings screen, where there is no page to
  /// photograph, so the cover is captured the first time the page is actually
  /// opened in the browser — or refreshed on the next run when the page is
  /// opened again. The home page then shows the real page instead of the
  /// generated monogram.
  void _maybeRefreshPreview(BrowserTab tab) {
    final state = _state;
    if (state == null || tab != _active) return;
    if (tab.blocked != null || tab.url == UrlResolver.homeUrl) return;
    final bookmark = state.bookmarkFor(tab.url);
    if (bookmark == null) return;
    if (!_thumbnailRefreshed.add(bookmark.id)) return;
    unawaited(_capturePreview(tab, bookmark));
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
    _snack(updated
        ? '已更新「${bookmark.displayTitle}」的预览图'
        : '暂时截不到图，请等页面显示完整后再试');
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
      final bytes = await BrowserBridge.captureThumbnail(tab.viewId, maxWidth: 480);
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
        setState(() {
          tab?.loading = true;
          tab?.progress = 0;
          tab?.url = event.url;
          tab?.blocked = null;
        });
      case 'pageFinished':
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
        setState(() => tab?.loading = false);
        _snack('已按名单拦截：${event.explanation}');
      case 'requestBlocked':
        state.handleNativeEvent(event.raw);
      case 'newWindow':
        if (event.url.isNotEmpty) _addTab(url: event.url);
      case 'pageError':
        setState(() => tab?.loading = false);
        if (event.message.isNotEmpty) {
          _snack('页面加载失败（${event.errorCode}）：${event.message}');
        }
      case 'downloadRequested':
        // The native layer only hands allowed URLs to the download manager,
        // and additionally emits requestBlocked for refused ones.
        _snack(event.allowed
            ? '开始下载：${event.url}'
            : '下载被名单拦截：${event.url}');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
        duration: const Duration(seconds: 4),
      ));
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final tab = _active;
    final theme = Theme.of(context);

    // No address bar: the page fills the screen and the only chrome is one thin
    // strip of navigation controls, the tab list and the menu.
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _BrowserTopBar(
              tabs: _tabs,
              activeIndex: _activeIndex,
              tab: tab,
              onSelect: _selectTab,
              onClose: _closeTab,
              onAddTab: () => _addTab(activate: true),
              onBack: () => tab?.controller.goBack(),
              onForward: () => tab?.controller.goForward(),
              onReload: () {
                if (tab == null) return;
                if (tab.loading) {
                  unawaited(tab.controller.stop());
                } else if (tab.url != UrlResolver.homeUrl) {
                  // Reload, or re-load when the view went away (going to the
                  // start page destroys it) — a plain reload would be dropped.
                  unawaited(tab.controller.reloadOrLoad(tab.url));
                }
              },
              onHome: () => _navigate(_homeUrl),
              onRefreshPreview: tab != null &&
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
                MaterialPageRoute<void>(builder: (_) => const PolicyTesterScreen()),
              ),
              onSettings: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
              onLog: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const RequestLogScreen()),
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
                        for (final each in _tabs) _buildTabBody(each, state, theme),
                      ],
                    ),
            ),
          ],
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
        onEditRules: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const RulesScreen()),
        ),
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
    return Container(
      height: 46,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Row(
        children: [
          IconButton(
            tooltip: '后退',
            visualDensity: VisualDensity.compact,
            onPressed: (tab?.canGoBack ?? false) ? onBack : null,
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
            tooltip: '起始页',
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
                      constraints: const BoxConstraints(maxWidth: 200, minWidth: 96),
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
                              color: each.blocked != null ? theme.colorScheme.error : null,
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
                const PopupMenuItem(
                  value: 'preview',
                  child: Text('更新当前页预览图'),
                ),
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
              style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 20),
            _BlockedField(label: '请求地址', value: url, mono: true),
            _BlockedField(label: '规范化地址', value: decision.normalizedUrl, mono: true),
            if (matched.isNotEmpty)
              _BlockedField(
                label: '决定性的名单条目（最具体者胜）',
                value: matched.map((m) => '${m.kind.labelZh}：${m.rule.pattern}').join('\n'),
                mono: true,
              ),
            if (decision.conflictResolved)
              _BlockedField(
                label: '冲突解决',
                value: '黑白名单均命中且互不包含，按当前设置「'
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
  const _BlockedField({required this.label, required this.value, this.mono = false});

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
