import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark_manager_screen.dart';
import 'package:tablet_browser/browser/browser_screen.dart';
import 'package:tablet_browser/browser/policy_webview.dart';
import 'package:tablet_browser/browser/start_view.dart';
import 'package:tablet_browser/files/local_file_url.dart';
import 'package:tablet_browser/pdf/pdf_reader_screen.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// The browser shell: a full-screen page with one thin strip of chrome and no
/// address bar, and a menu whose first entry is the settings screen.
void main() {
  late Directory directory;
  late AppState state;

  /// Every command the shell sent to the native side, for the load-watchdog
  /// assertions.
  final commandCalls = <MethodCall>[];

  /// What the mocked `captureThumbnail` returns.
  final previewBytes = Uint8List.fromList(<int>[137, 80, 78, 71, 1, 2, 3, 4]);

  /// A real 1x1 PNG, so the PDF reader can decode the mocked page.
  final pdfPageBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

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
    commandCalls.clear();
    const commands = MethodChannel('tablet_browser/commands');
    const events = MethodChannel('tablet_browser/events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commands, (call) async {
      commandCalls.add(call);
      if (call.method == 'captureThumbnail') return previewBytes;
      if (call.method == 'pdfPageCount') return 3;
      if (call.method == 'renderPdfPage') return pdfPageBytes;
      return null;
    });
    messenger.setMockMethodCallHandler(events, (call) async => null);
    // Navigating away from the start page builds the PlatformView; there is no
    // Android host in a widget test, so answer its creation call.
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter/platform_views'),
      (call) async => <String, dynamic>{'id': 0},
    );
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('tablet_browser/commands'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('tablet_browser/events'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter/platform_views'),
      null,
    );
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

  /// Delivers a native event on `tablet_browser/events`, as the Android side
  /// would.
  Future<void> sendNativeEvent(
    WidgetTester tester,
    Map<String, dynamic> event,
  ) async {
    await tester.runAsync(() async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'tablet_browser/events',
            const StandardMethodCodec().encodeSuccessEnvelope(event),
            (_) {},
          );
    });
    await tester.pump();
  }

  /// Real file I/O only completes outside the fake-async zone.
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() done, {
    int tries = 250,
  }) async {
    for (var i = 0; i < tries && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
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
    // 书签管理排在设置的最后，是一个通往单独一页的入口。
    expect(find.byKey(openBookmarkManagerKey), findsOneWidget);
    expect(find.text('书签管理'), findsWidgets);
  });

  /// Simulates the Android back button.
  Future<void> pressSystemBack(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  /// 起始页那面墙的滚动视图。
  Finder wallScrollable() => find
      .descendant(of: find.byType(StartView), matching: find.byType(Scrollable))
      .first;

  /// 起始页那面墙当前的滚动位置。
  double wallOffset(WidgetTester tester) =>
      tester.state<ScrollableState>(wallScrollable()).position.pixels;

  /// 铺一墙够长的书签，并把墙滚到「书 12」那里；返回滚到哪儿了。
  Future<double> scrollWallToMiddle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (int i = 0; i < 40; i++) {
        await state.addBookmark(url: 'https://site$i.test/page', title: '书 $i');
      }
    });
    await pumpShell(tester);
    await tester.scrollUntilVisible(
      find.text('书 12'),
      200,
      scrollable: wallScrollable(),
    );
    await tester.pumpAndSettle();
    return wallOffset(tester);
  }

  testWidgets('back on a page closes the tab and lands on the start page', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await state.addBookmark(url: 'https://school.test/lessons', title: '课程平台');
    });
    await pumpShell(tester);
    // The single tab starts on the start page, so back may leave the app.
    expect(
      tester.widget<PopScope<Object>>(find.byType(PopScope<Object>)).canPop,
      isTrue,
    );

    // Open the bookmark: the tab now displays a page.
    await tester.tap(find.text('课程平台'));
    await tester.pump();
    expect(find.byType(PolicyWebView), findsOneWidget);
    expect(
      tester.widget<PopScope<Object>>(find.byType(PopScope<Object>)).canPop,
      isFalse,
    );

    await pressSystemBack(tester);

    // The tab was closed, which returns to the start page — not to the desktop.
    expect(find.byType(PolicyWebView), findsNothing);
    expect(find.text('课程平台'), findsOneWidget);
    expect(
      tester.widget<PopScope<Object>>(find.byType(PopScope<Object>)).canPop,
      isTrue,
    );
  });

  testWidgets('固定桌面：图标与「+」「⋮」同一排，缺省关闭，点一下开启', (tester) async {
    final List<MethodCall> lockCalls = <MethodCall>[];
    // 原生那边的真实状态：由这份 mock 记着，switch 只反映它。
    String platformState = 'none';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('tablet_browser/commands'),
      (MethodCall call) async {
        switch (call.method) {
          case 'lockTaskState':
            lockCalls.add(call);
            return <String, dynamic>{'state': platformState};
          case 'startLockTask':
            lockCalls.add(call);
            platformState = 'pinned';
            return <String, dynamic>{'state': platformState};
          case 'stopLockTask':
            lockCalls.add(call);
            platformState = 'none';
            return <String, dynamic>{'state': platformState};
        }
        return null;
      },
    );

    await pumpShell(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();

    // 缺省不开启：设置里是关的，图标也是空心。
    expect(state.settings.lockTaskEnabled, isFalse);
    final Icon pinIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(lockTaskToggleKey),
        matching: find.byType(Icon),
      ),
    );
    expect(pinIcon.icon, Icons.push_pin_outlined);

    // 与「+」「⋮」同一排：三者中心同一水平线，且它在「+」左边。
    final Finder pin = find.byKey(lockTaskToggleKey);
    final Finder add = find.byTooltip('新建标签页');
    final Finder menu = find.byTooltip('菜单');
    expect(pin, findsOneWidget);
    expect(add, findsOneWidget);
    expect(menu, findsOneWidget);
    final double pinY = tester.getCenter(pin).dy;
    expect(pinY, tester.getCenter(add).dy);
    expect(pinY, tester.getCenter(menu).dy);
    expect(tester.getCenter(pin).dx, lessThan(tester.getCenter(add).dx));

    // 点一下：走原生 startLockTask，设置变成开启，图标转实心。
    await tester.tap(pin);
    await tester.pumpAndSettle();
    await waitFor(tester, () => state.settings.lockTaskEnabled == true);
    expect(
      lockCalls.map((MethodCall call) => call.method),
      contains('startLockTask'),
    );
    await waitFor(
      tester,
      () => find.textContaining('固定桌面已开启').evaluate().isNotEmpty,
    );
    expect(
      tester
          .widget<Icon>(find.descendant(
            of: find.byKey(lockTaskToggleKey),
            matching: find.byType(Icon),
          ))
          .icon,
      Icons.push_pin,
    );

    // 再点一下：解除固定。
    await tester.tap(pin);
    await tester.pumpAndSettle();
    await waitFor(tester, () => state.settings.lockTaskEnabled == false);
    expect(
      lockCalls.map((MethodCall call) => call.method),
      contains('stopLockTask'),
    );
    await waitFor(
      tester,
      () => find.textContaining('已解除固定桌面').evaluate().isNotEmpty,
    );
    expect(
      tester
          .widget<Icon>(find.descendant(
            of: find.byKey(lockTaskToggleKey),
            matching: find.byType(Icon),
          ))
          .icon,
      Icons.push_pin_outlined,
    );
  });

  testWidgets('back on the start page leaves the app alone', (tester) async {
    await pumpShell(tester);

    await pressSystemBack(tester);

    // Nothing to close: the pop is left to the system, which exits the app.
    expect(find.text('还没有书签'), findsOneWidget);
  });

  testWidgets('从网页返回时，书签墙回到进入网页前的位置', (tester) async {
    final double before = await scrollWallToMiddle(tester);
    expect(before, greaterThan(0), reason: '先得真的把墙滚动起来');

    await tester.tap(find.text('书 12'));
    await tester.pump();
    expect(find.byType(PolicyWebView), findsOneWidget);

    await pressSystemBack(tester);

    // 回到起始页，而且停在离开时的那一行，不是被弹回顶部。
    expect(find.byType(StartView), findsOneWidget);
    expect(
      wallOffset(tester),
      closeTo(before, 1),
      reason: '返回后书签墙应停在点击进入网页前的位置',
    );
    expect(find.text('书 12'), findsOneWidget);
  });

  testWidgets('顶栏后退在没有页内历史时也回起始页（停在原位）', (tester) async {
    final double before = await scrollWallToMiddle(tester);

    await tester.tap(find.text('书 12'));
    await tester.pump();
    expect(find.byType(PolicyWebView), findsOneWidget);
    // 从书签墙直接打开的一页在 WebView 里没有历史，以前这个按钮是灰的。
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('后退'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byTooltip('后退'));
    await tester.pumpAndSettle();

    expect(find.byType(StartView), findsOneWidget);
    expect(
      wallOffset(tester),
      closeTo(before, 1),
      reason: '返回后书签墙应停在点击进入网页前的位置',
    );
  });

  testWidgets('编辑模式点书签进网页，返回后仍在编辑模式且停在原位置', (tester) async {
    await tester.runAsync(() async {
      for (int i = 0; i < 40; i++) {
        await state.addBookmark(url: 'https://site$i.test/page', title: '书 $i');
      }
      // 直接进编辑模式（密码门有自己的测试）。
      state.setHomeEditMode(true);
    });
    await pumpShell(tester);
    expect(state.homeEditMode, isTrue);
    final String id = state.bookmarks.firstWhere((b) => b.title == '书 12').id;

    await tester.scrollUntilVisible(
      find.text('书 12'),
      200,
      scrollable: wallScrollable(),
    );
    await tester.pumpAndSettle();
    final double before = wallOffset(tester);
    expect(before, greaterThan(0), reason: '先得真的把墙滚动起来');

    await tester.tap(find.text('书 12'));
    await tester.pump();
    expect(find.byType(PolicyWebView), findsOneWidget);
    expect(state.homeEditMode, isTrue, reason: '打开网页不应退出编辑模式');

    await pressSystemBack(tester);

    // 回到编辑模式的那一行，而不是被弹回顶部、也不是变回方块墙。
    expect(find.byType(StartView), findsOneWidget);
    expect(state.homeEditMode, isTrue, reason: '返回后仍应是编辑模式');
    expect(find.byKey(ValueKey<String>('edit-item-$id')), findsOneWidget);
    expect(
      wallOffset(tester),
      closeTo(before, 1),
      reason: '返回后编辑模式应停在点击进入网页前的位置',
    );
    expect(find.text('书 12'), findsOneWidget);
  });

  testWidgets('已有预览图的书签，日后浏览页面不会再自动改图', (tester) async {
    late String savedPath;
    await tester.runAsync(() async {
      final bookmark = await state.addBookmark(
        url: 'https://school.test/lessons',
        title: '课程平台',
      );
      await state.setBookmarkThumbnail(bookmark, Uint8List.fromList(<int>[1, 2, 3, 4]));
      savedPath = state.bookmarkFor('https://school.test/lessons')!.thumbnailPath!;
    });
    expect(File(savedPath).readAsBytesSync(), <int>[1, 2, 3, 4]);

    await pumpShell(tester);
    commandCalls.clear();
    await tester.tap(find.text('课程平台'));
    await tester.pump();
    final viewId = tester.widget<PolicyWebView>(find.byType(PolicyWebView)).viewId;
    await sendNativeEvent(tester, <String, dynamic>{
      'type': 'pageFinished',
      'viewId': viewId,
      'url': 'https://school.test/lessons',
      'title': '课程平台',
    });
    // 老逻辑在 pageFinished 后 900ms 就会重截一张并覆盖，这里给足时间。
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    expect(
      commandCalls.where((MethodCall call) => call.method == 'captureThumbnail'),
      isEmpty,
      reason: '已经有预览图的书签不该再截图',
    );
    expect(
      state.bookmarkFor('https://school.test/lessons')!.thumbnailPath,
      savedPath,
      reason: '预览图生成后就该保持不变',
    );
    expect(File(savedPath).readAsBytesSync(), <int>[1, 2, 3, 4]);
  });

  testWidgets('opening a bookmarked page captures its tile preview', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await state.addBookmark(
        url: 'https://school.test/lessons',
        title: '课程平台',
      );
    });
    expect(state.bookmarks.single.thumbnailPath, isNull);

    await pumpShell(tester);
    await tester.tap(find.text('课程平台'));
    await tester.pump();
    final viewId = tester.widget<PolicyWebView>(find.byType(PolicyWebView)).viewId;
    await sendNativeEvent(tester, <String, dynamic>{
      'type': 'pageFinished',
      'viewId': viewId,
      'url': 'https://school.test/lessons',
      'title': '课程平台',
    });
    await waitFor(tester, () => state.bookmarks.single.thumbnailPath != null);

    final path = state.bookmarks.single.thumbnailPath;
    expect(path, isNotNull);
    expect(
      File(path!).readAsBytesSync(),
      previewBytes,
      reason: '截图应写入书签的预览图文件',
    );
  });

  testWidgets('a PDF bookmark opens the page-by-page reader', (tester) async {
    File('${directory.path}/说明.pdf').writeAsStringSync('%PDF-1.4 test');

    await tester.runAsync(() async {
      await state.addBookmark(
        url: LocalFileUrl.canonical('${directory.path}/说明.pdf'),
        title: '使用说明',
      );
    });

    await pumpShell(tester);
    await tester.tap(find.text('使用说明'));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }

    // The reader replaces the WebView — a WebView cannot show a PDF.
    expect(find.byType(PdfReaderScreen), findsOneWidget);
    expect(find.byType(PolicyWebView), findsNothing);
    expect(find.byKey(pdfPageIndicatorKey), findsOneWidget);
  });

  testWidgets('a page that is not bookmarked is not screenshotted', (
    tester,
  ) async {
    await pumpShell(tester);
    await sendNativeEvent(tester, <String, dynamic>{
      'type': 'pageFinished',
      'viewId': 1,
      'url': 'https://other.test/page',
      'title': '别的页面',
    });
    await tester.pump(const Duration(seconds: 2));
    expect(state.bookmarks, isEmpty);
  });

  testWidgets('a load that never finishes is retried, then reported', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await state.addBookmark(url: 'https://slow.test/page', title: '慢页面');
    });
    await pumpShell(tester);

    List<MethodCall> loadCalls() =>
        [for (final call in commandCalls) if (call.method == 'loadUrl') call];

    await tester.tap(find.text('慢页面'));
    await tester.pump();
    // The load is replayed once the platform view exists (after a frame).
    await tester.pump();
    await waitFor(tester, () => loadCalls().isNotEmpty);
    expect(loadCalls(), hasLength(1));
    final int viewId =
        (loadCalls().first.arguments as Map<Object?, Object?>)['viewId']! as int;

    // The page says it started but never finishes: without the watchdog the
    // shell would spin forever, which is the bug this guards.
    await sendNativeEvent(tester, <String, dynamic>{
      'type': 'pageStarted',
      'viewId': viewId,
      'url': 'https://slow.test/page',
    });
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(loadCalls().length, greaterThan(1), reason: '看门狗应重发加载命令');
    expect(
      state.appLog.any(
        (entry) => entry.tag == 'browser' && entry.message.contains('重试'),
      ),
      isTrue,
      reason: '每次重试都要留下日志',
    );

    // After the retries run out the spinner is cleared and the user is told,
    // instead of being left with a page that never arrives.
    for (var i = 0; i < 9; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('加载超时'), findsWidgets);
    expect(
      state.appLog.any((entry) => entry.level == LogLevel.error),
      isTrue,
    );
  });

  testWidgets('网页脚本报错写进诊断日志（白屏页面的唯一线索）', (tester) async {
    await pumpShell(tester);

    // A page that dies inside its own <script> still reports pageFinished: the
    // console error is the only thing that says why nothing was drawn.
    final Map<String, dynamic> consoleError = <String, dynamic>{
      'type': 'consoleMessage',
      'viewId': 1,
      'message':
          "Uncaught TypeError: Cannot read properties of null (reading 'assetUrl')",
      'level': 'ERROR',
      'source':
          'file:///sdcard/egame/071_%E7%88%AC%E8%A1%8C%E5%8A%A8%E7%89%A9/go/05/1c/dd9fad2e8ee601b4bb764205bfc89132.js',
      'line': 1,
    };
    await sendNativeEvent(tester, consoleError);

    expect(
      state.appLog.any(
        (entry) =>
            entry.tag == 'console' &&
            entry.level == LogLevel.error &&
            entry.message.contains("reading 'assetUrl'") &&
            entry.message.contains('dd9fad2e8ee601b4bb764205bfc89132.js:1'),
      ),
      isTrue,
      reason: '日志要能说明是哪个文件哪一行报的错',
    );

    // A page stuck in a failing render loop repeats the same error constantly.
    final int entries = state.appLog.length;
    await sendNativeEvent(tester, consoleError);
    expect(state.appLog.length, entries, reason: '同一条报错不重复记录');
  });
}
