import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/pdf/pdf_reader_screen.dart';

/// The PDF reader: one page at a time, turned by tapping the outer thirds or by
/// swiping.
void main() {
  /// A real 1x1 PNG, so `Image.memory` can decode what the mock renderer sends.
  final pageBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

  final commands = <MethodCall>[];
  late Map<String, dynamic> answers;

  setUp(() {
    commands.clear();
    answers = {
      'pdfPageCount': 3,
      'renderPdfPage': pageBytes,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('tablet_browser/commands'),
      (call) async {
        commands.add(call);
        final value = answers[call.method];
        return value is int ? value : value as Uint8List?;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('tablet_browser/commands'),
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
}
