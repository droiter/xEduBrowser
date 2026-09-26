import 'dart:io';

import 'package:flutter/material.dart';

import '../pdf/pdf_document.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import 'bookmark.dart';
import 'bookmark_dialog.dart';
import 'category_dialogs.dart';
import 'thumbnail_capture.dart';

/// Test hook for the home page's 进入编辑模式 button.
const Key homeEditModeButtonKey = ValueKey<String>('home-edit-mode');

/// Test hook for the 完成 button shown while the home page is in edit mode.
const Key homeEditDoneKey = ValueKey<String>('home-edit-done');

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
  const BookmarkGrid({super.key, required this.onOpen, this.editing = false});

  /// Opens a bookmark's URL through the browser's policy gate.
  final ValueChanged<String> onOpen;

  /// Edit mode: each bookmark gets ★ / 隐藏 / 改标题 / 改分类 / 重做预览图 / 删除
  /// buttons, the wall is rendered as a list so the buttons have room, and
  /// hidden bookmarks are shown again.
  final bool editing;

  /// Section id of the pinned 我的最爱 section.
  ///
  /// Starts with a NUL so it can never collide with a real category id, and it
  /// only names the fold state — 我的最爱 is a view, not a stored category.
  static const String favoritesSectionId = '\u0000favorites';

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);

    /// The bookmarks a section may show: every one in edit mode (so a hidden
    /// tile can be brought back), only the visible ones for the child.
    List<Bookmark> visible(List<Bookmark> bookmarks) => editing
        ? bookmarks
        : [for (final b in bookmarks) if (!state.isHiddenOnHome(b)) b];

    // 已经是"孩子能看到的"那一份：隐藏的书签或隐藏分类下的书签都不在里面。
    final favourites = state.favoriteBookmarks;
    final sections = <(String, String, List<Bookmark>, bool)>[
      // The pinned section is a child-facing shortcut. While the wall is being
      // edited it would just repeat rows that are already listed under their own
      // category — with their own ★ button — so it gives way there.
      if (!editing && favourites.isNotEmpty)
        (favoritesSectionId, '我的最爱', favourites, false),
      for (final categoryId in state.populatedCategoryIds)
        // A hidden category's whole section disappears for the child; edit mode
        // keeps it so the parent can unhide it.
        if (editing || !state.isCategoryHidden(categoryId))
          (
            categoryId,
            state.categoryLabel(categoryId),
            visible(state.bookmarksIn(categoryId)),
            state.isCategoryHidden(categoryId),
          ),
    ].where((section) => section.$3.isNotEmpty).toList();

    if (sections.isEmpty) {
      // Everything the wall could show is hidden. Say so instead of leaving a
      // blank page — the way back is the pencil.
      return _HiddenWallNotice(
        hidden: state.bookmarks.where(state.isHiddenOnHome).length,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (id, label, bookmarks, hiddenSection) in sections) ...[
          _CategorySection(
            state: state,
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
          const SizedBox(height: 22),
        ],
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

  final ValueChanged<String> onOpen;
  final bool editing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final collapsed = state.isCategoryCollapsed(sectionId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
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
        // The tiles are not built at all while folded: a folded wall of a hundred
        // bookmarks costs nothing to lay out.
        if (!collapsed) ...[
          const SizedBox(height: 10),
          if (editing)
            // Edit mode replaces the wall with rows: the four action buttons
            // cannot fit under a square tile without squeezing the caption.
            for (final bookmark in bookmarks)
              _EditableBookmarkRow(key: ValueKey<String>('edit-row-${bookmark.id}'), state: state, bookmark: bookmark)
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 190,
                mainAxisSpacing: 18,
                crossAxisSpacing: 16,
                // Taller than wide: the square thumbnail plus its caption below.
                childAspectRatio: 0.76,
              ),
              itemCount: bookmarks.length,
              itemBuilder: (context, index) {
                final bookmark = bookmarks[index];
                return BookmarkTile(
                  bookmark: bookmark,
                  onOpen: () => onOpen(bookmark.url),
                  onReorderOnto: (dragged) => _dropOn(state, dragged, bookmark),
                );
              },
            ),
        ],
      ],
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

/// One bookmark while the home page is in edit mode: a compact row with the four
/// management actions a parent needs — rename, change category, regenerate the
/// preview, delete — without a detour through the settings screen.
class _EditableBookmarkRow extends StatelessWidget {
  const _EditableBookmarkRow({
    super.key,
    required this.state,
    required this.bookmark,
  });

  final AppState state;
  final Bookmark bookmark;

  Future<void> _rename(BuildContext context) async {
    final title = await showBookmarkRenameDialog(
      context,
      initialTitle: bookmark.displayTitle,
    );
    if (title == null || !context.mounted) return;
    await state.updateBookmark(bookmark.copyWith(title: title));
    if (!context.mounted) return;
    showAppSnackBar(context, '书名已保存');
  }

  Future<void> _move(BuildContext context) async {
    final target = await showBookmarkTargetCategoryDialog(context, bookmarkCount: 1);
    if (target == null || !context.mounted) return;
    await state.moveBookmarksToCategory([bookmark], categoryId: target);
    if (!context.mounted) return;
    showAppSnackBar(context, '已移动到「${state.categoryLabel(target)}」');
  }

  /// Force a fresh preview image, replacing whatever the tile shows now.
  Future<void> _regenerate(BuildContext context) async {
    if (PdfDocuments.localPathOf(bookmark.url) != null) {
      showAppSnackBar(context, 'PDF 由阅读器按页显示，不生成预览图');
      return;
    }
    showAppSnackBar(context, '正在重新生成「${bookmark.displayTitle}」的预览图…');
    final bytes = await captureThumbnailFor(context, url: bookmark.url);
    if (!context.mounted) return;
    final current = state.bookmarkFor(bookmark.url);
    if (bytes == null || bytes.isEmpty || current == null) {
      showAppSnackBar(context, '没能生成预览图，请确认该页面能正常打开后重试', isError: true);
      return;
    }
    await state.setBookmarkThumbnail(current, bytes);
    if (!context.mounted) return;
    showAppSnackBar(context, '预览图已重新生成');
  }

  Future<void> _delete(BuildContext context) async {
    final removeRule = await confirmBookmarkDelete(context, bookmark: bookmark);
    if (removeRule == null || !context.mounted) return;
    await state.removeBookmark(bookmark, removeWhitelistRule: removeRule);
    if (!context.mounted) return;
    showAppSnackBar(context, '已删除「${bookmark.displayTitle}」');
  }

  /// Stars or unstars the bookmark. 我的最爱 is a section of its own on top of
  /// the wall; the bookmark stays where it already is as well.
  Future<void> _toggleFavorite(BuildContext context) async {
    final star = !bookmark.favorite;
    await state.toggleFavorite(bookmark);
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      star
          ? '已把「${bookmark.displayTitle}」加入我的最爱（同时也还在原分类里）'
          : '已把「${bookmark.displayTitle}」移出我的最爱',
    );
  }

  /// Hides the bookmark from the child-facing wall (edit mode keeps showing it).
  Future<void> _toggleHidden(BuildContext context) async {
    final hide = !bookmark.hidden;
    await state.setHidden(bookmark, hide);
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      hide
          ? '已隐藏「${bookmark.displayTitle}」：首页不再显示，点眼睛图标可以恢复'
          : '已取消隐藏「${bookmark.displayTitle}」',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbnail = bookmark.thumbnailPath;
    final id = bookmark.id;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      // A hidden bookmark is dimmed here so a parent can see at a glance what the
      // child's wall does not show.
      color: state.isHiddenOnHome(bookmark)
          ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55)
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 46,
                height: 46,
                child: thumbnail == null || thumbnail.isEmpty
                    ? _Monogram(bookmark: bookmark)
                    : Image.file(
                        File(thumbnail),
                        fit: BoxFit.cover,
                        cacheWidth: 138,
                        errorBuilder: (_, _, _) => _Monogram(bookmark: bookmark),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bookmark.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                  Text(
                    [
                      state.categoryLabel(bookmark.categoryId),
                      bookmark.host,
                      if (bookmark.favorite) '★ 我的最爱',
                      if (bookmark.hidden) '已隐藏',
                      if (!bookmark.hidden && state.isCategoryHidden(bookmark.categoryId))
                        '分类已隐藏',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                  ),
                  Text(
                    bookmark.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(context, fontSize: 11, color: theme.hintColor),
                  ),
                ],
              ),
            ),
            IconButton(
              key: ValueKey<String>('edit-favorite-$id'),
              tooltip: bookmark.favorite ? '移出我的最爱' : '加入我的最爱',
              visualDensity: VisualDensity.compact,
              onPressed: () => _toggleFavorite(context),
              icon: Icon(
                bookmark.favorite ? Icons.star : Icons.star_border,
                color: bookmark.favorite ? const Color(0xFFF2B01E) : null,
              ),
            ),
            IconButton(
              key: ValueKey<String>('edit-hide-$id'),
              tooltip: bookmark.hidden ? '取消隐藏' : '隐藏（首页不显示）',
              visualDensity: VisualDensity.compact,
              onPressed: () => _toggleHidden(context),
              icon: Icon(
                bookmark.hidden
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
            IconButton(
              key: ValueKey<String>('edit-rename-$id'),
              tooltip: '编辑书签名',
              visualDensity: VisualDensity.compact,
              onPressed: () => _rename(context),
              icon: const Icon(Icons.drive_file_rename_outline),
            ),
            IconButton(
              key: ValueKey<String>('edit-move-$id'),
              tooltip: '变更分类',
              visualDensity: VisualDensity.compact,
              onPressed: () => _move(context),
              icon: const Icon(Icons.drive_file_move_outline),
            ),
            IconButton(
              key: ValueKey<String>('edit-thumbnail-$id'),
              tooltip: '重新生成预览图',
              visualDensity: VisualDensity.compact,
              onPressed: () => _regenerate(context),
              icon: const Icon(Icons.image_outlined),
            ),
            IconButton(
              key: ValueKey<String>('edit-delete-$id'),
              tooltip: '删除书签',
              visualDensity: VisualDensity.compact,
              onPressed: () => _delete(context),
              icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
            ),
          ],
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbnail = bookmark.thumbnailPath;

    return Tooltip(
      message: bookmark.url,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          // The whole tile is tappable, caption included: with the title below
          // the square, tapping the text must open the bookmark too.
          onTap: onOpen,
          borderRadius: BorderRadius.circular(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: ColoredBox(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
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
                          const Positioned(top: 6, right: 6, child: _AllowedBadge()),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
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
