import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/policy/glob.dart';

GlobPattern p(String s, {bool prefix = true}) =>
    GlobPattern.compile(s, implicitTrailingStar: prefix);

void main() {
  group('matching', () {
    test('literal prefix pattern matches its extensions', () {
      expect(p('https://example.com/news').matches('https://example.com/news'), isTrue);
      expect(p('https://example.com/news').matches('https://example.com/news/1'), isTrue);
      expect(p('https://example.com/news').matches('https://example.com/newsroom'), isTrue);
      expect(p('https://example.com/news').matches('https://example.com/other'), isFalse);
    });

    test('exact (non-prefix) pattern matches only the whole string', () {
      expect(p('https://example.com', prefix: false).matches('https://example.com'), isTrue);
      expect(p('https://example.com', prefix: false).matches('https://example.com/'), isFalse);
      expect(
        p('https://example.com', prefix: false).matches('https://example.com.evil.test'),
        isFalse,
      );
    });

    test('star spans anything including separators', () {
      expect(p('*://*/ads/*').matches('https://any.test/ads/banner.png'), isTrue);
      expect(p('*://*.example.com').matches('https://a.b.example.com/x'), isTrue);
      expect(p('*://*.example.com').matches('https://example.com/x'), isFalse);
      expect(p('*://*.example.com').matches('https://notexample.com/x'), isFalse);
    });

    test('question mark consumes exactly one character', () {
      expect(p('https://a.test/?', prefix: false).matches('https://a.test/x'), isTrue);
      expect(p('https://a.test/?', prefix: false).matches('https://a.test/xy'), isFalse);
      expect(p('https://a.test/?', prefix: false).matches('https://a.test/'), isFalse);
    });

    test('backslash escapes a wildcard', () {
      expect(p(r'https://a.test/a\*b', prefix: false).matches('https://a.test/a*b'), isTrue);
      expect(p(r'https://a.test/a\*b', prefix: false).matches('https://a.test/axb'), isFalse);
    });

    test('bare star pattern matches everything', () {
      final all = p('*');
      expect(all.matches('anything at all'), isTrue);
      expect(all.matches(''), isTrue);
      expect(all.matchesEverything, isTrue);
    });

    test('matching is over UTF-16 code units consistently', () {
      expect(p('https://a.test/中文').matches('https://a.test/中文/页'), isTrue);
      expect(p('https://a.test/中文').matches('https://a.test/中'), isFalse);
    });
  });

  group('containment', () {
    bool subset(String a, String b, {bool pa = true, bool pb = true}) => GlobContainment.isSubset(
          [p(a, prefix: pa)],
          [p(b, prefix: pb)],
        );

    test('deeper path is contained in its ancestor', () {
      expect(subset('https://a.test/x/y', 'https://a.test/x'), isTrue);
      expect(subset('https://a.test/x', 'https://a.test/x/y'), isFalse);
    });

    test('identical patterns contain each other', () {
      expect(subset('https://a.test/x', 'https://a.test/x'), isTrue);
      expect(subset('https://a.test/x', 'https://a.test/x'), isTrue);
    });

    test('scheme wildcard is a superset of a concrete scheme', () {
      expect(subset('https://a.test', '*://a.test'), isTrue);
      expect(subset('*://a.test', 'https://a.test'), isFalse);
    });

    test('wildcard host relations', () {
      expect(subset('*://x.a.test', '*://*.a.test'), isTrue);
      expect(subset('*://*.a.test', '*://x.a.test'), isFalse);
      expect(subset('*://*.a.test', '*://a.test'), isFalse);
      expect(subset('*://a.test', '*://*.a.test'), isFalse);
    });

    test('disjoint patterns are incomparable', () {
      expect(subset('*://a.test/*/x', '*://a.test/*/y'), isFalse);
      expect(subset('*://a.test/*/y', '*://a.test/*/x'), isFalse);
    });

    test('union on the superset side is understood', () {
      final sub = [p('https://a.test/x')];
      final sup = [p('https://b.test'), p('https://a.test')];
      expect(GlobContainment.isSubset(sub, sup), isTrue);

      final supDisjoint = [p('https://b.test'), p('https://c.test')];
      expect(GlobContainment.isSubset(sub, supDisjoint), isFalse);
    });

    test('union on the subset side requires every member to be covered', () {
      final sub = [p('https://a.test/x'), p('https://z.test')];
      final sup = [p('https://a.test')];
      expect(GlobContainment.isSubset(sub, sup), isFalse);
    });

    test('empty sets', () {
      expect(GlobContainment.isSubset([], [p('https://a.test')]), isTrue);
      expect(GlobContainment.isSubset([p('https://a.test')], []), isFalse);
    });

    test('prefix and exact forms of the same host differ', () {
      expect(
        GlobContainment.isSubset([p('https://a.test', prefix: false)], [p('https://a.test')]),
        isTrue,
      );
      expect(
        GlobContainment.isSubset([p('https://a.test')], [p('https://a.test', prefix: false)]),
        isFalse,
      );
    });
  });
}
