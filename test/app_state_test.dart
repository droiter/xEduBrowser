import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/state/app_state.dart';

void main() {
  late Directory directory;
  late ConfigStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tablet_browser_state');
    store = ConfigStore(directory);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  group('ConfigStore', () {
    test('round trips a policy through disk', () async {
      final config = PolicyConfig(
        rules: const [
          PolicyRule(pattern: 'https://school.test/', kind: PolicyListKind.whitelist, note: '学校'),
          PolicyRule(pattern: '*://*/ads/*', kind: PolicyListKind.blacklist),
        ],
        conflictResolution: ConflictResolution.whitelistWins,
        strictDomainBoundary: true,
      );
      await store.savePolicy(config);

      final loaded = await store.loadPolicy();
      expect(loaded.rules.length, 2);
      expect(loaded.rules.first.note, '学校');
      expect(loaded.conflictResolution, ConflictResolution.whitelistWins);
      expect(loaded.strictDomainBoundary, isTrue);
    });

    test('a missing or corrupt file yields an empty policy rather than throwing', () async {
      expect((await store.loadPolicy()).rules, isEmpty);

      File('${directory.path}/policy.json').writeAsStringSync('{not json');
      expect((await store.loadPolicy()).rules, isEmpty);
    });

    test('round trips settings', () async {
      const settings = AppSettings(
        javaScript: false,
        textZoom: 130,
        localServerPort: 9999,
        localServerEnabled: false,
        userAgent: 'TabletBrowser/1.0',
      );
      await store.saveSettings(settings);
      final loaded = await store.loadSettings();
      expect(loaded.javaScript, isFalse);
      expect(loaded.textZoom, 130);
      expect(loaded.localServerPort, 9999);
      expect(loaded.localServerEnabled, isFalse);
      expect(loaded.userAgent, 'TabletBrowser/1.0');
    });

    test('export/import round trips, and rejects non-objects', () {
      const config = PolicyConfig(
        rules: [PolicyRule(pattern: 'example.com', kind: PolicyListKind.blacklist)],
      );
      final text = store.exportPolicy(config);
      expect(jsonDecode(text), isA<Map<String, dynamic>>());

      final imported = store.importPolicy(text);
      expect(imported.rules.single.pattern, 'example.com');

      expect(() => store.importPolicy('[1,2,3]'), throwsFormatException);
    });
  });

  group('AppState', () {
    AppState buildState() => AppState(
          store: store,
          settings: const AppSettings(localServerEnabled: false),
        );

    test('adding a rule normalises it and deduplicates within the list', () async {
      final state = buildState();
      await state.addRule(
        const PolicyRule(pattern: '  Example.COM/News  ', kind: PolicyListKind.blacklist),
      );
      await state.addRule(
        const PolicyRule(pattern: 'example.com/News', kind: PolicyListKind.blacklist),
      );

      expect(state.policy.rules.length, 1);
      expect(state.policy.rules.single.pattern, '*://example.com/News');
      expect(state.engine.decide('https://example.com/News/1').allowed, isFalse);
    });

    test('the same pattern is allowed in both lists', () async {
      final state = buildState();
      await state.addRule(
        const PolicyRule(pattern: 'example.com', kind: PolicyListKind.blacklist),
      );
      await state.addRule(
        const PolicyRule(pattern: 'example.com', kind: PolicyListKind.whitelist),
      );
      expect(state.policy.rules.length, 2);
      // Equal rules: neither is strictly more specific, so blacklist wins.
      expect(state.engine.decide('https://example.com/').allowed, isFalse);
    });

    test('empty patterns are refused', () async {
      final state = buildState();
      await state.addRule(const PolicyRule(pattern: '   ', kind: PolicyListKind.blacklist));
      expect(state.policy.rules, isEmpty);
    });

    test('removing a rule rebuilds the engine and persists', () async {
      final state = buildState();
      await state.addRule(
        const PolicyRule(pattern: 'example.com', kind: PolicyListKind.blacklist),
      );
      final persisted = await store.loadPolicy();
      expect(persisted.rules.length, 1);

      await state.removeRule(state.policy.rules.single);
      expect(state.policy.rules, isEmpty);
      expect(state.engine.decide('https://example.com/').allowed, isTrue);
      expect((await store.loadPolicy()).rules, isEmpty);
    });

    test('policy changes notify listeners and push to the native layer', () async {
      final state = buildState();
      var notifications = 0;
      Map<String, dynamic>? pushed;
      state.addListener(() => notifications++);
      state.onPolicyChanged = (payload) => pushed = payload;

      await state.updatePolicy(const PolicyConfig(
        rules: [PolicyRule(pattern: 'example.com', kind: PolicyListKind.whitelist)],
      ));

      expect(notifications, 1);
      expect(pushed, isNotNull);
      expect(pushed!['rules'], isA<List>());
      // The payload always carries the loopback mapping the native engine needs.
      expect(pushed!['localServer'], isA<Map>());
    });

    test('importing replaces the whole policy', () async {
      final state = buildState();
      await state.importPolicyText(jsonEncode(const PolicyConfig(
        rules: [
          PolicyRule(pattern: 'https://ok.test', kind: PolicyListKind.whitelist),
        ],
        unmatchedAction: UnmatchedAction.deny,
      ).toJson()));

      expect(state.policy.unmatchedAction, UnmatchedAction.deny);
      expect(state.engine.decide('https://other.test').allowed, isFalse);
      expect(state.engine.decide('https://ok.test/x').allowed, isTrue);
    });

    test('local server reporting and log bookkeeping', () async {
      final state = buildState();
      state.handleNativeEvent(const {
        'type': 'requestBlocked',
        'url': 'https://ads.test/banner.png',
        'resourceType': 'image',
        'reason': 'blacklistOnly',
        'explanation': '仅命中黑名单：ads.test',
        'matched': ['ads.test'],
      });

      expect(state.log.length, 1);
      expect(state.log.first.allowed, isFalse);
      expect(state.log.first.matched, ['ads.test']);

      state.clearLog();
      expect(state.log, isEmpty);
    });

    test('local server starts on a free port and stops cleanly', () async {
      final state = AppState(
        store: store,
        settings: AppSettings(
          localServerEnabled: false,
          localServerRoot: directory.path,
        ),
      );
      File('${directory.path}/index.html').writeAsStringSync('<h1>本地</h1>');

      final port = await state.startLocalServer();
      expect(port, isNotNull);
      expect(state.localServerRunning, isTrue);
      expect(state.localServer!.baseUrl, 'http://127.0.0.1:$port');

      await state.stopLocalServer();
      expect(state.localServerRunning, isFalse);
    });

    test('native policy payload carries the loopback mapping', () async {
      final state = AppState(
        store: store,
        settings: AppSettings(localServerEnabled: false, localServerRoot: directory.path),
      );
      final port = await state.startLocalServer();
      final payload = state.nativePolicyPayload();
      final localServer = payload['localServer'] as Map;
      expect(localServer['port'], port);
      expect(localServer['rootPath'], directory.path);
      await state.stopLocalServer();
    });
  });
}
