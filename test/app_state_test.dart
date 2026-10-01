import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/bookmarks/bookmark.dart';
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

    test('固定桌面 缺省关闭，且能落盘', () async {
      expect(const AppSettings().lockTaskEnabled, isFalse);
      // 旧配置文件没有这个键时也保持关闭。
      expect(AppSettings.fromJson(const <String, dynamic>{}).lockTaskEnabled, isFalse);

      await store.saveSettings(const AppSettings(lockTaskEnabled: true));
      expect((await store.loadSettings()).lockTaskEnabled, isTrue);
      await store.saveSettings(const AppSettings());
      expect((await store.loadSettings()).lockTaskEnabled, isFalse);
    });

    test('round trips settings', () async {
      const settings = AppSettings(
        javaScript: false,
        textZoom: 130,
        localServerPort: 9999,
        localServerEnabled: false,
        userAgent: 'TabletBrowser/1.0',
        localFetchShim: true,
      );
      await store.saveSettings(settings);
      final loaded = await store.loadSettings();
      expect(loaded.javaScript, isFalse);
      expect(loaded.textZoom, 130);
      expect(loaded.localServerPort, 9999);
      expect(loaded.localServerEnabled, isFalse);
      expect(loaded.userAgent, 'TabletBrowser/1.0');
      expect(loaded.localFetchShim, isTrue);
    });

    test('the local fetch patch is off unless it was switched on', () async {
      // Default: a device that never touched the switch keeps the old behaviour.
      expect(const AppSettings().localFetchShim, isFalse);
      // A settings file written before the switch existed must not turn it on.
      final fromDisk = AppSettings.fromJson(<String, dynamic>{'javaScript': true});
      expect(fromDisk.localFetchShim, isFalse);
      // It is also part of the map the WebView receives.
      expect(const AppSettings().toNativeSettings()['localFetchShim'], isFalse);
      expect(
        const AppSettings(localFetchShim: true).toNativeSettings()['localFetchShim'],
        isTrue,
      );
    });

    test('防反复看 的默认值：开启、10 分钟', () async {
      // 旧配置文件没有这两个键，也必须保持"开启 + 10 分钟"。
      final loaded = AppSettings.fromJson(const <String, dynamic>{});
      expect(loaded.antiRepeatEnabled, isTrue);
      expect(loaded.antiRepeatMinutes, 10);
      expect(const AppSettings().antiRepeatEnabled, isTrue);
      expect(const AppSettings().antiRepeatMinutes, 10);

      await store.saveSettings(
        const AppSettings(antiRepeatEnabled: false, antiRepeatMinutes: 25),
      );
      final again = await store.loadSettings();
      expect(again.antiRepeatEnabled, isFalse);
      expect(again.antiRepeatMinutes, 25);
      // 越界值被夹住，免得算出 0 分钟或几天的冷却。
      expect(const AppSettings().copyWith(antiRepeatMinutes: 0).antiRepeatMinutes, 1);
      expect(const AppSettings().copyWith(antiRepeatMinutes: 99999).antiRepeatMinutes, 600);
    });

    test('防翻页 的默认值：关闭、10 秒', () async {
      // 旧配置文件没有这两个键时，不能突然开始拦孩子的翻页：保持"关闭 + 10 秒"。
      final loaded = AppSettings.fromJson(const <String, dynamic>{});
      expect(loaded.flipGuardEnabled, isFalse);
      expect(loaded.flipGuardSeconds, 10);
      expect(const AppSettings().flipGuardEnabled, isFalse);
      expect(const AppSettings().flipGuardSeconds, 10);

      await store.saveSettings(
        const AppSettings(flipGuardEnabled: true, flipGuardSeconds: 7),
      );
      final again = await store.loadSettings();
      expect(again.flipGuardEnabled, isTrue);
      expect(again.flipGuardSeconds, 7);
      // 越界值被夹住：0 秒等于没锁，超大值等于页面被锁死。
      expect(const AppSettings().copyWith(flipGuardSeconds: 0).flipGuardSeconds, 1);
      expect(
        const AppSettings().copyWith(flipGuardSeconds: 99999).flipGuardSeconds,
        600,
      );
      // 两个键都要送进 WebView，否则原生侧会走"旧调用方"分支而不注入。
      final Map<String, dynamic> native =
          const AppSettings(flipGuardEnabled: true, flipGuardSeconds: 5)
              .toNativeSettings();
      expect(native['flipGuardEnabled'], isTrue);
      expect(native['flipGuardSeconds'], 5);
      // 缺省的一整套设置送进原生时必须是"不注入"。
      expect(const AppSettings().toNativeSettings()['flipGuardEnabled'], isFalse);
      expect(const AppSettings().toNativeSettings()['flipGuardSeconds'], 10);
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

  group('防反复看', () {
    late Directory cooldownDir;
    late DateTime now;

    AppState buildCooling({bool enabled = true, int minutes = 10}) => AppState(
          store: ConfigStore(cooldownDir),
          settings: AppSettings(
            localServerEnabled: false,
            antiRepeatEnabled: enabled,
            antiRepeatMinutes: minutes,
          ),
          clock: () => now,
        );

    setUp(() {
      cooldownDir = Directory.systemTemp.createTempSync('tb_cooldown');
      now = DateTime(2026, 9, 29, 10, 0);
    });

    tearDown(() {
      if (cooldownDir.existsSync()) cooldownDir.deleteSync(recursive: true);
    });

    test('看过之后锁定 N 分钟，到点自动解锁', () async {
      final state = buildCooling();
      final bookmark = await state.addBookmark(url: 'https://a.test/', title: 'A');
      expect(state.isCoolingDown(bookmark), isFalse, reason: '没看过就不锁');

      await state.markBookmarkOpened(bookmark);
      Bookmark watched() => state.bookmarkFor('https://a.test/')!;
      expect(watched().lastOpenedAt, DateTime(2026, 9, 29, 10, 0));
      expect(state.isCoolingDown(watched()), isTrue);
      expect(state.cooldownRemaining(watched()).inMinutes, 10);
      expect(state.nextCooldownDeadline(), DateTime(2026, 9, 29, 10, 10));
      expect(state.nextCooldownWait(), const Duration(minutes: 10));

      now = now.add(const Duration(minutes: 9, seconds: 59));
      expect(state.isCoolingDown(watched()), isTrue);
      expect(state.cooldownRemaining(watched()).inSeconds, 1);

      now = now.add(const Duration(seconds: 1));
      expect(state.isCoolingDown(watched()), isFalse);
      expect(state.cooldownRemaining(watched()), Duration.zero);
      expect(state.nextCooldownDeadline(), isNull);
    });

    test('N 可配置', () async {
      final state = buildCooling(minutes: 30);
      final bookmark = await state.addBookmark(url: 'https://b.test/', title: 'B');
      await state.markBookmarkOpened(bookmark);
      now = now.add(const Duration(minutes: 29));
      expect(state.isCoolingDown(state.bookmarkFor('https://b.test/')!), isTrue);
      now = now.add(const Duration(minutes: 2));
      expect(state.isCoolingDown(state.bookmarkFor('https://b.test/')!), isFalse);
    });

    test('关掉开关后既不锁定也不记录', () async {
      final state = buildCooling(enabled: false);
      final bookmark = await state.addBookmark(url: 'https://c.test/', title: 'C');
      await state.markBookmarkOpened(bookmark);
      final stored = state.bookmarkFor('https://c.test/')!;
      expect(stored.lastOpenedAt, isNull, reason: '关闭时不该留下时间戳');
      expect(state.isCoolingDown(stored), isFalse);
      expect(state.nextCooldownDeadline(), isNull);
    });

    test('取最近一次解锁时间', () async {
      final state = buildCooling();
      final first = await state.addBookmark(url: 'https://d.test/', title: 'D');
      final second = await state.addBookmark(url: 'https://e.test/', title: 'E');
      await state.markBookmarkOpened(first);
      now = now.add(const Duration(minutes: 5));
      await state.markBookmarkOpened(second);
      // 先看的那个先解锁。
      expect(state.nextCooldownDeadline(), DateTime(2026, 9, 29, 10, 10));
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

    test('a hand-typed local rule is stored percent-encoded', () async {
      final state = buildState();
      await state.addRule(
        const PolicyRule(pattern: 'file:///sdcard/课件/', kind: PolicyListKind.whitelist),
      );

      // Encoded, so it matches the URL the WebView reports for that folder.
      expect(state.policy.rules.single.pattern,
          'file:///sdcard/%E8%AF%BE%E4%BB%B6/');
      expect(
        state.engine.decide('file:///sdcard/%E8%AF%BE%E4%BB%B6/1.html').allowed,
        isTrue,
      );
    });

    test('a wildcard local rule keeps its pattern language', () {
      expect(
        AppState.canonicalizeRulePattern('file:///sdcard/课件/*/index.html'),
        'file:///sdcard/%E8%AF%BE%E4%BB%B6/*/index.html',
      );
      // A `?` is left alone: it may be a wildcard, not a query separator.
      expect(
        AppState.canonicalizeRulePattern('file:///sdcard/课?/index.html'),
        'file:///sdcard/课?/index.html',
      );
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
