import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark.dart';
import 'package:tablet_browser/bookmarks/bookmark_dialog.dart';
import 'package:tablet_browser/browser/start_view.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// The home page bookmark wall: square tiles showing each bookmark, and nothing
/// else — adding and deleting live in the settings screen.
void main() {
  late Directory directory;
  late AppState state;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tablet_browser_home');
    state = AppState(
      store: ConfigStore(directory),
      settings: AppSettings(
        localServerEnabled: false,
        localServerRoot: directory.path,
      ),
    );
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<void> pumpStart(
    WidgetTester tester, {
    ValueChanged<String>? onNavigate,
  }) async {
    tester.view.physicalSize = const Size(1400, 1100);
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
          home: Scaffold(body: StartView(onNavigate: onNavigate ?? (_) {})),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'with no bookmarks the home page only explains where to add one',
    (tester) async {
      await pumpStart(tester);

      expect(find.text('还没有书签'), findsOneWidget);
      // No add/delete controls on the home page.
      expect(find.text('添加书签'), findsNothing);
      expect(find.textContaining('添加到'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(IconButton), findsNothing);
    },
  );

  testWidgets('bookmarks appear as tiles with names and the allowed badge', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await state.addBookmark(
        url: 'https://school.test/lessons',
        title: '课程平台',
      );
      await state.addBookmark(
        url: 'https://news.test/',
        title: '新闻',
        addToWhitelist: false,
      );
    });

    await pumpStart(tester);

    expect(find.text('课程平台'), findsOneWidget);
    expect(find.text('新闻'), findsOneWidget);
    // Only the bookmark that granted a whitelist entry carries the badge.
    expect(find.text('已放行'), findsOneWidget);
    // The section header is the category name and its count.
    expect(find.text(uncategorizedLabel), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('a missing screenshot falls back to the monogram tile', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final bookmark = await state.addBookmark(
        url: 'https://school.test/a',
        title: '学校',
      );
      await state.updateBookmark(
        bookmark.copyWith(thumbnailPath: '${directory.path}/nope.png'),
      );
    });

    await pumpStart(tester);
    await tester.pump(const Duration(milliseconds: 50));

    // The tile still renders with its caption even though the image is gone.
    expect(find.text('学校'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a tile opens its URL', (tester) async {
    await tester.runAsync(() async {
      await state.addBookmark(
        url: 'https://school.test/lessons',
        title: '课程平台',
      );
    });

    final opened = <String>[];
    await pumpStart(tester, onNavigate: opened.add);

    await tester.tap(find.text('课程平台'));
    await tester.pump();

    expect(opened, ['https://school.test/lessons']);
  });

  testWidgets('the home page has no bookmark management buttons at all', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await state.addBookmark(url: 'https://school.test/a', title: '学校');
    });

    await pumpStart(tester);

    // The management controls that used to live here moved into settings.
    expect(find.text('添加书签'), findsNothing);
    expect(find.text('从目录导入'), findsNothing);
    expect(find.text('分类管理'), findsNothing);
    expect(find.text('添加到$uncategorizedLabel'), findsNothing);
    expect(find.byTooltip('更多操作'), findsNothing);
    expect(find.byTooltip('删除书签'), findsNothing);
  });

  testWidgets('the URL prompt returns the typed address', (tester) async {
    String? result;
    var finished = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showBookmarkUrlPrompt(context);
                  finished = true;
                },
                child: const Text('开始'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    expect(find.text('添加书签'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '  school.test/lessons  ');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(finished, isTrue);
    expect(result, 'school.test/lessons');
  });

  testWidgets('the URL prompt can be cancelled', (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async =>
                    result = await showBookmarkUrlPrompt(context),
                child: const Text('开始'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets(
    'the address step can pick a page through the local file browser',
    (tester) async {
      // A local page the browser can reach, inside the app's own directory.
      File('${directory.path}/page.html')
          .writeAsStringSync('<html><head><title>本地页</title></head></html>');

      String? result;
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        AppScope(
          state: state,
          child: MaterialApp(
            theme: AppTheme.light,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () async =>
                        result = await showBookmarkUrlPrompt(context),
                    child: const Text('开始'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('开始'));
      await tester.pumpAndSettle();

      // The address step offers browsing; the file browser lists real files, so it
      // needs real time interleaved with pumps.
      await tester.tap(find.byKey(browseLocalFileKey));
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(
        find.textContaining('page.html'),
        findsWidgets,
        reason: '文件浏览器应列出目录里的本地页',
      );

      await tester.tap(find.textContaining('page.html').first);
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }

      // Back at the address step, the picked file URL is filled in.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, 'file://${directory.path}/page.html');

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(result, 'file://${directory.path}/page.html');
    },
  );

  testWidgets('the grid reflows with the number of bookmarks', (tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 5; i++) {
        await state.addBookmark(url: 'https://site$i.test/', title: '站点 $i');
      }
    });
    await pumpStart(tester);

    for (var i = 0; i < 5; i++) {
      expect(find.text('站点 $i'), findsOneWidget);
    }
  });

  Future<void> pumpForm(WidgetTester tester, String url) async {
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showBookmarkDialog(
                    context,
                    url: url,
                    whitelistDefault: true,
                  ),
                  child: const Text('开始'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
  }

  testWidgets('the dialog lists the address and its folder before granting', (
    tester,
  ) async {
    await pumpForm(
      tester,
      'file:///sdcard/Books/Caterpillar/Caterpillar%20ebook.html',
    );

    // Both rules are created: the file, and the folder holding it (so its
    // sibling CSS/scripts/images load instead of the page coming up blank).
    expect(
      find.textContaining('file:///sdcard/Books/Caterpillar/'),
      findsWidgets,
    );
    expect(
      find.textContaining(
        'file:///sdcard/Books/Caterpillar/Caterpillar%20ebook.html',
      ),
      findsWidgets,
    );
    expect(find.textContaining('还会放行它所在的目录'), findsOneWidget);
  });

  testWidgets('a loopback address is previewed as the file it stands for', (
    tester,
  ) async {
    // The rule the dialog promises must be the one the engine actually checks:
    // a locally served page is judged as its `file://` address.
    await pumpForm(tester, 'http://127.0.0.1:8787/pages/a.html');

    expect(
      find.textContaining('file://${directory.path}/pages/a.html'),
      findsWidgets,
    );
    expect(find.textContaining('http://127.0.0.1:8787'), findsNothing);
  });

  testWidgets(
    'a local page offers its name, folder and <title> as title sources',
    (tester) async {
      Directory('${directory.path}/课件').createSync(recursive: true);
      File('${directory.path}/课件/第一课.html')
          .writeAsStringSync('<html><head><title>拼音第一课</title></head></html>');

      await pumpForm(tester, 'file://${directory.path}/课件/第一课.html');

      // The page's own <title> is pre-filled, and the dropdown is offered.
      expect(find.byKey(bookmarkTitleSourceKey), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '拼音第一课',
      );

      // Picking the folder name fills the field...
      await tester.tap(find.byKey(bookmarkTitleSourceKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('所在目录名：课件').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '课件',
      );

      // ...which stays editable afterwards.
      await tester.enterText(find.byType(TextField), '我的课件');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '我的课件',
      );

      // First choice: the HTML file name without its extension.
      await tester.tap(find.byKey(bookmarkTitleSourceKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('HTML 文件名：第一课').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '第一课',
      );

      // Last choice clears the field.
      await tester.tap(find.byKey(bookmarkTitleSourceKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('留空').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '',
      );
    },
  );

  testWidgets(
    'a page without a <title> says so and stays selectable otherwise',
    (tester) async {
      File('${directory.path}/plain.html').writeAsStringSync('<html></html>');

      await pumpForm(tester, 'file://${directory.path}/plain.html');

      expect(find.byKey(bookmarkTitleSourceKey), findsOneWidget);
      // No <title> in the file: the file name is the fallback.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'plain',
      );

      await tester.tap(find.byKey(bookmarkTitleSourceKey));
      await tester.pumpAndSettle();
      expect(find.text('网页内部标题（这个文件没有）'), findsWidgets);
      await tester.tap(
        find.text('所在目录名：${directory.path.split('/').last}').last,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        directory.path.split('/').last,
      );
    },
  );

  testWidgets('a local page in a storage root stays file-only', (tester) async {
    await pumpForm(tester, 'file:///sdcard/page.html');

    expect(find.textContaining('整张存储卡'), findsOneWidget);
    expect(find.textContaining('file:///sdcard/page.html'), findsWidgets);
  });
}
