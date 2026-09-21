import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../bookmarks/bookmark_grid.dart';
import '../policy/policy_config.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../rules/rules_screen.dart';
import 'url_input.dart';

/// The internal `about:home` page. Rendered by Flutter rather than a WebView so
/// the start page can never be blocked by the very rules it lets you edit.
class StartView extends StatelessWidget {
  const StartView({
    super.key,
    required this.onNavigate,
    required this.onOpenLocalFile,
    this.onAddBookmark,
    this.onImportBookmarks,
    this.onCaptureThumbnail,
  });

  final ValueChanged<String> onNavigate;
  final VoidCallback onOpenLocalFile;

  /// Opens the add-bookmark flow, targeting the given category.
  final Future<void> Function(String categoryId)? onAddBookmark;

  /// Imports bookmarks from a local directory.
  final Future<void> Function()? onImportBookmarks;

  /// Captures the current page, used to refresh a bookmark screenshot.
  final Future<Uint8List?> Function()? onCaptureThumbnail;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final whitelist = state.policy.rulesOf(PolicyListKind.whitelist);
    final blacklist = state.policy.rulesOf(PolicyListKind.blacklist);

    // StartView is used inside the browser shell's Scaffold, but it brings its
    // own Material so it also renders correctly on its own (tests, previews).
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 40),
        children: [
          Text('起始页', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
            '在地址栏输入网址，或打开本地网页。所有访问都会按黑白名单策略判定。',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 24),
          BookmarkGrid(
            onOpen: onNavigate,
            onAdd: onAddBookmark,
            onImport: onImportBookmarks,
            onCaptureThumbnail: onCaptureThumbnail,
          ),
          const SizedBox(height: 28),
          _StatusCard(
            state: state,
            whitelist: whitelist.length,
            blacklist: blacklist.length,
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.tonalIcon(
                onPressed: onOpenLocalFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('打开本地网页'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const RulesScreen()),
                ),
                icon: const Icon(Icons.rule),
                label: const Text('管理黑白名单'),
              ),
              FilledButton.tonalIcon(
                onPressed: state.localServerRunning
                    ? () => onNavigate('${state.localServer!.baseUrl}/')
                    : null,
                icon: const Icon(Icons.dns_outlined),
                label: Text(
                  state.localServerRunning
                      ? '浏览本地站点（:${state.localServer!.port}）'
                      : '本地服务器未启动',
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          if (whitelist.isNotEmpty) ...[
            Text('白名单（仅这些范围可访问）', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            _RulePreview(rules: whitelist, onNavigate: onNavigate),
            const SizedBox(height: 24),
          ],
          if (blacklist.isNotEmpty) ...[
            Text('黑名单', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            _RulePreview(rules: blacklist, onNavigate: onNavigate),
          ],
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.state,
    required this.whitelist,
    required this.blacklist,
  });

  final AppState state;
  final int whitelist;
  final int blacklist;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final policy = state.policy;
    final localRoot = state.effectiveLocalRoot;

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  policy.enabled
                      ? Icons.shield_outlined
                      : Icons.shield_moon_outlined,
                  size: 20,
                  color: policy.enabled
                      ? theme.colorScheme.primary
                      : theme.hintColor,
                ),
                const SizedBox(width: 8),
                Text(
                  policy.enabled ? '策略已启用' : '策略总开关已关闭（所有网址放行）',
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                _Fact(label: '白名单', value: '$whitelist 条'),
                _Fact(label: '黑名单', value: '$blacklist 条'),
                _Fact(label: '冲突解决', value: policy.conflictResolution.labelZh),
                _Fact(label: '未匹配', value: policy.unmatchedAction.labelZh),
                _Fact(
                  label: '域名边界',
                  value: policy.strictDomainBoundary ? '严格' : '前缀（默认）',
                ),
                _Fact(
                  label: '本地服务器',
                  value: state.localServerRunning
                      ? '运行中 · :${state.localServer!.port}'
                      : '已停止',
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.folder_outlined, size: 16, color: theme.hintColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '本地站点根目录：$localRoot',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
        ),
        const SizedBox(height: 2),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

class _RulePreview extends StatelessWidget {
  const _RulePreview({required this.rules, required this.onNavigate});

  final List<PolicyRule> rules;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = rules.take(8).toList();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final rule in visible)
          Builder(
            builder: (context) {
              // Wildcards are not loadable addresses; show them as plain chips.
              final loadable =
                  !rule.pattern.contains('*') && !rule.pattern.contains('?');
              final resolved = loadable
                  ? UrlResolver.resolve(rule.pattern)
                  : null;
              final canOpen = resolved != null && resolved.url.isNotEmpty;
              return ActionChip(
                avatar: Icon(
                  Directory(rule.pattern).existsSync()
                      ? Icons.folder
                      : Icons.public,
                  size: 16,
                ),
                label: Text(rule.pattern, overflow: TextOverflow.ellipsis),
                onPressed: canOpen ? () => onNavigate(resolved.url) : null,
                labelStyle: theme.textTheme.bodySmall,
              );
            },
          ),
        if (rules.length > visible.length)
          Chip(label: Text('还有 ${rules.length - visible.length} 条')),
      ],
    );
  }
}
