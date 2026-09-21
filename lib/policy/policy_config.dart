/// Configuration model for the whitelist / blacklist filter, plus the rule
/// text normaliser and expansion into concrete glob patterns.
library;

import 'glob.dart';

/// Which list a rule belongs to.
enum PolicyListKind {
  whitelist('whitelist'),
  blacklist('blacklist');

  const PolicyListKind(this.wire);
  final String wire;

  static PolicyListKind fromWire(String? value) => PolicyListKind.values.firstWhere(
        (k) => k.wire == value,
        orElse: () => PolicyListKind.blacklist,
      );

  String get labelZh => this == whitelist ? '白名单' : '黑名单';
}

/// How to resolve a conflict when a URL matches a whitelist entry and a
/// blacklist entry and **neither is a subset of the other**.
///
/// Note this setting is only consulted for genuinely incomparable matches.
/// When one matching entry is a subset of the other, the more specific
/// (subset) entry always wins and this setting is ignored.
enum ConflictResolution {
  /// Default, as specified: blacklist wins.
  blacklistWins('blacklistWins', '黑名单优先（默认）'),
  whitelistWins('whitelistWins', '白名单优先');

  const ConflictResolution(this.wire, this.labelZh);
  final String wire;
  final String labelZh;

  static ConflictResolution fromWire(String? value) =>
      ConflictResolution.values.firstWhere(
        (c) => c.wire == value,
        orElse: () => ConflictResolution.blacklistWins,
      );
}

/// What to do with a URL that matches **no** rule at all.
enum UnmatchedAction {
  /// Whitelist mode when a whitelist exists: deny anything not whitelisted.
  /// With no whitelist entries configured, allow everything (pure blacklist
  /// mode). This keeps a single config able to express both classic models.
  auto('auto', '自动（白名单非空则拒绝，否则放行）'),
  allow('allow', '一律放行'),
  deny('deny', '一律拒绝');

  const UnmatchedAction(this.wire, this.labelZh);
  final String wire;
  final String labelZh;

  static UnmatchedAction fromWire(String? value) => UnmatchedAction.values.firstWhere(
        (a) => a.wire == value,
        orElse: () => UnmatchedAction.auto,
      );
}

/// One configured entry, e.g. `https://example.com/news` or `*://*.ads.example`.
class PolicyRule {
  /// Raw text as authored by the user.
  final String pattern;

  final PolicyListKind kind;
  final bool enabled;

  /// Optional free-form note shown in the UI.
  final String note;

  const PolicyRule({
    required this.pattern,
    required this.kind,
    this.enabled = true,
    this.note = '',
  });

  /// Stable identity: normalised pattern plus list kind. Two entries that
  /// normalise to the same text in the same list are the same rule.
  String get id => '${kind.wire}:${PatternNormalizer.normalizeRulePattern(pattern)}';

  PolicyRule copyWith({
    String? pattern,
    PolicyListKind? kind,
    bool? enabled,
    String? note,
  }) =>
      PolicyRule(
        pattern: pattern ?? this.pattern,
        kind: kind ?? this.kind,
        enabled: enabled ?? this.enabled,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => {
        'pattern': pattern,
        'kind': kind.wire,
        'enabled': enabled,
        if (note.isNotEmpty) 'note': note,
      };

  factory PolicyRule.fromJson(Map<String, dynamic> json) => PolicyRule(
        pattern: (json['pattern'] as String? ?? '').trim(),
        kind: PolicyListKind.fromWire(json['kind'] as String?),
        enabled: json['enabled'] as bool? ?? true,
        note: json['note'] as String? ?? '',
      );
}

/// The complete filter configuration.
class PolicyConfig {
  static const int schemaVersion = 1;

  /// Master switch. When disabled every request is allowed.
  final bool enabled;

  final List<PolicyRule> rules;

  /// Only used for incomparable whitelist/blacklist overlaps.
  final ConflictResolution conflictResolution;

  /// Action for URLs matching nothing.
  final UnmatchedAction unmatchedAction;

  /// When true, a rule whose text stops at the host (`example.com`) is
  /// expanded so that it only matches that exact host or a host-boundary
  /// (`example.com/`, `example.com:8080`, `example.com?x`), instead of any
  /// string merely starting with it (`example.com.evil.test`).
  ///
  /// Default **false**, because the specification asks for plain prefix
  /// matching. Turn it on for hostile environments; the trade-off is
  /// documented in the README.
  final bool strictDomainBoundary;

  const PolicyConfig({
    this.enabled = true,
    this.rules = const [],
    this.conflictResolution = ConflictResolution.blacklistWins,
    this.unmatchedAction = UnmatchedAction.auto,
    this.strictDomainBoundary = false,
  });

  List<PolicyRule> rulesOf(PolicyListKind kind) =>
      [for (final r in rules) if (r.kind == kind) r];

  /// Whether a non-empty, enabled whitelist exists. Drives [UnmatchedAction.auto].
  bool get hasActiveWhitelist => rules.any(
        (r) => r.enabled && r.kind == PolicyListKind.whitelist && r.pattern.trim().isNotEmpty,
      );

  PolicyConfig copyWith({
    bool? enabled,
    List<PolicyRule>? rules,
    ConflictResolution? conflictResolution,
    UnmatchedAction? unmatchedAction,
    bool? strictDomainBoundary,
  }) =>
      PolicyConfig(
        enabled: enabled ?? this.enabled,
        rules: rules ?? this.rules,
        conflictResolution: conflictResolution ?? this.conflictResolution,
        unmatchedAction: unmatchedAction ?? this.unmatchedAction,
        strictDomainBoundary: strictDomainBoundary ?? this.strictDomainBoundary,
      );

  Map<String, dynamic> toJson() => {
        'version': schemaVersion,
        'enabled': enabled,
        'conflictResolution': conflictResolution.wire,
        'unmatchedAction': unmatchedAction.wire,
        'strictDomainBoundary': strictDomainBoundary,
        'rules': [for (final r in rules) r.toJson()],
      };

  factory PolicyConfig.fromJson(Map<String, dynamic> json) => PolicyConfig(
        enabled: json['enabled'] as bool? ?? true,
        rules: [
          for (final raw in (json['rules'] as List? ?? const []))
            if (raw is Map) PolicyRule.fromJson(Map<String, dynamic>.from(raw)),
        ],
        conflictResolution: ConflictResolution.fromWire(json['conflictResolution'] as String?),
        unmatchedAction: UnmatchedAction.fromWire(json['unmatchedAction'] as String?),
        strictDomainBoundary: json['strictDomainBoundary'] as bool? ?? false,
      );

  static const PolicyConfig empty = PolicyConfig();
}

/// A concrete glob produced from a rule, carrying its own prefix flag because
/// the host-boundary expansion mixes prefix and exact patterns.
class GlobSpec {
  final String glob;
  final bool prefix;
  const GlobSpec(this.glob, {this.prefix = true});

  GlobPattern compile() => GlobPattern.compile(glob, implicitTrailingStar: prefix);

  @override
  String toString() => prefix ? '$glob*' : glob;

  @override
  bool operator ==(Object other) =>
      other is GlobSpec && other.glob == glob && other.prefix == prefix;

  @override
  int get hashCode => Object.hash(glob, prefix);
}

/// Turns authored rule text into patterns the engine can reason about.
abstract final class PatternNormalizer {
  /// Canonicalises a rule's text:
  ///
  ///  * trims surrounding whitespace;
  ///  * adds a `*://` scheme wildcard when no scheme was given, so `example.com`
  ///    matches `http` and `https` alike (and `file://` local paths still work
  ///    when written as `/sdcard/pages/`);
  ///  * lowercases the scheme and authority only — the path, query and
  ///    fragment stay case sensitive, matching real URL semantics.
  static String normalizeRulePattern(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';
    if (!text.contains('://') && !text.startsWith('*:')) {
      text = '*://$text';
    }
    final schemeEnd = text.indexOf('://');
    if (schemeEnd < 0) return text;
    final scheme = text.substring(0, schemeEnd).toLowerCase();
    final rest = text.substring(schemeEnd + 3);
    final authorityEnd = rest.indexOf('/');
    var authority = (authorityEnd < 0 ? rest : rest.substring(0, authorityEnd)).toLowerCase();
    final tail = authorityEnd < 0 ? '' : rest.substring(authorityEnd);
    // Drop a default port so that `https://host:443/x` and `https://host/x`
    // are the same rule, mirroring URL normalisation. A `*` scheme wildcard
    // must drop both, because URLs are normalised per concrete scheme and so
    // never carry `:80` or `:443` after normalisation.
    final stripsHttpDefault = scheme == 'http' || scheme == '*';
    final stripsHttpsDefault = scheme == 'https' || scheme == '*';
    if (stripsHttpDefault && authority.endsWith(':80')) {
      authority = authority.substring(0, authority.length - 3);
    } else if (stripsHttpsDefault && authority.endsWith(':443')) {
      authority = authority.substring(0, authority.length - 4);
    }
    return '$scheme://$authority$tail';
  }

  /// Normalises an absolute URL for matching: scheme and authority lowercased,
  /// default port removed. Path/query/fragment are preserved verbatim.
  ///
  /// A URL without a scheme is treated as `https://`.
  static String normalizeUrl(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return text;
    if (!text.contains('://')) {
      if (text.startsWith('//')) {
        text = 'https:$text';
      } else if (text.startsWith('/')) {
        // Bare filesystem path: address it as a local file.
        text = 'file://$text';
      } else {
        text = 'https://$text';
      }
    }
    final schemeEnd = text.indexOf('://');
    final scheme = text.substring(0, schemeEnd).toLowerCase();
    final rest = text.substring(schemeEnd + 3);
    final authorityEnd = rest.indexOf('/');
    var authority = authorityEnd < 0 ? rest : rest.substring(0, authorityEnd);
    var tail = authorityEnd < 0 ? '' : rest.substring(authorityEnd);

    // Split off userinfo if present; only the host is case-insensitive-safe to
    // rewrite wholesale because we keep everything else byte-identical.
    authority = authority.toLowerCase();
    // Strip default ports.
    if (scheme == 'http' && authority.endsWith(':80')) {
      authority = authority.substring(0, authority.length - 3);
    } else if (scheme == 'https' && authority.endsWith(':443')) {
      authority = authority.substring(0, authority.length - 4);
    }
    if (tail.isEmpty && scheme != 'file') tail = '/';
    // Drop an empty fragment; keep queries (they can change the resource).
    final fragment = tail.indexOf('#');
    if (fragment >= 0) tail = tail.substring(0, fragment);
    return '$scheme://$authority$tail';
  }

  /// Expands a normalised rule into one or more concrete glob specs.
  static List<GlobSpec> expandRule(String normalized, {bool strictDomainBoundary = false}) {
    if (normalized.isEmpty) return const [];
    final specs = <GlobSpec>[GlobSpec(normalized)];
    if (!strictDomainBoundary) return specs;

    final schemeEnd = normalized.indexOf('://');
    if (schemeEnd < 0) return specs;
    final rest = normalized.substring(schemeEnd + 3);
    // Only host-only rules can be boundary-anchored; a rule that already
    // mentions a path, query or fragment is left as a prefix rule.
    if (rest.contains('/') || rest.contains('?') || rest.contains('#')) return specs;

    return [
      GlobSpec(normalized, prefix: false), // the bare host, exactly
      GlobSpec('$normalized/'),
      GlobSpec('$normalized:'),
      // `?` and `#` are glob metacharacters, so the boundary characters
      // themselves must be escaped — otherwise `host?` would match `host.`
      // followed by any single character, which is exactly the
      // `example.com.evil.test` hole this option exists to close.
      GlobSpec('$normalized\\?'),
      GlobSpec('$normalized\\#'),
    ];
  }

  /// Human-readable list of what a rule expands to, for the UI.
  static String describeExpansion(String raw, {bool strictDomainBoundary = false}) {
    final normalized = normalizeRulePattern(raw);
    final specs = expandRule(normalized, strictDomainBoundary: strictDomainBoundary);
    if (specs.isEmpty) return '（空规则，无效）';
    return specs.map((s) => s.toString()).join('  或  ');
  }
}
