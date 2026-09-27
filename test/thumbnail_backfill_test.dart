import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark.dart';
import 'package:tablet_browser/bookmarks/thumbnail_backfill.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';

/// The background pass that fills in bookmarks without a preview.
///
/// Two halves, tested separately: the decisions (which bookmark, when, how often)
/// live in [ThumbnailBackfill] and are driven here by a fake clock and a fake
/// timer, so every scenario is instant; the pixels live in
/// [ThumbnailCaptureHost], which is pumped once with the platform channels
/// mocked.
/// A timer the test fires by hand, so scheduling tests run instantly.
class FakeTimers {
  final List<Duration> delays = <Duration>[];
  void Function()? pending;

  /// Records the delay and hands the test the callback to fire by hand. The
  /// returned timer is already cancelled, so nothing is left pending.
  Timer schedule(Duration delay, void Function() callback) {
    delays.add(delay);
    pending = callback;
    return Timer(Duration.zero, () {})..cancel();
  }

  /// Runs whatever is scheduled next.
  void fire() {
    final callback = pending;
    pending = null;
    callback?.call();
  }

  Duration? get lastDelay => delays.isEmpty ? null : delays.last;
}

void main() {
  Bookmark bookmark(String id, String url, {String? thumbnailPath}) => Bookmark(
        id: id,
        url: url,
        title: '书-$id',
        thumbnailPath: thumbnailPath,
        createdAt: DateTime(2026, 1, 1),
      );

  late FakeTimers timers;
  late DateTime now;
  late List<Bookmark> library;
  late List<String> saved;
  late List<String> logs;

  ThumbnailBackfill build({
    bool enabled = true,
    Duration gap = const Duration(seconds: 45),
    Duration idle = const Duration(seconds: 20),
  }) {
    timers = FakeTimers();
    now = DateTime(2026, 1, 1, 12);
    final backfill = ThumbnailBackfill(
      // Same contract as AppState's wiring: only bookmarks *without* a preview.
      candidates: () => library
          .where((Bookmark bookmark) => bookmark.thumbnailPath == null)
          .toList(),
      save: (Bookmark target, Uint8List bytes) async {
        saved.add(target.id);
        // AppState.setBookmarkThumbnail writes the file and stores the path, so
        // the bookmark drops out of `candidates` — mirror that here.
        library = <Bookmark>[
          for (final Bookmark item in library)
            if (item.id == target.id)
              bookmark(item.id, item.url, thumbnailPath: '/tmp/${item.id}.png')
            else
              item,
        ];
      },
      log: (String tag, String message, {bool warn = false}) =>
          logs.add('${warn ? 'W' : 'I'}:$message'),
      isEnabled: () => enabled,
      gap: gap,
      idleBeforeStart: idle,
      retryCooldown: const Duration(minutes: 30),
      allocateViewId: () => 100 + timers.delays.length,
      scheduleTimer: timers.schedule,
      clock: () => now,
    );
    addTearDown(backfill.dispose);
    return backfill;
  }

  setUp(() {
    library = <Bookmark>[
      bookmark('a', 'https://a.example/'),
      bookmark('b', 'https://b.example/'),
      bookmark('c', 'https://c.example/'),
    ];
    saved = <String>[];
    logs = <String>[];
  });

  group('ThumbnailBackfill', () {
    test('第一个补图要等一个 gap，且一次只做一张', () {
      final backfill = build();

      // Nothing happens until the gap elapses.
      expect(backfill.request, isNull);
      expect(timers.lastDelay, const Duration(seconds: 45));

      timers.fire();
      final first = backfill.request;
      expect(first, isNotNull);
      expect(first!.bookmarkId, 'a');
      expect(backfill.pendingCount, 3);
      // 正在补的那一张还在候选里（它还没有图），但同一时刻只允许一个 request。
      expect(logs.single, startsWith('I:后台补预览图开始：「书-a」'));

      // A tick while a capture is in flight must not start a second one.
      backfill.setForeground(true);
      expect(backfill.request!.bookmarkId, 'a');
      expect(saved, isEmpty);
    });

    test('补完一张后存图，并在一个 gap 之后再补下一张', () async {
      final backfill = build();
      timers.fire();
      final request = backfill.request!;

      await backfill.complete(Uint8List.fromList(List<int>.filled(2048, 7)));

      expect(saved, <String>['a']);
      expect(backfill.request, isNull);
      expect(backfill.capturedCount, 1);
      expect(backfill.pendingCount, 2);
      expect(logs.last, contains('后台补预览图完成：「书-a」2 KB，还剩 2 个待补'));
      expect(timers.lastDelay, const Duration(seconds: 45));

      timers.fire();
      expect(backfill.request!.bookmarkId, 'b');
      expect(request.viewId, isNot(backfill.request!.viewId));
    });

    test('孩子一动，就推迟到空闲够久再补', () {
      final backfill = build(idle: const Duration(seconds: 20));
      backfill.noteUserActivity();
      timers.fire();

      // Nothing captured; the next attempt is scheduled for the rest of the idle
      // window.
      expect(backfill.request, isNull);
      expect(timers.lastDelay, const Duration(seconds: 20));

      now = now.add(const Duration(seconds: 20));
      timers.fire();
      expect(backfill.request, isNotNull);
    });

    test('截图为空的书签会被冷却，先去补别人', () async {
      final backfill = build();
      timers.fire();
      final failed = backfill.request!.bookmarkId;
      expect(failed, 'a');

      await backfill.complete(null);

      expect(saved, isEmpty);
      expect(backfill.failedCount, 1);
      expect(backfill.capturedCount, 0);
      expect(logs.last, startsWith('W:后台补预览图失败：「书-a」截图为空'));
      expect(backfill.pendingCount, 2);

      timers.fire();
      expect(backfill.request!.bookmarkId, 'b');

      // 冷却期一过，a 又回到队列（它的顺序仍然在最前）。
      now = now.add(const Duration(minutes: 31));
      await backfill.complete(null); // b 也失败，进入冷却
      timers.fire();
      expect(backfill.request!.bookmarkId, 'a');
    });

    test('起始页与 PDF 永远不截图，也不占队列', () {
      library = <Bookmark>[
        bookmark('home', 'about:home'),
        bookmark('pdf', 'file:///sdcard/book/故事.pdf'),
        bookmark('ok', 'https://ok.example/'),
      ];
      final backfill = build();
      expect(backfill.pendingCount, 1);

      timers.fire();
      expect(backfill.request!.bookmarkId, 'ok');
    });

    test('没有可补的书签时，日志只写一次', () {
      library = <Bookmark>[];
      final backfill = build();
      timers.fire();
      expect(backfill.request, isNull);
      expect(logs.single, contains('没有缺图的书签'));
      expect(timers.lastDelay, const Duration(minutes: 10));

      timers.fire();
      expect(logs, hasLength(1));
    });

    test('开关关掉或应用不在前台时不补图', () {
      final off = build(enabled: false);
      timers.fire();
      expect(off.request, isNull);
      expect(off.pendingCount, 3);

      final background = build();
      background.setForeground(false);
      timers.fire();
      expect(background.request, isNull);
      // 回到前台后重新排期，仍然要空闲够久。
      background.setForeground(true);
      expect(timers.lastDelay, const Duration(seconds: 20));
    });

    test('补图期间书签被删掉：不写文件，继续下一张', () async {
      final backfill = build();
      timers.fire();
      library = <Bookmark>[
        bookmark('b', 'https://b.example/'),
        bookmark('c', 'https://c.example/'),
      ];

      await backfill.complete(Uint8List.fromList(<int>[1, 2, 3]));

      expect(saved, isEmpty);
      expect(backfill.capturedCount, 0);
      timers.fire();
      expect(backfill.request!.bookmarkId, 'b');
    });
  });

  group('ThumbnailCaptureHost', () {
    late Directory directory;
    late AppState state;
    final commands = <MethodCall>[];
    final png = Uint8List.fromList(
      const <int>[137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3],
    );

    setUp(() {
      directory = Directory.systemTemp.createTempSync('tb_backfill');
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
        (MethodCall call) async {
          commands.add(call);
          if (call.method == 'captureThumbnail') return png;
          return null;
        },
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('tablet_browser/events'),
        (MethodCall call) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter/platform_views'),
        (MethodCall call) async => <String, dynamic>{'id': 0},
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

    Future<void> sendEvent(WidgetTester tester, Map<String, dynamic> event) async {
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

    testWidgets('离屏加载、截图，并把字节交回去', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Uint8List? result;
      var done = false;
      const request = ThumbnailCaptureRequest(
        viewId: 42,
        bookmarkId: 'a',
        url: 'https://a.example/',
      );

      await tester.pumpWidget(
        AppScope(
          state: state,
          child: MaterialApp(
            home: Stack(
              children: <Widget>[
                const Scaffold(body: Text('前台内容')),
                ThumbnailCaptureHost(
                  request: request,
                  onDone: (Uint8List? bytes) {
                    result = bytes;
                    done = true;
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // 宿主被摆在窗口外面：孩子永远看不到它。
      final origin = tester.getTopLeft(find.text('前台内容'));
      expect(origin, Offset.zero);
      expect(tester.getTopLeft(find.byType(ThumbnailCaptureHost)).dx, lessThan(0));

      await sendEvent(tester, <String, dynamic>{
        'type': 'pageFinished',
        'viewId': 42,
        'url': 'https://a.example/',
      });
      for (var i = 0; i < 60 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(done, isTrue);
      expect(result, png);
      expect(
        commands.where((MethodCall call) => call.method == 'captureThumbnail').length,
        greaterThanOrEqualTo(2),
      );
    });
  });
}
