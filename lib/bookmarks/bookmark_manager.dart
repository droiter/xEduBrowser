import 'dart:io';

import 'package:flutter/material.dart';

import '../browser/url_input.dart';
import '../files/local_file_url.dart';
import '../files/local_files_screen.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import 'bookmark.dart';
import 'bookmark_dialog.dart';
import 'category_dialogs.dart';

/// Stable test hooks for the settings-screen bookmark controls.
const Key addBookmarkButtonKey = ValueKey<String>('settings-add-bookmark');
const Key importBookmarksButtonKey = ValueKey<String>('settings-import-bookmarks');
const Key manageCategoriesButtonKey = ValueKey<String>('settings-manage-categories');

/// The 书签 card of the settings screen: add a bookmark, import a directory of
/// local pages, manage categories, and edit/delete the bookmarks that exist.
///
/// The home page shows bookmarks only, so every management action lives here.
/// Adding a bookmark grants the address **and** the site (or local folder) that
/// contains it — see [AppState.addBookmark].
class BookmarkManagerCard extends StatelessWidget {
  const BookmarkManagerCard({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final bookmarks = state.bookmarks;

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
          ],
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

/// One bookmark in the settings list, with its own ⋮ actions.
class _BookmarkRow extends StatelessWidget {
  const _BookmarkRow({super.key, required this.state, required this.bookmark});

  final AppState state;
  final Bookmark bookmark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final patterns = bookmark.whitelistPatterns;
    final local = bookmark.url.startsWith('file://');
    final thumbnail = bookmark.thumbnailPath;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _Preview(
        path: thumbnail,
        fallback: Icon(local ? Icons.insert_drive_file_outlined : Icons.public),
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
                ? '预览图：打开该页面后自动生成'
                : '预览图：已生成，打开该页面会刷新',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        tooltip: '书签操作',
        onSelected: (value) => _onAction(context, value),
        itemBuilder: (context) => const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(value: 'rename', child: Text('修改标题')),
          PopupMenuItem<String>(value: 'edit', child: Text('分类与白名单')),
          PopupMenuItem<String>(value: 'delete', child: Text('删除书签')),
        ],
      ),
      onTap: () => _onAction(context, 'rename'),
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
