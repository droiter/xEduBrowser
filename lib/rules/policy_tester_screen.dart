import 'package:flutter/material.dart';

import '../policy/policy_config.dart';
import '../policy/policy_engine.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';

/// 策略测试器：输入一个网址，展示它命中的规则、两两包含关系与最终裁决。
///
/// 这是验证“更具体者胜 / 互不包含时按冲突设置”这套语义的可视化工具。
class PolicyTesterScreen extends StatefulWidget {
  const PolicyTesterScreen({super.key});

  @override
  State<PolicyTesterScreen> createState() => _PolicyTesterScreenState();
}

class _PolicyTesterScreenState extends State<PolicyTesterScreen> {
  final TextEditingController _url = TextEditingController();
  PolicyTrace? _trace;
  String _testedUrl = '';

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _run(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) {
      showAppSnackBar(context, '请先输入要测试的网址', isError: true);
      return;
    }
    final state = AppScope.read(context);
    setState(() {
      _testedUrl = text;
      _trace = state.engine.trace(text);
    });
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final List<_Example> examples = _buildExamples(state);

    return Scaffold(
      appBar: AppBar(title: const Text('策略测试器')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTheme.contentMaxWidth),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: <Widget>[
              _ruleExplanation(context),
              const SizedBox(height: 16),
              _inputCard(context),
              const SizedBox(height: 12),
              if (examples.isNotEmpty) _examplesCard(context, examples),
              if (examples.isNotEmpty) const SizedBox(height: 16),
              if (_trace == null)
                const EmptyState(
                  icon: Icons.travel_explore_outlined,
                  title: '还没有测试结果',
                  message: '输入一个网址后点击“测试”，或直接点击上面的示例网址。',
                )
              else
                ..._resultWidgets(context, state, _trace!),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 说明段落

  Widget _ruleExplanation(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.rule, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('判定规则', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text(
                    '更具体者胜；互不包含时按冲突设置，缺省黑名单优先。'
                    '也就是说：同时命中黑白名单时，若其中一条规则更窄（是另一条的子集），'
                    '就由这条更具体的规则决定；只有当两条互不包含（或多条最具体的规则分属两边）时，'
                    '才由“全局策略设置”里的冲突解决方式决定。完全没有命中任何规则时，'
                    '由“未匹配网址的处理”决定。',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 输入区域

  Widget _inputCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('要测试的网址', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _url,
                    autofocus: true,
                    style: monoStyle(context, fontSize: 14),
                    textInputAction: TextInputAction.go,
                    onSubmitted: _run,
                    decoration: const InputDecoration(
                      hintText: 'https://example.com/news/1',
                      prefixIcon: Icon(Icons.link_outlined),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: () => _run(_url.text),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('测试'),
                  ),
                ),
              ],
            ),
            const HintText('可以只写域名（按 https 处理），也可以粘贴完整的 file:// 路径。'),
          ],
        ),
      ),
    );
  }

  Widget _examplesCard(BuildContext context, List<_Example> examples) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.bolt_outlined, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('按当前规则生成的示例', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '点击即可测试，用来快速验证包含关系与冲突设置是否按预期生效。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final _Example example in examples)
                  ActionChip(
                    avatar: Icon(
                      example.allowed ? Icons.check_circle_outline : Icons.block_outlined,
                      size: 17,
                      color: example.allowed
                          ? const Color(0xFF1B6B3A)
                          : theme.colorScheme.error,
                    ),
                    label: Text(
                      '${example.label}：${example.url}',
                      style: monoStyle(context, fontSize: 12),
                    ),
                    onPressed: () {
                      _url.text = example.url;
                      _run(example.url);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 结果展示

  List<Widget> _resultWidgets(BuildContext context, AppState state, PolicyTrace trace) {
    final PolicyDecision decision = trace.decision;
    final ThemeData theme = Theme.of(context);
    final List<_PairRow> pairs = _pairRows(context, trace);

    return <Widget>[
      // 最终裁决
      Card(
        color: decision.allowed
            ? const Color(0xFF1B6B3A).withValues(alpha: 0.10)
            : theme.colorScheme.errorContainer.withValues(alpha: 0.55),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                decision.allowed ? Icons.verified_user_outlined : Icons.gpp_bad_outlined,
                size: 34,
                color: decision.allowed ? const Color(0xFF1B6B3A) : theme.colorScheme.error,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          decision.allowed ? '允许' : '拒绝',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: decision.allowed
                                ? const Color(0xFF1B6B3A)
                                : theme.colorScheme.error,
                          ),
                        ),
                        const SizedBox(width: 10),
                        RuleChip(
                          decision.allowed ? '放行' : '拦截',
                          tone: decision.allowed ? ChipTone.allow : ChipTone.deny,
                        ),
                        if (decision.conflictResolved) ...<Widget>[
                          const SizedBox(width: 6),
                          const RuleChip('由冲突设置决定', tone: ChipTone.warning),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('裁决原因：${decision.reason.labelZh}',
                        style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const SizedBox(width: 68, child: Text('规范化后', style: TextStyle(fontSize: 12.5))),
                        Expanded(child: PatternText(decision.normalizedUrl, fontSize: 12.5)),
                      ],
                    ),
                    if (decision.normalizedUrl != _testedUrl.trim()) ...<Widget>[
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const SizedBox(width: 68, child: Text('原始输入', style: TextStyle(fontSize: 12.5))),
                          Expanded(
                            child: PatternText(
                              _testedUrl.trim(),
                              fontSize: 12.5,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),

      // 命中情况
      _matchesCard(
        context,
        title: '命中的白名单条目',
        tone: ChipTone.allow,
        matches: decision.whitelistMatches,
        decisive: decision.decisiveRules,
        emptyHint: '没有任何白名单规则匹配这个网址。',
      ),
      const SizedBox(height: 12),
      _matchesCard(
        context,
        title: '命中的黑名单条目',
        tone: ChipTone.deny,
        matches: decision.blacklistMatches,
        decisive: decision.decisiveRules,
        emptyHint: '没有任何黑名单规则匹配这个网址。',
      ),
      const SizedBox(height: 12),

      // 决定性条目
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.gavel_outlined, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('决定性条目（最具体 / 子集）', style: theme.textTheme.titleSmall),
                ],
              ),
              const SizedBox(height: 8),
              if (decision.decisiveRules.isEmpty)
                Text('本次判定没有取决于任何规则（未命中规则或策略总开关已关闭）。',
                    style: theme.textTheme.bodyMedium)
              else
                for (final RuleMatch match in decision.decisiveRules)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        RuleChip(
                          match.kind.labelZh,
                          tone: match.kind == PolicyListKind.whitelist
                              ? ChipTone.allow
                              : ChipTone.deny,
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: PatternText(match.rule.pattern, fontSize: 13)),
                        if (match.rule.note.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              match.rule.note,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),

      // 两两包含关系
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.account_tree_outlined, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('白名单 × 黑名单 包含关系', style: theme.textTheme.titleSmall),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '逐对判断两条规则的语言是否互相包含；“前者包含后者”表示后者更具体，会更具体者胜。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              if (pairs.isEmpty)
                Text('本次没有同时命中黑白名单，因此不存在需要比较的规则对。',
                    style: theme.textTheme.bodyMedium)
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 20,
                    headingRowHeight: 40,
                    dataRowMinHeight: 44,
                    dataRowMaxHeight: 88,
                    columns: const <DataColumn>[
                      DataColumn(label: Text('白名单条目')),
                      DataColumn(label: Text('黑名单条目')),
                      DataColumn(label: Text('包含关系')),
                    ],
                    rows: <DataRow>[
                      for (final _PairRow pair in pairs)
                        DataRow(
                          cells: <DataCell>[
                            DataCell(
                              SizedBox(
                                width: 220,
                                child: Text(
                                  pair.whitelist.rule.pattern,
                                  style: monoStyle(context, fontSize: 12.5),
                                  softWrap: true,
                                ),
                              ),
                            ),
                            DataCell(
                              SizedBox(
                                width: 220,
                                child: Text(
                                  pair.blacklist.rule.pattern,
                                  style: monoStyle(context, fontSize: 12.5),
                                  softWrap: true,
                                ),
                              ),
                            ),
                            DataCell(
                              SizedBox(
                                width: 260,
                                child: RuleChip(
                                  pair.relation.labelZh,
                                  tone: pair.relation == RuleRelation.incomparable
                                      ? ChipTone.warning
                                      : ChipTone.accent,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              if (trace.budgetWarnings.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                for (final String warning in trace.budgetWarnings)
                  HintText(warning, tone: ChipTone.warning, icon: Icons.warning_amber_rounded),
              ],
            ],
          ),
        ),
      ),
    ];
  }

  Widget _matchesCard(
    BuildContext context, {
    required String title,
    required ChipTone tone,
    required List<RuleMatch> matches,
    required List<RuleMatch> decisive,
    required String emptyHint,
  }) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                RuleChip('${matches.length} 条', tone: tone),
              ],
            ),
            const SizedBox(height: 10),
            if (matches.isEmpty)
              Text(
                emptyHint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final RuleMatch match in matches)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        decisive.any((RuleMatch d) => d.rule.id == match.rule.id)
                            ? Icons.star_rounded
                            : Icons.remove,
                        size: 16,
                        color: decisive.any((RuleMatch d) => d.rule.id == match.rule.id)
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: PatternText(match.rule.pattern, fontSize: 13)),
                      if (!match.rule.enabled)
                        const RuleChip('已停用', tone: ChipTone.warning),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  /// 每一对“命中的白名单 × 命中的黑名单”及其包含关系。
  List<_PairRow> _pairRows(BuildContext context, PolicyTrace trace) {
    final List<RuleMatch> whites = trace.decision.whitelistMatches;
    final List<RuleMatch> blacks = trace.decision.blacklistMatches;
    if (whites.isEmpty || blacks.isEmpty) return const <_PairRow>[];

    // trace() 按 白名单 × 黑名单 顺序给出关系，长度对得上就直接使用。
    final List<RuleRelation> relations = trace.relations.length == whites.length * blacks.length
        ? trace.relations
        : _recomputeRelations(context, whites, blacks);

    final List<_PairRow> rows = <_PairRow>[];
    var index = 0;
    for (final RuleMatch white in whites) {
      for (final RuleMatch black in blacks) {
        rows.add(_PairRow(white, black, relations[index++]));
      }
    }
    return rows;
  }

  List<RuleRelation> _recomputeRelations(
    BuildContext context,
    List<RuleMatch> whites,
    List<RuleMatch> blacks,
  ) {
    final PolicyEngine engine = AppScope.read(context).engine;
    return <RuleRelation>[
      for (final RuleMatch white in whites)
        for (final RuleMatch black in blacks)
          engine.relationBetween(white.rule, black.rule),
    ];
  }
}

// ------------------------------------------------------------------ 示例生成

class _Example {
  const _Example(this.url, this.label, this.allowed);

  final String url;
  final String label;
  final bool allowed;
}

/// 由当前规则生成 3–4 个“一按即可测试”的示例网址。
///
/// 做法：把每条规则具体化成一个真实网址，再用引擎判定它属于哪种情形，
/// 优先展示能体现包含关系与冲突解决方式的示例。
List<_Example> _buildExamples(AppState state) {
  final PolicyEngine engine = state.engine;
  final Set<String> seen = <String>{};
  final List<_Example> found = <_Example>[];

  var budget = 16;
  for (final PolicyRule rule in state.policy.rules) {
    if (budget-- <= 0) break;
    if (!rule.enabled) continue;
    final String url = _concretize(rule.pattern);
    if (url.isEmpty || !seen.add(url)) continue;
    found.add(_describeExample(engine, url));
  }

  const String unmatchedProbe = 'https://example.org/not-configured-by-any-rule';
  if (seen.add(unmatchedProbe)) {
    found.add(_describeExample(engine, unmatchedProbe));
  }

  int rank(_Example example) => switch (example.label) {
        '黑白冲突' => 0,
        '仅命中白名单' => 1,
        '仅命中黑名单' => 2,
        _ => 3,
      };

  found.sort((_Example a, _Example b) => rank(a).compareTo(rank(b)));

  final List<_Example> selected = <_Example>[];
  final Map<String, int> perLabel = <String, int>{};
  for (final _Example example in found) {
    if (selected.length >= 4) break;
    final int used = perLabel[example.label] ?? 0;
    if (used >= 2) continue; // 同类情形最多两条，保证示例覆盖不同情况
    perLabel[example.label] = used + 1;
    selected.add(example);
  }
  return selected;
}

_Example _describeExample(PolicyEngine engine, String url) {
  final PolicyDecision decision = engine.decide(url);
  final bool hasWhite = decision.whitelistMatches.isNotEmpty;
  final bool hasBlack = decision.blacklistMatches.isNotEmpty;
  final String label = hasWhite && hasBlack
      ? '黑白冲突'
      : hasWhite
          ? '仅命中白名单'
          : hasBlack
              ? '仅命中黑名单'
              : '未命中任何规则';
  return _Example(url, label, decision.allowed);
}

/// 把一条规则变成一个真实可测的网址（通配符替换成普通字符）。
String _concretize(String raw) {
  final String normalized = PatternNormalizer.normalizeRulePattern(raw);
  final int schemeEnd = normalized.indexOf('://');
  if (normalized.isEmpty || schemeEnd < 0) return '';
  String scheme = normalized.substring(0, schemeEnd);
  if (scheme == '*') scheme = 'https';
  final String rest = normalized.substring(schemeEnd + 3);
  final int slash = rest.indexOf('/');
  final String authorityRaw = slash < 0 ? rest : rest.substring(0, slash);
  final String tailRaw = slash < 0 ? '/' : rest.substring(slash);
  String authority = authorityRaw.replaceAll('*', 'x').replaceAll('?', 'b');
  if (authority.isEmpty && scheme != 'file') authority = 'example.com';
  final String tail = tailRaw.replaceAll('*', 'a').replaceAll('?', 'b');
  return '$scheme://$authority$tail';
}

class _PairRow {
  const _PairRow(this.whitelist, this.blacklist, this.relation);

  final RuleMatch whitelist;
  final RuleMatch blacklist;
  final RuleRelation relation;
}
