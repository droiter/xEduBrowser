import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/browser/url_input.dart';
import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/policy/policy_engine.dart';

void main() {
  group('URL resolution', () {
    test('empty input goes to the internal start page', () {
      expect(UrlResolver.resolve('   ').url, UrlResolver.homeUrl);
    });

    test('full URLs pass through', () {
      expect(UrlResolver.resolve('https://example.com/a?b=1').url, 'https://example.com/a?b=1');
      expect(UrlResolver.resolve('file:///sdcard/a.html').url, 'file:///sdcard/a.html');
      expect(UrlResolver.resolve('about:home').url, 'about:home');
    });

    test('bare domains default to https', () {
      expect(UrlResolver.resolve('example.com').url, 'https://example.com');
      expect(UrlResolver.resolve('example.com/news').url, 'https://example.com/news');
    });

    test('loopback and explicit ports default to http', () {
      expect(UrlResolver.resolve('127.0.0.1:8080/x').url, 'http://127.0.0.1:8080/x');
      expect(UrlResolver.resolve('localhost:9000').url, 'http://localhost:9000');
    });

    test('absolute paths become file URLs when no server is running', () {
      final resolved = UrlResolver.resolve('/sdcard/pages/index.html');
      expect(resolved.url, 'file:///sdcard/pages/index.html');
      expect(resolved.isLocalFile, isTrue);
    });

    test('paths inside the served root are served over loopback instead', () {
      final resolved = UrlResolver.resolve(
        '/data/app/files/site/index.html',
        localServerBase: 'http://127.0.0.1:8787',
        localRoot: '/data/app/files/site',
      );
      expect(resolved.url, 'http://127.0.0.1:8787/index.html');
    });

    test('paths outside the served root stay file URLs', () {
      final resolved = UrlResolver.resolve(
        '/sdcard/other.html',
        localServerBase: 'http://127.0.0.1:8787',
        localRoot: '/data/app/files/site',
      );
      expect(resolved.url, 'file:///sdcard/other.html');
    });

    test('file URLs inside the served root are upgraded to loopback', () {
      final resolved = UrlResolver.resolve(
        'file:///data/app/files/site/app/index.html',
        localServerBase: 'http://127.0.0.1:8787',
        localRoot: '/data/app/files/site',
      );
      expect(resolved.url, 'http://127.0.0.1:8787/app/index.html');
      expect(resolved.isLocalFile, isTrue);
    });

    test('file URLs outside the served root are left alone', () {
      expect(
        UrlResolver.resolve(
          'file:///sdcard/a.html',
          localServerBase: 'http://127.0.0.1:8787',
          localRoot: '/data/app/files/site',
        ).url,
        'file:///sdcard/a.html',
      );
    });

    test('meaningless input is rejected rather than searched', () {
      final resolved = UrlResolver.resolve('你好世界');
      expect(resolved.url, isEmpty);
      expect(resolved.error, isNotNull);
    });

    test('display strips the file scheme', () {
      expect(UrlResolver.displayFor('about:home'), '');
      expect(UrlResolver.displayFor('file:///sdcard/a%20b.html'), '/sdcard/a b.html');
      expect(UrlResolver.displayFor('https://a.test/'), 'https://a.test/');
    });
  });

  group('rule normalisation', () {
    test('bare entries gain a scheme wildcard', () {
      expect(PatternNormalizer.normalizeRulePattern('example.com'), '*://example.com');
      expect(PatternNormalizer.normalizeRulePattern('  example.com/x  '), '*://example.com/x');
    });

    test('explicit schemes are kept and authority lowercased', () {
      expect(
        PatternNormalizer.normalizeRulePattern('HTTPS://Example.COM/Path'),
        'https://example.com/Path',
      );
      expect(
        PatternNormalizer.normalizeRulePattern('*://*.Ads.Example'),
        '*://*.ads.example',
      );
    });

    test('default ports are dropped from rules as well as URLs', () {
      expect(
        PatternNormalizer.normalizeRulePattern('https://example.com:443/x'),
        'https://example.com/x',
      );
      expect(PatternNormalizer.normalizeRulePattern('example.com:80'), '*://example.com');
    });

    test('paths become file rules', () {
      expect(
        PatternNormalizer.normalizeRulePattern('/sdcard/pages/'),
        '*:///sdcard/pages/',
      );
      expect(
        PatternNormalizer.normalizeRulePattern('file:///sdcard/pages/'),
        'file:///sdcard/pages/',
      );
    });

    test('URL normalisation keeps paths case sensitive and drops fragments', () {
      expect(
        PatternNormalizer.normalizeUrl('HTTPS://Example.COM:443/Path#frag'),
        'https://example.com/Path',
      );
      expect(PatternNormalizer.normalizeUrl('example.com'), 'https://example.com/');
      expect(PatternNormalizer.normalizeUrl('/sdcard/a.html'), 'file:///sdcard/a.html');
    });

    test('strict host boundary expansion escapes the glob metacharacters', () {
      final specs = PatternNormalizer.expandRule(
        PatternNormalizer.normalizeRulePattern('example.com'),
        strictDomainBoundary: true,
      );
      expect(specs.length, 5);
      expect(specs.first.prefix, isFalse, reason: 'the bare host must match exactly');
      expect(specs.map((s) => s.glob).toList(), contains(r'*://example.com\?'));
      expect(specs.map((s) => s.glob).toList(), contains(r'*://example.com\#'));
    });

    test('a rule that already has a path is not boundary-expanded', () {
      final specs = PatternNormalizer.expandRule(
        PatternNormalizer.normalizeRulePattern('example.com/ads'),
        strictDomainBoundary: true,
      );
      expect(specs.length, 1);
      expect(specs.single.prefix, isTrue);
    });
  });

  group('engine detail', () {
    PolicyEngine engineOf(List<PolicyRule> rules, {
      ConflictResolution conflict = ConflictResolution.blacklistWins,
      UnmatchedAction unmatched = UnmatchedAction.auto,
      bool strict = false,
      bool enabled = true,
    }) =>
        PolicyEngine(PolicyConfig(
          enabled: enabled,
          rules: rules,
          conflictResolution: conflict,
          unmatchedAction: unmatched,
          strictDomainBoundary: strict,
        ));

    test('auto unmatched action follows whitelist presence', () {
      final withWhitelist = engineOf(const [
        PolicyRule(pattern: 'https://a.test', kind: PolicyListKind.whitelist),
      ]);
      expect(withWhitelist.config.hasActiveWhitelist, isTrue);
      expect(withWhitelist.decide('https://b.test').reason, DecisionReason.unmatchedDeny);

      final withoutWhitelist = engineOf(const [
        PolicyRule(pattern: 'https://a.test', kind: PolicyListKind.blacklist),
      ]);
      expect(withoutWhitelist.config.hasActiveWhitelist, isFalse);
      expect(withoutWhitelist.decide('https://b.test').reason, DecisionReason.unmatchedAllow);
    });

    test('a disabled whitelist does not activate whitelist mode', () {
      final engine = engineOf(const [
        PolicyRule(
          pattern: 'https://a.test',
          kind: PolicyListKind.whitelist,
          enabled: false,
        ),
      ]);
      expect(engine.config.hasActiveWhitelist, isFalse);
      expect(engine.decide('https://b.test').allowed, isTrue);
    });

    test('decisions expose the decisive entries and an explanation', () {
      final engine = engineOf(const [
        PolicyRule(pattern: 'https://a.test/deep', kind: PolicyListKind.whitelist),
        PolicyRule(pattern: 'https://a.test', kind: PolicyListKind.blacklist),
      ]);
      final decision = engine.decide('https://a.test/deep/page');
      expect(decision.allowed, isTrue);
      expect(decision.reason, DecisionReason.whitelistMoreSpecific);
      expect(decision.decisiveRules.single.rule.pattern, 'https://a.test/deep');
      expect(decision.explanation, contains('https://a.test/deep'));
      expect(decision.conflictResolved, isFalse);
    });

    test('trace reports pairwise relations between the two lists', () {
      final engine = engineOf(const [
        PolicyRule(pattern: 'https://a.test', kind: PolicyListKind.whitelist),
        PolicyRule(pattern: 'https://a.test/ads', kind: PolicyListKind.blacklist),
      ]);
      final trace = engine.trace('https://a.test/ads/x');
      expect(trace.relations.single, RuleRelation.subsumes);
      expect(trace.decision.reason, DecisionReason.blacklistMoreSpecific);
    });

    test('trace marks genuinely incomparable overlaps', () {
      final engine = engineOf(const [
        PolicyRule(pattern: '*://*.a.test', kind: PolicyListKind.whitelist),
        PolicyRule(pattern: '*://x.*', kind: PolicyListKind.blacklist),
      ]);
      final trace = engine.trace('https://x.a.test/');
      expect(trace.relations.single, RuleRelation.incomparable);
      expect(trace.decision.reason, DecisionReason.conflictBlacklistWins);
      expect(trace.decision.conflictResolved, isTrue);
    });

    test('equivalent rules are reported as such', () {
      final engine = engineOf(const [
        PolicyRule(pattern: 'https://a.test/x', kind: PolicyListKind.whitelist),
        PolicyRule(pattern: 'https://a.test/x', kind: PolicyListKind.blacklist),
      ]);
      expect(engine.trace('https://a.test/x').relations.single, RuleRelation.equivalent);
      // Equivalent rules are not *strictly* more specific, so the conflict
      // setting decides: blacklist by default.
      expect(engine.decide('https://a.test/x').reason, DecisionReason.conflictBlacklistWins);
    });

    test('shadowed rules are detected', () {
      final engine = engineOf(const [
        PolicyRule(pattern: 'https://a.test', kind: PolicyListKind.blacklist),
        PolicyRule(pattern: 'https://a.test/ads', kind: PolicyListKind.blacklist),
        PolicyRule(pattern: 'https://b.test', kind: PolicyListKind.blacklist),
      ]);
      final shadowed = engine.shadowedRules(PolicyListKind.blacklist);
      expect(shadowed.map((r) => r.pattern), ['https://a.test/ads']);
    });

    test('relationBetween works on arbitrary rule pairs', () {
      final engine = engineOf(const []);
      RuleRelation relation(String a, String b) => engine.relationBetween(
            PolicyRule(pattern: a, kind: PolicyListKind.whitelist),
            PolicyRule(pattern: b, kind: PolicyListKind.blacklist),
          );
      expect(relation('https://a.test/x', 'https://a.test'), RuleRelation.subsumedBy);
      expect(relation('https://a.test', 'https://a.test/x'), RuleRelation.subsumes);
      expect(relation('https://a.test/x', 'https://a.test/x'), RuleRelation.equivalent);
      expect(relation('https://a.test/x', 'https://b.test/y'), RuleRelation.incomparable);
    });

    test('empty patterns are ignored rather than matching everything', () {
      final engine = engineOf(const [
        PolicyRule(pattern: '   ', kind: PolicyListKind.blacklist),
      ]);
      expect(engine.activeRules, isEmpty);
      expect(engine.decide('https://anything.test').allowed, isTrue);
    });

    test('config survives a JSON round trip', () {
      final config = PolicyConfig(
        rules: const [
          PolicyRule(pattern: 'example.com', kind: PolicyListKind.whitelist, note: '学校'),
        ],
        conflictResolution: ConflictResolution.whitelistWins,
        unmatchedAction: UnmatchedAction.deny,
        strictDomainBoundary: true,
        enabled: false,
      );
      final restored = PolicyConfig.fromJson(config.toJson());
      expect(restored.rules.single.pattern, 'example.com');
      expect(restored.rules.single.note, '学校');
      expect(restored.conflictResolution, ConflictResolution.whitelistWins);
      expect(restored.unmatchedAction, UnmatchedAction.deny);
      expect(restored.strictDomainBoundary, isTrue);
      expect(restored.enabled, isFalse);
    });
  });
}
