import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The vectors are the shared specification asserted by BOTH the Dart engine
/// and the Kotlin engine. Two copies exist because Gradle unit tests can only
/// read from `src/test/resources`; this test fails the build the moment they
/// drift apart, so the Kotlin cross-check can never silently test stale data.
void main() {
  test('the Kotlin test resource is byte-identical to the asset', () {
    const asset = 'assets/policy_test_vectors.json';
    const resource = 'android/app/src/test/resources/policy_test_vectors.json';

    final assetFile = File(asset);
    expect(assetFile.existsSync(), isTrue, reason: '$asset is missing');

    final resourceFile = File(resource);
    if (!resourceFile.existsSync()) {
      // The Kotlin workstream may not have landed yet; never fail the Dart
      // suite for a file another part of the build owns.
      markTestSkipped('$resource not created yet');
      return;
    }

    expect(
      resourceFile.readAsStringSync(),
      assetFile.readAsStringSync(),
      reason: 're-copy $asset to $resource',
    );
  });

  test('the vector file declares both decision and containment cases', () {
    final decoded = File('assets/policy_test_vectors.json').readAsStringSync();
    expect(decoded, contains('"cases"'));
    expect(decoded, contains('"relations"'));
    expect(decoded, contains('conflictBlacklistWins'));
  });
}
