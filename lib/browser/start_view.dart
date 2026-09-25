import 'package:flutter/material.dart';

import '../bookmarks/bookmark_grid.dart';
import '../parental/parental_password_prompt.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';

/// The internal `about:home` page: the bookmark wall, one section per category.
///
/// Rendered by Flutter rather than a WebView so the start page can never be
/// blocked by the very rules it lets you edit. Bookmarks are normally managed
/// from the settings screen; the small pencil in the corner opens an **edit
/// mode** guarded by the parental password for the parent who is already looking
/// at the wall.
class StartView extends StatelessWidget {
  const StartView({super.key, required this.onNavigate});

  /// Opens a bookmark's URL through the browser's policy gate.
  final ValueChanged<String> onNavigate;

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
      reason: '编辑模式可以删除书签、改书名、换分类和重做预览图，需要家长密码。',
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

    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 16, 28, 40),
        children: [
          Row(
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
          if (state.homeEditMode)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '编辑模式：每一行左侧是书签，右侧四个按钮分别是改书名、换分类、'
                '重做预览图、删除。改完点「完成」退出。',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ),
          const SizedBox(height: 14),
          BookmarkGrid(
            onOpen: (url) {
              // Opening a page leaves the wall, so editing ends with it.
              if (state.homeEditMode) state.setHomeEditMode(false);
              onNavigate(url);
            },
            editing: state.homeEditMode,
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
