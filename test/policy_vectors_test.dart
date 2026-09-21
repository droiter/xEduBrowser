import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/policy/glob.dart';
import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/policy/policy_engine.dart';

/// Asserts the hand-authored specification vectors in
/// `assets/policy_test_vectors.json`. The identical file is asserted by the
/// Kotlin engine's JVM unit tests, so the two implementations are checked
/// against the spec rather than against each other.
void main() {
  final file = File('assets/policy_test_vectors.json');
  final vectors = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final configs = (vectors['configs'] as Map).cast<String, dynamic>();

  group('decision vectors', () {
    for (final raw in vectors['cases'] as List) {
      final vector = (raw as Map).cast<String, dynamic>();
      test('${vector['config']}: ${vector['name']}', () {
        final config = PolicyConfig.fromJson(
          (configs[vector['config']] as Map).cast<String, dynamic>(),
        );
        final decision = PolicyEngine(config).decide(vector['url'] as String);
        expect(
          decision.allowed,
          vector['allowed'],
          reason: 'url=${vector['url']} -> ${decision.explanation}',
        );
        expect(
          decision.reason.name,
          vector['reason'],
          reason: 'url=${vector['url']} path taken',
        );
      });
    }
  });

  group('containment vectors', () {
    for (final raw in vectors['relations'] as List) {
      final vector = (raw as Map).cast<String, dynamic>();
      test('${vector['a']}  ⊆  ${vector['b']} : ${vector['why']}', () {
        final a = GlobPatternBuilder.of(vector['a'] as String);
        final b = GlobPatternBuilder.of(vector['b'] as String);
        expect(GlobContainment.isSubset(a, b), vector['subset']);
      });
    }
  });
}

/// Test-local helper mirroring what the engine does to a rule before matching:
/// normalise the text, then compile it.
abstract final class GlobPatternBuilder {
  static List<GlobPattern> of(String raw) {
    final normalized = PatternNormalizer.normalizeRulePattern(raw);
    return [
      for (final spec in PatternNormalizer.expandRule(normalized)) spec.compile(),
    ];
  }
}
