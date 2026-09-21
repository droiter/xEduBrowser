import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'bookmark.dart';
import 'bookmark_dialog.dart';
import 'category_dialogs.dart';

/// The home page bookmark wall: one section per category, each a grid of square
/// tiles with the title underneath.
///
/// Tiles can be dragged onto one another to change their order inside a
/// category, and dragged from one category into another.
class BookmarkGrid extends StatelessWidget {
  const BookmarkGrid({
    super.key,
    required this.onOpen,
    this.onAdd,
    this.onImport,
    this.onCaptureThumbnail,
    this.emptyHint = '还没有书签。打开一个网页后点地址栏右侧的 ☆ 即可加入，'
        '也可以用「添加书签」直接输入网址。',
  });

  final ValueChanged<String> onOpen;

  /// Adds a bookmark into the given category (the ＋ tile of that section).
  final Future<void> Function(String categoryId)? onAdd;

  /// Imports bookmarks from a local directory.
  final Future<void> Function()? onImport;

  /// Captures the current page, for the 更新缩略图 menu action.
  final Future<Uint8List?> Function()? onCaptureThumbnail;

  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final sections = state.populatedCategoryIds;
    final total = state.bookmarks.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('书签', style: theme.textTheme.titleSmall),
            const SizedBox(width: 8),
            if (total > 0)
              Text(
                '$total 个 · ${state.categories.length} 个分类',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
              ),
            const Spacer(),
            if (state.categories.isNotEmpty || total > 0)
              TextButton.icon(
                onPressed: () => _manageCategories(context, state),
                icon: const Icon(Icons.folder_outlined, size: 18),
                label: const Text('分类管理'),
              ),
            if (onImport != null)
              TextButton.icon(
                onPressed: () => onImport!.call(),
                icon: const Icon(Icons.drive_folder_upload_outlined, size: 18),
                label: const Text('从目录导入'),
              ),
            if (onAdd != null)
              TextButton.icon(
                onPressed: () => onAdd!(uncategorizedId),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加书签'),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (sections.isEmpty)
          _EmptyState(hint: emptyHint, onAdd: onAdd == null ? null : () => onAdd!(uncategorizedId))
        else
          for (final categoryId in sections) ...[
            _CategorySection(
              state: state,
              categoryId: categoryId,
              onOpen: onOpen,
              onAdd: onAdd,
              onCaptureThumbnail: onCaptureThumbnail,
            ),
            const SizedBox(height: 22),
          ],
      ],
    );
  }

  Future<void> _manageCategories(BuildContext context, AppState state) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text('分类管理', style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            for (final category in state.categories)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(category.name),
                subtitle: Text('${state.bookmarksIn(category.id).length} 个书签'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '重命名',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () async {
                        final name = await showCategoryNameDialog(
                          sheetContext,
                          title: '重命名分类',
                          initialName: category.name,
                          confirmLabel: '保存',
                        );
                        if (name != null) await state.renameCategory(category, name);
                      },
                    ),
                    IconButton(
                      tooltip: '删除分类',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        final confirmed = await confirmCategoryDelete(
                          sheetContext,
                          category: category,
                          bookmarkCount: state.bookmarksIn(category.id).length,
                        );
                        if (confirmed == true) await state.removeCategory(category);
                      },
                    ),
                  ],
                ),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('新建分类'),
              onTap: () async {
                final name = await showCategoryNameDialog(sheetContext, title: '新建分类');
                if (name != null) await state.addCategory(name);
              },
            ),
            if (state.categories.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: Text(
                  '还没有分类。分类用来把书签分组显示在首页，'
                  '也可以在添加书签或从目录导入时直接新建。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hint, this.onAdd});

  final String hint;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hint, style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor)),
          if (onAdd != null) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('添加第一个书签'),
            ),
          ],
        ],
      ),
    );
  }
}

/// One category: a header plus its tiles.
class _CategorySection extends StatelessWidget {
  const _CategorySection({
    required this.state,
    required this.categoryId,
    required this.onOpen,
    required this.onAdd,
    required this.onCaptureThumbnail,
  });

  final AppState state;
  final String categoryId;
  final ValueChanged<String> onOpen;
  final Future<void> Function(String categoryId)? onAdd;
  final Future<Uint8List?> Function()? onCaptureThumbnail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bookmarks = state.bookmarksIn(categoryId);
    final label = state.categoryLabel(categoryId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Text(
              '${bookmarks.length}',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
            ),
            if (state.categoryById(categoryId) != null) ...[
              const SizedBox(width: 4),
              IconButton(
                tooltip: '重命名分类',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final category = state.categoryById(categoryId);
                  if (category == null) return;
                  final name = await showCategoryNameDialog(
                    context,
                    title: '重命名分类',
                    initialName: category.name,
                    confirmLabel: '保存',
                  );
                  if (name != null) await state.renameCategory(category, name);
                },
              ),
            ],
            const Spacer(),
            Text(
              '拖动方块可调整顺序',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
            ),
          ],
        ),
        const SizedBox(height: 10),
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
          itemCount: bookmarks.length + (onAdd == null ? 0 : 1),
          itemBuilder: (context, index) {
            if (index >= bookmarks.length) {
              return _AddTile(categoryLabel: label, onTap: () => onAdd!(categoryId));
            }
            final bookmark = bookmarks[index];
            return BookmarkTile(
              bookmark: bookmark,
              onOpen: () => onOpen(bookmark.url),
              onReorderOnto: (dragged) => _dropOn(state, dragged, bookmark),
              onCaptureThumbnail: onCaptureThumbnail,
            );
          },
        ),
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

/// One bookmark: square thumbnail, then the title and its folder/host below.
class BookmarkTile extends StatelessWidget {
  const BookmarkTile({
    super.key,
    required this.bookmark,
    required this.onOpen,
    this.onReorderOnto,
    this.onCaptureThumbnail,
  });

  final Bookmark bookmark;
  final VoidCallback onOpen;

  /// Called with the dragged bookmark when another tile is dropped here.
  final Future<void> Function(Bookmark dragged)? onReorderOnto;

  final Future<Uint8List?> Function()? onCaptureThumbnail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visual = _TileBody(
      bookmark: bookmark,
      onOpen: onOpen,
      // Long-press is reserved for reordering, so the menu lives on its own
      // button instead of competing for the same gesture.
      onLongPress: null,
      onMenu: () => _showMenu(context),
    );

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
            child: _TileBody(
              bookmark: bookmark,
              onOpen: () {},
              onLongPress: () {},
              onMenu: () {},
            ),
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

  Future<void> _showMenu(BuildContext context) async {
    final state = AppScope.read(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('打开'),
              onTap: () => Navigator.of(context).pop('open'),
            ),
            ListTile(
              leading: const Icon(Icons.title),
              title: const Text('修改标题'),
              subtitle: Text(bookmark.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.of(context).pop('rename'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移动到分类 / 修改白名单'),
              onTap: () => Navigator.of(context).pop('edit'),
            ),
            if (onCaptureThumbnail != null)
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('用当前页面更新缩略图'),
                onTap: () => Navigator.of(context).pop('thumbnail'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除书签'),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case 'open':
        onOpen();
      case 'rename':
        final title = await showBookmarkRenameDialog(
          context,
          initialTitle: bookmark.displayTitle,
        );
        if (title == null) return;
        await state.updateBookmark(bookmark.copyWith(title: title));
      case 'edit':
        final result = await showBookmarkDialog(
          context,
          url: bookmark.url,
          initialTitle: bookmark.displayTitle,
          whitelistDefault: bookmark.whitelistPattern != null,
          isEditing: true,
          categoryId: bookmark.categoryId,
        );
        if (result == null) return;
        await state.editBookmark(
          bookmark,
          title: result.title,
          grantWhitelist: result.grantWhitelist,
          wholeSite: result.wholeSite,
        );
        if (result.categoryId != bookmark.categoryId) {
          await state.moveBookmark(bookmark.copyWith(title: result.title),
              categoryId: result.categoryId);
        }
      case 'thumbnail':
        final bytes = await onCaptureThumbnail!.call();
        if (bytes == null || bytes.isEmpty) return;
        await state.setBookmarkThumbnail(bookmark, bytes);
      case 'delete':
        if (!context.mounted) return;
        final removeRule = await confirmBookmarkDelete(context, bookmark: bookmark);
        if (removeRule == null) return;
        await state.removeBookmark(bookmark, removeWhitelistRule: removeRule);
    }
  }
}

class _TileBody extends StatelessWidget {
  const _TileBody({
    required this.bookmark,
    required this.onOpen,
    required this.onLongPress,
    required this.onMenu,
  });

  final Bookmark bookmark;
  final VoidCallback onOpen;

  /// Null while the tile is used as drag feedback.
  final VoidCallback? onLongPress;

  final VoidCallback onMenu;

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
          onLongPress: onLongPress,
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
              Row(
                children: [
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      bookmark.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                    ),
                  ),
                  SizedBox(
                    width: 26,
                    height: 22,
                    child: IconButton(
                      tooltip: '更多操作',
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      visualDensity: VisualDensity.compact,
                      onPressed: onMenu,
                      icon: const Icon(Icons.more_vert),
                    ),
                  ),
                ],
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

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap, required this.categoryLabel});

  final VoidCallback onTap;
  final String categoryLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Material(
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(14),
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            child: InkWell(
              onTap: onTap,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add, size: 28, color: theme.colorScheme.primary),
                    const SizedBox(height: 4),
                    Text('添加到$categoryLabel', style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        // Keeps the add tile optically aligned with the captioned tiles.
        Text(' ', style: theme.textTheme.bodySmall, maxLines: 2),
        Text(' ', style: theme.textTheme.labelSmall),
      ],
    );
  }
}
