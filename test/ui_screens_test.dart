import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/browser/browser_bridge.dart';
import 'package:tablet_browser/browser/start_view.dart';
import 'package:tablet_browser/files/local_files_screen.dart';
import 'package:tablet_browser/log/request_log_screen.dart';
import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/rules/policy_tester_screen.dart';
import 'package:tablet_browser/rules/rules_screen.dart';
import 'package:tablet_browser/settings/settings_screen.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// Integration tests for the management screens: they must actually build and
/// render against the real [AppState], not merely compile.
void main() {
  late Directory directory;
  late AppState state;

  const threeLevel = PolicyConfig(
    rules: [
      PolicyRule(pattern: 'https://a.test', kind: PolicyListKind.whitelist, note: '站点根'),
      PolicyRule(pattern: 'https://a.test/x/y', kind: PolicyListKind.whitelist),
      PolicyRule(pattern: 'https://a.test/x', kind: PolicyListKind.blacklist, note: '广告位'),
    ],
  );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tablet_browser_ui');
    File('${directory.path}/index.html').writeAsStringSync('<h1>本地页面</h1>');
    Directory('${directory.path}/sub').createSync();
    state = AppState(
      store: ConfigStore(directory),
      policy: threeLevel,
      settings: AppSettings(
        localServerEnabled: false,
        localServerRoot: directory.path,
        // These tests are about the content of each screen; the parental gate
        // is exercised in test/parental_gate_test.dart, which is the only place
        // that should have to answer a challenge to see a screen.
        parentalGateEnabled: false,
      ),
    );
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Widget screen) async {
    // A tablet-sized surface, matching the target device class.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: AppTheme.light,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: screen,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the start view is a bare bookmark wall with no controls',
      (tester) async {
    await pump(tester, StartView(onNavigate: (_) {}));

    // Nothing to open yet, so it explains where bookmarks are added — without
    // offering a button of its own.
    expect(find.text('还没有书签'), findsOneWidget);
    expect(find.textContaining('设置'), findsWidgets);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('rules screen lists both lists and flags shadowed rules', (tester) async {
    await pump(tester, const RulesScreen());

    expect(find.text('白名单 (2)'), findsOneWidget);
    expect(find.text('黑名单 (1)'), findsOneWidget);
    expect(find.textContaining('https://a.test/x/y'), findsWidgets);
    // The blacklist entry is more specific than the whitelist root, so it is
    // reported as overridden by the broader rule in its own list.
    expect(find.textContaining('https://a.test'), findsWidgets);
  });

  testWidgets('policy tester renders the containment verdict for a URL', (tester) async {
    await pump(tester, const PolicyTesterScreen());

    await tester.enterText(find.byType(TextField).first, 'https://a.test/x/y/z');
    await tester.tap(find.text('测试'));
    await tester.pumpAndSettle();

    // The deepest whitelist entry is the most specific match, so the URL is
    // allowed even though a blacklist entry also matches.
    expect(find.textContaining('允许'), findsWidgets);
    expect(find.textContaining('白名单更具体'), findsWidgets);
  });

  testWidgets('policy tester explains an incomparable conflict', (tester) async {
    // updatePolicy writes to disk, and real I/O must run outside the fake
    // async zone a widget test body executes in.
    await tester.runAsync(() => state.updatePolicy(const PolicyConfig(
          rules: [
            PolicyRule(pattern: '*://*.a.test', kind: PolicyListKind.whitelist),
            PolicyRule(pattern: '*://x.*', kind: PolicyListKind.blacklist),
          ],
        )));
    await pump(tester, const PolicyTesterScreen());

    await tester.enterText(find.byType(TextField).first, 'https://x.a.test/page');
    await tester.tap(find.text('测试'));
    await tester.pumpAndSettle();

    expect(find.textContaining('黑名单优先'), findsWidgets);
    expect(find.textContaining('互不包含'), findsWidgets);
  });

  testWidgets('settings screen renders the current values', (tester) async {
    await pump(tester, const SettingsScreen());
    expect(find.textContaining('JavaScript'), findsWidgets);
    expect(find.textContaining('本地服务器'), findsWidgets);
  });

  group('the 关于 card', () {
    test('labels the version the way the card shows it', () {
      expect(
        const AppVersion(name: '1.0.12', code: 2013).label,
        '1.0.12（构建 2013）',
      );
      // A platform that only knows the name (or only the code) still reads
      // sensibly rather than printing an empty string.
      expect(const AppVersion(name: '1.0.12', code: 0).label, '1.0.12');
      expect(const AppVersion(name: '', code: 2013).label, '未知（构建 2013）');
      expect(const AppVersion(name: '', code: 0).label, '未知');
      expect(
        AppVersion.fromMap(<Object?, Object?>{'versionName': ' 1.0.9 ', 'versionCode': 10})
            .label,
        '1.0.9（构建 10）',
      );
    });

    testWidgets('shows the version the platform reports', (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('tablet_browser/commands'),
        (call) async => call.method == 'appVersion'
            ? <String, dynamic>{'versionName': '9.9.9', 'versionCode': 42}
            : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(
            const MethodChannel('tablet_browser/commands'),
            null,
          ));

      await pump(tester, const SettingsScreen());
      // The lookup is a platform round trip, so give the real event loop a turn.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();

      expect(find.text('关于'), findsWidgets);
      expect(
        find.descendant(
          of: find.byKey(aboutVersionKey),
          matching: find.text('9.9.9（构建 42）'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('says so when the version cannot be read', (tester) async {
      // No native layer in this test: the host has no package manager to ask.
      await pump(tester, const SettingsScreen());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(aboutVersionKey),
          matching: find.text('未知（无法读取）'),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('request log renders entries and its empty state', (tester) async {
    await pump(tester, const RequestLogScreen());
    // The screen opens on the 诊断日志 tab; the request log is the second one.
    await tester.tap(find.text('请求日志'));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无请求记录'), findsWidgets);

    state.logDecision(
      'https://a.test/x/y/z',
      state.engine.decide('https://a.test/x/y/z'),
    );
    // Log notifications are coalesced into a 200ms window to avoid rebuilding
    // the shell once per blocked subresource, so advance the clock past it.
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.textContaining('https://a.test/x/y/z'), findsWidgets);
  });

  testWidgets('the diagnostic log tab lists what the app did', (tester) async {
    state.logEvent('bookmark', '新增书签「课程平台」');
    await pump(tester, const RequestLogScreen());

    expect(find.text('诊断日志'), findsWidgets);
    expect(find.text('新增书签「课程平台」'), findsOneWidget);
    expect(find.text('暂无诊断记录'), findsNothing);
  });

  testWidgets('the file browser warns when all-files access is missing',
      (tester) async {
    // No native side in a widget test, so hasAllFilesAccess() reports false —
    // which is exactly the state a tablet is in before the parent grants it.
    // Under /sdcard the listing silently comes back empty there, so the screen
    // must say why instead of claiming the folder is empty.
    // The screen asks the platform for all-files access from initState; that
    // round trip needs the real event loop, so give it one before settling.
    await pump(tester, const LocalFilesScreen(startPath: '/sdcard/Download'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pumpAndSettle();

    expect(find.textContaining('未获得「所有文件访问权限」'), findsOneWidget);
    expect(find.text('打开系统权限设置'), findsWidgets);
    expect(find.textContaining('显示为空'), findsWidgets);
  });

  testWidgets('returning from the permission screen re-checks and refreshes', (
    tester,
  ) async {
    // The first visit to shared storage sends the parent to the system screen;
    // when they come back the screen must notice the permission and refresh,
    // instead of still claiming it is missing.
    var granted = false;
    const commands = MethodChannel('tablet_browser/commands');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commands, (call) async {
      if (call.method == 'hasAllFilesAccess') return granted;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(commands, null));

    await pump(tester, const LocalFilesScreen(startPath: '/sdcard/Download'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('未获得「所有文件访问权限」'), findsOneWidget);

    // The parent grants it and returns to the app.
    granted = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('未获得「所有文件访问权限」'), findsNothing);
    expect(find.text('已获得存储权限，目录已刷新'), findsOneWidget);
  });

  testWidgets('no permission warning for a private directory', (tester) async {
    await pump(tester, LocalFilesScreen(startPath: directory.path));
    expect(find.textContaining('未获得「所有文件访问权限」'), findsNothing);
  });

  testWidgets('local file browser lists the served directory', (tester) async {
    await pump(tester, LocalFilesScreen(startPath: directory.path));
    expect(find.textContaining('index.html'), findsWidgets);
    expect(find.textContaining('sub'), findsWidgets);
  });
}
