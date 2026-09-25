import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../browser/url_input.dart';
import '../files/local_file_url.dart';
import '../files/local_files_screen.dart';
import '../pdf/pdf_document.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import 'bookmark.dart';
import 'bookmark_dialog.dart';
import 'category_dialogs.dart';
import 'thumbnail_capture.dart';

/// Stable test hooks for the settings-screen bookmark controls.
const Key addBookmarkButtonKey = ValueKey<String>('settings-add-bookmark');
const Key importBookmarksButtonKey = ValueKey<String>('settings-import-bookmarks');
const Key manageCategoriesButtonKey = ValueKey<String>('settings-manage-categories');

/// Test hooks for the multi-select mode of the bookmark list.
const Key multiSelectBookmarksKey = ValueKey<String>('settings-bookmarks-multiselect');
const Key selectAllBookmarksKey = ValueKey<String>('settings-bookmarks-select-all');
const Key moveSelectedBookmarksKey = ValueKey<String>('settings-bookmarks-move');
const Key deleteSelectedBookmarksKey = ValueKey<String>('settings-bookmarks-delete');

/// The 书签 card of the settings screen: add a bookmark, import a directory of
/// local pages, manage categories, and edit/delete/move the bookmarks that
/// exist — one at a time or as a multi-selection.
///
/// The home page shows bookmarks only, so every management action lives here.
/// Adding a bookmark grants the address **and** the site (or local folder) that
/// contains it — see [AppState.addBookmark].
class BookmarkManagerCard extends StatefulWidget {
  const BookmarkManagerCard({super.key});

  @override
  State<BookmarkManagerCard> createState() => _BookmarkManagerCardState();
}

class _BookmarkManagerCardState extends State<BookmarkManagerCard> {
  /// Whether the list is in multi-select mode.
  ///
  /// Off by default: a plain tap keeps renaming a bookmark, so bulk actions are
  /// something the user opts into rather than a mode they can fall into.
  bool _selecting = false;

  /// Ids of the ticked bookmarks; only meaningful while [_selecting].
  final Set<String> _selected = <String>{};

  void _setSelecting(bool value) {
    setState(() {
      _selecting = value;
      _selected.clear();
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _selectAll(bool allSelected) {
    setState(() {
      _selected.clear();
      if (allSelected) return;
      _selected.addAll(AppScope.read(context).bookmarks.map((b) => b.id));
    });
  }

  /// The bookmarks of the current selection, in list order.
  List<Bookmark> _chosen(AppState state, Set<String> selected) => [
        for (final bookmark in state.bookmarks)
          if (selected.contains(bookmark.id)) bookmark,
      ];

  Future<void> _deleteSelected(AppState state, Set<String> selected) async {
    final chosen = _chosen(state, selected);
    if (chosen.isEmpty) return;
    final confirmed = await confirmBookmarkBulkDelete(context, count: chosen.length);
    if (confirmed != true || !mounted) return;
    await state.removeBookmarks(chosen);
    if (!mounted) return;
    _setSelecting(false);
    showAppSnackBar(context, '已删除 ${chosen.length} 个书签');
  }

  Future<void> _moveSelected(AppState state, Set<String> selected) async {
    final chosen = _chosen(state, selected);
    if (chosen.isEmpty) return;
    final target = await showBookmarkTargetCategoryDialog(
      context,
      bookmarkCount: chosen.length,
    );
    if (target == null || !mounted) return;
    await state.moveBookmarksToCategory(chosen, categoryId: target);
    if (!mounted) return;
    _setSelecting(false);
    showAppSnackBar(
      context,
      '已把 ${chosen.length} 个书签移动到「${state.categoryLabel(target)}」',
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final bookmarks = state.bookmarks;
    // A bookmark deleted elsewhere must not stay counted in the selection.
    final selected = _selected.intersection({for (final b in bookmarks) b.id});
    final allSelected = bookmarks.isNotEmpty && selected.length == bookmarks.length;

    return SectionCard(
      title: '书签',
      subtitle: '首页方块就是这里的书签。添加书签时，该网址与它所在的网站'
          '（本地网页则是所在目录）会一起加入白名单。',
      icon: Icons.bookmark_add_outlined,
      trailing: RuleChip(
        '${bookmarks.length} 个',
        tone: bookmarks.isEmpty ? ChipTone.warning : ChipTone.allow,
        icon: Icons.bookmark_outline,
      ),
      children: <Widget>[
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              key: addBookmarkButtonKey,
              onPressed: () => _addBookmark(context),
              icon: const Icon(Icons.add),
              label: const Text('添加书签'),
            ),
            OutlinedButton.icon(
              key: importBookmarksButtonKey,
              onPressed: () => _importFromDirectory(context),
              icon: const Icon(Icons.drive_folder_upload_outlined),
              label: const Text('从本地目录导入'),
            ),
            OutlinedButton.icon(
              key: manageCategoriesButtonKey,
              onPressed: () => showCategoryManagerSheet(context),
              icon: const Icon(Icons.folder_outlined),
              label: const Text('分类管理'),
            ),
            if (bookmarks.isNotEmpty)
              OutlinedButton.icon(
                key: multiSelectBookmarksKey,
                onPressed: () => _setSelecting(!_selecting),
                icon: Icon(_selecting ? Icons.close : Icons.checklist_outlined),
                label: Text(_selecting ? '退出多选' : '多选'),
              ),
          ],
        ),
        if (_selecting)
          _SelectionBar(
            total: bookmarks.length,
            selected: selected.length,
            allSelected: allSelected,
            onSelectAll: () => _selectAll(allSelected),
            onMove: selected.isEmpty ? null : () => _moveSelected(state, selected),
            onDelete: selected.isEmpty ? null : () => _deleteSelected(state, selected),
          ),
        const SizedBox(height: 8),
        if (bookmarks.isEmpty)
          Text(
            '还没有书签。点「添加书签」输入网址，或点「浏览本地文件」直接选中'
            '存储卡里的 HTML 页面。',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          )
        else
          for (final bookmark in bookmarks)
            _BookmarkRow(
              key: ValueKey<String>('bookmark-row-${bookmark.id}'),
              state: state,
              bookmark: bookmark,
              selecting: _selecting,
              selected: selected.contains(bookmark.id),
              onToggleSelected: () => _toggleSelected(bookmark.id),
            ),
      ],
    );
  }

  /// Asks for an address (typed or picked from the local file browser), then
  /// collects the title/category/whitelist decision.
  Future<void> _addBookmark(BuildContext context) async {
    final state = AppScope.read(context);
    final typed = await showBookmarkUrlPrompt(context);
    if (typed == null || !context.mounted) return;

    final resolved = UrlResolver.resolve(
      typed,
      localServerBase: state.localServer?.baseUrl,
      localRoot: state.localServerRunning ? state.effectiveLocalRoot : null,
    );
    if (resolved.url.isEmpty || resolved.url == UrlResolver.homeUrl) {
      if (context.mounted) {
        showAppSnackBar(context, resolved.error ?? '无法识别的地址', isError: true);
      }
      return;
    }
    // A folder becomes its index.html, so the bookmark opens a real page.
    var target = resolved.url;
    if (LocalFileUrl.isDirectory(target)) {
      final index = LocalFileUrl.indexHtmlFor(target);
      if (index == null) {
        if (context.mounted) {
          showAppSnackBar(
            context,
            '这个目录里没有 index.html：请选择具体的 HTML 文件，'
            '或用「从本地目录导入」批量导入。',
            isError: true,
          );
        }
        return;
      }
      target = index;
    }

    final result = await showBookmarkDialog(
      context,
      url: target,
      whitelistDefault: state.settings.bookmarkWhitelistByDefault,
      // Settings sits behind the parental gate, so it may offer the preview.
      allowPreview: true,
    );
    if (result == null || !context.mounted) return;

    final bookmark = await state.addBookmark(
      url: target,
      title: result.title,
      addToWhitelist: result.grantWhitelist,
      categoryId: result.categoryId,
    );
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      result.grantWhitelist
          ? '已添加书签「${bookmark.displayTitle}」，网址与所在站点已加入白名单'
          : '已添加书签「${bookmark.displayTitle}」（未加入白名单）',
    );

    // Take the tile's picture right away instead of waiting for the page to be
    // opened once. Fire-and-forget: the bookmark is already saved, and the
    // capture reports its own outcome.
    unawaited(_captureAddedPreview(state, bookmark));
  }

  /// Generates the preview image of a freshly added bookmark.
  ///
  /// The page is loaded in a throwaway WebView (see [captureThumbnailFor]) so the
  /// home page shows the real page immediately, rather than the generated
  /// monogram until the bookmark is opened for the first time. A failed capture
  /// changes nothing: the bookmark keeps its monogram and the usual first-open
  /// capture still fills the preview in later.
  Future<void> _captureAddedPreview(AppState state, Bookmark bookmark) async {
    if (!mounted) return;
    // A PDF is read page by page by the built-in reader and Android's WebView
    // cannot render one, so there is nothing to photograph — and nothing to
    // promise the user either.
    if (PdfDocuments.localPathOf(bookmark.url) != null) return;
    final bytes = await captureThumbnailFor(context, url: bookmark.url);
    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      showAppSnackBar(context, '暂时截不到预览图，打开该页面时会自动生成');
      return;
    }
    // The bookmark may have been deleted while the page was loading.
    final current = state.bookmarkFor(bookmark.url);
    if (current == null || current.id != bookmark.id) return;
    await state.setBookmarkThumbnail(current, bytes);
    if (!mounted) return;
    showAppSnackBar(context, '已生成「${current.displayTitle}」的预览图');
  }

  /// Picks a directory and imports every HTML page found in it and in its
  /// first-level subdirectories.
  Future<void> _importFromDirectory(BuildContext context) async {
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const LocalFilesScreen(pickDirectory: true)),
    );
    if (picked == null || !context.mounted) return;

    final path = LocalFileUrl.pathOf(picked);
    if (path == null || path.isEmpty) {
      showAppSnackBar(context, '无法解析所选目录：$picked', isError: true);
      return;
    }

    final outcome = await showBookmarkImportDialog(context, directoryPath: path);
    if (outcome == null || !context.mounted) return;

    // A name clash is the one import result a snackbar cannot explain: the user
    // has to see *which* pages were left out, so it gets a dialog — which also
    // carries the summary and the whitelist line the snackbar would have shown.
    if (outcome.nameConflicts.isNotEmpty) {
      await showImportNameConflictDialog(context, outcome: outcome);
      return;
    }

    final buffer = StringBuffer(outcome.summary);
    if (outcome.whitelistPattern.isNotEmpty) {
      buffer.write('；白名单：${outcome.whitelistPattern}');
    }
    showAppSnackBar(context, buffer.toString());
  }
}

/// The bar shown in multi-select mode: how much is ticked, and what can be done
/// with it. A [Wrap] rather than a Row so the actions fold onto a second line on
/// a narrow settings pane instead of overflowing.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.total,
    required this.selected,
    required this.allSelected,
    required this.onSelectAll,
    required this.onMove,
    required this.onDelete,
  });

  final int total;
  final int selected;
  final bool allSelected;
  final VoidCallback onSelectAll;

  /// Null while nothing is ticked, which disables the batch actions.
  final VoidCallback? onMove;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('已选 $selected / $total 个', style: theme.textTheme.bodyMedium),
          TextButton(
            key: selectAllBookmarksKey,
            onPressed: onSelectAll,
            child: Text(allSelected ? '取消全选' : '全选'),
          ),
          TextButton.icon(
            key: moveSelectedBookmarksKey,
            onPressed: onMove,
            icon: const Icon(Icons.drive_file_move_outline, size: 18),
            label: const Text('移动到分类'),
          ),
          TextButton.icon(
            key: deleteSelectedBookmarksKey,
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

/// One bookmark in the settings list, with its own ⋮ actions.
///
/// In multi-select mode the ⋮ menu gives way to a checkbox and a tap ticks the
/// row; outside it, a tap renames the bookmark, exactly as before.
class _BookmarkRow extends StatelessWidget {
  const _BookmarkRow({
    super.key,
    required this.state,
    required this.bookmark,
    this.selecting = false,
    this.selected = false,
    this.onToggleSelected,
  });

  final AppState state;
  final Bookmark bookmark;

  /// Multi-select mode is on: the row shows a checkbox and toggles on tap.
  final bool selecting;
  final bool selected;
  final VoidCallback? onToggleSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final patterns = bookmark.whitelistPatterns;
    final local = bookmark.url.startsWith('file://');
    final thumbnail = bookmark.thumbnailPath;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      selected: selecting && selected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
      leading: SizedBox(
        width: selecting ? 92 : 44,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selecting)
              Checkbox(
                value: selected,
                onChanged: (_) => onToggleSelected?.call(),
              ),
            _Preview(
              path: thumbnail,
              fallback: Icon(local ? Icons.insert_drive_file_outlined : Icons.public),
            ),
          ],
        ),
      ),
      title: Text(bookmark.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            bookmark.url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(context, fontSize: 12),
          ),
          const SizedBox(height: 2),
          Text(
            '${state.categoryLabel(bookmark.categoryId)} · '
            '${patterns.isEmpty ? '未加入白名单' : '白名单：${patterns.join('、')}'}',
            maxLines: 2,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 2),
          Text(
            thumbnail == null || thumbnail.isEmpty
                ? (PdfDocuments.localPathOf(bookmark.url) != null
                    ? '预览图：PDF 不生成预览图'
                    : '预览图：还没生成，打开该页面即可生成')
                : '预览图：已生成，打开该页面会刷新',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
      trailing: selecting
          ? null
          : PopupMenuButton<String>(
              tooltip: '书签操作',
              onSelected: (value) => _onAction(context, value),
              itemBuilder: (context) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(value: 'rename', child: Text('修改标题')),
                PopupMenuItem<String>(value: 'edit', child: Text('分类与白名单')),
                PopupMenuItem<String>(value: 'delete', child: Text('删除书签')),
              ],
            ),
      onTap: selecting ? onToggleSelected : () => _onAction(context, 'rename'),
    );
  }

  Future<void> _onAction(BuildContext context, String action) async {
    switch (action) {
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
          whitelistDefault: bookmark.whitelistPatterns.isNotEmpty,
          isEditing: true,
          categoryId: bookmark.categoryId,
          allowPreview: true,
        );
        if (result == null) return;
        await state.editBookmark(
          bookmark,
          title: result.title,
          grantWhitelist: result.grantWhitelist,
        );
        if (result.categoryId != bookmark.categoryId) {
          await state.moveBookmark(
            bookmark.copyWith(title: result.title),
            categoryId: result.categoryId,
          );
        }
      case 'delete':
        if (!context.mounted) return;
        final removeRule = await confirmBookmarkDelete(context, bookmark: bookmark);
        if (removeRule == null) return;
        await state.removeBookmark(bookmark, removeWhitelistRule: removeRule);
    }
  }
}

/// The list's leading picture: the captured preview when there is one, and the
/// supplied icon until the page has been opened once.
class _Preview extends StatelessWidget {
  const _Preview({required this.path, required this.fallback});

  final String? path;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (path == null || path!.isEmpty) {
      return SizedBox(width: 44, height: 44, child: Center(child: fallback));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Image.file(
          File(path!),
          fit: BoxFit.cover,
          cacheWidth: 132,
          errorBuilder: (context, error, stack) =>
              Center(child: Icon(Icons.broken_image_outlined, color: theme.hintColor)),
        ),
      ),
    );
  }
}
