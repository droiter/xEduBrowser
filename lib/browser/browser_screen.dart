import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../bookmarks/bookmark.dart';
import '../bookmarks/bookmark_dialog.dart';
import '../bookmarks/category_dialogs.dart';
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
  final TextEditingController _addressController = TextEditingController();
  final FocusNode _addressFocus = FocusNode();
  StreamSubscription<BrowserEvent>? _eventSubscription;
  AppState? _state;
  bool _wired = false;
  int _nextViewId = 1;
  int _activeIndex = 0;

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
    _syncAddressBar();
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    _addressController.dispose();
    _addressFocus.dispose();
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
    _syncAddressBar();
  }

  void _selectTab(int index) {
    setState(() => _activeIndex = index);
    _syncAddressBar();
  }

  // --------------------------------------------------------- navigation

  void _syncAddressBar() {
    final tab = _active;
    if (tab == null || _addressFocus.hasFocus) return;
    _addressController.text = UrlResolver.displayFor(tab.url);
  }

  /// Every user-initiated navigation goes through here: resolve, then decide.
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
      _syncAddressBar();
      return;
    }

    // The native layer also enforces the policy; deciding here as well gives
    // an immediate, consistent answer and avoids loading a page we know is
    // refused.
    final decision = state.engine.decide(resolved.url);
    state.logDecision(resolved.url, decision);
    setState(() {
      tab.url = resolved.url;
      tab.blocked = decision.allowed ? null : decision;
    });
    _syncAddressBar();

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

  /// The star button: bookmark the current page, or manage an existing
  /// bookmark.
  Future<void> _toggleBookmark() async {
    final state = _state;
    final tab = _active;
    if (state == null || tab == null) return;

    final existing = state.bookmarkFor(tab.url);
    if (existing != null) {
      final removeRule = await confirmBookmarkDelete(context, bookmark: existing);
      if (removeRule == null || !mounted) return;
      await state.removeBookmark(existing, removeWhitelistRule: removeRule);
      if (mounted) _snack('已删除书签「${existing.displayTitle}」');
      return;
    }
    await _addBookmarkForActiveTab();
  }

  /// Adds the active tab as a bookmark.
  ///
  /// The address also joins the whitelist unless the user unticks it, which is
  /// what makes bookmarking a way to grant access. [navigateAfterwards] retries
  /// the page, for the "blocked → allow it" flow; [allowUrlPrompt] lets the home
  /// page ask for an address when no page is open.
  Future<void> _addBookmarkForActiveTab({
    bool navigateAfterwards = false,
    bool allowUrlPrompt = false,
    String categoryId = uncategorizedId,
  }) async {
    final state = _state;
    final tab = _active;
    if (state == null || tab == null) return;

    String url;
    // A blocked page is only bookmarkable through the "allow it" button, where
    // the URL is already known; otherwise there is nothing on screen to
    // bookmark and the address has to be typed.
    final blockedPage = tab.blocked != null;
    final needsTypedUrl =
        tab.url == UrlResolver.homeUrl || (blockedPage && !navigateAfterwards);
    if (needsTypedUrl) {
      if (!allowUrlPrompt) {
        _snack('先打开一个网页，再添加书签');
        return;
      }
      final typed = await showBookmarkUrlPrompt(context);
      if (typed == null || !mounted) return;
      final resolved = UrlResolver.resolve(
        typed,
        localServerBase: state.localServer?.baseUrl,
        localRoot: state.localServerRunning ? state.effectiveLocalRoot : null,
      );
      if (resolved.url.isEmpty || resolved.url == UrlResolver.homeUrl) {
        _snack(resolved.error ?? '无法识别的地址');
        return;
      }
      url = resolved.url;
    } else {
      url = tab.url;
    }
    final result = await showBookmarkDialog(
      context,
      url: url,
      initialTitle: tab.blocked != null ? '' : tab.title,
      whitelistDefault: state.settings.bookmarkWhitelistByDefault,
      categoryId: categoryId,
    );
    if (result == null || !mounted) return;

    // A blocked page has nothing worth screenshotting.
    final bytes = navigateAfterwards || tab.url != url
        ? null
        : await _captureActiveThumbnail();
    final bookmark = await state.addBookmark(
      url: url,
      title: result.title,
      thumbnail: bytes,
      addToWhitelist: result.grantWhitelist,
      wholeSite: result.wholeSite,
      categoryId: result.categoryId,
    );
    if (!mounted) return;
    _snack(result.grantWhitelist
        ? '已添加书签「${bookmark.displayTitle}」并加入白名单'
        : '已添加书签「${bookmark.displayTitle}」（未加入白名单）');

    if (navigateAfterwards) _navigate(url);
  }

  /// Screenshots the active tab, or null when there is nothing to capture.
  Future<Uint8List?> _captureActiveThumbnail() async {
    final tab = _active;
    if (tab == null || !tab.controller.isCreated) return null;
    if (tab.url == UrlResolver.homeUrl || tab.blocked != null) return null;
    return BrowserBridge.captureThumbnail(tab.viewId);
  }

  /// Picks a local directory and imports the HTML pages found in its
  /// first-level subdirectories.
  Future<void> _importBookmarksFromDirectory() async {
    final state = _state;
    if (state == null) return;

    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const LocalFilesScreen(pickDirectory: true)),
    );
    if (picked == null || !mounted) return;

    final path = _localPathOf(picked);
    if (path == null) {
      _snack('无法解析所选目录：$picked');
      return;
    }

    final outcome = await showBookmarkImportDialog(context, directoryPath: path);
    if (outcome == null || !mounted) return;

    final buffer = StringBuffer(outcome.summary);
    if (outcome.whitelistPattern.isNotEmpty) {
      buffer.write('；白名单：${outcome.whitelistPattern}');
    }
    _snack(buffer.toString());
  }

  /// `file:///a/b/` → `/a/b`.
  String? _localPathOf(String url) {
    if (!url.startsWith('file://')) return null;
    var path = Uri.decodeComponent(url.substring('file://'.length));
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    return path.isEmpty ? null : path;
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
        _syncAddressBar();
      case 'pageFinished':
        setState(() {
          tab?.loading = false;
          tab?.progress = 100;
          tab?.url = event.url;
          if (event.title.isNotEmpty) tab?.title = event.title;
        });
        _syncAddressBar();
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
        _syncAddressBar();
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

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _TabStrip(
              tabs: _tabs,
              activeIndex: _activeIndex,
              onSelect: _selectTab,
              onClose: _closeTab,
              onAdd: () => _addTab(activate: true),
            ),
            _Toolbar(
              controller: _addressController,
              focusNode: _addressFocus,
              tab: tab,
              onSubmit: (value) {
                _addressFocus.unfocus();
                _navigate(value);
              },
              onBack: () => tab?.controller.goBack(),
              onForward: () => tab?.controller.goForward(),
              onReload: () {
                if (tab == null) return;
                if (tab.loading) {
                  unawaited(tab.controller.stop());
                } else if (tab.url != UrlResolver.homeUrl) {
                  unawaited(tab.controller.reload());
                }
              },
              onHome: () => _navigate(_homeUrl),
              onBookmark: _toggleBookmark,
              isBookmarked: tab != null && state.isBookmarked(tab.url),
              canBookmark: tab != null &&
                  tab.url != UrlResolver.homeUrl &&
                  tab.blocked == null,
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
        onAllowAndBookmark: () => _addBookmarkForActiveTab(navigateAfterwards: true),
        onBack: () {
          setState(() {
            tab.blocked = null;
            tab.url = _homeUrl;
          });
          _syncAddressBar();
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
      return StartView(
        onNavigate: _navigate,
        onOpenLocalFile: _openLocalFile,
        onAddBookmark: (categoryId) => _addBookmarkForActiveTab(
          allowUrlPrompt: true,
          categoryId: categoryId,
        ),
        onImportBookmarks: _importBookmarksFromDirectory,
        onCaptureThumbnail: _captureActiveThumbnail,
      );
    }
    return PolicyWebView(
      viewId: tab.viewId,
      settings: _nativeSettings(state.settings.toNativeSettings()),
      policy: state.nativePolicyPayload(),
      onCreated: (_) => tab.controller.markCreated(),
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.tabs,
    required this.activeIndex,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
  });

  final List<BrowserTab> tabs;
  final int activeIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 44,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              itemCount: tabs.length,
              itemBuilder: (context, index) {
                final tab = tabs[index];
                final selected = index == activeIndex;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    onTap: () => onSelect(index),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 220, minWidth: 140),
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
                          if (tab.loading)
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Icon(
                              tab.blocked != null
                                  ? Icons.block
                                  : tab.url.startsWith('file://')
                                      ? Icons.insert_drive_file_outlined
                                      : Icons.public,
                              size: 14,
                              color: tab.blocked != null ? theme.colorScheme.error : null,
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              tab.title,
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
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 20),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.focusNode,
    required this.tab,
    required this.onSubmit,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onHome,
    required this.onBookmark,
    required this.isBookmarked,
    required this.canBookmark,
    required this.onOpenFile,
    required this.onRules,
    required this.onTester,
    required this.onSettings,
    required this.onLog,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final BrowserTab? tab;
  final ValueChanged<String> onSubmit;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onReload;
  final VoidCallback onHome;
  final Future<void> Function() onBookmark;
  final bool isBookmarked;
  final bool canBookmark;
  final VoidCallback onOpenFile;
  final VoidCallback onRules;
  final VoidCallback onTester;
  final VoidCallback onSettings;
  final VoidCallback onLog;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      child: Row(
        children: [
          IconButton(
            tooltip: '后退',
            onPressed: (tab?.canGoBack ?? false) ? onBack : null,
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            tooltip: '前进',
            onPressed: (tab?.canGoForward ?? false) ? onForward : null,
            icon: const Icon(Icons.arrow_forward),
          ),
          IconButton(
            tooltip: (tab?.loading ?? false) ? '停止' : '刷新',
            onPressed: onReload,
            icon: Icon(tab?.loading ?? false ? Icons.close : Icons.refresh),
          ),
          IconButton(
            tooltip: '起始页',
            onPressed: onHome,
            icon: const Icon(Icons.home_outlined),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              textInputAction: TextInputAction.go,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: onSubmit,
              decoration: InputDecoration(
                isDense: true,
                hintText: '输入网址、域名或本地文件路径',
                prefixIcon: Icon(
                  tab?.url.startsWith('file://') ?? false ? Icons.folder : Icons.search,
                  size: 18,
                ),
                suffixIcon: IconButton(
                  tooltip: '清空',
                  icon: const Icon(Icons.backspace_outlined, size: 16),
                  onPressed: () => controller.clear(),
                ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
              ),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '打开',
            onPressed: () {
              focusNode.unfocus();
              onSubmit(controller.text);
            },
            icon: const Icon(Icons.subdirectory_arrow_left),
          ),
          IconButton(
            tooltip: isBookmarked ? '已加入书签（点击管理）' : '添加书签',
            onPressed: canBookmark ? () => onBookmark() : null,
            icon: Icon(isBookmarked ? Icons.star : Icons.star_border),
            color: isBookmarked ? theme.colorScheme.primary : null,
          ),
          IconButton(tooltip: '本地文件', onPressed: onOpenFile, icon: const Icon(Icons.folder_open)),
          IconButton(
            tooltip: '黑白名单',
            onPressed: onRules,
            icon: const Icon(Icons.rule),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              switch (value) {
                case 'tester':
                  onTester();
                case 'log':
                  onLog();
                case 'settings':
                  onSettings();
                case 'file':
                  onOpenFile();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'tester', child: Text('策略测试器')),
              PopupMenuItem(value: 'log', child: Text('访问日志')),
              PopupMenuItem(value: 'settings', child: Text('浏览器设置')),
              PopupMenuItem(value: 'file', child: Text('打开本地网页')),
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
