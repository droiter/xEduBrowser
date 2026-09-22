import 'package:flutter/material.dart';

import '../bookmarks/bookmark_grid.dart';
import '../state/app_scope.dart';

/// The internal `about:home` page: nothing but the bookmark wall, one section
/// per category.
///
/// Rendered by Flutter rather than a WebView so the start page can never be
/// blocked by the very rules it lets you edit, and deliberately free of any
/// add/delete control — bookmarks are managed from the settings screen, which
/// the menu in the top-right corner opens.
class StartView extends StatelessWidget {
  const StartView({super.key, required this.onNavigate});

  /// Opens a bookmark's URL through the browser's policy gate.
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);

    // StartView is used inside the browser shell's Scaffold, but it brings its
    // own Material so it also renders correctly on its own (tests, previews).
    return Material(
      type: MaterialType.transparency,
      child: state.bookmarks.isEmpty
          ? const _EmptyHome()
          : ListView(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
              children: [
                BookmarkGrid(onOpen: onNavigate),
              ],
            ),
    );
  }
}

/// Shown while there is nothing to open yet. Text only: the home page has no
/// add button by design.
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
