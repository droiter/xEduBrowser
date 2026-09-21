import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../parental/parental_gate.dart';
import '../policy/policy_config.dart';
import '../state/app_scope.dart';
import '../ui/theme.dart';
import 'policy_tester_screen.dart';
import 'rule_editor_sheet.dart';

/// 规则管理主界面：白名单 / 黑名单两个分页，加上全局策略设置、
/// 导入导出与策略测试器入口。
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  int _lastTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: PolicyListKind.values.length, vsync: this);
    _tabController.addListener(_handleTabChanged);
  }

  void _handleTabChanged() {
    if (_tabController.index == _lastTabIndex) return;
    _lastTabIndex = _tabController.index;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  PolicyListKind get _currentKind => PolicyListKind.values[_tabController.index];

  /// 修改全局策略。始终以**当前**配置为基础，避免用界面上捕获的旧快照
  /// 覆盖掉刚刚新增 / 修改的规则。
  Future<void> _mutatePolicy(PolicyConfig Function(PolicyConfig current) mutate) async {
    final state = AppScope.read(context);
    try {
      await state.updatePolicy(mutate(state.policy));
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, '保存策略失败：$error', isError: true);
    }
  }

  // ------------------------------------------------------------------ 编辑

  Future<void> _openEditor({PolicyRule? initial, required PolicyListKind kind}) async {
    final RuleEditorOutcome? outcome = await showRuleEditorSheet(
      context,
      initial: initial,
      initialKind: kind,
    );
    if (outcome == null || !mounted) return;

    final state = AppScope.read(context);
    try {
      if (outcome.action == RuleEditorAction.delete) {
        if (initial != null) await state.removeRule(initial);
        if (!mounted) return;
        showAppSnackBar(context, '已删除规则：${initial?.pattern ?? ''}');
        return;
      }
      final PolicyRule rule = outcome.rule!;
      if (initial != null && initial.id != rule.id) {
        await state.removeRule(initial); // 规则身份包含内容本身，改内容等于换一条
      }
      await state.addRule(rule);
      if (!mounted) return;
      showAppSnackBar(context, '已保存规则：${rule.pattern}');
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, '保存失败：$error', isError: true);
    }
  }

  Future<void> _toggleRule(PolicyRule rule, bool enabled) async {
    final state = AppScope.read(context);
    final List<PolicyRule> next = <PolicyRule>[
      for (final PolicyRule item in state.policy.rules)
        if (item.id == rule.id) item.copyWith(enabled: enabled) else item,
    ];
    try {
      await state.replaceRules(next);
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, '保存失败：$error', isError: true);
    }
  }

  Future<void> _confirmDelete(PolicyRule rule) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除规则'),
        content: Text(
          '确定删除${rule.kind.labelZh}规则「${rule.pattern}」吗？\n删除后立即生效，且无法撤销。',
        ),
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
    final state = AppScope.read(context);
    try {
      await state.removeRule(rule);
      if (!mounted) return;
      showAppSnackBar(context, '已删除规则：${rule.pattern}');
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, '删除失败：$error', isError: true);
    }
  }

  // -------------------------------------------------------------- 导入导出

  Future<void> _exportPolicy() async {
    final String json = AppScope.read(context).exportPolicyText();
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('导出规则（JSON）'),
        content: SizedBox(
          width: 620,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('下面是当前完整的策略配置，可复制到另一台平板导入。'),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(dialogContext)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: PatternText(json, fontSize: 12.5),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: json));
              if (!dialogContext.mounted) return;
              showAppSnackBar(dialogContext, '规则 JSON 已复制到剪贴板');
            },
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('复制'),
          ),
        ],
      ),
    );
  }

  Future<void> _importPolicy() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _ImportDialog(),
    );
  }

  void _openTester() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const PolicyTesterScreen()),
    );
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final PolicyConfig config = state.policy;
    final List<PolicyRule> whitelist = config.rulesOf(PolicyListKind.whitelist);
    final List<PolicyRule> blacklist = config.rulesOf(PolicyListKind.blacklist);
    final Set<String> shadowedWhitelist = <String>{
      for (final PolicyRule rule in state.engine.shadowedRules(PolicyListKind.whitelist))
        rule.id,
    };
    final Set<String> shadowedBlacklist = <String>{
      for (final PolicyRule rule in state.engine.shadowedRules(PolicyListKind.blacklist))
        rule.id,
    };

    // 只有设置里打开了“同时保护黑白名单页”才加验证；ParentalGate 自己会处理
    // 家长验证总开关关闭的情况，所以这里不需要再判断总开关。
    final Widget body = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppTheme.contentMaxWidth),
        child: Column(
          children: <Widget>[
            _TesterBanner(onOpen: _openTester),
            _GlobalPolicyPanel(
              config: config,
              onEnabledChanged: (bool value) => _mutatePolicy(
                (PolicyConfig current) => current.copyWith(enabled: value),
              ),
              onConflictChanged: (ConflictResolution value) => _mutatePolicy(
                (PolicyConfig current) => current.copyWith(conflictResolution: value),
              ),
              onUnmatchedChanged: (UnmatchedAction value) => _mutatePolicy(
                (PolicyConfig current) => current.copyWith(unmatchedAction: value),
              ),
              onStrictChanged: (bool value) => _mutatePolicy(
                (PolicyConfig current) => current.copyWith(strictDomainBoundary: value),
              ),
            ),
            Material(
              color: Theme.of(context).colorScheme.surface,
              child: TabBar(
                controller: _tabController,
                tabs: <Widget>[
                  Tab(text: '白名单 (${whitelist.length})'),
                  Tab(text: '黑名单 (${blacklist.length})'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: <Widget>[
                  _RulesList(
                    kind: PolicyListKind.whitelist,
                    rules: whitelist,
                    shadowedIds: shadowedWhitelist,
                    strictDomainBoundary: config.strictDomainBoundary,
                    onAdd: () => _openEditor(kind: PolicyListKind.whitelist),
                    onEdit: (PolicyRule rule) => _openEditor(
                      initial: rule,
                      kind: PolicyListKind.whitelist,
                    ),
                    onDelete: _confirmDelete,
                    onToggle: _toggleRule,
                  ),
                  _RulesList(
                    kind: PolicyListKind.blacklist,
                    rules: blacklist,
                    shadowedIds: shadowedBlacklist,
                    strictDomainBoundary: config.strictDomainBoundary,
                    onAdd: () => _openEditor(kind: PolicyListKind.blacklist),
                    onEdit: (PolicyRule rule) => _openEditor(
                      initial: rule,
                      kind: PolicyListKind.blacklist,
                    ),
                    onDelete: _confirmDelete,
                    onToggle: _toggleRule,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final Scaffold screen = Scaffold(
      appBar: AppBar(
        title: const Text('网址过滤规则'),
        actions: <Widget>[
          IconButton(
            tooltip: '策略测试器',
            onPressed: _openTester,
            icon: const Icon(Icons.science_outlined),
          ),
          IconButton(
            tooltip: '导入规则',
            onPressed: _importPolicy,
            icon: const Icon(Icons.file_download_outlined),
          ),
          IconButton(
            tooltip: '导出规则',
            onPressed: _exportPolicy,
            icon: const Icon(Icons.file_upload_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: body,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(kind: _currentKind),
        icon: const Icon(Icons.add),
        label: Text('添加${_currentKind.labelZh}规则'),
      ),
    );

    // Gate the whole screen rather than just its body. Wrapping the body alone
    // would leave the AppBar actions (策略测试器 / 导入 / 导出) and the
    // 添加规则 button usable while the challenge is still up, which would make
    // the protection trivially bypassable.
    if (!state.settings.parentalGateProtectRules) return screen;
    return ParentalGate(child: screen);
  }
}

// ---------------------------------------------------------------- 顶部横幅

class _TesterBanner extends StatelessWidget {
  const _TesterBanner({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Card(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.55),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            children: <Widget>[
              Icon(Icons.science_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('不确定规则会不会误伤？', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      '用策略测试器输入网址，查看命中的规则、包含关系与最终裁决。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('策略测试器'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ 全局策略设置

class _GlobalPolicyPanel extends StatefulWidget {
  const _GlobalPolicyPanel({
    required this.config,
    required this.onEnabledChanged,
    required this.onConflictChanged,
    required this.onUnmatchedChanged,
    required this.onStrictChanged,
  });

  /// 仅用于展示；写入时由回调基于最新配置计算，避免旧快照覆盖新规则。
  final PolicyConfig config;

  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<ConflictResolution> onConflictChanged;
  final ValueChanged<UnmatchedAction> onUnmatchedChanged;
  final ValueChanged<bool> onStrictChanged;

  @override
  State<_GlobalPolicyPanel> createState() => _GlobalPolicyPanelState();
}

class _GlobalPolicyPanelState extends State<_GlobalPolicyPanel> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PolicyConfig config = widget.config;
    final double maxBodyHeight = MediaQuery.sizeOf(context).height * 0.34;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.tune, size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('全局策略设置', style: theme.textTheme.titleMedium),
                          const SizedBox(height: 4),
                          Text(
                            '冲突：${config.conflictResolution.labelZh} · '
                            '未匹配：${_unmatchedShort(config.unmatchedAction)} · '
                            '严格域名边界：${config.strictDomainBoundary ? '开' : '关'}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!config.enabled)
                      const RuleChip('过滤已关闭', tone: ChipTone.warning),
                    IconButton(
                      tooltip: _expanded ? '收起' : '展开',
                      onPressed: () => setState(() => _expanded = !_expanded),
                      icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxBodyHeight),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Divider(height: 1),
                      const SizedBox(height: 12),

                      // 总开关
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: config.enabled,
                        onChanged: widget.onEnabledChanged,
                        title: const Text('启用网址过滤（总开关）'),
                        subtitle: const Text('关闭后所有网址一律放行，规则仍然保留。'),
                      ),
                      const SizedBox(height: 8),

                      // 冲突解决方式
                      Text('冲突解决方式', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      SegmentedButton<ConflictResolution>(
                        segments: const <ButtonSegment<ConflictResolution>>[
                          ButtonSegment<ConflictResolution>(
                            value: ConflictResolution.blacklistWins,
                            label: Text('黑名单优先'),
                            icon: Icon(Icons.block_outlined),
                          ),
                          ButtonSegment<ConflictResolution>(
                            value: ConflictResolution.whitelistWins,
                            label: Text('白名单优先'),
                            icon: Icon(Icons.check_circle_outline),
                          ),
                        ],
                        selected: <ConflictResolution>{config.conflictResolution},
                        onSelectionChanged: (Set<ConflictResolution> selection) =>
                            widget.onConflictChanged(selection.first),
                      ),
                      HintText(
                        '当同一网址同时命中黑白名单、且两条规则互不包含时生效'
                        '（当前：${config.conflictResolution.labelZh}）。'
                        '若其中一条更具体（是另一条的子集），始终由更具体的那条决定，不受此项影响。',
                      ),
                      const SizedBox(height: 18),

                      // 未匹配网址的处理
                      Text('未匹配网址的处理', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: <Widget>[
                          for (final UnmatchedAction action in UnmatchedAction.values)
                            ChoiceChip(
                              label: Text(_unmatchedShort(action)),
                              selected: config.unmatchedAction == action,
                              onSelected: (_) => widget.onUnmatchedChanged(action),
                            ),
                        ],
                      ),
                      HintText(
                        '${config.unmatchedAction.labelZh}。'
                        '当前${config.hasActiveWhitelist ? '已有启用的白名单，选择“自动”时未匹配的网址会被拒绝' : '没有启用的白名单，选择“自动”时未匹配的网址会被放行'}。',
                      ),
                      const SizedBox(height: 18),

                      // 严格域名边界
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: config.strictDomainBoundary,
                        onChanged: widget.onStrictChanged,
                        title: const Text('严格域名边界'),
                        subtitle: const Text(
                          '开启后 example.com 只匹配该域名本身及其下级路径，'
                          '不再匹配 example.com.evil.test 这类“前缀钓鱼”域名；'
                          '关闭则按纯前缀匹配，兼容性更好但更宽松。',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _unmatchedShort(UnmatchedAction action) => switch (action) {
      UnmatchedAction.auto => '自动',
      UnmatchedAction.allow => '一律放行',
      UnmatchedAction.deny => '一律拒绝',
    };

// ------------------------------------------------------------------ 规则列表

class _RulesList extends StatelessWidget {
  const _RulesList({
    required this.kind,
    required this.rules,
    required this.shadowedIds,
    required this.strictDomainBoundary,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  final PolicyListKind kind;
  final List<PolicyRule> rules;
  final Set<String> shadowedIds;
  final bool strictDomainBoundary;
  final VoidCallback onAdd;
  final ValueChanged<PolicyRule> onEdit;
  final ValueChanged<PolicyRule> onDelete;
  final void Function(PolicyRule rule, bool enabled) onToggle;

  @override
  Widget build(BuildContext context) {
    if (rules.isEmpty) {
      return EmptyState(
        icon: kind == PolicyListKind.whitelist
            ? Icons.check_circle_outline
            : Icons.block_outlined,
        title: '还没有${kind.labelZh}规则',
        message: kind == PolicyListKind.whitelist
            ? '添加一条白名单后，未命中白名单的网址将被拒绝（“未匹配网址的处理”为“自动”时）。'
            : '添加一条黑名单后，命中的网址会被拦截，并显示拦截原因。',
        action: FilledButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: Text('添加${kind.labelZh}规则'),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 112),
      itemCount: rules.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (BuildContext context, int index) {
        if (index == rules.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Center(
              child: OutlinedButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: Text('继续添加${kind.labelZh}规则'),
              ),
            ),
          );
        }
        final PolicyRule rule = rules[index];
        return _RuleCard(
          rule: rule,
          shadowed: shadowedIds.contains(rule.id),
          strictDomainBoundary: strictDomainBoundary,
          onEdit: () => onEdit(rule),
          onDelete: () => onDelete(rule),
          onToggle: (bool value) => onToggle(rule, value),
        );
      },
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.rule,
    required this.shadowed,
    required this.strictDomainBoundary,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  final PolicyRule rule;
  final bool shadowed;
  final bool strictDomainBoundary;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool isWhitelist = rule.kind == PolicyListKind.whitelist;

    return Opacity(
      opacity: rule.enabled ? 1 : 0.6,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: PatternText(rule.pattern, fontSize: 14.5),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: rule.enabled,
                    onChanged: onToggle,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  RuleChip(
                    isWhitelist ? '白名单' : '黑名单',
                    tone: isWhitelist ? ChipTone.allow : ChipTone.deny,
                    icon: isWhitelist ? Icons.check : Icons.block,
                  ),
                  if (!rule.enabled) const RuleChip('已停用', icon: Icons.pause_circle_outline),
                  if (shadowed)
                    const RuleChip(
                      '永不生效：已被同名单中更宽的规则覆盖',
                      tone: ChipTone.warning,
                      icon: Icons.warning_amber_rounded,
                    ),
                ],
              ),
              if (rule.note.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.sticky_note_2_outlined, size: 16, color: scheme.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        rule.note,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(Icons.filter_alt_outlined, size: 15, color: scheme.primary),
                        const SizedBox(width: 6),
                        Text(
                          '实际匹配（前缀匹配，末尾自带 *）',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    PatternText(
                      PatternNormalizer.describeExpansion(
                        rule.pattern,
                        strictDomainBoundary: strictDomainBoundary,
                      ),
                      fontSize: 12.5,
                      color: scheme.primary,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('编辑'),
                  ),
                  TextButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('删除'),
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
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

// -------------------------------------------------------------- 导入对话框

class _ImportDialog extends StatefulWidget {
  const _ImportDialog();

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '请先粘贴规则 JSON 内容');
      return;
    }
    final state = AppScope.read(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.importPolicyText(text);
      if (!mounted) return;
      navigator.pop();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('导入成功，当前共 ${state.policy.rules.length} 条规则')),
        );
    } catch (error) {
      if (!mounted) return;
      final String message = '导入失败：${_describeError(error)}。原有配置未改变。';
      setState(() {
        _busy = false;
        _error = message;
      });
      // 解析失败时同时用 SnackBar 提示，弹层保持打开以便修改后重试。
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
            ),
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
            duration: const Duration(seconds: 5),
          ),
        );
    }
  }

  static String _describeError(Object error) {
    if (error is FormatException) return error.message;
    return error.toString();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: const Text('导入规则（JSON）'),
      content: SizedBox(
        width: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '粘贴由“导出规则”生成的 JSON。导入会整体替换当前的名单与全局设置。',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              minLines: 6,
              maxLines: 14,
              style: monoStyle(context, fontSize: 12.5),
              decoration: InputDecoration(
                hintText: '{"version":1,"rules":[{"pattern":"example.com","kind":"whitelist"}]}',
                errorText: _error,
                errorMaxLines: 3,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.file_download_done_outlined),
          label: const Text('导入并替换'),
        ),
      ],
    );
  }
}
