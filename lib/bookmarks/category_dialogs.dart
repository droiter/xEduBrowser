import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import 'bookmark.dart';
import 'bookmark_import.dart';

/// Dialogs for bookmark categories and for importing a directory of local
/// pages.
///
/// Kept out of `bookmark_dialog.dart` so the single-bookmark forms stay small;
/// all three entry points are plain `showDialog` wrappers that return the user's
/// decision and change nothing themselves — the caller writes through
/// `AppState`.
///
/// Everything is Simplified Chinese, matching the rest of the app.

/// Value of the "新建分类…" entry in the target-category dropdown.
///
/// Not a category id, so it must never become the selected value; picking it
/// opens [showCategoryNameDialog] instead.
const String _newCategoryValue = '\u0000new-category';

/// Prompts for a category name. Returns the trimmed name, or null on cancel.
Future<String?> showCategoryNameDialog(
  BuildContext context, {
  required String title,
  String initialName = '',
  String confirmLabel = '确定',
}) =>
    showDialog<String>(
      context: context,
      builder: (context) => _CategoryNameDialog(
        title: title,
        initialName: initialName,
        confirmLabel: confirmLabel,
      ),
    );

/// Confirmation before deleting a category. Returns true to proceed.
///
/// Deleting a category never deletes bookmarks: they move to 未分类, which is
/// what this dialog has to make obvious before the user commits.
Future<bool?> confirmCategoryDelete(
  BuildContext context, {
  required BookmarkCategory category,
  required int bookmarkCount,
}) =>
    showDialog<bool>(
      context: context,
      builder: (context) => _CategoryDeleteDialog(
        category: category,
        bookmarkCount: bookmarkCount,
      ),
    );

/// The directory-import flow. Scans [directoryPath], shows a preview, imports
/// on confirm. Returns the outcome, or null when cancelled.
Future<BookmarkImportOutcome?> showBookmarkImportDialog(
  BuildContext context, {
  required String directoryPath,
}) =>
    showDialog<BookmarkImportOutcome>(
      context: context,
      builder: (context) => _BookmarkImportDialog(directoryPath: directoryPath),
    );

// --------------------------------------------------------------- name dialog

/// The name prompt.
///
/// A StatefulWidget rather than a `StatefulBuilder`: the text controller needs
/// an owner whose lifetime matches the dialog. Disposing it when the future
/// completes is too early — the closing dialog keeps rebuilding during its exit
/// animation and would use a disposed controller.
class _CategoryNameDialog extends StatefulWidget {
  const _CategoryNameDialog({
    required this.title,
    required this.initialName,
    required this.confirmLabel,
  });

  final String title;
  final String initialName;
  final String confirmLabel;

  @override
  State<_CategoryNameDialog> createState() => _CategoryNameDialogState();
}

class _CategoryNameDialogState extends State<_CategoryNameDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName);

  /// Pop with the trimmed name; an empty name is refused rather than sent on.
  void _submit() {
    final value = _name.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop(value);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _name.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '分类名称',
                hintText: '例如：语文课程',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '分类只影响书签的归组，不会改变打开权限。',
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
          // Disabled while the field is empty, and [_submit] refuses an empty
          // name as a second line of defence.
          onPressed: canSubmit ? _submit : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------- delete dialog

/// Confirms deleting a category, spelling out that its bookmarks survive.
class _CategoryDeleteDialog extends StatelessWidget {
  const _CategoryDeleteDialog({
    required this.category,
    required this.bookmarkCount,
  });

  final BookmarkCategory category;
  final int bookmarkCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('删除分类'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确定删除分类「${category.name}」吗？'),
            const SizedBox(height: 10),
            if (bookmarkCount > 0)
              Text('该分类下的 $bookmarkCount 个书签不会被删除，它们会移动到「$uncategorizedLabel」。')
            else
              const Text('该分类下没有书签。'),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 15, color: theme.hintColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '删除分类本身无法撤销，需要的话可以重新建一个同名分类。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
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
          // Destructive action, styled like the delete confirms elsewhere in
          // the app (书签删除 / 规则删除).
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除分类'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------- import dialog

/// How many scanned pages the preview lists before it collapses into "还有 K 个…".
const int _previewLimit = 10;

/// The directory-import dialog: scan, preview, choose target, import.
class _BookmarkImportDialog extends StatefulWidget {
  const _BookmarkImportDialog({required this.directoryPath});

  final String directoryPath;

  @override
  State<_BookmarkImportDialog> createState() => _BookmarkImportDialogState();
}

class _BookmarkImportDialogState extends State<_BookmarkImportDialog> {
  /// Null until the scan returns; drives the scanning state.
  BookmarkImportPlan? _plan;

  String? _scanError;
  String? _importError;
  bool _importing = false;

  String _categoryId = uncategorizedId;

  BookmarkWhitelistScope _scope = BookmarkWhitelistScope.directory;

  @override
  void initState() {
    super.initState();
    // Real file I/O, kicked off here on purpose: the dialog already shows its
    // scanning state, and every completion below is guarded with `mounted` so a
    // dismissed dialog is never rebuilt.
    unawaited(_scan());
  }

  Future<void> _scan() async {
    try {
      final plan = await BookmarkImporter.scan(widget.directoryPath);
      if (!mounted) return;
      setState(() => _plan = plan);
    } catch (error) {
      if (!mounted) return;
      setState(() => _scanError = '$error');
    }
  }

  bool get _canImport {
    final plan = _plan;
    return !_importing && plan != null && !plan.isEmpty;
  }

  Future<void> _startImport() async {
    final plan = _plan;
    if (!_canImport || plan == null) return;
    final state = AppScope.read(context);
    setState(() {
      _importing = true;
      _importError = null;
    });
    try {
      final outcome = await state.applyImportPlan(
        plan,
        categoryId: _categoryId,
        whitelistScope: _scope,
      );
      if (!mounted) return;
      Navigator.of(context).pop(outcome);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _importError = '导入失败：$error';
      });
    }
  }

  /// Handles the target-category dropdown, including its 新建分类… entry.
  Future<void> _onCategorySelected(String? value) async {
    if (value == null) return;
    if (value != _newCategoryValue) {
      setState(() => _categoryId = value);
      return;
    }

    // Picking 新建分类… is an action, not a selection: the dropdown must keep
    // showing the previous target unless a category is actually created.
    final state = AppScope.read(context);
    final name = await showCategoryNameDialog(context, title: '新建分类');
    if (!mounted) return;
    if (name == null || name.trim().isEmpty) {
      setState(() {});
      return;
    }
    final created = await state.addCategory(name);
    if (!mounted) return;
    setState(() => _categoryId = created.id);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    final plan = _plan;
    return AlertDialog(
      title: const Text('导入本地目录'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _pathLine(context),
              const SizedBox(height: 14),
              if (_scanError != null)
                _message(
                  context,
                  icon: Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                  text: '扫描失败：$_scanError',
                )
              else if (plan == null)
                _scanning(context)
              else ...[
                _planSummary(context, plan),
                const SizedBox(height: 14),
                if (plan.isEmpty)
                  _emptyState(context, plan)
                else
                  _preview(context, plan),
                const SizedBox(height: 6),
                if (plan.truncated)
                  _message(
                    context,
                    icon: Icons.warning_amber_outlined,
                    color: Theme.of(context).colorScheme.error,
                    text: '已达到 ${BookmarkImporter.defaultMaxFiles} 个文件的上限，'
                        '超出的页面这次不会被导入。',
                  ),
                const Divider(height: 28),
                _categoryField(context, state),
                const SizedBox(height: 16),
                _scopeField(context),
              ],
              if (_importError != null) ...[
                const SizedBox(height: 12),
                _message(
                  context,
                  icon: Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                  text: _importError!,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _canImport ? _startImport : null,
          icon: const Icon(Icons.download_outlined),
          label: Text(_importing ? '正在导入…' : '开始导入'),
        ),
      ],
    );
  }

  // ---------------------------------------------------------- content parts

  Widget _pathLine(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: widget.directoryPath,
      child: Text(
        widget.directoryPath,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: monoStyle(context, fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _scanning(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text('正在扫描目录…', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );

  /// Directory / subdirectory / page counts, plus the whitelist outcome.
  Widget _planSummary(BuildContext context, BookmarkImportPlan plan) {
    final theme = Theme.of(context);
    final names = plan.subdirectories;
    final shown = names.take(4).join('、');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fact(context, Icons.folder_outlined, '一级子目录 ${names.length} 个'),
        if (names.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 26, top: 2),
            child: Text(
              names.length > 4 ? '$shown 等' : shown,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ),
        const SizedBox(height: 4),
        _fact(context, Icons.description_outlined, '找到 ${plan.fileCount} 个 HTML 页面'),
      ],
    );
  }

  Widget _fact(BuildContext context, IconData icon, String text) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 9),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
      ],
    );
  }

  Widget _emptyState(BuildContext context, BookmarkImportPlan plan) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _message(
          context,
          icon: Icons.search_off_outlined,
          color: theme.colorScheme.outline,
          text: '没有找到可以导入的页面。',
        ),
        const SizedBox(height: 8),
        Text(
          '导入规则：所选目录下的 HTML 会直接导入；它的一级子目录也会被遍历，'
          '其中的 HTML（含更深层的）同样会成为书签。',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
        if (plan.subdirectories.isEmpty && plan.rootLevelHtmlCount == 0) ...[
          const SizedBox(height: 8),
          Text(
            '这个目录下既没有 HTML 文件，也没有一级子目录。',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ],
    );
  }

  Widget _preview(BuildContext context, BookmarkImportPlan plan) {
    final theme = Theme.of(context);
    final shown = plan.candidates.take(_previewLimit).toList();
    final rest = plan.candidates.length - shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('预览', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        for (final candidate in shown)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    candidate.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  candidate.subdirectory.isEmpty ? '所选目录' : candidate.subdirectory,
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                ),
              ],
            ),
          ),
        if (rest > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '还有 $rest 个…',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ),
      ],
    );
  }

  Widget _categoryField(BuildContext context, AppState state) {
    final theme = Theme.of(context);
    final categories = state.categories;
    // Guard against a selection whose category vanished from under the dialog:
    // DropdownButton asserts when its value has no matching item.
    final known = categories.any((category) => category.id == _categoryId);
    final selected = _categoryId == uncategorizedId || known ? _categoryId : uncategorizedId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InputDecorator(
          decoration: const InputDecoration(
            labelText: '目标分类',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          isEmpty: false,
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              value: selected,
              onChanged: (value) => unawaited(_onCategorySelected(value)),
              items: [
                const DropdownMenuItem<String>(
                  value: uncategorizedId,
                  child: Text(uncategorizedLabel),
                ),
                for (final category in categories)
                  DropdownMenuItem<String>(
                    value: category.id,
                    child: Text(category.name),
                  ),
                const DropdownMenuItem<String>(
                  value: _newCategoryValue,
                  child: Text('新建分类…'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '导入的书签会放进这个分类，之后可以随时拖动调整。',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
      ],
    );
  }

  Widget _scopeField(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('白名单范围', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<BookmarkWhitelistScope>(
          segments: <ButtonSegment<BookmarkWhitelistScope>>[
            for (final scope in BookmarkWhitelistScope.values)
              ButtonSegment<BookmarkWhitelistScope>(
                value: scope,
                label: Text(scope.labelZh),
              ),
          ],
          selected: <BookmarkWhitelistScope>{_scope},
          onSelectionChanged: (selection) => setState(() => _scope = selection.first),
        ),
        const SizedBox(height: 8),
        _scopeHint(context),
      ],
    );
  }

  /// The rule text the chosen scope would produce.
  Widget _scopeHint(BuildContext context) {
    final theme = Theme.of(context);
    switch (_scope) {
      case BookmarkWhitelistScope.directory:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('放行规则（整个导入目录）：', style: theme.textTheme.bodySmall),
            const SizedBox(height: 2),
            Text(
              BookmarkWhitelist.directoryPattern(widget.directoryPath),
              style: monoStyle(context, fontSize: 12),
            ),
            const SizedBox(height: 2),
            Text(
              '一条规则覆盖全部页面，连带这些页面引用的同目录素材。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ],
        );
      case BookmarkWhitelistScope.perFile:
        final count = _plan?.fileCount ?? 0;
        return Text(
          '每个页面各自添加一条白名单规则，共 $count 条；同目录的其他素材不会被放行。',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        );
      case BookmarkWhitelistScope.none:
        return Text(
          '不添加任何白名单规则：只收藏，不放行，在白名单模式下打开这些页面会被拦截。',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        );
    }
  }

  Widget _message(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String text,
  }) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color, height: 1.45),
          ),
        ),
      ],
    );
  }
}
