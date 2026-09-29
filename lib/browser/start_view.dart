import 'dart:async';

import 'package:flutter/material.dart';

import '../bookmarks/bookmark_grid.dart';
import '../parental/parental_password_prompt.dart';
import '../bookmarks/bookmark.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';

/// The internal `about:home` page: the bookmark wall, one section per category.
///
/// Rendered by Flutter rather than a WebView so the start page can never be
/// blocked by the very rules it lets you edit. Bookmarks are normally managed
/// from the 书签管理 page (设置 → 书签管理); the small pencil in the corner opens
/// an **edit mode** guarded by the parental password for the parent who is
/// already looking at the wall.
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
  Future<void> _scrollToTop() async {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return;
    await controller.animateTo(
      0,
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

  /// Asks for the parental password, then turns edit mode on.
  ///
  /// With no password configured there is nothing to check, so the mode opens
  /// directly — and says so, instead of pretending a password was verified.
  Future<void> _openEditMode(BuildContext context, AppState state) async {
    if (state.homeEditMode) {
      state.setHomeEditMode(false);
      return;
    }
    final bool unlocked = await showParentalPasswordPrompt(
      context,
      title: '进入编辑模式',
      reason: '编辑模式可以改书名、换分类、隐藏、重做预览图和删除书签，需要家长密码。',
    );
    if (!context.mounted || !unlocked) return;
    if (!state.settings.hasParentalPassword) {
      showAppSnackBar(context, '还没有设置家长密码，已直接进入编辑模式');
    }
    state.setHomeEditMode(true);
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
          final double wallWidth = (constraints.maxWidth - 56).clamp(160.0, 100000.0);
          // 防反复看：为最近一次解锁安排一次刷新，灰块到点自己恢复。
          _scheduleCooldownRefresh(state);
          return CustomScrollView(
        controller: _controller,
        slivers: <Widget>[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(28, 16, 28, 0),
            sliver: SliverToBoxAdapter(
              child: Row(
            children: [
              Text('书签', style: theme.textTheme.titleMedium),
              const Spacer(),
              if (state.homeEditMode)
                FilledButton.icon(
                  key: homeEditDoneKey,
                  onPressed: () => state.setHomeEditMode(false),
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('完成'),
                )
              else
                IconButton(
                  key: homeEditModeButtonKey,
                  tooltip: '编辑书签（需要家长密码）',
                  onPressed: () => _openEditMode(context, state),
                  icon: const Icon(Icons.edit_outlined),
                ),
            ],
            ),
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
                  '改完点「完成」退出。',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
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
          );
        },
            ),
          ),
          // 编辑模式的「回到顶部」做成浮动按钮：表头会随滚动移出屏幕，钉在表头里的
          // 按钮滚下去就够不着了，而这个按钮在任何位置都能点。
          if (state.homeEditMode)
            Positioned(
              right: 20,
              bottom: 20,
              child: FloatingActionButton.small(
                key: homeEditTopKey,
                tooltip: '回到顶部',
                onPressed: _scrollToTop,
                child: const Icon(Icons.vertical_align_top),
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
