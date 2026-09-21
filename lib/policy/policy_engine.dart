/// The decision procedure: given a URL, decide allow/deny according to the
/// whitelist / blacklist configuration.
///
/// Resolution rules implemented here (see README for the full specification):
///
///  1. A rule matches a URL when the URL starts with the rule's pattern
///     (wildcards `*` and `?` allowed). This is prefix matching: the pattern
///     is compiled with an implicit trailing `*`.
///  2. If a URL matches entries from both lists:
///       * when one matching entry's language is a **strict subset** of the
///         other's, the more specific (subset) entry decides — regardless of
///         which list it is in;
///       * when they are equal, or incomparable (neither contains the other),
///         the configured [ConflictResolution] decides, defaulting to
///         blacklist-wins.
///     With more than two matching entries the rule generalises to the
///     minimal elements of the subset partial order: if every most-specific
///     matching entry comes from one list, that list decides; if the
///     most-specific entries are mixed, the conflict resolution decides.
///  3. If only one list matches, that list decides.
///  4. If nothing matches, [UnmatchedAction] decides — by default deny when a
///     whitelist is configured, allow otherwise.
library;

import 'glob.dart';
import 'policy_config.dart';

/// Why a request was allowed or denied. Machine-readable so the UI can explain
/// itself and so tests can assert the *path* taken, not just the outcome.
enum DecisionReason {
  policyDisabled('策略总开关已关闭'),
  unmatchedAllow('未匹配任何名单，且默认动作是放行'),
  unmatchedDeny('未匹配任何名单，且默认动作是拒绝'),
  whitelistOnly('仅命中白名单'),
  blacklistOnly('仅命中黑名单'),
  whitelistMoreSpecific('同时命中黑白名单，白名单更具体（是其子集）'),
  blacklistMoreSpecific('同时命中黑白名单，黑名单更具体（是其子集）'),
  conflictBlacklistWins('黑白名单互不包含，冲突解决方式为黑名单优先'),
  conflictWhitelistWins('黑白名单互不包含，冲突解决方式为白名单优先'),
  containmentBudgetExceeded('包含关系判定超出预算，按互不包含处理');

  const DecisionReason(this.labelZh);
  final String labelZh;
}

/// A rule together with the URL-normalised form it was matched against.
class RuleMatch {
  final PolicyRule rule;
  final String normalizedPattern;
  const RuleMatch(this.rule, this.normalizedPattern);

  PolicyListKind get kind => rule.kind;

  @override
  String toString() => '${rule.kind.labelZh}: ${rule.pattern}';
}

/// The outcome of evaluating one URL.
class PolicyDecision {
  final bool allowed;
  final DecisionReason reason;

  /// The URL as normalised for matching.
  final String normalizedUrl;

  final List<RuleMatch> whitelistMatches;
  final List<RuleMatch> blacklistMatches;

  /// The most specific matching entries (minimal elements of the subset order).
  final List<RuleMatch> decisiveRules;

  /// True when the outcome came from the conflict setting rather than from
  /// specificity.
  final bool conflictResolved;

  const PolicyDecision({
    required this.allowed,
    required this.reason,
    required this.normalizedUrl,
    this.whitelistMatches = const [],
    this.blacklistMatches = const [],
    this.decisiveRules = const [],
    this.conflictResolved = false,
  });

  /// A short, user-facing explanation, e.g. for the block page.
  String get explanation {
    final buffer = StringBuffer(reason.labelZh);
    if (decisiveRules.isNotEmpty) {
      buffer.write('：');
      buffer.write(decisiveRules.map((m) => m.rule.pattern).join('、'));
    }
    return buffer.toString();
  }

  Map<String, dynamic> toJson() => {
        'allowed': allowed,
        'reason': reason.name,
        'reasonLabel': reason.labelZh,
        'url': normalizedUrl,
        'whitelistMatches': [for (final m in whitelistMatches) m.rule.pattern],
        'blacklistMatches': [for (final m in blacklistMatches) m.rule.pattern],
        'decisive': [for (final m in decisiveRules) m.rule.pattern],
        'conflictResolved': conflictResolved,
      };
}

/// How two rules' languages relate.
enum RuleRelation {
  subsumes('前者包含后者（后者更具体）'),
  subsumedBy('前者被后者包含（前者更具体）'),
  equivalent('两者等价'),
  incomparable('互不包含');

  const RuleRelation(this.labelZh);
  final String labelZh;
}

/// Detail used by the in-app policy tester.
class PolicyTrace {
  final PolicyDecision decision;
  final List<RuleRelation> relations;
  final List<String> budgetWarnings;
  const PolicyTrace({
    required this.decision,
    this.relations = const [],
    this.budgetWarnings = const [],
  });
}

/// A rule compiled into matchable glob patterns.
class CompiledRule {
  final PolicyRule rule;
  final String normalized;
  final List<GlobPattern> patterns;
  final bool valid;

  CompiledRule._(this.rule, this.normalized, this.patterns, this.valid);

  factory CompiledRule.compile(PolicyRule rule, {required bool strictDomainBoundary}) {
    final normalized = PatternNormalizer.normalizeRulePattern(rule.pattern);
    if (normalized.isEmpty) {
      return CompiledRule._(rule, normalized, const [], false);
    }
    final specs = PatternNormalizer.expandRule(
      normalized,
      strictDomainBoundary: strictDomainBoundary,
    );
    return CompiledRule._(rule, normalized, [for (final s in specs) s.compile()], true);
  }

  bool get isWhitelist => rule.kind == PolicyListKind.whitelist;

  bool get isBlacklist => rule.kind == PolicyListKind.blacklist;

  bool matchesNormalized(String normalizedUrl) {
    for (final pattern in patterns) {
      if (pattern.matches(normalizedUrl)) return true;
    }
    return false;
  }

  @override
  String toString() => '${rule.kind.wire}:$normalized';
}

/// The filter engine. Immutable: rebuild one when the configuration changes.
class PolicyEngine {
  final PolicyConfig config;
  final List<CompiledRule> compiledRules;

  /// Rules that are enabled and syntactically usable.
  final List<CompiledRule> activeRules;

  final Map<String, bool> _subsetCache = {};

  PolicyEngine(this.config)
      : compiledRules = [
          for (final rule in config.rules)
            CompiledRule.compile(rule, strictDomainBoundary: config.strictDomainBoundary),
        ],
        activeRules = [
          for (final rule in config.rules)
            if (rule.enabled &&
                PatternNormalizer.normalizeRulePattern(rule.pattern).isNotEmpty)
              CompiledRule.compile(rule, strictDomainBoundary: config.strictDomainBoundary),
        ];

  bool isAllowed(String url) => decide(url).allowed;

  /// Evaluates [url] and returns the full decision.
  PolicyDecision decide(String url) {
    final normalizedUrl = PatternNormalizer.normalizeUrl(url);

    if (!config.enabled) {
      return PolicyDecision(
        allowed: true,
        reason: DecisionReason.policyDisabled,
        normalizedUrl: normalizedUrl,
      );
    }

    final whitelistMatches = <RuleMatch>[];
    final blacklistMatches = <RuleMatch>[];
    for (final candidate in activeRules) {
      if (!candidate.matchesNormalized(normalizedUrl)) continue;
      final match = RuleMatch(candidate.rule, candidate.normalized);
      if (candidate.isWhitelist) {
        whitelistMatches.add(match);
      } else {
        blacklistMatches.add(match);
      }
    }

    // (4) nothing matched
    if (whitelistMatches.isEmpty && blacklistMatches.isEmpty) {
      final bool allowed;
      final DecisionReason reason;
      switch (config.unmatchedAction) {
        case UnmatchedAction.allow:
          allowed = true;
          reason = DecisionReason.unmatchedAllow;
        case UnmatchedAction.deny:
          allowed = false;
          reason = DecisionReason.unmatchedDeny;
        case UnmatchedAction.auto:
          if (config.hasActiveWhitelist) {
            allowed = false;
            reason = DecisionReason.unmatchedDeny;
          } else {
            allowed = true;
            reason = DecisionReason.unmatchedAllow;
          }
      }
      return PolicyDecision(
        allowed: allowed,
        reason: reason,
        normalizedUrl: normalizedUrl,
        whitelistMatches: whitelistMatches,
        blacklistMatches: blacklistMatches,
      );
    }

    // (3) only one list matched
    if (blacklistMatches.isEmpty) {
      return PolicyDecision(
        allowed: true,
        reason: DecisionReason.whitelistOnly,
        normalizedUrl: normalizedUrl,
        whitelistMatches: whitelistMatches,
        blacklistMatches: blacklistMatches,
        decisiveRules: whitelistMatches,
      );
    }
    if (whitelistMatches.isEmpty) {
      return PolicyDecision(
        allowed: false,
        reason: DecisionReason.blacklistOnly,
        normalizedUrl: normalizedUrl,
        whitelistMatches: whitelistMatches,
        blacklistMatches: blacklistMatches,
        decisiveRules: blacklistMatches,
      );
    }

    // (2) both lists matched: reduce to the most specific entries.
    final allMatches = [...whitelistMatches, ...blacklistMatches];
    final byPattern = <String, CompiledRule>{
      for (final rule in activeRules)
        if (rule.valid) _ruleKey(rule.rule): rule,
    };

    var budgetExceeded = false;
    bool isStrictlyMoreSpecific(RuleMatch candidate, RuleMatch other) {
      final a = byPattern[_ruleKey(candidate.rule)];
      final b = byPattern[_ruleKey(other.rule)];
      if (a == null || b == null) return false;
      try {
        final aSubsetB = _isSubset(a, b);
        if (!aSubsetB) return false;
        final bSubsetA = _isSubset(b, a);
        return !bSubsetA; // strict
      } on ContainmentBudgetExceeded {
        budgetExceeded = true;
        return false;
      }
    }

    final minimal = <RuleMatch>[
      for (final candidate in allMatches)
        if (!allMatches.any((other) =>
            !identical(other, candidate) && isStrictlyMoreSpecific(other, candidate)))
          candidate,
    ];

    final anyWhitelist = minimal.any((m) => m.kind == PolicyListKind.whitelist);
    final anyBlacklist = minimal.any((m) => m.kind == PolicyListKind.blacklist);

    if (minimal.isNotEmpty && !(anyWhitelist && anyBlacklist)) {
      // Every most-specific entry sits in the same list: specificity decides.
      final whitelistDecides = anyWhitelist;
      return PolicyDecision(
        allowed: whitelistDecides,
        reason: whitelistDecides
            ? DecisionReason.whitelistMoreSpecific
            : DecisionReason.blacklistMoreSpecific,
        normalizedUrl: normalizedUrl,
        whitelistMatches: whitelistMatches,
        blacklistMatches: blacklistMatches,
        decisiveRules: minimal,
      );
    }

    // Mixed most-specific entries: equal patterns or genuinely incomparable
    // ones. The configured conflict resolution decides.
    final blacklistWins = config.conflictResolution == ConflictResolution.blacklistWins;
    return PolicyDecision(
      allowed: !blacklistWins,
      reason: budgetExceeded
          ? DecisionReason.containmentBudgetExceeded
          : (blacklistWins
              ? DecisionReason.conflictBlacklistWins
              : DecisionReason.conflictWhitelistWins),
      normalizedUrl: normalizedUrl,
      whitelistMatches: whitelistMatches,
      blacklistMatches: blacklistMatches,
      decisiveRules: minimal,
      conflictResolved: true,
    );
  }

  /// Evaluates [url] and additionally reports the pairwise relation between
  /// every matching whitelist and blacklist entry. Backs the in-app tester.
  PolicyTrace trace(String url) {
    final decision = decide(url);
    final relations = <RuleRelation>[];
    final warnings = <String>[];
    final byPattern = <String, CompiledRule>{
      for (final rule in activeRules)
        if (rule.valid) _ruleKey(rule.rule): rule,
    };

    for (final w in decision.whitelistMatches) {
      for (final b in decision.blacklistMatches) {
        final a = byPattern[_ruleKey(w.rule)];
        final c = byPattern[_ruleKey(b.rule)];
        if (a == null || c == null) continue;
        try {
          final aSubsetC = _isSubset(a, c);
          final cSubsetA = _isSubset(c, a);
          final relation = aSubsetC && cSubsetA
              ? RuleRelation.equivalent
              : aSubsetC
                  ? RuleRelation.subsumedBy // a is the smaller one => b more specific
                  : cSubsetA
                      ? RuleRelation.subsumes
                      : RuleRelation.incomparable;
          relations.add(relation);
        } on ContainmentBudgetExceeded catch (e) {
          warnings.add(e.toString());
          relations.add(RuleRelation.incomparable);
        }
      }
    }
    return PolicyTrace(decision: decision, relations: relations, budgetWarnings: warnings);
  }

  /// True iff every URL matched by [a] is also matched by [b].
  bool _isSubset(CompiledRule a, CompiledRule b) {
    final key = '${_ruleKey(a.rule)}\u0000${_ruleKey(b.rule)}';
    final cached = _subsetCache[key];
    if (cached != null) return cached;
    final result = GlobContainment.isSubset(a.patterns, b.patterns);
    _subsetCache[key] = result;
    return result;
  }

  static String _ruleKey(PolicyRule rule) => '${rule.kind.wire}\u0000${rule.pattern.trim()}';

  /// Convenience for the UI: relation between two configured rules.
  RuleRelation relationBetween(PolicyRule a, PolicyRule b) {
    final ca = CompiledRule.compile(a, strictDomainBoundary: config.strictDomainBoundary);
    final cb = CompiledRule.compile(b, strictDomainBoundary: config.strictDomainBoundary);
    if (!ca.valid || !cb.valid) return RuleRelation.incomparable;
    try {
      final aSubsetB = _isSubset(ca, cb);
      final bSubsetA = _isSubset(cb, ca);
      if (aSubsetB && bSubsetA) return RuleRelation.equivalent;
      if (aSubsetB) return RuleRelation.subsumedBy;
      if (bSubsetA) return RuleRelation.subsumes;
      return RuleRelation.incomparable;
    } on ContainmentBudgetExceeded {
      return RuleRelation.incomparable;
    }
  }

  /// Rules that could never fire because a broader rule in the same list
  /// already covers them (unreachable entries, still legal to configure).
  ///
  /// A rule is shadowed when some *other* rule in the same list is strictly
  /// broader: every URL the candidate matches is matched by that other rule,
  /// but not the reverse.
  List<PolicyRule> shadowedRules(PolicyListKind kind) {
    final list = [
      for (final r in activeRules)
        if (r.rule.kind == kind && r.valid) r,
    ];
    final shadowed = <PolicyRule>[];
    for (final candidate in list) {
      for (final other in list) {
        if (identical(candidate, other)) continue;
        try {
          final candidateCoveredByOther = _isSubset(candidate, other);
          final otherCoveredByCandidate = _isSubset(other, candidate);
          if (candidateCoveredByOther && !otherCoveredByCandidate) {
            shadowed.add(candidate.rule);
            break;
          }
        } on ContainmentBudgetExceeded {
          break;
        }
      }
    }
    return shadowed;
  }
}
