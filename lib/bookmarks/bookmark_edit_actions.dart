import 'package:flutter/material.dart';

import '../pdf/pdf_document.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import 'bookmark.dart';
import 'bookmark_dialog.dart';
import 'category_dialogs.dart';
import 'thumbnail_capture.dart';

/// The six things a parent can do to one bookmark from the home page's edit mode.
///
/// They live here rather than inside the tile widget so the wall stays layout
/// only, and so the same wording is used wherever an edit control appears next
/// to a bookmark. Every action confirms the outcome with a snackbar: the wall
/// itself only changes in small ways (a star, a dimmed tile), which is easy to
/// miss on a tablet.
abstract final class BookmarkEditActions {
  /// Stars or unstars the bookmark. 我的最爱 is a section of its own on top of
  /// the wall; the bookmark stays where it already is as well.
  static Future<void> toggleFavorite(
    BuildContext context,
    AppState state,
    Bookmark bookmark,
  ) async {
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

  /// Hides the bookmark from the child-facing wall (edit mode keeps showing it,
  /// at the end of its category).
  static Future<void> toggleHidden(
    BuildContext context,
    AppState state,
    Bookmark bookmark,
  ) async {
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

  /// Renames the bookmark.
  static Future<void> rename(
    BuildContext context,
    AppState state,
    Bookmark bookmark,
  ) async {
    final title = await showBookmarkRenameDialog(
      context,
      initialTitle: bookmark.displayTitle,
    );
    if (title == null || !context.mounted) return;
    await state.updateBookmark(bookmark.copyWith(title: title));
    if (!context.mounted) return;
    showAppSnackBar(context, '书名已保存');
  }

  /// Files the bookmark under another category.
  static Future<void> move(
    BuildContext context,
    AppState state,
    Bookmark bookmark,
  ) async {
    final target = await showBookmarkTargetCategoryDialog(
      context,
      bookmarkCount: 1,
    );
    if (target == null || !context.mounted) return;
    await state.moveBookmarksToCategory([bookmark], categoryId: target);
    if (!context.mounted) return;
    showAppSnackBar(context, '已移动到「${state.categoryLabel(target)}」');
  }

  /// Force a fresh preview image, replacing whatever the tile shows now.
  static Future<void> regenerateThumbnail(
    BuildContext context,
    AppState state,
    Bookmark bookmark,
  ) async {
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

  /// Deletes the bookmark, asking first whether its whitelist rule should go too.
  static Future<void> delete(
    BuildContext context,
    AppState state,
    Bookmark bookmark,
  ) async {
    final removeRule = await confirmBookmarkDelete(context, bookmark: bookmark);
    if (removeRule == null || !context.mounted) return;
    await state.removeBookmark(bookmark, removeWhitelistRule: removeRule);
    if (!context.mounted) return;
    showAppSnackBar(context, '已删除「${bookmark.displayTitle}」');
  }
}
