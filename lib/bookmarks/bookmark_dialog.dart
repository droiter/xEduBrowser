import 'package:flutter/material.dart';

import '../files/local_files_screen.dart';
import '../state/app_scope.dart';
import 'bookmark.dart';

/// What the user chose in [showBookmarkDialog].
class BookmarkEditResult {
  const BookmarkEditResult({
    required this.title,
    required this.grantWhitelist,
    this.categoryId = uncategorizedId,
  });

  final String title;
  final bool grantWhitelist;

  /// Category the bookmark should live in.
  final String categoryId;
}

/// Add/edit dialog for a bookmark.
///
/// The whitelist switch is ticked by default, because a bookmarked address is
/// meant to be reachable — that is the "书签网址缺省进入白名单" behaviour — and
/// granting it always covers both the address itself and the site (or local
/// folder) that contains it.
Future<BookmarkEditResult?> showBookmarkDialog(
  BuildContext context, {
  required String url,
  String initialTitle = '',
  required bool whitelistDefault,
  bool isEditing = false,
  String categoryId = uncategorizedId,
}) =>
    showDialog<BookmarkEditResult>(
      context: context,
      builder: (context) => _BookmarkFormDialog(
        url: url,
        initialTitle: initialTitle,
        whitelistDefault: whitelistDefault,
        isEditing: isEditing,
        categoryId: categoryId,
      ),
    );

/// Renames a bookmark. Returns the new title, or null on cancel.
Future<String?> showBookmarkRenameDialog(
  BuildContext context, {
  required String initialTitle,
}) =>
    showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(initialTitle: initialTitle),
    );

/// Test hook for the 浏览本地文件 button.
const Key browseLocalFileKey = ValueKey<String>('bookmark-browse-local');

/// Asks for an address, for adding a bookmark when no page is open (the home
/// page's own ＋ tile). The address can be typed, or picked through the local
/// file browser built into the app.
Future<String?> showBookmarkUrlPrompt(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (context) => const _UrlPromptDialog(),
    );

/// Confirmation for deleting a bookmark. Returns whether the whitelist entry
/// the bookmark created should be removed as well, or null when cancelled.
Future<bool?> confirmBookmarkDelete(
  BuildContext context, {
  required Bookmark bookmark,
}) {
  final grants = bookmark.whitelistPattern != null;
  return showDialog<bool>(
    context: context,
    builder: (context) => _DeleteConfirmDialog(bookmark: bookmark, grants: grants),
  );
}

/// The form for adding or editing a bookmark.
///
/// A StatefulWidget rather than a `StatefulBuilder`, so the text controllers
/// have an owner whose lifetime matches the dialog. Disposing them when the
/// future completes is too early: the closing dialog keeps rebuilding during
/// its exit animation and would use a disposed controller.
class _BookmarkFormDialog extends StatefulWidget {
  const _BookmarkFormDialog({
    required this.url,
    required this.initialTitle,
    required this.whitelistDefault,
    required this.isEditing,
    required this.categoryId,
  });

  final String url;
  final String initialTitle;
  final bool whitelistDefault;
  final bool isEditing;
  final String categoryId;

  @override
  State<_BookmarkFormDialog> createState() => _BookmarkFormDialogState();
}

class _BookmarkFormDialogState extends State<_BookmarkFormDialog> {
  late final TextEditingController _title =
      TextEditingController(text: widget.initialTitle);
  final TextEditingController _newCategory = TextEditingController();
  late bool _grant = widget.whitelistDefault;
  late String _categoryId = widget.categoryId;
  bool _creatingCategory = false;

  static const String _createSentinel = '__create__';

  /// Every rule the dialog is about to create: the address itself, then the
  /// site (or local folder) holding it.
  List<String> get _patterns => BookmarkWhitelist.grantPatterns(widget.url);

  bool get _isLocalFile => widget.url.startsWith('file://');

  @override
  void dispose() {
    _title.dispose();
    _newCategory.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    var categoryId = _categoryId;
    if (_creatingCategory) {
      final name = _newCategory.text.trim();
      if (name.isNotEmpty) {
        final category = await AppScope.read(context).addCategory(name);
        categoryId = category.id;
      } else {
        categoryId = uncategorizedId;
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(BookmarkEditResult(
      title: _title.text,
      grantWhitelist: _grant,
      categoryId: categoryId,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final categories = AppScope.of(context).categories;

    return AlertDialog(
      title: Text(widget.isEditing ? '编辑书签' : '添加书签'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.url,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.hintColor,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '标题',
                  hintText: '显示在方块下方，例如：学校作业平台',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _creatingCategory ? _createSentinel : _categoryId,
                decoration: const InputDecoration(
                  labelText: '分类',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(
                    value: uncategorizedId,
                    child: Text(uncategorizedLabel),
                  ),
                  for (final category in categories)
                    DropdownMenuItem(value: category.id, child: Text(category.name)),
                  const DropdownMenuItem(value: _createSentinel, child: Text('＋ 新建分类…')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _creatingCategory = value == _createSentinel;
                    if (!_creatingCategory) _categoryId = value;
                  });
                },
              ),
              if (_creatingCategory) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _newCategory,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '新分类名称',
                    hintText: '例如：语文课程',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _grant,
                onChanged: (value) => setState(() => _grant = value ?? false),
                title: const Text('加入白名单'),
                subtitle: Text(
                  _grant
                      ? '放行范围：${_patterns.join('   +   ')}'
                      : '只收藏，不放行（白名单模式下打开会被拦截）',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (_grant)
                Padding(
                  padding: const EdgeInsets.only(left: 4, top: 4),
                  child: Text(
                    _isLocalFile
                        ? (BookmarkWhitelist.wholeSiteWidens(widget.url)
                            ? '本地网页的样式、脚本、页面图片都在同一个目录里，'
                                '所以除了这个文件本身，还会放行它所在的目录。'
                            : '这个文件就在存储卡根目录下，放行它的目录等于放行整张存储卡，'
                                '所以只放行该文件本身。')
                        : '除了这个地址，还会放行它所在的整个网站，'
                            '页面引用的站内样式、脚本和图片才能加载。',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.bookmark_add_outlined),
          label: Text(widget.isEditing ? '保存' : '添加'),
        ),
      ],
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _title =
      TextEditingController(text: widget.initialTitle);

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改标题'),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _title,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
          decoration: const InputDecoration(
            labelText: '标题',
            hintText: '显示在方块下方；留空则显示网址或域名',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_title.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _UrlPromptDialog extends StatefulWidget {
  const _UrlPromptDialog();

  @override
  State<_UrlPromptDialog> createState() => _UrlPromptDialogState();
}

class _UrlPromptDialogState extends State<_UrlPromptDialog> {
  final TextEditingController _url = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  /// Picks a page through the local file browser and fills the address in.
  Future<void> _browseLocalFile() async {
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const LocalFilesScreen()),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _url.text = picked;
      _url.selection = TextSelection.collapsed(offset: picked.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加书签'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _url,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '网址',
                hintText: '例如 school.test/lessons 或 /sdcard/pages/index.html',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: browseLocalFileKey,
                onPressed: _browseLocalFile,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('浏览本地文件'),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '也可以在文件浏览器里找到本地网页，地址会自动填入。'
              '下一步可以设置标题、分类，并决定是否把它加入白名单。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final value = _url.text.trim();
            Navigator.of(context).pop(value.isEmpty ? null : value);
          },
          child: const Text('下一步'),
        ),
      ],
    );
  }
}

class _DeleteConfirmDialog extends StatefulWidget {
  const _DeleteConfirmDialog({required this.bookmark, required this.grants});

  final Bookmark bookmark;
  final bool grants;

  @override
  State<_DeleteConfirmDialog> createState() => _DeleteConfirmDialogState();
}

class _DeleteConfirmDialogState extends State<_DeleteConfirmDialog> {
  bool _removeRule = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('删除书签'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确定删除「${widget.bookmark.displayTitle}」吗？'),
            if (widget.grants) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _removeRule,
                onChanged: (value) => setState(() => _removeRule = value ?? false),
                title: const Text('同时移除对应的白名单条目'),
                subtitle: Text(
                  widget.bookmark.whitelistPatterns.join('\n'),
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
              ),
              Text(
                '如果同一个白名单条目还被其他书签使用，则不会被移除。',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_removeRule),
          child: const Text('删除'),
        ),
      ],
    );
  }
}
