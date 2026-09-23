import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark_dialog.dart';
import 'package:tablet_browser/bookmarks/bookmark_preview_screen.dart';
import 'package:tablet_browser/browser/browser_bridge.dart';
import 'package:tablet_browser/browser/policy_webview.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// The preview browser behind the add-bookmark dialog.
///
/// It exists so a parent can look at a page *before* allowing it, so the page
/// is shown without the address filter; the bookmark it creates covers the
/// current page and the folder/site holding it.
void main() {
  late Directory directory;
  late AppState state;
  final commands = <MethodCall>[];

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tb_preview');
    state = AppState(
      store: ConfigStore(directory),
      settings: AppSettings(
        localServerEnabled: false,
        localServerRoot: directory.path,
        parentalGateEnabled: false,
      ),
    );
    commands.clear();

    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const commandsChannel = MethodChannel('tablet_browser/commands');
    messenger.setMockMethodCallHandler(commandsChannel, (call) async {
      commands.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('tablet_browser/events'),
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter/platform_views'),
      (call) async => <String, dynamic>{'id': 0},
    );
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('tablet_browser/commands'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('tablet_browser/events'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter/platform_views'), null);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  /// Advances a few frames. `pumpAndSettle` cannot be used here: the preview
  /// shows an indeterminate progress bar while a page loads, which never
  /// settles.
  Future<void> settle(WidgetTester tester, [int frames = 8]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Delivers a native event on `tablet_browser/events`.
  Future<void> sendNativeEvent(WidgetTester tester, Map<String, dynamic> event) async {
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

  /// Simulates the Android back button.
  Future<void> pressSystemBack(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
      (_) {},
    );
    await settle(tester);
  }

  /// Real file I/O only completes outside the fake-async zone.
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() done, {
    int tries = 250,
  }) async {
    for (var i = 0; i < tries && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> pumpPreview(
    WidgetTester tester,
    String url, {
    ValueChanged<bool?>? onResult,
  }) async {
    tester.view.physicalSize = const Size(1600, 1200);
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
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    final result = await Navigator.of(context).push<bool>(
                      MaterialPageRoute<bool>(
                        builder: (_) => BookmarkPreviewScreen(initialUrl: url),
                      ),
                    );
                    onResult?.call(result);
                  },
                  child: const Text('打开预览'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开预览'));
    await settle(tester);
  }

  testWidgets('the preview shows the address and follows the navigation',
      (tester) async {
    await pumpPreview(tester, 'https://school.test/lessons');

    final webView = tester.widget<PolicyWebView>(find.byType(PolicyWebView));
    // The preview runs with filtering switched off, for this view only.
    expect(webView.previewPolicy, const {'enabled': false});
    expect(tester.widget<TextField>(find.byKey(previewAddressKey)).controller?.text,
        'https://school.test/lessons');

    // Clicking through to another page updates the address box.
    await sendNativeEvent(tester, <String, dynamic>{
      'type': 'urlChanged',
      'viewId': webView.viewId,
      'url': 'https://school.test/lessons/chapter-2',
      'canGoBack': true,
    });
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(previewAddressKey)).controller?.text,
        'https://school.test/lessons/chapter-2');
  });

  testWidgets('a bookmark added here covers the page and the folder holding it',
      (tester) async {
    Directory('${directory.path}/课件').createSync(recursive: true);
    File('${directory.path}/课件/第一课.html')
        .writeAsStringSync('<html><head><title>拼音第一课</title></head></html>');
    final url = 'file://${directory.path}/课件/第一课.html';

    bool? result;
    await pumpPreview(tester, url, onResult: (value) => result = value);

    await tester.tap(find.byKey(previewAddBookmarkKey));
    await settle(tester);

    // No nested preview from inside the preview.
    expect(find.byKey(bookmarkPreviewButtonKey), findsNothing);
    // The title came from the page itself.
    expect(find.text('拼音第一课'), findsWidgets);

    await tester.tap(find.text('添加'));
    await waitFor(tester, () => state.bookmarks.isNotEmpty);

    // Stored (and granted) in the canonical percent-encoded form the WebView
    // reports, which is what the filter compares.
    final canonical = Uri.file('${directory.path}/课件/第一课.html').toString();
    final folder = Uri.file('${directory.path}/课件/').toString();
    expect(state.bookmarks.single.url, canonical);
    expect(state.bookmarks.single.whitelistPatterns, [canonical, folder]);
    expect(state.decideUrl(canonical).allowed, isTrue);

    // Leaving the preview tells the dialog that the flow is finished. The flag
    // is set once the bookmark has been written, which is after the list was
    // already populated, so wait for its snackbar.
    await waitFor(
      tester,
      () => find.textContaining('已添加书签').evaluate().isNotEmpty,
    );
    await pressSystemBack(tester);
    expect(result, isTrue);
  });

  testWidgets('the event stream can be shared by two listeners', (tester) async {
    final seenByFirst = <String>[];
    final seenBySecond = <String>[];
    final first = BrowserBridge.eventStream().listen(
      (event) => seenByFirst.add('${event['url']}'),
    );
    final second = BrowserBridge.eventStream().listen(
      (event) => seenBySecond.add('${event['url']}'),
    );
    addTearDown(() async {
      await first.cancel();
      await second.cancel();
    });

    await sendNativeEvent(tester, <String, dynamic>{
      'type': 'urlChanged',
      'viewId': 42,
      'url': 'https://school.test/shared',
    });
    await tester.pump();

    // The preview and the browser shell both listen while the preview is open:
    // a second `receiveBroadcastStream()` would steal the first one's events.
    expect(seenByFirst, ['https://school.test/shared']);
    expect(seenBySecond, ['https://school.test/shared']);
  });
}
