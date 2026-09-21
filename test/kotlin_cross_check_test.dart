import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/policy/policy_engine.dart';

/// Differential cross-check between the two independent implementations of the
/// filter: the authoritative Dart engine (`lib/policy`) and the Kotlin port
/// (`android/.../policy`) that the WebView must use for synchronous
/// subresource gating.
///
/// `android/app/src/test/resources/dart_cross_check.json` contains 14 configs
/// x 40 URLs (560 cases) with the Dart engine's verdict recorded as the
/// expectation, and the Kotlin `DartCrossCheckTest` asserts its port reproduces
/// every one of them. This test asserts the Dart side still reproduces them as
/// well, so the fixture cannot silently rot: if `lib/policy` changes and the
/// fixture is not regenerated, this fails here AND in Gradle.
///
/// Note this fixture is derived from the Dart engine, so it proves the two
/// implementations agree; it is the hand-authored `policy_test_vectors.json`
/// that anchors both of them to the written specification.
void main() {
  final file = File('android/app/src/test/resources/dart_cross_check.json');

  test('the fixture exists and is substantial', () {
    expect(file.existsSync(), isTrue,
        reason: 'regenerate it as documented in docs/ANDROID_NATIVE.md');
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect((decoded['configs'] as Map).length, greaterThanOrEqualTo(10));
    expect((decoded['cases'] as List).length, greaterThanOrEqualTo(500));
  });

  test('the Dart engine reproduces every cross-check case', () {
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final configs = (decoded['configs'] as Map).cast<String, dynamic>();
    final engines = <String, PolicyEngine>{
      for (final entry in configs.entries)
        entry.key: PolicyEngine(
          PolicyConfig.fromJson((entry.value as Map).cast<String, dynamic>()),
        ),
    };

    final mismatches = <String>[];
    var checked = 0;
    for (final raw in decoded['cases'] as List) {
      final vector = (raw as Map).cast<String, dynamic>();
      final engine = engines[vector['config'] as String];
      expect(engine, isNotNull, reason: 'unknown config ${vector['config']}');
      final decision = engine!.decide(vector['url'] as String);
      checked++;
      if (decision.allowed != vector['allowed'] ||
          decision.reason.name != vector['reason'] ||
          decision.normalizedUrl != vector['normalizedUrl']) {
        mismatches.add('${vector['config']} | ${vector['url']} | '
            'expected ${vector['allowed']}/${vector['reason']}/${vector['normalizedUrl']} '
            'got ${decision.allowed}/${decision.reason.name}/${decision.normalizedUrl}');
      }
    }

    expect(checked, greaterThanOrEqualTo(500));
    expect(mismatches, isEmpty,
        reason: 'Dart engine drifted from the fixture the Kotlin port asserts:\n'
            '${mismatches.take(10).join('\n')}');
  });

  test('the fixture loaded by Gradle is byte-identical to the checked-in one', () {
    // Both live in the same place today; this guards against a future split.
    final resource = File('android/app/src/test/resources/dart_cross_check.json');
    expect(resource.readAsStringSync(), file.readAsStringSync());
  });
}
