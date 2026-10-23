import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark.dart';
import 'package:tablet_browser/bookmarks/bookmark_manager.dart';
import 'package:tablet_browser/bookmarks/bookmark_manager_screen.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// The bookmark management page: bookmarks are grouped by category, each group
/// shows ten rows with the rest folded behind 展开, the scrollbar is a real
/// draggable thumb, and there is a pair of 到顶/到底 buttons.
void main() {
  late Directory directory;
  late AppState state;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tb_manager_ui');
    state = AppState(
      store: ConfigStore(directory),
      settings: AppSettings(
        localServerEnabled: false,
        localServerRoot: directory.path,
        // The parental gate is the settings screen's business, not this page's.
        parentalGateEnabled: false,
      ),
    );
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  /// Fills [categoryId] with [count] bookmarks, titled so rows can be told apart.
  Future<void> addIn(String categoryId, int count, String prefix) async {
    for (var i = 0; i < count; i++) {
      await state.addBookmark(
        url: 'https://$prefix-$i.test/lesson',
        title: '$prefix-$i',
        categoryId: categoryId,
        addToWhitelist: false,
      );
    }
  }

  Future<void> pumpManager(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
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
          home: const BookmarkManagerScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('groups the list by category, 未分类 last, each with its count',
      (tester) async {
    late String chineseId;
    late String mathId;
    await tester.runAsync(() async {
      chineseId = (await state.addCategory('语文')).id;
      mathId = (await state.addCategory('数学')).id;
      await addIn(chineseId, 2, '语文课');
      await addIn(mathId, 1, '数学课');
      await state.addBookmark(
        url: 'https://free.test/',
        title: '单独一个',
        addToWhitelist: false,
      );
    });

    await pumpManager(tester);

    // One header per category that holds a bookmark, in category order.
    expect(find.byKey(bookmarkGroupKey(chineseId)), findsOneWidget);
    expect(find.byKey(bookmarkGroupKey(mathId)), findsOneWidget);
    expect(find.byKey(bookmarkGroupKey(uncategorizedId)), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(bookmarkGroupKey(chineseId))).dy,
      lessThan(tester.getTopLeft(find.byKey(bookmarkGroupKey(mathId))).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(bookmarkGroupKey(mathId))).dy,
      lessThan(tester.getTopLeft(find.byKey(bookmarkGroupKey(uncategorizedId))).dy),
      reason: '未分类排在所有真实分类之后',
    );

    // The counts of the groups themselves.
    expect(find.text('2 个'), findsOneWidget);
    expect(find.text('语文'), findsOneWidget);
    expect(find.text('数学'), findsOneWidget);
    expect(find.text('未分类'), findsOneWidget);
    // Every row is there, grouped under its own header.
    expect(find.byType(ListTile), findsNWidgets(4));
  });

  testWidgets('a category shows ten rows and folds the rest behind 展开',
      (tester) async {
    late String categoryId;
    await tester.runAsync(() async {
      categoryId = (await state.addCategory('语文')).id;
      await addIn(categoryId, 13, '第课');
    });

    await pumpManager(tester);

    expect(find.byType(ListTile), findsNWidgets(10), reason: '缺省每分类 10 个');
    final expand = find.byKey(bookmarkGroupExpandKey(categoryId));
    expect(expand, findsOneWidget);
    expect(find.text('展开（还有 3 个）'), findsOneWidget);

    await tester.ensureVisible(expand);
    await tester.pumpAndSettle();
    await tester.tap(expand);
    await tester.pumpAndSettle();

    expect(find.byType(ListTile), findsNWidgets(13));
    expect(find.text('收起'), findsOneWidget);

    final collapse = find.byKey(bookmarkGroupExpandKey(categoryId));
    await tester.ensureVisible(collapse);
    await tester.pumpAndSettle();
    await tester.tap(collapse);
    await tester.pumpAndSettle();

    expect(find.byType(ListTile), findsNWidgets(10), reason: '收起点回缺省的 10 个');
    expect(find.text('展开（还有 3 个）'), findsOneWidget);
  });

  testWidgets('只折叠超长的分类，短分类不出现展开按钮', (tester) async {
    late String smallId;
    late String bigId;
    await tester.runAsync(() async {
      smallId = (await state.addCategory('小分类')).id;
      bigId = (await state.addCategory('大分类')).id;
      await addIn(smallId, 2, '小');
      await addIn(bigId, 11, '大');
    });

    await pumpManager(tester);

    expect(find.byKey(bookmarkGroupExpandKey(smallId)), findsNothing);
    expect(find.byKey(bookmarkGroupExpandKey(bigId)), findsOneWidget);
    expect(find.text('展开（还有 1 个）'), findsOneWidget);
  });

  testWidgets('滚动条常驻、可拖动，到顶 / 到底把页签滚到两端', (tester) async {
    await tester.runAsync(() async {
      for (var c = 0; c < 4; c++) {
        final category = await state.addCategory('分类 $c');
        await addIn(category.id, 12, '分类$c');
      }
    });

    await pumpManager(tester, size: const Size(1400, 800));

    final Scrollbar scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    expect(scrollbar.thumbVisibility, isTrue, reason: '侧边滚动条要常驻');
    expect(scrollbar.interactive, isTrue, reason: '滚动条要能触摸拖动');
    expect(scrollbar.thickness, 12, reason: '滑块要够宽，手指按得住');
    // 滑块和列表盯着同一个控制器：拖滑块就是滚列表。
    final ListView listView = tester.widget<ListView>(find.byType(ListView));
    expect(identical(listView.controller, scrollbar.controller), isTrue);
    expect(scrollbar.controller!.hasClients, isTrue);

    Finder pageScrollable() => find
        .descendant(
          of: find.byType(BookmarkManagerScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    double offset() =>
        tester.state<ScrollableState>(pageScrollable()).position.pixels;
    double maxOffset() =>
        tester.state<ScrollableState>(pageScrollable()).position.maxScrollExtent;

    await tester.tap(find.byKey(bookmarkManagerScrollBottomKey));
    await tester.pumpAndSettle();
    expect(offset(), maxOffset(), reason: '「到底」应把整页拉到最下面');
    expect(offset(), greaterThan(0), reason: '先得真的把页面滚动起来');

    await tester.tap(find.byKey(bookmarkManagerScrollTopKey));
    await tester.pumpAndSettle();
    expect(offset(), 0, reason: '「到顶」应把页面拉回最上面');
  });

  testWidgets('滚动条滑块真的能用手指拖动', (tester) async {
    await tester.runAsync(() async {
      for (var c = 0; c < 4; c++) {
        final category = await state.addCategory('分类 $c');
        await addIn(category.id, 12, '分类$c');
      }
    });

    await pumpManager(tester, size: const Size(1400, 800));

    final Scrollbar scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    final controller = scrollbar.controller!;
    expect(controller.offset, 0);

    // 滑块最初在轨道顶端：从它身上按住往下一段一段地拖，列表要跟着滚。
    final rect = tester.getRect(find.byType(Scrollbar));
    final gesture = await tester.startGesture(
      Offset(rect.right - 6, rect.top + 20),
    );
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0), reason: '拖动滑块应该滚动列表');
  });
}
