import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('start view summarises the active policy', (tester) async {
    await pump(tester, StartView(onNavigate: (_) {}, onOpenLocalFile: () {}));

    expect(find.text('起始页'), findsOneWidget);
    expect(find.text('策略已启用'), findsOneWidget);
    expect(find.text('2 条'), findsWidgets); // two whitelist entries
    expect(find.textContaining('白名单'), findsWidgets);
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

  testWidgets('request log renders entries and its empty state', (tester) async {
    await pump(tester, const RequestLogScreen());
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

  testWidgets('local file browser lists the served directory', (tester) async {
    await pump(tester, LocalFilesScreen(startPath: directory.path));
    expect(find.textContaining('index.html'), findsWidgets);
    expect(find.textContaining('sub'), findsWidgets);
  });
}
