import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'bookmark.dart';
import 'bookmark_edit_actions.dart';

/// Test hook for the home page's 进入编辑模式 button.
const Key homeEditModeButtonKey = ValueKey<String>('home-edit-mode');

/// Test hook for the 完成 button shown while the home page is in edit mode.
const Key homeEditDoneKey = ValueKey<String>('home-edit-done');

/// Test hook for the 回到顶部 button, shown next to 完成 in edit mode.
const Key homeEditTopKey = ValueKey<String>('home-edit-top');

/// The home page bookmark wall: one section per category, each a grid of square
/// tiles with the title underneath, with the starred 我的最爱 section pinned on
/// top.
///
/// Tiles can be dragged onto one another to change their order inside a
/// category, and dragged from one category into another. A section header folds
/// its category shut, so a wall with several subjects fits on one screen. There
/// is deliberately no add/delete control here — bookmarks are managed in the
/// settings screen, or from [editing] mode, which a parent unlocks with the
/// parental password. Hidden bookmarks are left out unless [editing] is on, so
/// the parent can always bring one back.
class BookmarkGrid extends StatelessWidget {
  const BookmarkGrid({
    super.key,
    required this.onOpen,
    this.editing = false,
    required this.wallWidth,
  });

  /// Width the wall itself gets (the scroll view minus its padding).
  ///
  /// Handed in rather than measured with a [LayoutBuilder]: a sliver layout
  /// builder sees the scroll offset in its constraints, so it rebuilds on every
  /// scroll frame — which re-created the whole edit-mode row list per frame. The
  /// outer box's constraints only change when the window does.
  final double wallWidth;

  /// Opens a bookmark through the browser's policy gate.
  ///
  /// The whole bookmark, not just its URL: the wall has to be able to say no
  /// (防反复看) and to record that it was watched.
  final ValueChanged<Bookmark> onOpen;

  /// Edit mode: the wall keeps its shape — the very same tiles — and each one
  /// grows the six management buttons (★ 我的最爱 / 隐藏·显示 / 更改标题 /
  /// 更换分类 / 强制生成缩略图 / 删除) underneath, wrapped over as many rows as
  /// they need.
  ///
  /// Hidden bookmarks come back **at the end of their category**, and hidden
  /// categories move to the **end of the page**, so a parent can reach what the
  /// child cannot see without the visible part of the wall moving around.
  final bool editing;

  /// Section id of the pinned 我的最爱 section.
  ///
  /// Starts with a NUL so it can never collide with a real category id, and it
  /// only names the fold state — 我的最爱 is a view, not a stored category.
  static const String favoritesSectionId = '\u0000favorites';

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);

    /// The bookmarks a section shows, in the order it shows them.
    ///
    /// The child never sees a hidden one. Edit mode brings them back — **after**
    /// the visible ones, so the wall the parent was looking at keeps its shape
    /// and whatever is currently invisible waits at the end of its category.
    List<Bookmark> sectionBookmarks(List<Bookmark> bookmarks) {
      final shown = <Bookmark>[];
      final hidden = <Bookmark>[];
      for (final bookmark in bookmarks) {
        (state.isHiddenOnHome(bookmark) ? hidden : shown).add(bookmark);
      }
      if (!editing) return shown;
      return [...shown, ...hidden];
    }

    /// Categories in wall order. While editing, the hidden ones move to the end
    /// of the page (still reachable, no longer mixed in with the visible ones).
    final List<String> orderedCategoryIds = editing
        ? [
            for (final id in state.populatedCategoryIds)
              if (!state.isCategoryHidden(id)) id,
            for (final id in state.populatedCategoryIds)
              if (state.isCategoryHidden(id)) id,
          ]
        : state.populatedCategoryIds;

    // 已经是"孩子能看到的"那一份：隐藏的书签或隐藏分类下的书签都不在里面。
    final favourites = state.favoriteBookmarks;
    final sections = <(String, String, List<Bookmark>, bool)>[
      // The pinned section is a child-facing shortcut. While the wall is being
      // edited it would just repeat rows that are already listed under their own
      // category — with their own ★ button — so it gives way there.
      if (!editing && favourites.isNotEmpty)
        (favoritesSectionId, '我的最爱', favourites, false),
      for (final categoryId in orderedCategoryIds)
        // A hidden category's whole section disappears for the child; edit mode
        // keeps it so the parent can unhide it.
        if (editing || !state.isCategoryHidden(categoryId))
          (
            categoryId,
            state.categoryLabel(categoryId),
            sectionBookmarks(state.bookmarksIn(categoryId)),
            state.isCategoryHidden(categoryId),
          ),
    ].where((section) => section.$3.isNotEmpty).toList();

    if (sections.isEmpty) {
      // Everything the wall could show is hidden. Say so instead of leaving a
      // blank page — the way back is the pencil.
      return SliverToBoxAdapter(
        child: _HiddenWallNotice(
          hidden: state.bookmarks.where(state.isHiddenOnHome).length,
        ),
      );
    }

    // A **sliver group**, not a Column: the wall has to be laid out lazily. As
    // one giant child it was re-laid out on every scroll frame, and edit mode
    // (six buttons and a marker line per tile instead of one tile) turned that
    // into stutter — measured on a 150-bookmark wall, a dozen scroll drags took
    // 786ms in edit mode against 230ms on the child's wall, with **zero** widget
    // rebuilds: the cost was layout, not rebuilding.
    return SliverMainAxisGroup(
      slivers: <Widget>[
        for (final (id, label, bookmarks, hiddenSection) in sections)
          _CategorySection(
            state: state,
            wallWidth: wallWidth,
            sectionId: id,
            label: label,
            bookmarks: bookmarks,
            hiddenSection: hiddenSection,
            starred: id == favoritesSectionId,
            onToggleHidden: id == favoritesSectionId
                ? null
                : () => _toggleSectionHidden(state, id),
            onOpen: onOpen,
            editing: editing,
          ),
      ],
    );
  }

  /// Hides a category (and with it every bookmark under it) or shows it again.
  Future<void> _toggleSectionHidden(AppState state, String categoryId) async {
    final category = state.categoryById(categoryId);
    if (category == null) return;
    await state.setCategoryHidden(category, !category.hidden);
  }
}

/// Shown when every bookmark is hidden: the wall would otherwise be blank.
class _HiddenWallNotice extends StatelessWidget {
  const _HiddenWallNotice({required this.hidden});

  final int hidden;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        children: [
          Icon(Icons.visibility_off_outlined, size: 18, color: theme.hintColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$hidden 个书签都被隐藏了（书签或它所在的分类）。点右上角的铅笔进入编辑模式，'
              '再点眼睛图标即可恢复。',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// One section: a foldable header plus, while it is open, its tiles.
///
/// The fold state lives in [AppState] (in memory) rather than in this widget, so
/// it survives every rebuild of the wall — a tile reorder or a settings visit
/// does not pop the categories back open.
class _CategorySection extends StatelessWidget {
  const _CategorySection({
    required this.state,
    required this.wallWidth,
    required this.sectionId,
    required this.label,
    required this.bookmarks,
    required this.onOpen,
    required this.editing,
    this.starred = false,
    this.hiddenSection = false,
    this.onToggleHidden,
  });

  final AppState state;

  /// Width the wall gets; see [BookmarkGrid.wallWidth].
  final double wallWidth;

  /// Identifies the section for folding and for the test key; for 我的最爱 this
  /// is [BookmarkGrid.favoritesSectionId], not a real category id.
  final String sectionId;
  final String label;

  /// The tiles to show — already filtered by the caller.
  final List<Bookmark> bookmarks;

  /// The pinned 我的最爱 section, which gets a star in its header.
  final bool starred;

  /// This category is hidden from the child-facing wall (edit mode only).
  final bool hiddenSection;

  /// Hides/shows the category; null for the pinned 我的最爱 section.
  final VoidCallback? onToggleHidden;

  final ValueChanged<Bookmark> onOpen;
  final bool editing;

  /// The same numbers the child-facing grid hands to its delegate.
  static const double _maxTileExtent = 190;
  static const double _crossSpacing = 16;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final collapsed = state.isCategoryCollapsed(sectionId);

    return SliverMainAxisGroup(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Tooltip(
            message: collapsed ? '展开这一段' : '折叠这一段',
          child: InkWell(
            key: ValueKey<String>('bookmark-section-$sectionId'),
            onTap: () => state.toggleCategoryCollapsed(sectionId),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Row(
                children: [
                  Icon(
                    collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 20,
                    color: theme.hintColor,
                  ),
                  const SizedBox(width: 4),
                  if (starred) ...[
                    const Icon(Icons.star, size: 16, color: Color(0xFFF2B01E)),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${bookmarks.length}',
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                  ),
                  if (collapsed) ...[
                    const SizedBox(width: 8),
                    Text(
                      '已折叠',
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                    ),
                  ],
                  if (hiddenSection) ...[
                    const SizedBox(width: 8),
                    Text(
                      '已隐藏',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  // 隐藏/取消隐藏整个分类：只在编辑模式下给家长看。
                  if (editing && onToggleHidden != null) ...[
                    const Spacer(),
                    IconButton(
                      key: ValueKey<String>('section-hide-$sectionId'),
                      tooltip: hiddenSection ? '取消隐藏这个分类' : '隐藏这个分类（首页不显示）',
                      visualDensity: VisualDensity.compact,
                      onPressed: onToggleHidden,
                      icon: Icon(
                        hiddenSection
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ),
          ),
        ),
        // The tiles are not built at all while folded: a folded wall of a hundred
        // bookmarks costs nothing to lay out.
        if (!collapsed) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 10)),
          if (editing) _editableRows() else _tileGrid(),
        ],
        // The gap that used to live between sections in the old Column.
        const SliverToBoxAdapter(child: SizedBox(height: 22)),
      ],
    );
  }

  /// Column count and tile width, worked out the way
  /// [SliverGridDelegateWithMaxCrossAxisExtent] does it, so both modes agree on
  /// the wall's shape.
  static (int, double) _columns(double width) {
    final int columns =
        (width / (_maxTileExtent + _crossSpacing)).ceil().clamp(1, 64);
    return (columns, (width - _crossSpacing * (columns - 1)) / columns);
  }

  /// The child's wall: the same lazy grid as before, now a real sliver so only
  /// the visible tiles are laid out.
  Widget _tileGrid() => SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: _maxTileExtent,
          mainAxisSpacing: 18,
          crossAxisSpacing: _crossSpacing,
          // Taller than wide: the square thumbnail plus its caption below.
          childAspectRatio: 0.76,
        ),
        itemCount: bookmarks.length,
        itemBuilder: (BuildContext context, int index) {
          final bookmark = bookmarks[index];
          return BookmarkTile(
            bookmark: bookmark,
            onOpen: () => onOpen(bookmark),
            onReorderOnto: (dragged) => _dropOn(state, dragged, bookmark),
          );
        },
      );

  /// Edit mode: the same wall, one row of tiles at a time.
  ///
  /// Edit-mode tiles carry buttons and an optional marker line, so they are not
  /// all the same height and a [SliverGrid] cannot hold them; a row of fixed-width
  /// tiles can, and [SliverList] keeps only the visible rows alive. Tapping a tile
  /// still opens the page — the buttons are for editing, not a replacement for
  /// visiting it.
  Widget _editableRows() {
    final (int columns, double tileWidth) = _columns(wallWidth);
    final int rows = (bookmarks.length / columns).ceil();
    return SliverList.builder(
          itemCount: rows,
          itemBuilder: (BuildContext context, int row) {
            final int first = row * columns;
            final int last = math.min(first + columns, bookmarks.length);
            return Padding(
              // The Wrap this replaced spaced the runs, not the last row.
              padding: EdgeInsets.only(bottom: row == rows - 1 ? 0 : 18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (int i = first; i < last; i++) ...[
                    if (i > first) const SizedBox(width: _crossSpacing),
                    SizedBox(
                      key: ValueKey<String>('edit-item-${bookmarks[i].id}'),
                      width: tileWidth,
                      child: _EditableTile(
                        state: state,
                        bookmark: bookmarks[i],
                        width: tileWidth,
                        onOpen: () => onOpen(bookmarks[i]),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
  }

  /// Dropping tile A onto tile B gives A B's slot, moving B along — the same
  /// behaviour as dropping into a list. Dropping across sections moves the
  /// bookmark into that category.
  Future<void> _dropOn(AppState state, Bookmark dragged, Bookmark target) async {
    if (dragged.id == target.id) return;
    final siblings = state.bookmarksIn(target.categoryId);
    final targetIndex = siblings.indexWhere((b) => b.id == target.id);
    if (targetIndex < 0) return;

    if (dragged.categoryId == target.categoryId) {
      await state.reorderBookmark(dragged, targetIndex);
    } else {
      await state.moveBookmark(dragged, categoryId: target.categoryId, index: targetIndex);
    }
  }
}

/// One bookmark in edit mode: the tile the child sees, its state markers, then
/// the six actions — wrapped over as many rows as they need.
///
/// The tile itself is unchanged and still opens the page; the buttons are for
/// editing it, and a hidden bookmark is dimmed so a parent can tell at a glance
/// what the child's wall currently leaves out.
class _EditableTile extends StatelessWidget {
  const _EditableTile({
    required this.state,
    required this.bookmark,
    required this.width,
    required this.onOpen,
  });

  final AppState state;
  final Bookmark bookmark;

  /// Width handed out by the wall; only used to reproduce the grid cell's
  /// height, so the square keeps its size in both modes.
  final double width;

  final VoidCallback onOpen;

  /// The aspect ratio the child-facing grid gives every cell.
  static const double _cellAspectRatio = 0.76;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = bookmark.id;
    final hidden = state.isHiddenOnHome(bookmark);
    final markers = <String>[
      if (bookmark.favorite) '★ 我的最爱',
      if (state.isCoolingDown(bookmark)) '刚看过',
      if (bookmark.hidden) '已隐藏',
      if (!bookmark.hidden && state.isCategoryHidden(bookmark.categoryId))
        '分类已隐藏',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Opacity(
          opacity: hidden ? 0.6 : 1,
          child: SizedBox(
            height: width / _cellAspectRatio,
            child: _TileBody(bookmark: bookmark, onOpen: onOpen),
          ),
        ),
        if (markers.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            markers.join(' · '),
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: hidden ? theme.colorScheme.error : theme.hintColor,
            ),
          ),
        ],
        const SizedBox(height: 4),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 2,
          children: [
            _EditAction(
              key: ValueKey<String>('edit-favorite-$id'),
              label: bookmark.favorite ? '移出我的最爱' : '收藏到我的最爱',
              icon: bookmark.favorite ? Icons.star : Icons.star_border,
              color: bookmark.favorite ? const Color(0xFFF2B01E) : null,
              onTap: () =>
                  BookmarkEditActions.toggleFavorite(context, state, bookmark),
            ),
            _EditAction(
              key: ValueKey<String>('edit-hide-$id'),
              label: bookmark.hidden ? '取消隐藏' : '隐藏（首页不显示）',
              icon: bookmark.hidden
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              onTap: () =>
                  BookmarkEditActions.toggleHidden(context, state, bookmark),
            ),
            _EditAction(
              key: ValueKey<String>('edit-rename-$id'),
              label: '更改标题',
              icon: Icons.drive_file_rename_outline,
              onTap: () => BookmarkEditActions.rename(context, state, bookmark),
            ),
            _EditAction(
              key: ValueKey<String>('edit-move-$id'),
              label: '更换分类',
              icon: Icons.drive_file_move_outline,
              onTap: () => BookmarkEditActions.move(context, state, bookmark),
            ),
            _EditAction(
              key: ValueKey<String>('edit-thumbnail-$id'),
              label: '强制生成缩略图',
              icon: Icons.image_outlined,
              onTap: () =>
                  BookmarkEditActions.regenerateThumbnail(context, state, bookmark),
            ),
            _EditAction(
              key: ValueKey<String>('edit-delete-$id'),
              label: '删除',
              icon: Icons.delete_outline,
              color: theme.colorScheme.error,
              onTap: () => BookmarkEditActions.delete(context, state, bookmark),
            ),
          ],
        ),
      ],
    );
  }
}

/// One of the six actions under an edit-mode tile.
///
/// Deliberately **not** an [IconButton]: the wall is lazy, so scrolling builds and
/// discards rows continuously, and a Material icon button is a small tree of its
/// own (ink response, tooltip, hover/focus machinery, icon theme) that has to be
/// created and torn down again for every one of them. Six per tile × a row of
/// tiles × every row scrolled past is what made editing stutter. The label stays
/// for screen readers (and for `uiautomator`); the edit-mode hint above the wall
/// lists the six actions by name.
class _EditAction extends StatelessWidget {
  const _EditAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.color,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;

  /// Comfortably tappable with a finger, small enough that six fit per tile.
  static const double _size = 38;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_size / 2),
        child: SizedBox(
          width: _size,
          height: _size,
          child: Icon(icon, size: 20, color: color),
        ),
      ),
    );
  }
}

/// One bookmark: square thumbnail, then the title and its folder/host below.
///
/// The whole tile opens the bookmark; a long press picks it up for reordering,
/// which is why the tile carries no button of its own.
class BookmarkTile extends StatelessWidget {
  const BookmarkTile({
    super.key,
    required this.bookmark,
    required this.onOpen,
    this.onReorderOnto,
  });

  final Bookmark bookmark;
  final VoidCallback onOpen;

  /// Called with the dragged bookmark when another tile is dropped here.
  final Future<void> Function(Bookmark dragged)? onReorderOnto;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visual = _TileBody(bookmark: bookmark, onOpen: onOpen);

    final draggable = LongPressDraggable<Bookmark>(
      data: bookmark,
      delay: const Duration(milliseconds: 350),
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.9,
          child: SizedBox(
            // The overlay hands out unbounded height, so the tile needs an
            // explicit one or its Expanded square cannot lay out.
            width: 160,
            height: 160 / 0.76,
            child: _TileBody(bookmark: bookmark, onOpen: () {}),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: visual),
      child: visual,
    );

    if (onReorderOnto == null) return draggable;

    return DragTarget<Bookmark>(
      onWillAcceptWithDetails: (details) => details.data.id != bookmark.id,
      onAcceptWithDetails: (details) => onReorderOnto!(details.data),
      builder: (context, candidates, rejected) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: candidates.isEmpty ? Colors.transparent : theme.colorScheme.primary,
            width: 2,
          ),
        ),
        child: draggable,
      ),
    );
  }
}

class _TileBody extends StatelessWidget {
  const _TileBody({
    required this.bookmark,
    required this.onOpen,
  });

  final Bookmark bookmark;
  final VoidCallback onOpen;

  /// 缩略图与书签名之间的间隙；悬停提示的上沿也对齐到这里。
  static const double captionGap = 6;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbnail = bookmark.thumbnailPath;
    // 防反复看：刚看过的书签整块压成灰的，并显示还要等多久。
    final state = AppScope.of(context);
    final bool cooling = state.isCoolingDown(bookmark);
    final Duration left =
        cooling ? state.cooldownRemaining(bookmark) : Duration.zero;

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: <Widget>[
          InkWell(
        // The whole tile is tappable, caption included: with the title below
        // the square, tapping the text must open the bookmark too.
        onTap: onOpen,
        borderRadius: BorderRadius.circular(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 悬停提示挂在**缩略图**上：提示框于是落在缩略图正下方，
            // 与下面那行书名齐平；内容是书签名、大字，不再是网址。
            //
            // 偏移量必须按缩略图高度算，不能写死一个小数字：Tooltip 的位置以
            // 「目标中心点」为基准（`positionDependentBox`），固定值只会把提示
            // 压在缩略图中间。半个高度 + 间隙，提示的上沿正好落在书签名那一行。
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  return Tooltip(
                    message: bookmark.displayTitle,
                    textStyle: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                      color: theme.colorScheme.onInverseSurface,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    constraints: const BoxConstraints(maxWidth: 320),
                    preferBelow: true,
                    verticalOffset: constraints.maxHeight / 2 + captionGap,
                    waitDuration: const Duration(milliseconds: 350),
                    showDuration: const Duration(seconds: 6),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (thumbnail != null && thumbnail.isNotEmpty)
                              Image.file(
                                File(thumbnail),
                                fit: BoxFit.cover,
                                cacheWidth: 480,
                                errorBuilder: (context, error, stack) =>
                                    _Monogram(bookmark: bookmark),
                              )
                            else
                              _Monogram(bookmark: bookmark),
                            if (bookmark.whitelistPattern != null)
                              const Positioned(
                                top: 6,
                                right: 6,
                                child: _AllowedBadge(),
                              ),
                            if (cooling) Center(child: _CooldownBadge(left: left)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: captionGap),
            // The caption lives below the square, as specified.
            Text(
              bookmark.displayTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              bookmark.host,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
            ),
          ],
              ),
            ),
          // 一层灰罩住整块（缩略图与文字都压灰）。点击拦截在 StartView 判定，
          // 这里用 IgnorePointer 让点击穿透到下面本来就有的 InkWell。
          if (cooling)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF9E9E9E).withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The chip over a tile that was watched too recently: how long until it opens.
class _CooldownBadge extends StatelessWidget {
  const _CooldownBadge({required this.left});

  /// Time left before the bookmark may be opened again.
  final Duration left;

  @override
  Widget build(BuildContext context) {
    final int minutes = (left.inSeconds / 60).ceil().clamp(1, 600);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.hourglass_bottom, size: 14, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            '$minutes 分钟后可再看',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _AllowedBadge extends StatelessWidget {
  const _AllowedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_user_outlined, size: 11, color: Colors.white),
          SizedBox(width: 3),
          Text('已放行', style: TextStyle(color: Colors.white, fontSize: 9)),
        ],
      ),
    );
  }
}

/// Fallback tile: a colour derived from the host plus its monogram, so a
/// bookmark without a screenshot still looks deliberate.
class _Monogram extends StatelessWidget {
  const _Monogram({required this.bookmark});

  final Bookmark bookmark;

  static const List<Color> _palette = [
    Color(0xFF0E6E78),
    Color(0xFF35506B),
    Color(0xFF6B4A3A),
    Color(0xFF4A5D3A),
    Color(0xFF5B3F63),
    Color(0xFF7A5A2E),
  ];

  @override
  Widget build(BuildContext context) {
    final hue = bookmark.host.hashCode.abs() % _palette.length;
    final base = _palette[hue];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base, Color.lerp(base, Colors.black, 0.35)!],
        ),
      ),
      child: Center(
        child: Text(
          bookmark.monogram,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 36,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
