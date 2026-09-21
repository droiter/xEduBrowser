import 'package:flutter/material.dart';

import '../policy/policy_config.dart';
import '../state/app_scope.dart';
import '../ui/theme.dart';

/// 编辑面板的提交结果。
enum RuleEditorAction { save, delete }

/// 规则编辑面板的返回值，由调用方（规则管理页）负责落库。
class RuleEditorOutcome {
  const RuleEditorOutcome.save(PolicyRule this.rule) : action = RuleEditorAction.save;

  const RuleEditorOutcome.delete()
      : action = RuleEditorAction.delete,
        rule = null;

  final RuleEditorAction action;

  /// 仅在 [RuleEditorAction.save] 时非空。
  final PolicyRule? rule;
}

/// 以底部弹层形式打开规则编辑器，返回 `null` 表示用户取消。
Future<RuleEditorOutcome?> showRuleEditorSheet(
  BuildContext context, {
  PolicyRule? initial,
  PolicyListKind initialKind = PolicyListKind.blacklist,
}) {
  return showModalBottomSheet<RuleEditorOutcome>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => RuleEditorSheet(
      initial: initial,
      initialKind: initialKind,
    ),
  );
}

/// 新增 / 编辑一条白名单或黑名单规则的底部弹层表单。
///
/// 表单项：名单类型、规则内容（带即时校验）、备注、启用开关，
/// 以及一行实时预览，显示规范化后的规则与实际展开的匹配表达式。
class RuleEditorSheet extends StatefulWidget {
  const RuleEditorSheet({
    super.key,
    this.initial,
    this.initialKind = PolicyListKind.blacklist,
  });

  /// 为空表示新增。
  final PolicyRule? initial;

  /// 新增时预选的名单类型。
  final PolicyListKind initialKind;

  @override
  State<RuleEditorSheet> createState() => _RuleEditorSheetState();
}

class _RuleEditorSheetState extends State<RuleEditorSheet> {
  late final TextEditingController _pattern;
  late final TextEditingController _note;
  late PolicyListKind _kind;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    final PolicyRule? initial = widget.initial;
    _pattern = TextEditingController(text: initial?.pattern ?? '');
    _note = TextEditingController(text: initial?.note ?? '');
    _kind = initial?.kind ?? widget.initialKind;
    _enabled = initial?.enabled ?? true;
  }

  @override
  void dispose() {
    _pattern.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _isEditing => widget.initial != null;

  /// 校验当前输入，返回错误与警告（错误阻止保存，警告只是提醒）。
  _Validation _validate(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) {
      return const _Validation(error: '请输入规则内容，例如 example.com 或 https://example.com/news');
    }
    if (RegExp(r'\s').hasMatch(text)) {
      return const _Validation(error: '规则中不能包含空格');
    }
    if (RegExp(r'[\x00-\x1F\x7F]').hasMatch(text)) {
      return const _Validation(error: '规则中不能包含控制字符');
    }
    if (text.contains(':/') && !text.contains('://')) {
      return const _Validation(error: '协议分隔符应写作 “://”，例如 https://example.com');
    }
    if (text.contains('://')) {
      final int schemeEnd = text.indexOf('://');
      final String scheme = text.substring(0, schemeEnd);
      final String rest = text.substring(schemeEnd + 3);
      if (scheme.isEmpty || scheme == '*') {
        // `*://` 是合法的协议通配写法，继续检查主机部分。
      } else if (!RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*$').hasMatch(scheme)) {
        return const _Validation(error: '协议名只能包含字母、数字、加号、点和连字符');
      }
      if (rest.isEmpty) {
        return const _Validation(error: '缺少域名或路径，例如 https://example.com');
      }
      final int slash = rest.indexOf('/');
      final String authority = slash < 0 ? rest : rest.substring(0, slash);
      if (authority.isEmpty && !scheme.startsWith('file')) {
        return const _Validation(error: '缺少域名，例如 https://example.com');
      }
      if (authority.isNotEmpty && !RegExp(r'^[A-Za-z0-9\-._~*?\[\]:@%]+$').hasMatch(authority)) {
        return const _Validation(error: '域名部分含有不支持的字符');
      }
    }

    final String normalized = PatternNormalizer.normalizeRulePattern(text);
    if (normalized.isEmpty) {
      return const _Validation(error: '规则内容无效');
    }
    if (normalized.replaceAll(RegExp(r'[*?/:]'), '').isEmpty) {
      return const _Validation(
        warning: '这条规则会匹配所有网址，请确认确实要放行或拦截全部访问',
      );
    }
    if (normalized.startsWith('file://') && !normalized.endsWith('/')) {
      final String tail = normalized.substring(normalized.lastIndexOf('/') + 1);
      if (tail.contains('.')) {
        return const _Validation(
          warning: '路径规则按前缀匹配，会同时命中同前缀的其他文件；如需整目录，建议以 / 结尾',
        );
      }
    }

    final state = AppScope.read(context);
    for (final PolicyRule other in state.policy.rules) {
      if (other.kind != _kind) continue;
      if (PatternNormalizer.normalizeRulePattern(other.pattern) != normalized) continue;
      if (widget.initial != null && widget.initial!.kind == other.kind &&
          PatternNormalizer.normalizeRulePattern(widget.initial!.pattern) == normalized) {
        continue; // 正在编辑的就是它自己
      }
      return const _Validation(error: '同一名单中已存在相同规则');
    }
    return const _Validation();
  }

  void _save() {
    final String raw = _pattern.text;
    if (_validate(raw).error != null) {
      setState(() {}); // 触发一次重建以显示错误
      return;
    }
    final String normalized = PatternNormalizer.normalizeRulePattern(raw);
    Navigator.of(context).pop(
      RuleEditorOutcome.save(
        PolicyRule(
          pattern: normalized,
          kind: _kind,
          enabled: _enabled,
          note: _note.text.trim(),
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final PolicyRule? initial = widget.initial;
    if (initial == null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除规则'),
        content: Text('确定删除「${initial.pattern}」吗？删除后立即生效。'),
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
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Navigator.of(context).pop(const RuleEditorOutcome.delete());
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final ThemeData theme = Theme.of(context);
    final bool strict = state.policy.strictDomainBoundary;

    final _Validation validation = _validate(_pattern.text);
    final String raw = _pattern.text.trim();
    final String normalized = PatternNormalizer.normalizeRulePattern(raw);
    final String? error = _pattern.text.isEmpty ? null : validation.error;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    _isEditing ? Icons.edit_outlined : Icons.add_circle_outline,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isEditing ? '编辑规则' : '添加规则',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ---------------------------------------------------- 名单类型
              Text('名单类型', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<PolicyListKind>(
                segments: const <ButtonSegment<PolicyListKind>>[
                  ButtonSegment<PolicyListKind>(
                    value: PolicyListKind.whitelist,
                    label: Text('白名单'),
                    icon: Icon(Icons.check_circle_outline),
                  ),
                  ButtonSegment<PolicyListKind>(
                    value: PolicyListKind.blacklist,
                    label: Text('黑名单'),
                    icon: Icon(Icons.block_outlined),
                  ),
                ],
                selected: <PolicyListKind>{_kind},
                onSelectionChanged: (Set<PolicyListKind> selection) {
                  setState(() => _kind = selection.first);
                },
              ),
              const SizedBox(height: 6),
              HintText(
                _kind == PolicyListKind.whitelist
                    ? '白名单：命中即放行。若白名单非空，未命中任何规则的网址默认会被拒绝。'
                    : '黑名单：命中即拦截，优先级由“全局策略设置”里的冲突解决方式决定。',
              ),
              const SizedBox(height: 18),

              // ---------------------------------------------------- 规则内容
              Text('规则内容', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _pattern,
                autofocus: !_isEditing,
                style: monoStyle(context, fontSize: 14),
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _save(),
                decoration: InputDecoration(
                  hintText: 'example.com 或 https://example.com/news',
                  errorText: error,
                  prefixIcon: const Icon(Icons.link_outlined),
                ),
              ),
              if (validation.warning != null) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(Icons.warning_amber_rounded,
                          size: 16, color: theme.colorScheme.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          validation.warning!,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),

              // ---------------------------------------------------- 实时预览
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(Icons.visibility_outlined,
                            size: 16, color: theme.colorScheme.primary),
                        const SizedBox(width: 6),
                        Text('实时预览', style: theme.textTheme.titleSmall),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const SizedBox(
                          width: 76,
                          child: Text('规范化后', style: TextStyle(fontSize: 12.5)),
                        ),
                        Expanded(
                          child: PatternText(
                            normalized.isEmpty ? '（空规则）' : normalized,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const SizedBox(
                          width: 76,
                          child: Text('实际匹配', style: TextStyle(fontSize: 12.5)),
                        ),
                        Expanded(
                          child: PatternText(
                            PatternNormalizer.describeExpansion(
                              raw,
                              strictDomainBoundary: strict,
                            ),
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (normalized.startsWith('*:///'))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '开头的 “*” 是协议通配符：这条路径规则会同时匹配 '
                          'file://、http:// 与 https:// 下的该路径。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    Text(
                      '规则按前缀匹配，末尾相当于自动带有 *。'
                      '${strict ? '已开启严格域名边界，纯域名规则不会命中 example.com.evil.test。' : '当前为纯前缀匹配，example.com 也会命中 example.com.evil.test。'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // ---------------------------------------------------- 示例
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: <Widget>[
                  for (final String sample in const <String>[
                    'example.com',
                    'https://example.com/news',
                    '*://*.ads.example/*',
                    '/sdcard/pages/',
                  ])
                    ActionChip(
                      label: Text(sample, style: monoStyle(context, fontSize: 12)),
                      onPressed: () => setState(() => _pattern.text = sample),
                    ),
                ],
              ),
              const SizedBox(height: 18),

              // ---------------------------------------------------- 备注
              Text('备注（可选）', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _note,
                maxLines: 2,
                maxLength: 120,
                decoration: const InputDecoration(
                  hintText: '例如：公司内网课件站',
                ),
              ),
              const SizedBox(height: 4),

              // ---------------------------------------------------- 启用开关
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _enabled,
                onChanged: (bool value) => setState(() => _enabled = value),
                title: const Text('启用这条规则'),
                subtitle: Text(
                  _enabled ? '规则已生效' : '规则已保存但不参与匹配',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 12),

              Row(
                children: <Widget>[
                  if (_isEditing) ...<Widget>[
                    OutlinedButton.icon(
                      onPressed: _delete,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('删除'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: error == null && raw.isNotEmpty ? _save : null,
                    icon: const Icon(Icons.check),
                    label: Text(_isEditing ? '保存修改' : '保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Validation {
  const _Validation({this.error, this.warning});

  final String? error;
  final String? warning;
}
