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

/// The home page bookmark wall: square tiles showing each bookmark.
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
    Future<void> Function(String categoryId)? onAdd,
    Future<void> Function()? onImport,
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
          home: Scaffold(
            body: StartView(
              onNavigate: onNavigate ?? (_) {},
              onOpenLocalFile: () {},
              onAddBookmark: onAdd,
              onImportBookmarks: onImport,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('with no bookmarks the home page invites adding one', (tester) async {
    await pumpStart(tester, onAdd: (_) async {});
    expect(find.text('书签'), findsOneWidget);
    expect(find.textContaining('还没有书签'), findsOneWidget);
    expect(find.text('添加书签'), findsWidgets);
  });

  testWidgets('bookmarks appear as tiles with names and the allowed badge',
      (tester) async {
    await tester.runAsync(() async {
      await state.addBookmark(url: 'https://school.test/lessons', title: '课程平台');
      await state.addBookmark(
        url: 'https://news.test/',
        title: '新闻',
        addToWhitelist: false,
      );
    });

    await pumpStart(tester, onAdd: (_) async {});

    expect(find.text('课程平台'), findsOneWidget);
    expect(find.text('新闻'), findsOneWidget);
    // Only the bookmark that granted a whitelist entry carries the badge.
    expect(find.text('已放行'), findsOneWidget);
    expect(find.text('2 个 · 0 个分类'), findsOneWidget);
  });

  testWidgets('a missing screenshot falls back to the monogram tile',
      (tester) async {
    await tester.runAsync(() async {
      final bookmark = await state.addBookmark(url: 'https://school.test/a', title: '学校');
      await state.updateBookmark(
        bookmark.copyWith(thumbnailPath: '${directory.path}/nope.png'),
      );
    });

    await pumpStart(tester, onAdd: (_) async {});
    await tester.pump(const Duration(milliseconds: 50));

    // The tile still renders with its caption even though the image is gone.
    expect(find.text('学校'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a tile opens its URL', (tester) async {
    await tester.runAsync(() async {
      await state.addBookmark(url: 'https://school.test/lessons', title: '课程平台');
    });

    final opened = <String>[];
    await pumpStart(tester, onNavigate: opened.add, onAdd: (_) async {});

    await tester.tap(find.text('课程平台'));
    await tester.pump();

    expect(opened, ['https://school.test/lessons']);
  });

  testWidgets('the add tile starts the add flow with its category', (tester) async {
    await tester.runAsync(() async {
      await state.addBookmark(url: 'https://school.test/a', title: '学校');
    });

    final requested = <String>[];
    await pumpStart(tester, onAdd: (categoryId) async => requested.add(categoryId));

    // '添加到未分类' is the per-section ＋ tile; the header button is '添加书签'.
    await tester.tap(find.text('添加到$uncategorizedLabel'));
    await tester.pump();

    expect(requested, [uncategorizedId]);
  });

  testWidgets('the URL prompt returns the typed address', (tester) async {
    String? result;
    var finished = false;
    await tester.pumpWidget(MaterialApp(
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
    ));

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
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async => result = await showBookmarkUrlPrompt(context),
              child: const Text('开始'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('the grid reflows with the number of bookmarks', (tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 5; i++) {
        await state.addBookmark(url: 'https://site$i.test/', title: '站点 $i');
      }
    });
    await pumpStart(tester, onAdd: (_) async {});

    expect(find.text('5 个 · 0 个分类'), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      expect(find.text('站点 $i'), findsOneWidget);
    }
  });
}
