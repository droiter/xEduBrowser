import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/pdf/pdf_document.dart';
import 'package:tablet_browser/pdf/pdf_reader_screen.dart';
import 'package:tablet_browser/state/app_state.dart';

/// The PDF reader: one page at a time, turned by tapping the outer thirds or by
/// swiping.
void main() {
  /// A real 1x1 PNG, so `Image.memory` can decode what the mock renderer sends.
  final pageBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

  final commands = <MethodCall>[];
  final speechCalls = <MethodCall>[];
  late Map<String, dynamic> answers;

  setUp(() {
    commands.clear();
    speechCalls.clear();
    answers = {
      'pdfPageCount': 3,
      'renderPdfPage': pageBytes,
      'pdfPageText': null,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('tablet_browser/commands'),
      (call) async {
        commands.add(call);
        final value = answers[call.method];
        if (value is int) return value;
        if (value is Map) return Map<String, dynamic>.from(value);
        return value as Uint8List?;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('tablet_browser/pdf_tts'),
      (call) async {
        speechCalls.add(call);
        if (call.method == 'speak') return 'utt-test';
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('tablet_browser/commands'),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('tablet_browser/pdf_tts'),
      null,
    );
  });

  Future<void> pumpReader(
    WidgetTester tester, {
    String url = 'file:///sdcard/ebooks/说明.pdf',
    String title = '使用说明',
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: PdfReaderScreen(url: url, title: title),
    ));
    // The page count and the first page are real async channel calls.
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  String indicator(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(pdfPageIndicatorKey)).data ?? '';

  /// Replaces the shared command handler for one test, still recording [commands].
  void mockCommandHandler(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('tablet_browser/commands'),
      (call) {
        commands.add(call);
        return handler(call);
      },
    );
  }

  /// Every `renderPdfPage` request sent so far, in order.
  List<MethodCall> renderCalls() =>
      commands.where((call) => call.method == 'renderPdfPage').toList();

  testWidgets('shows the first page and the page count', (tester) async {
    await pumpReader(tester);

    expect(find.text('使用说明'), findsOneWidget);
    expect(indicator(tester), '1 / 3');
    expect(
      commands.where((call) => call.method == 'pdfPageCount').single.arguments,
      {'path': '/sdcard/ebooks/说明.pdf'},
    );
    expect(commands.any((call) => call.method == 'renderPdfPage'), isTrue);
  });

  testWidgets('tapping the right third goes forward, the left third goes back',
      (tester) async {
    await pumpReader(tester);
    final page = tester.getRect(find.byType(PageView));

    // Right third → next page.
    await tester.tapAt(Offset(page.right - 20, page.center.dy));
    await tester.pumpAndSettle();
    expect(indicator(tester), '2 / 3');

    // Left third → previous page.
    await tester.tapAt(Offset(page.left + 20, page.center.dy));
    await tester.pumpAndSettle();
    expect(indicator(tester), '1 / 3');

    // The first page has nothing before it: the tap does nothing.
    await tester.tapAt(Offset(page.left + 20, page.center.dy));
    await tester.pumpAndSettle();
    expect(indicator(tester), '1 / 3');
  });

  testWidgets('the middle tap hides and shows the reading chrome', (tester) async {
    await pumpReader(tester);
    expect(find.byKey(pdfPageIndicatorKey), findsOneWidget);

    final page = tester.getRect(find.byType(PageView));
    await tester.tapAt(page.center);
    await tester.pumpAndSettle();
    expect(find.byKey(pdfPageIndicatorKey), findsNothing);

    await tester.tapAt(page.center);
    await tester.pumpAndSettle();
    expect(find.byKey(pdfPageIndicatorKey), findsOneWidget);
  });

  testWidgets('swiping turns pages', (tester) async {
    await pumpReader(tester);

    // A quick swipe: what a reader does to turn a page.
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
    await tester.pumpAndSettle();
    expect(indicator(tester), '2 / 3');

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
    await tester.pumpAndSettle();
    expect(indicator(tester), '3 / 3');

    // Past the last page nothing happens.
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
    await tester.pumpAndSettle();
    expect(indicator(tester), '3 / 3');

    await tester.fling(find.byType(PageView), const Offset(400, 0), 1200);
    await tester.pumpAndSettle();
    expect(indicator(tester), '2 / 3');

    // A slow drag past half the width turns the page too.
    await tester.drag(find.byType(PageView), const Offset(900, 0));
    await tester.pumpAndSettle();
    expect(indicator(tester), '1 / 3');
  });

  testWidgets('the buttons page as well', (tester) async {
    await pumpReader(tester);
    expect(
      tester.widget<IconButton>(find.byKey(pdfPreviousButtonKey)).onPressed,
      isNull,
    );

    await tester.tap(find.byKey(pdfNextButtonKey));
    await tester.pumpAndSettle();
    expect(indicator(tester), '2 / 3');
    expect(
      tester.widget<IconButton>(find.byKey(pdfPreviousButtonKey)).onPressed,
      isNotNull,
    );
  });

  testWidgets('an unreadable document says so instead of showing blank pages',
      (tester) async {
    answers['pdfPageCount'] = 0;
    await pumpReader(tester, url: 'file:///sdcard/broken.pdf', title: '');

    expect(find.textContaining('这个 PDF 打不开'), findsOneWidget);
    expect(find.text('broken'), findsOneWidget, reason: '标题回退到文件名');
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('tapping a text line speaks it and highlights it', (tester) async {
    answers['pdfPageText'] = <String, Object?>{
      'width': 1000,
      'height': 1000,
      'lines': <Object?>[
        <String, Object?>{
          'text': '第一行文字',
          'left': 0.1,
          'top': 0.1,
          'right': 0.9,
          'bottom': 0.2,
        },
      ],
    };
    await pumpReader(tester);

    // 1x1 render → a 1200×1200 page centred in the 1200×1600 view; the line's
    // normalised box makes its middle y = 200 + 0.15 × 1200 = 380.
    await tester.tapAt(const Offset(600, 380));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(indicator(tester), '1 / 3', reason: '点文字不应翻页');
    expect(find.byKey(pdfSpeechHighlightKey), findsOneWidget);
    final MethodCall speak = speechCalls.lastWhere((c) => c.method == 'speak');
    expect((speak.arguments as Map)['text'], '第一行文字');
    expect((speak.arguments as Map)['rate'], 1.0);

    // The native done callback clears the highlight.
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'tablet_browser/pdf_tts',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onDone', <String, Object?>{'id': 'utt-test'}),
      ),
      (_) {},
    );
    await tester.pump();
    expect(find.byKey(pdfSpeechHighlightKey), findsNothing);
  });

  testWidgets('the speech rate slider changes the rate sent to the engine',
      (tester) async {
    answers['pdfPageText'] = <String, Object?>{
      'width': 1000,
      'height': 1000,
      'lines': <Object?>[
        <String, Object?>{
          'text': '朗读这一行',
          'left': 0.2,
          'top': 0.3,
          'right': 0.8,
          'bottom': 0.4,
        },
      ],
    };
    await pumpReader(tester);

    final Slider slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(1.5);
    slider.onChangeEnd!(1.5);
    await tester.pump();

    // Line middle: y = 200 + 0.35 × 1200 = 620.
    await tester.tapAt(const Offset(600, 620));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final MethodCall speak = speechCalls.lastWhere((c) => c.method == 'speak');
    expect((speak.arguments as Map)['rate'], 1.5);
  });

  testWidgets('renders one page at a time, and the page on screen first',
      (tester) async {
    // Each request hangs until the test completes it: this is the slow-reader
    // situation that used to stack up a render backlog.
    final pending = <int, Completer<Uint8List?>>{};
    mockCommandHandler((call) async {
      switch (call.method) {
        case 'pdfPageCount':
          return 6;
        case 'renderPdfPage':
          final Map<Object?, Object?> args =
              Map<Object?, Object?>.from(call.arguments as Map);
          final int index = args['index'] as int;
          final Completer<Uint8List?> completer = Completer<Uint8List?>();
          pending[index] = completer;
          return completer.future;
        default:
          return null;
      }
    });

    await pumpReader(tester);
    expect(find.text('正在渲染第 1 页…'), findsOneWidget);

    // Flip three pages while the first render is still unanswered: no new
    // request goes out, so nothing piles up behind the page being waited for.
    final Rect page = tester.getRect(find.byType(PageView));
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(Offset(page.right - 20, page.center.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
    }
    expect(indicator(tester), '4 / 6');
    expect(renderCalls(), hasLength(1), reason: '一次只渲染一页，翻页不再排队');

    // The first render finally lands: the page now on screen (4th) must be
    // rendered next, not the pages already flipped past.
    pending[0]!.complete(pageBytes);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final MethodCall next = renderCalls().last;
    expect(
      (next.arguments as Map<Object?, Object?>)['index'],
      3,
      reason: '屏幕上的页优先于翻过的页',
    );
  });

  testWidgets('翻回已缓存的页时，预渲染不会把它挤出缓存变成黑屏',
      (tester) async {
    final rendered = <int>[];
    mockCommandHandler((call) async {
      switch (call.method) {
        case 'pdfPageCount':
          return 8;
        case 'renderPdfPage':
          rendered.add(((call.arguments as Map)['index'] as num).toInt());
          return pageBytes;
        default:
          return null;
      }
    });

    await pumpReader(tester);
    final Rect page = tester.getRect(find.byType(PageView));
    Future<void> tapAt(double dx) async {
      await tester.tapAt(Offset(dx, page.center.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    // 前进五页：0 → 1 → 2 → 3 → 4 → 5，缓存装到上限。
    for (var i = 0; i < 5; i++) {
      await tapAt(page.right - 20);
    }
    expect(indicator(tester), '6 / 8');

    // 往左翻四页回到第 2 页（索引 1）。这一页一直在缓存里，翻到它时不应
    // 因为要渲染索引 0 而被挤掉——那正是"页面显示了又黑屏"的原因。
    for (var i = 0; i < 4; i++) {
      await tapAt(page.left + 20);
    }
    expect(indicator(tester), '2 / 8');

    expect(find.text('正在渲染第 2 页…'), findsNothing);
    expect(find.byType(Image), findsWidgets);
    expect(
      rendered.where((index) => index == 1),
      hasLength(1),
      reason: '已缓存的这一页不该被邻居的预渲染踢掉后再重渲',
    );
  });

  testWidgets('a render that never answers becomes 重试, not an endless spinner',
      (tester) async {
    var wedged = true;
    mockCommandHandler((call) async {
      switch (call.method) {
        case 'pdfPageCount':
          return 3;
        case 'renderPdfPage':
          return wedged
              ? Completer<Uint8List?>().future
              : Future<Uint8List?>.value(pageBytes);
        default:
          return null;
      }
    });

    await pumpReader(tester);
    expect(find.text('正在渲染第 1 页…'), findsOneWidget);

    // The watchdog gives up on a render that never replies.
    await tester.pump(const Duration(seconds: 21));
    expect(find.text('第 1 页渲染失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('正在渲染第 1 页…'), findsNothing);

    // 重试 preempts whatever is (not) rendering and shows the page.
    wedged = false;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('第 1 页渲染失败'), findsNothing);
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('渲染过程写进诊断日志，可从导出日志定位问题', (tester) async {
    final Directory directory = Directory.systemTemp.createTempSync('tb_pdf_log');
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final AppState state = AppState(
      store: ConfigStore(directory),
      settings: AppSettings(
        localServerEnabled: false,
        localServerRoot: directory.path,
        parentalGateEnabled: false,
      ),
    );

    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: PdfReaderScreen(url: 'file:///sdcard/ebooks/说明.pdf', state: state),
    ));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }

    // 翻一页：日志里要有翻页、请求、完成这些可对照的记录。
    final Rect page = tester.getRect(find.byType(PageView));
    await tester.tapAt(Offset(page.right - 20, page.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    String logText() => state.appLog
        .where((AppLogEntry entry) => entry.tag == 'pdf')
        .map((AppLogEntry entry) => entry.message)
        .join('\n');

    final String log = logText();
    expect(log, contains('打开「/sdcard/ebooks/说明.pdf」'));
    expect(log, contains('3 页'));
    expect(log, contains('渲染 #'));
    expect(log, contains('完成'));
    expect(log, contains('翻页 1 → 2（向右）'));
    expect(log, contains('在渲染='));

    // Let the reader go away and flush the log notification timer it schedules.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(logText(), contains('关闭阅读器'));
  });

  testWidgets('a PDF bookmark preview is its first rendered page', (tester) async {
    final bytes = await PdfDocuments.captureThumbnail(
      'file:///sdcard/ebooks/说明.pdf',
    );
    expect(bytes, pageBytes);
    final MethodCall render =
        commands.lastWhere((call) => call.method == 'renderPdfPage');
    expect(render.arguments, <String, Object?>{
      'path': '/sdcard/ebooks/说明.pdf',
      'index': 0,
      'maxWidth': 480,
    });
  });
}
