import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/thumbnail_capture.dart';
import 'package:tablet_browser/browser/policy_webview.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// Capturing a bookmark's cover from the settings screen.
///
/// The capture route loads the page without the address filter — the bookmark
/// was just created, so the page is usually not allowed yet — and it is only
/// reachable from the settings, behind the parental gate. The tests drive the
/// native channels exactly like the bookmark-preview harness does.
void main() {
  late Directory directory;
  late AppState state;
  final commands = <MethodCall>[];

  /// A stand-in PNG: the tile decodes whatever the native layer hands back, so
  /// the test only cares that the exact bytes travel back through the channel.
  final png = Uint8List.fromList(
    const <int>[137, 80, 78, 71, 13, 10, 26, 10, 42, 43, 44],
  );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tb_thumbnail');
    state = AppState(
      store: ConfigStore(directory),
      settings: AppSettings(
        localServerEnabled: false,
        localServerRoot: directory.path,
        parentalGateEnabled: false,
      ),
    );
    commands.clear();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('tablet_browser/commands'),
      (call) async {
        commands.add(call);
        // The screenshot itself: everything else (loadUrl, disposeView, ...)
        // only needs to answer without throwing.
        if (call.method == 'captureThumbnail') return png;
        return null;
      },
    );
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
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('tablet_browser/commands'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('tablet_browser/events'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter/platform_views'), null);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  /// Advances a few frames. `pumpAndSettle` cannot be used here: the capture
  /// screen shows an indeterminate progress indicator, which never settles.
  Future<void> settle(WidgetTester tester, [int frames = 8]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Delivers a native event on `tablet_browser/events`.
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

  /// Pumps and, outside the fake-async zone, waits real time as well: the
  /// capture waits 900ms before it screenshots, and either clock may be the one
  /// driving that delay.
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

  /// Taps a button that calls [captureThumbnailFor] and reports what it returns.
  Future<void> pumpCapture(
    WidgetTester tester,
    String url, {
    Duration timeout = const Duration(seconds: 20),
    int frames = 8,
    required ValueChanged<Uint8List?> onResult,
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
                    final bytes = await captureThumbnailFor(
                      context,
                      url: url,
                      timeout: timeout,
                    );
                    onResult(bytes);
                  },
                  child: const Text('生成预览图'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('生成预览图'));
    await settle(tester, frames);
  }

  testWidgets('a finished page is screenshotted and pops its PNG bytes',
      (tester) async {
    Uint8List? result;
    var finished = false;
    await pumpCapture(
      tester,
      'https://school.test/lessons',
      onResult: (bytes) {
        result = bytes;
        finished = true;
      },
    );

    // The throwaway view is on screen while the page loads.
    final webView = tester.widget<PolicyWebView>(find.byType(PolicyWebView));
    expect(find.byKey(thumbnailCaptureScreenKey), findsOneWidget);
    // Unfiltered for this view alone: the page is not allowed yet.
    expect(webView.previewPolicy, const {'enabled': false});

    await sendNativeEvent(tester, <String, dynamic>{
      'type': 'pageFinished',
      'viewId': webView.viewId,
      'url': 'https://school.test/lessons',
      'title': 'Lessons',
    });
    await waitFor(tester, () => finished);

    // Exactly the bytes the native side produced, at the agreed width.
    expect(result, equals(png));
    final capture = commands.lastWhere((c) => c.method == 'captureThumbnail');
    expect(capture.arguments, {'viewId': webView.viewId, 'maxWidth': 480});
    // The route is gone once its exit transition has played, so the caller is
    // not left staring at a loading card.
    await settle(tester);
    expect(find.byKey(thumbnailCaptureScreenKey), findsNothing);
  });

  testWidgets('a page that never finishes gives up at the timeout',
      (tester) async {
    Uint8List? result;
    var finished = false;
    await pumpCapture(
      tester,
      'https://school.test/slow',
      // Comfortably longer than the frames pumped below, so the screen is still
      // up when the state is inspected, yet short enough to be reached.
      timeout: const Duration(seconds: 2),
      onResult: (bytes) {
        result = bytes;
        finished = true;
      },
    );

    // No `pageFinished` ever arrives, so the caller must not hang on the view.
    expect(find.byKey(thumbnailCaptureScreenKey), findsOneWidget);
    expect(finished, isFalse);

    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await settle(tester);

    expect(finished, isTrue);
    expect(result, isNull);
    expect(find.byKey(thumbnailCaptureScreenKey), findsNothing);
    expect(commands.where((c) => c.method == 'captureThumbnail'), isEmpty);
  });

  testWidgets('a local PDF is refused without opening a capture screen',
      (tester) async {
    Uint8List? result;
    var finished = false;
    await pumpCapture(
      tester,
      'file:///sdcard/课件/第一课.pdf',
      onResult: (bytes) {
        result = bytes;
        finished = true;
      },
    );

    // Android's WebView cannot render a PDF, so there is nothing to photograph:
    // the reader shows it instead, and no route was pushed.
    expect(finished, isTrue);
    expect(result, isNull);
    expect(find.byKey(thumbnailCaptureScreenKey), findsNothing);
    expect(find.byType(PolicyWebView), findsNothing);
    expect(commands.where((c) => c.method == 'captureThumbnail'), isEmpty);
  });
}
