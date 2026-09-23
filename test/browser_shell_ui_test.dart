import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/browser/browser_screen.dart';
import 'package:tablet_browser/browser/policy_webview.dart';
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
    const commands = MethodChannel('tablet_browser/commands');
    const events = MethodChannel('tablet_browser/events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commands, (call) async {
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
    // The bookmark card, where bookmarks are added now.
    expect(find.text('添加书签'), findsWidgets);
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

  testWidgets('back on the start page leaves the app alone', (tester) async {
    await pumpShell(tester);

    await pressSystemBack(tester);

    // Nothing to close: the pop is left to the system, which exits the app.
    expect(find.text('还没有书签'), findsOneWidget);
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
}
