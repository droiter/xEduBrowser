import 'dart:async';

import 'package:flutter/material.dart';

import '../bookmarks/bookmark_grid.dart';
import '../bookmarks/bookmark.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';

/// Test hook for the 到顶 button of the bookmark wall.
const Key homeScrollTopKey = ValueKey<String>('home-scroll-top');

/// Test hook for the 到底 button of the bookmark wall.
const Key homeScrollBottomKey = ValueKey<String>('home-scroll-bottom');

/// The internal `about:home` page: the bookmark wall, one section per category.
///
/// Rendered by Flutter rather than a WebView so the start page can never be
/// blocked by the very rules it lets you edit. Bookmarks are normally managed
/// from the 书签管理 page (设置 → 书签管理); the pencil that opens an **edit mode**
/// (guarded by the parental password) now lives in the browser's top bar, next
/// to 固定桌面, and is only enabled while this page is showing.
///
/// The wall also remembers where it was scrolled to: opening a page throws this
/// widget away, so the offset lives in [AppState] and coming back lands on the
/// same row instead of the top (see [_StartViewState]).
class StartView extends StatefulWidget {
  const StartView({super.key, required this.onNavigate});

  /// Opens a bookmark's URL through the browser's policy gate.
  final ValueChanged<String> onNavigate;

  @override
  State<StartView> createState() => _StartViewState();
}

class _StartViewState extends State<StartView> {
  /// Keeps the wall where the child left it. The offset is handed to [AppState],
  /// because this widget is disposed the moment a page opens.
  ScrollController? _controller;

  /// One refresh scheduled for the moment the next 防反复看 lock expires, so a
  /// greyed tile comes back on its own. Deliberately a **single** timer rather
  /// than a repeating one: a periodic timer would keep `pumpAndSettle` — and the
  /// frame loop — busy forever.
  Timer? _cooldownRefresh;

  /// The deadline [_cooldownRefresh] was scheduled for; null when none is set.
  DateTime? _cooldownRefreshDue;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final state = AppScope.of(context);
    _controller = ScrollController(initialScrollOffset: state.homeScrollOffset)
      ..addListener(() {
        final controller = _controller;
        if (controller != null && controller.hasClients) {
          state.rememberHomeScrollOffset(controller.offset);
        }
      });
  }

  @override
  void dispose() {
    _cooldownRefresh?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  /// Rolls the wall back to the top: a parent who scrolled down to find a tile
  /// edits it, then wants the toolbar (and the rest of the wall) again.
  Future<void> _scrollToTop() => _scrollTo(0);

  /// Rolls the wall to its end (the last category / 展开 button).
  Future<void> _scrollToBottom() async {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return;
    await _scrollTo(controller.position.maxScrollExtent);
  }

  Future<void> _scrollTo(double offset) async {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return;
    await controller.animateTo(
      offset,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  /// Opens [bookmark] unless 防反复看 says it was watched too recently.
  ///
  /// Edit mode is the parent's tool: it neither blocks nor records, so checking a
  /// page from there never locks the child out.
  void _openBookmark(BuildContext context, AppState state, Bookmark bookmark) {
    if (state.homeEditMode) {
      widget.onNavigate(bookmark.url);
      return;
    }
    final Duration left = state.cooldownRemaining(bookmark);
    if (left > Duration.zero) {
      final int minutes = (left.inSeconds / 60).ceil().clamp(1, 600);
      showAppSnackBar(
        context,
        '「${bookmark.displayTitle}」刚看过，$minutes 分钟后才能再看',
      );
      return;
    }
    unawaited(state.markBookmarkOpened(bookmark));
    widget.onNavigate(bookmark.url);
  }

  /// Schedules one rebuild for when the nearest cooldown ends.
  ///
  /// Rescheduling only when the deadline actually changes keeps a rebuild-happy
  /// wall from pushing the timer back forever.
  void _scheduleCooldownRefresh(AppState state) {
    final DateTime? due = state.nextCooldownDeadline();
    if (due == _cooldownRefreshDue) return;
    _cooldownRefreshDue = due;
    _cooldownRefresh?.cancel();
    _cooldownRefresh = null;
    if (due == null) return;
    final Duration wait = state.nextCooldownWait() ?? Duration.zero;
    _cooldownRefresh = Timer(
      wait + const Duration(milliseconds: 250),
      () {
        _cooldownRefreshDue = null;
        if (mounted) setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);

    if (state.bookmarks.isEmpty) {
      // StartView is used inside the browser shell's Scaffold, but it brings its
      // own Material so it also renders correctly on its own (tests, previews).
      return const Material(type: MaterialType.transparency, child: _EmptyHome());
    }

    // A [CustomScrollView] rather than a [ListView]: the wall is a sliver group
    // now, so only the tiles on screen are built and laid out. With the whole
    // wall as one child of a list, every scroll frame re-laid out every bookmark —
    // and in edit mode, where each tile carries six buttons, that stuttered.
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                // Measured once here: the wall's own width, for the edit-mode rows.
                final double wallWidth =
                    (constraints.maxWidth - 56).clamp(160.0, 100000.0);
                // 防反复看：为最近一次解锁安排一次刷新，灰块到点自己恢复。
                _scheduleCooldownRefresh(state);
                return Scrollbar(
                  // 常驻滚动条：平板上外接鼠标时能一眼看到墙滚到哪儿了。
                  controller: _controller,
                  thumbVisibility: true,
                  // Android 上必须显式打开：否则滑块只是画出来，手指/鼠标拖不动。
                  // 加宽到 12dp 也是为了让手指按得住。
                  interactive: true,
                  thickness: 12,
                  radius: const Radius.circular(6),
                  scrollbarOrientation: ScrollbarOrientation.right,
                  child: CustomScrollView(
                    controller: _controller,
                    slivers: <Widget>[
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(28, 16, 28, 0),
                        sliver: SliverToBoxAdapter(
                          child: Text('书签', style: theme.textTheme.titleMedium),
                        ),
                      ),
                      if (state.homeEditMode)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(28, 2, 28, 0),
                          sliver: SliverToBoxAdapter(
                            child: Text(
                              '编辑模式：书签还是原来的方块，每个方块下面是它的操作按钮——'
                              '收藏到我的最爱、隐藏/显示、更改标题、更换分类、强制生成缩略图、删除。'
                              '隐藏的书签排在所属分类最后，隐藏的分类整段排在首页最后；'
                              '改完点顶栏的 ✓ 退出。',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.hintColor,
                              ),
                            ),
                          ),
                        ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(28, 14, 28, 40),
                        sliver: BookmarkGrid(
                          wallWidth: wallWidth,
                          // 打开网页**不退出编辑模式**：家长常常是点开一条看看页面对不对，
                          // 回到首页还要接着改。而且编辑模式是行布局、非编辑模式是方块布局，
                          // 一进一出就回不到原来那一行了（滚动位置相同、看到的内容却变了）。
                          onOpen: (Bookmark bookmark) =>
                              _openBookmark(context, state, bookmark),
                          editing: state.homeEditMode,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          // 到顶 / 到底做成浮动按钮：表头会随滚动移出屏幕，而这个按钮在任何位置
          // 都能点。无论是否在编辑模式都显示——长分类默认只展开 8 行，滚到深处后
          // 想回到顶部或直接跳到分类末尾都用得上。
          Positioned(
            right: 20,
            bottom: 20,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FloatingActionButton.small(
                  key: homeScrollTopKey,
                  // 两个浮动按钮不参与 Hero 动画：默认 tag 相同，页面跳转时会撞成
                  // "multiple heroes share the same tag"。
                  heroTag: null,
                  tooltip: '到顶',
                  onPressed: _scrollToTop,
                  child: const Icon(Icons.vertical_align_top),
                ),
                const SizedBox(height: 10),
                FloatingActionButton.small(
                  key: homeScrollBottomKey,
                  heroTag: null,
                  tooltip: '到底',
                  onPressed: _scrollToBottom,
                  child: const Icon(Icons.vertical_align_bottom),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown while there is nothing to open yet. Text only: with nothing to edit,
/// the home page still offers no control of its own.
class _EmptyHome extends StatelessWidget {
  const _EmptyHome();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bookmark_border, size: 44, color: theme.hintColor),
              const SizedBox(height: 14),
              Text('还没有书签', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                '点右上角菜单 →「设置」，在设置里添加书签；'
                '添加后会同时放行该网址和它所在的网站（本地网页则是它所在的目录）。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
