import 'dart:async';

import 'package:flutter/material.dart';

import '../browser/block_page_template.dart';
import '../browser/browser_bridge.dart';
import '../browser/policy_webview.dart';
import '../browser/url_input.dart';
import '../files/local_file_url.dart';
import '../state/app_scope.dart';
import 'bookmark_dialog.dart';

/// Test hook for the preview's 加为书签 action.
const Key previewAddBookmarkKey = ValueKey<String>('preview-add-bookmark');

/// Test hook for the preview's address field.
const Key previewAddressKey = ValueKey<String>('preview-address');

/// A page preview for the add-bookmark dialog.
///
/// The parent types an address (or picks a local HTML), opens it here, clicks
/// through it and confirms what the page actually is before — or after —
/// bookmarking it. The address field follows the navigation, and 加为书签
/// bookmarks **the page currently displayed**, granting the address together
/// with the site (or the local folder) holding it.
///
/// **This screen runs without the address filter** (`previewPolicy`), because
/// the page being checked is usually not allowed yet. That is why it is only
/// reachable from the settings screens — which sit behind the parental gate —
/// and why the banner says so. Never open it from the child-facing browser.
class BookmarkPreviewScreen extends StatefulWidget {
  const BookmarkPreviewScreen({
    super.key,
    required this.initialUrl,
    this.initialTitle = '',
  });

  final String initialUrl;
  final String initialTitle;

  @override
  State<BookmarkPreviewScreen> createState() => _BookmarkPreviewScreenState();
}

class _BookmarkPreviewScreenState extends State<BookmarkPreviewScreen> {
  late final int _viewId = nextPlatformViewId();
  late final BrowserViewController _controller = BrowserViewController(
    viewId: _viewId,
  );
  final TextEditingController _address = TextEditingController();
  final FocusNode _addressFocus = FocusNode();
  StreamSubscription<BrowserEvent>? _events;

  String _url = '';
  String _title = '';
  bool _loading = false;
  int _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;

  /// Set once a bookmark was created here, so the dialog that opened this
  /// screen closes instead of adding a second one.
  bool _added = false;

  @override
  void initState() {
    super.initState();
    _title = widget.initialTitle;
    _open(widget.initialUrl);
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
    unawaited(_events?.cancel());
    unawaited(BrowserBridge.disposeView(_viewId));
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------- navigation

  /// Opens [input], resolved without the loopback mapping: a local page is
  /// previewed straight from disk, so the built-in server — which filters every
  /// request it serves — is not involved.
  void _open(String input) {
    final resolved = UrlResolver.resolve(input.trim());
    if (resolved.url.isEmpty) {
      _snack(resolved.error ?? '无法识别的地址');
      return;
    }
    // A folder is opened through its index.html — the same rule as the server.
    var target = resolved.url;
    if (LocalFileUrl.isDirectory(target)) {
      final index = LocalFileUrl.indexHtmlFor(target);
      if (index == null) {
        _snack('这个目录里没有 index.html：请选择具体的 HTML 文件，'
            '或用设置里的「从本地目录导入」批量导入。');
        return;
      }
      target = index;
    }
    setState(() {
      _url = target;
      _loading = true;
      _progress = 0;
    });
    _syncAddress();
    unawaited(_controller.loadUrl(target));
  }

  void _syncAddress() {
    if (_addressFocus.hasFocus) return;
    _address.text = _url;
  }

  void _onEvent(BrowserEvent event) {
    if (event.viewId != _viewId) return;
    switch (event.type) {
      case 'pageStarted':
        setState(() {
          _loading = true;
          _progress = 0;
          if (event.url.isNotEmpty) _url = event.url;
        });
        _syncAddress();
      case 'pageFinished':
        setState(() {
          _loading = false;
          _progress = 100;
          if (event.url.isNotEmpty) _url = event.url;
          if (event.title.isNotEmpty) _title = event.title;
        });
        _syncAddress();
      case 'urlChanged':
        setState(() {
          if (event.url.isNotEmpty) _url = event.url;
          _canGoBack = event.canGoBack;
          _canGoForward = event.canGoForward;
        });
        _syncAddress();
      case 'progress':
        setState(() => _progress = event.progress);
      case 'titleChanged':
        if (event.title.isNotEmpty) setState(() => _title = event.title);
      case 'newWindow':
        // Stay in the preview instead of opening a tab behind the settings.
        if (event.url.isNotEmpty) _open(event.url);
      case 'pageError':
        setState(() => _loading = false);
        if (event.message.isNotEmpty) {
          _snack('页面加载失败（${event.errorCode}）：${event.message}');
        }
      case 'navigationBlocked':
        // Should not happen: this view runs unfiltered.
        setState(() => _loading = false);
        _snack('已按名单拦截：${event.explanation}');
      case 'downloadRequested':
        _snack(event.allowed ? '开始下载：${event.url}' : '下载被名单拦截：${event.url}');
    }
  }

  // ----------------------------------------------------------- bookmarking

  /// Bookmarks the page currently displayed.
  ///
  /// The headline address **and** the site (or the local folder) containing it
  /// join the whitelist — for a local HTML that is the directory pattern
  /// `file:///…/<目录>/`, which is what makes the flipbook's assets load.
  Future<void> _addBookmark() async {
    final state = AppScope.read(context);
    final url = _url;
    if (url.isEmpty || url == UrlResolver.homeUrl) {
      _snack('先打开一个页面，再添加书签');
      return;
    }
    final result = await showBookmarkDialog(
      context,
      url: url,
      initialTitle: _title,
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
    setState(() => _added = true);
    _snack(
      result.grantWhitelist
          ? '已添加书签「${bookmark.displayTitle}」并加入白名单：'
                '${bookmark.whitelistPatterns.join('、')}'
          : '已添加书签「${bookmark.displayTitle}」（未加入白名单）',
    );
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

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);

    return PopScope(
      // The result says whether a bookmark was created here, so the dialog that
      // opened this screen can close instead of adding another one.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(_added);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title.isEmpty ? '浏览确认' : _title),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                key: previewAddBookmarkKey,
                onPressed: _addBookmark,
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: const Text('加为书签'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              _PreviewNotice(theme: theme),
              _addressBar(theme),
              if (_loading)
                LinearProgressIndicator(
                  value: _progress <= 0 ? null : _progress / 100,
                  minHeight: 2,
                ),
              Expanded(
                child: PolicyWebView(
                  viewId: _viewId,
                  settings: {
                    ...state.settings.toNativeSettings(),
                    'blockPageHtml': BlockPageTemplate.html,
                  },
                  policy: state.nativePolicyPayload(),
                  // Filtering off for this view alone: the page is being
                  // checked precisely because it is not allowed yet.
                  previewPolicy: const {'enabled': false},
                  onCreated: (_) => _controller.markCreated(),
                  onDisposed: _controller.markDisposed,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addressBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      child: Row(
        children: [
          IconButton(
            tooltip: '后退',
            onPressed: _canGoBack ? () => _controller.goBack() : null,
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            tooltip: '前进',
            onPressed: _canGoForward ? () => _controller.goForward() : null,
            icon: const Icon(Icons.arrow_forward),
          ),
          IconButton(
            tooltip: _loading ? '停止' : '刷新',
            onPressed: () {
              if (_loading) {
                unawaited(_controller.stop());
              } else {
                unawaited(_controller.reloadOrLoad(_url));
              }
            },
            icon: Icon(_loading ? Icons.close : Icons.refresh),
          ),
          Expanded(
            child: TextField(
              key: previewAddressKey,
              controller: _address,
              focusNode: _addressFocus,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.go,
              onSubmitted: (value) {
                _addressFocus.unfocus();
                _open(value);
              },
              decoration: InputDecoration(
                isDense: true,
                hintText: '输入网址或本地文件路径',
                prefixIcon: Icon(
                  _url.startsWith('file://') ? Icons.folder : Icons.search,
                  size: 18,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 12,
                ),
              ),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '打开',
            onPressed: () {
              _addressFocus.unfocus();
              _open(_address.text);
            },
            icon: const Icon(Icons.subdirectory_arrow_left),
          ),
        ],
      ),
    );
  }
}

/// Says out loud that this page is not being filtered — it must never look like
/// ordinary browsing.
class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Icon(
            Icons.visibility_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '预览模式：这一页不受黑白名单限制，仅用于确认内容；'
              '确认好后点「加为书签」，该地址与它所在的网站（本地网页是所在目录）会加入白名单。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
