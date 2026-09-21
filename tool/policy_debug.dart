// Operator diagnostic CLI (not part of the app): explains how the filter
// decides a URL, or how a rule expands.
//
//   dart run tool/policy_cli.dart --rules policy.json https://example.com/x
//   dart run tool/policy_cli.dart --rule "example.com"
//
// With no --rules, an empty policy is used, which is useful for checking how a
// rule text expands.
import 'dart:convert';
import 'dart:io';

import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/policy/policy_engine.dart';

void main(List<String> args) {
  final out = stdout;
  final options = _parse(args);

  final ruleText = options['rule'];
  if (ruleText != null) {
    _explainRule(out, ruleText, strict: options.containsKey('strict'));
    if (options['url'] == null) return;
  }

  final url = options['url'];
  if (url == null) {
    out.writeln('用法: dart run tool/policy_cli.dart [--rules <文件>] [--strict] '
        '[--rule <规则文本>] <网址>');
    return;
  }

  var config = PolicyConfig.empty;
  final rulesPath = options['rules'];
  if (rulesPath != null) {
    final file = File(rulesPath);
    if (!file.existsSync()) {
      stderr.writeln('规则文件不存在: $rulesPath');
      exitCode = 2;
      return;
    }
    config = PolicyConfig.fromJson(
      Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()) as Map),
    );
  }
  if (options.containsKey('strict')) {
    config = config.copyWith(strictDomainBoundary: true);
  }

  final engine = PolicyEngine(config);
  final trace = engine.trace(url);
  final decision = trace.decision;

  out
    ..writeln('输入网址      : $url')
    ..writeln('规范化后      : ${decision.normalizedUrl}')
    ..writeln('判定          : ${decision.allowed ? '允许' : '拒绝'}')
    ..writeln('判定路径      : ${decision.reason.name}（${decision.reason.labelZh}）')
    ..writeln('冲突解决      : ${decision.conflictResolved ? '是' : '否'}');

  void listOf(String label, List<RuleMatch> matches) {
    out.writeln('$label: ${matches.isEmpty ? '（无）' : ''}');
    for (final match in matches) {
      out.writeln('  - ${match.rule.pattern}  →  ${match.normalizedPattern}');
    }
  }

  listOf('命中白名单', decision.whitelistMatches);
  listOf('命中黑名单', decision.blacklistMatches);
  listOf('决定性条目（最具体者）', decision.decisiveRules);

  if (trace.relations.isNotEmpty) {
    out.writeln('包含关系（白名单 × 黑名单）:');
    var index = 0;
    for (final whitelist in decision.whitelistMatches) {
      for (final blacklist in decision.blacklistMatches) {
        final relation = trace.relations[index++];
        out.writeln('  ${whitelist.rule.pattern}  vs  ${blacklist.rule.pattern}'
            '  →  ${relation.labelZh}');
      }
    }
  }
  for (final warning in trace.budgetWarnings) {
    out.writeln('警告: $warning');
  }

  // Also show which rules are dead weight, since that is a common config bug.
  for (final kind in PolicyListKind.values) {
    final shadowed = engine.shadowedRules(kind);
    if (shadowed.isEmpty) continue;
    out.writeln('${kind.labelZh}中被更宽规则覆盖（永不生效）: '
        '${shadowed.map((r) => r.pattern).join('、')}');
  }
}

void _explainRule(IOSink out, String rule, {required bool strict}) {
  final normalized = PatternNormalizer.normalizeRulePattern(rule);
  out
    ..writeln('规则原文      : $rule')
    ..writeln('规范化后      : $normalized')
    ..writeln('展开为        : ${PatternNormalizer.describeExpansion(rule, strictDomainBoundary: strict)}')
    ..writeln('严格域名边界  : ${strict ? '开' : '关'}');
}

Map<String, String> _parse(List<String> args) {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--strict') {
      options['strict'] = 'true';
    } else if (arg.startsWith('--') && i + 1 < args.length) {
      options[arg.substring(2)] = args[++i];
    } else if (!arg.startsWith('--')) {
      options['url'] = arg;
    }
  }
  return options;
}
