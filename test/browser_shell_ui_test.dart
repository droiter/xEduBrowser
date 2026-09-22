import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/browser/browser_screen.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// The browser shell: a full-screen page with one thin strip of chrome and no
/// address bar, and a menu whose first entry is the settings screen.
void main() {
  late Directory directory;
  late AppState state;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tb_shell');
    state = AppState(
      store: ConfigStore(directory),
      settings: AppSettings(
        localServerEnabled: false,
        localServerRoot: directory.path,
        parentalGateEnabled: false,
      ),
    );

    // No native layer in a widget test; answer the channel calls with nulls
    // instead of letting them raise MissingPluginException.
    const commands = MethodChannel('tablet_browser/commands');
    const events = MethodChannel('tablet_browser/events');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commands, (call) async => null);
    messenger.setMockMethodCallHandler(events, (call) async => null);
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('tablet_browser/commands'), null);
    messenger.setMockMethodCallHandler(const MethodChannel('tablet_browser/events'), null);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<void> pumpShell(WidgetTester tester) async {
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
          home: const BrowserScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the browser has no address bar', (tester) async {
    await pumpShell(tester);

    // No text input anywhere in the shell: the only way in is a bookmark.
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('输入网址'), findsNothing);
    // Navigation controls and the tab strip are still there.
    expect(find.byTooltip('后退'), findsOneWidget);
    expect(find.byTooltip('起始页'), findsOneWidget);
    expect(find.byTooltip('新建标签页'), findsOneWidget);
  });

  testWidgets('the top-right menu opens settings', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.byTooltip('菜单'));
    await tester.pumpAndSettle();

    // 设置 is the first entry, above the management screens.
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('黑白名单'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.text('网页引擎'), findsOneWidget);
    // The bookmark card, where bookmarks are added now.
    expect(find.text('添加书签'), findsWidgets);
  });
}
