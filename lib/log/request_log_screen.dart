import 'package:flutter/material.dart';

import '../policy/policy_engine.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';

/// 请求日志：所有被拦截的导航、资源请求与放行裁决的审计记录。
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
        title: const Text('清空请求日志'),
        content: const Text('确定清空全部日志记录吗？该操作不可撤销。'),
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
    AppScope.read(context).clearLog();
    if (!mounted) return;
    showAppSnackBar(context, '请求日志已清空');
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final ThemeData theme = Theme.of(context);
    final List<RequestLogEntry> all = state.log; // AppState 已按最新在最前维护
    final int deniedCount = all.where((RequestLogEntry e) => !e.allowed).length;
    final List<RequestLogEntry> entries = _onlyDenied
        ? <RequestLogEntry>[for (final RequestLogEntry e in all) if (!e.allowed) e]
        : all;

    return Scaffold(
      appBar: AppBar(
        title: const Text('请求日志'),
        actions: <Widget>[
          IconButton(
            tooltip: '清空日志',
            onPressed: all.isEmpty ? null : _confirmClear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Center(
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
