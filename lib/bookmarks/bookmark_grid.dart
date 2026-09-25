import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'bookmark.dart';

/// The home page bookmark wall: one section per category, each a grid of square
/// tiles with the title underneath.
///
/// Tiles can be dragged onto one another to change their order inside a
/// category, and dragged from one category into another. A section header folds
/// its category shut, so a wall with several subjects fits on one screen. There
/// is deliberately no add/delete control here — bookmarks are managed in the
/// settings screen.
class BookmarkGrid extends StatelessWidget {
  const BookmarkGrid({super.key, required this.onOpen});

  /// Opens a bookmark's URL through the browser's policy gate.
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final sections = state.populatedCategoryIds;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final categoryId in sections) ...[
          _CategorySection(
            state: state,
            categoryId: categoryId,
            onOpen: onOpen,
          ),
          const SizedBox(height: 22),
        ],
      ],
    );
  }
}

/// One category: a foldable header plus, while it is open, its tiles.
///
/// The fold state lives in [AppState] (in memory) rather than in this widget, so
/// it survives every rebuild of the wall — a tile reorder or a settings visit
/// does not pop the categories back open.
class _CategorySection extends StatelessWidget {
  const _CategorySection({
    required this.state,
    required this.categoryId,
    required this.onOpen,
  });

  final AppState state;
  final String categoryId;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bookmarks = state.bookmarksIn(categoryId);
    final label = state.categoryLabel(categoryId);
    final collapsed = state.isCategoryCollapsed(categoryId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: collapsed ? '展开这个分类' : '折叠这个分类',
          child: InkWell(
            key: ValueKey<String>('bookmark-section-$categoryId'),
            onTap: () => state.toggleCategoryCollapsed(categoryId),
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
                ],
              ),
            ),
          ),
        ),
        // The tiles are not built at all while folded: a folded wall of a hundred
        // bookmarks costs nothing to lay out.
        if (!collapsed) ...[
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
