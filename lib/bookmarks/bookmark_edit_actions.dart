import 'package:flutter/material.dart';

import '../pdf/pdf_document.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import 'bookmark.dart';
import 'bookmark_dialog.dart';
import 'category_dialogs.dart';
import 'thumbnail_capture.dart';

/// The six things a parent can do to one bookmark from edit mode — on the home
/// wall or in the page-view toolbar.
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
  ///
  /// A PDF gets its first page rendered by the native PDF renderer; a web page is
  /// photographed in a throwaway WebView.
  static Future<void> regenerateThumbnail(
    BuildContext context,
    AppState state,
    Bookmark bookmark,
  ) async {
    final bool isPdf = PdfDocuments.localPathOf(bookmark.url) != null;
    showAppSnackBar(context, '正在重新生成「${bookmark.displayTitle}」的预览图…');
    final bytes = isPdf
        ? await PdfDocuments.captureThumbnail(bookmark.url)
        : await captureThumbnailFor(context, url: bookmark.url);
    if (!context.mounted) return;
    final current = state.bookmarkFor(bookmark.url);
    if (bytes == null || bytes.isEmpty || current == null) {
      showAppSnackBar(
        context,
        isPdf ? '没能生成 PDF 首页预览图，请确认这个 PDF 能正常打开后重试' : '没能生成预览图，请确认该页面能正常打开后重试',
        isError: true,
      );
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

/// One of a bookmark's six edit actions, shared by the home wall's edit mode and
/// the page-view toolbar.
///
/// Deliberately **not** an [IconButton]: the wall is lazy, so scrolling builds and
/// discards rows continuously, and a Material icon button is a small tree of its
/// own (ink response, tooltip, hover/focus machinery, icon theme) that has to be
/// created and torn down again for every one of them. Six per tile × a row of
/// tiles × every row scrolled past is what made editing stutter. The label stays
/// for screen readers (and for `uiautomator`).
///
/// [enabled] lets the page-view toolbar show the six buttons before the parent
/// has unlocked 编辑模式: they stay laid out, but grey and inert.
class BookmarkEditActionButton extends StatelessWidget {
  const BookmarkEditActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.color,
    this.tooltip,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;

  /// Hover/long-press hint; the home wall leaves it null (tooltips per tile were
  /// part of the scrolling cost the lightweight button exists to avoid).
  final String? tooltip;
  final bool enabled;

  /// Comfortably tappable with a finger, small enough that six fit per tile.
  static const double _size = 38;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget button = Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(_size / 2),
        child: SizedBox(
          width: _size,
          height: _size,
          child: Icon(
            icon,
            size: 20,
            color: enabled ? color : theme.disabledColor,
          ),
        ),
      ),
    );
    final String? message = tooltip;
    if (message == null) return button;
    return Tooltip(message: message, child: button);
  }
}

