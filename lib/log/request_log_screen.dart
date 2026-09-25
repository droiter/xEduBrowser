import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../policy/policy_engine.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import 'log_export.dart';

/// Test hook for the 导出日志到文件 button.
const Key exportLogButtonKey = ValueKey<String>('log-export');

/// Test hook for the dialog that reports where the log file went.
const Key logExportDialogKey = ValueKey<String>('log-export-dialog');

/// 日志：两页——**诊断日志**（应用自己做了什么）与**请求日志**（每次放行/拦截的
/// 裁决）。两者都能一键导出成一个文本文件，方便把问题带出去定位。
class RequestLogScreen extends StatefulWidget {
  const RequestLogScreen({super.key});

  @override
  State<RequestLogScreen> createState() => _RequestLogScreenState();
}

class _RequestLogScreenState extends State<RequestLogScreen> {
  bool _onlyDenied = false;

  Future<void> _confirmClear() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('确定清空全部诊断日志与请求日志吗？该操作不可撤销。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final AppState state = AppScope.read(context);
    state
      ..clearAppLog()
      ..clearLog();
    if (!mounted) return;
    showAppSnackBar(context, '日志已清空');
  }

  /// Writes both logs to a text file and says where it went.
  Future<void> _export() async {
    final AppState state = AppScope.read(context);
    final LogExportResult? result = await exportLogs(state);
    if (!mounted) return;

    if (result == null) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          key: logExportDialogKey,
          title: const Text('导出失败'),
          content: const SizedBox(
            width: 420,
            child: Text('没有可写入的目录。请检查应用的文件访问权限后重试。'),
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: logExportDialogKey,
        title: const Text('日志已导出'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                result.shared
                    ? '文件已写入共享的「下载」目录，可以用文件管理器或 USB 取走：'
                    : '没有存储权限，文件写在了应用私有目录里（仍在设备上）：',
                style: Theme.of(dialogContext).textTheme.bodyMedium,
              ),
              const SizedBox(height: 10),
              Text(result.path, style: monoStyle(dialogContext, fontSize: 12.5)),
              const SizedBox(height: 10),
              Text(
                '内容：诊断日志 ${state.appLog.length} 条 + 请求日志 ${state.log.length} 条。'
                '把整个文件发给开发者即可定位问题。',
                style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                      color: Theme.of(dialogContext).hintColor,
                    ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: result.path));
              if (!dialogContext.mounted) return;
              showAppSnackBar(dialogContext, '路径已复制');
            },
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            label: const Text('复制路径'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = AppScope.of(context);
    final bool hasAny = state.log.isNotEmpty || state.appLog.isNotEmpty;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('日志'),
          actions: <Widget>[
            IconButton(
              key: exportLogButtonKey,
              tooltip: '导出日志到文件',
              onPressed: () => unawaited(_export()),
              icon: const Icon(Icons.save_alt),
            ),
            IconButton(
              tooltip: '清空日志',
              onPressed: hasAny ? _confirmClear : null,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
            const SizedBox(width: 4),
          ],
          bottom: const TabBar(
            tabs: <Widget>[
              Tab(text: '诊断日志'),
              Tab(text: '请求日志'),
            ],
          ),
        ),
        body: TabBarView(
          children: <Widget>[
            _AppLogTab(state: state),
            _requestTab(state),
          ],
        ),
      ),
    );
  }

  Widget _requestTab(AppState state) {
    final ThemeData theme = Theme.of(context);
    final List<RequestLogEntry> all = state.log; // AppState 已按最新在最前维护
    final int deniedCount = all.where((RequestLogEntry e) => !e.allowed).length;
    final List<RequestLogEntry> entries = _onlyDenied
        ? <RequestLogEntry>[for (final RequestLogEntry e in all) if (!e.allowed) e]
        : all;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppTheme.contentMaxWidth),
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '共 ${all.length} 条记录，其中被拒绝 $deniedCount 条（最多保留 500 条，最新在最前）',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilterChip(
                    label: const Text('仅显示被拒绝'),
                    selected: _onlyDenied,
                    avatar: Icon(
                      _onlyDenied ? Icons.filter_alt : Icons.filter_alt_outlined,
                      size: 18,
                    ),
                    onSelected: (bool value) => setState(() => _onlyDenied = value),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: entries.isEmpty
                  ? EmptyState(
                      icon: _onlyDenied
                          ? Icons.verified_user_outlined
                          : Icons.receipt_long_outlined,
                      title: _onlyDenied ? '没有“被拒绝”的记录' : '暂无请求记录',
                      message: _onlyDenied
                          ? '当前所有请求都被放行。关闭筛选可查看全部记录。'
                          : '浏览网页、加载资源或本地服务器响应时，这里会记录每次裁决与命中的规则。',
                      action: _onlyDenied
                          ? OutlinedButton.icon(
                              onPressed: () => setState(() => _onlyDenied = false),
                              icon: const Icon(Icons.filter_alt_off_outlined),
                              label: const Text('显示全部记录'),
                            )
                          : null,
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (BuildContext context, int index) =>
                          _LogCard(entry: entries[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 诊断日志：应用自己的步骤流水，按时间倒序。
class _AppLogTab extends StatelessWidget {
  const _AppLogTab({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<AppLogEntry> entries = state.appLog;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppTheme.contentMaxWidth),
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '共 ${entries.length} 条（最多保留 800 条，最新在最前）：'
                  '页面加载、书签增删改、预览图、服务器与导出都在这里',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: entries.isEmpty
                  ? const EmptyState(
                      icon: Icons.subject_outlined,
                      title: '暂无诊断记录',
                      message: '应用启动、打开页面、增删书签与生成预览图时，这里会记下每一步。',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 9),
                      itemBuilder: (BuildContext context, int index) =>
                          _AppLogRow(entry: entries[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One diagnostic line: time, level tag and the message, on one selectable row.
class _AppLogRow extends StatelessWidget {
  const _AppLogRow({required this.entry});

  final AppLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color color = switch (entry.level) {
      LogLevel.error => scheme.error,
      LogLevel.warn => scheme.tertiary,
      LogLevel.debug => scheme.outline,
      LogLevel.info => scheme.onSurface,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            entry.timeLabel,
            style: monoStyle(context, fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 34,
            child: Text(
              entry.level.labelZh,
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          ),
          SizedBox(
            width: 76,
            child: Text(
              '[${entry.tag}]',
              style: monoStyle(context, fontSize: 12, color: scheme.primary),
            ),
          ),
          Expanded(
            child: Text(
              entry.message,
              style: theme.textTheme.bodySmall?.copyWith(color: color, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard({required this.entry});

  final RequestLogEntry entry;

  static String _reasonLabel(String name) {
    for (final DecisionReason reason in DecisionReason.values) {
      if (reason.name == name) return reason.labelZh;
    }
    return name.isEmpty ? '未提供原因' : name;
  }

  static String _kindLabel(String kind) => switch (kind) {
        'navigation' => '页面导航',
        'request' => '资源请求',
        'localServer' => '本地服务器',
        'download' => '下载',
        '' => '未知来源',
        _ => kind,
      };

  static String _dateLabel(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final DateTime now = DateTime.now();
    final bool isToday = entry.time.year == now.year &&
        entry.time.month == now.month &&
        entry.time.day == now.day;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                RuleChip(
                  entry.allowed ? '允许' : '拒绝',
                  tone: entry.allowed ? ChipTone.allow : ChipTone.deny,
                  icon: entry.allowed ? Icons.check_circle_outline : Icons.block_outlined,
                ),
                const SizedBox(width: 8),
                RuleChip(_kindLabel(entry.kind), icon: Icons.layers_outlined),
                const Spacer(),
                Text(
                  '${isToday ? '' : '${_dateLabel(entry.time)} '}${entry.timeLabel}',
                  style: monoStyle(context, fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 10),
            PatternText(entry.url.isEmpty ? '（无网址）' : entry.url, fontSize: 13.5),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.gavel_outlined, size: 15, color: scheme.outline),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '原因：${_reasonLabel(entry.reason)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (entry.explanation.isNotEmpty &&
                entry.explanation != _reasonLabel(entry.reason)) ...<Widget>[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 21),
                child: Text(
                  entry.explanation,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            if (entry.matched.isEmpty)
              Text(
                '命中规则：无',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '命中规则',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final String pattern in entry.matched)
                        RuleChip(
                          pattern,
                          tone: entry.allowed ? ChipTone.allow : ChipTone.deny,
                          monospace: true,
                          icon: Icons.filter_alt_outlined,
                        ),
                    ],
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
