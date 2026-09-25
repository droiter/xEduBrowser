import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark.dart';
import 'package:tablet_browser/bookmarks/bookmark_grid.dart';
import 'package:tablet_browser/bookmarks/category_dialogs.dart';
import 'package:tablet_browser/browser/start_view.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// The home page bookmark wall with categories: sections, captions below the
/// square, drag-to-reorder and renaming.
void main() {
  late Directory directory;
  late AppState state;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tb_cat_ui');
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

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1400);
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
            body: StartView(onNavigate: (_) {}),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('bookmarks are grouped into their category sections', (tester) async {
    await tester.runAsync(() async {
      final lessons = await state.addCategory('课程');
      final news = await state.addCategory('新闻');
      await state.addBookmark(url: 'https://math.test/', title: '数学', categoryId: lessons.id);
      await state.addBookmark(
          url: 'https://science.test/', title: '科学', categoryId: lessons.id);
      await state.addBookmark(url: 'https://news.test/', title: '日报', categoryId: news.id);
    });

    await pumpHome(tester);

    expect(find.text('课程'), findsWidgets);
    expect(find.text('新闻'), findsWidgets);
    expect(find.text('数学'), findsOneWidget);
    expect(find.text('科学'), findsOneWidget);
    expect(find.text('日报'), findsOneWidget);
  });

  testWidgets('a bookmark without a category lands in 未分类', (tester) async {
    await tester.runAsync(() async {
      await state.addBookmark(url: 'https://loose.test/', title: '散装');
    });

    await pumpHome(tester);

    expect(find.text(uncategorizedLabel), findsWidgets);
    expect(find.text('散装'), findsOneWidget);
  });

  testWidgets('the caption sits below the square thumbnail', (tester) async {
    await tester.runAsync(() async {
      await state.addBookmark(url: 'https://school.test/a', title: '学校平台');
    });

    await pumpHome(tester);

    final captionBox = tester.getRect(find.text('学校平台'));
    // The generated monogram is the content of the square itself.
    final monogramBox = tester.getRect(find.text('SC'));
    expect(
      captionBox.top,
      greaterThan(monogramBox.bottom),
      reason: '标题必须在方块下方',
    );
    expect(captionBox.width, greaterThan(0));
  });

  testWidgets('dragging a tile onto another changes the order', (tester) async {
    late AppState st;
    await tester.runAsync(() async {
      final category = await state.addCategory('课程');
      await state.addBookmark(url: 'https://a.test/', title: '第一', categoryId: category.id);
      await state.addBookmark(url: 'https://b.test/', title: '第二', categoryId: category.id);
      await state.addBookmark(url: 'https://c.test/', title: '第三', categoryId: category.id);
      st = state;
    });

    await pumpHome(tester);
    final categoryId = st.categories.single.id;
    expect(st.bookmarksIn(categoryId).map((b) => b.title), ['第一', '第二', '第三']);

    // Long-press to pick the first tile up, drag it onto the third.
    final gesture = await tester.startGesture(tester.getCenter(find.text('第一')));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.moveTo(tester.getCenter(find.text('第三')));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      st.bookmarksIn(categoryId).map((b) => b.title),
      ['第二', '第三', '第一'],
      reason: '被拖动的方块应占据目标方块的位置',
    );
  });

  testWidgets('dragging a tile into another category moves it', (tester) async {
    late AppState st;
    late String lessonsId;
    await tester.runAsync(() async {
      final lessons = await state.addCategory('课程');
      final news = await state.addCategory('新闻');
      lessonsId = lessons.id;
      await state.addBookmark(url: 'https://a.test/', title: '第一', categoryId: lessons.id);
      await state.addBookmark(url: 'https://n.test/', title: '日报', categoryId: news.id);
      st = state;
    });

    await pumpHome(tester);

    final gesture = await tester.startGesture(tester.getCenter(find.text('第一')));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.moveTo(tester.getCenter(find.text('日报')));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(st.bookmarksIn(lessonsId), isEmpty);
    final newsCategory = st.categories.firstWhere((c) => c.name == '新闻');
    expect(st.bookmarksIn(newsCategory.id).map((b) => b.title), contains('第一'));
  });

  testWidgets('an empty category is not shown as a section', (tester) async {
    await tester.runAsync(() async {
      await state.addCategory('还没有书签的分类');
      await state.addBookmark(url: 'https://a.test/', title: '唯一');
    });

    await pumpHome(tester);

    expect(find.text('唯一'), findsOneWidget);
    expect(find.text('还没有书签的分类'), findsNothing);
  });

  testWidgets('a category folds shut without hiding the others', (tester) async {    late AppState st;
    late String lessonsId;
    await tester.runAsync(() async {
      final lessons = await state.addCategory('课程');
      final news = await state.addCategory('新闻');
      lessonsId = lessons.id;
      await state.addBookmark(
          url: 'https://math.test/', title: '数学', categoryId: lessons.id);
      await state.addBookmark(
          url: 'https://news.test/', title: '日报', categoryId: news.id);
      st = state;
    });

    await pumpHome(tester);
    expect(find.text('数学'), findsOneWidget);

    // The header itself is the toggle.
    await tester.tap(find.byKey(ValueKey<String>('bookmark-section-$lessonsId')));
    await tester.pumpAndSettle();

    expect(st.isCategoryCollapsed(lessonsId), isTrue);
    expect(find.text('数学'), findsNothing, reason: '折叠后不构建设方块');
    expect(find.text('已折叠'), findsOneWidget);
    // The header stays, with its count, and the other category is untouched.
    expect(find.text('课程'), findsWidgets);
    expect(find.text('日报'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey<String>('bookmark-section-$lessonsId')));
    await tester.pumpAndSettle();

    expect(st.isCategoryCollapsed(lessonsId), isFalse);
    expect(find.text('数学'), findsOneWidget);
    expect(find.text('已折叠'), findsNothing);
  });

  /// Real file I/O only completes outside the fake-async zone, so the dialog
  /// pumps are followed by a few interleaved real-time pumps.
  Future<void> settleIo(WidgetTester tester, [int frames = 12]) async {
    for (var i = 0; i < frames; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  testWidgets('the home edit mode is behind the parental password', (tester) async {
    late String bookmarkId;
    await tester.runAsync(() async {
      await state.setParentalPassword('parent-2026');
      final bookmark = await state.addBookmark(url: 'https://a.test/', title: '唯一');
      bookmarkId = bookmark.id;
    });

    await pumpHome(tester);

    // Locked by default: the wall has no per-tile controls at all.
    expect(find.byKey(ValueKey<String>('edit-delete-$bookmarkId')), findsNothing);

    await tester.tap(find.byKey(homeEditModeButtonKey));
    await tester.pumpAndSettle();
    expect(find.text('进入编辑模式'), findsWidgets);

    // A wrong password keeps the mode shut.
    await tester.enterText(find.byType(TextField), 'not-the-password');
    await tester.tap(find.widgetWithText(FilledButton, '进入编辑模式'));
    await tester.pumpAndSettle();
    expect(find.text('密码不正确'), findsOneWidget);
    expect(state.homeEditMode, isFalse);

    // The right one opens it and shows the four actions.
    await tester.enterText(find.byType(TextField), 'parent-2026');
    await tester.tap(find.widgetWithText(FilledButton, '进入编辑模式'));
    await tester.pumpAndSettle();

    expect(state.homeEditMode, isTrue);
    expect(find.byKey(ValueKey<String>('edit-rename-$bookmarkId')), findsOneWidget);
    expect(find.byKey(ValueKey<String>('edit-move-$bookmarkId')), findsOneWidget);
    expect(find.byKey(ValueKey<String>('edit-thumbnail-$bookmarkId')), findsOneWidget);
    expect(find.byKey(ValueKey<String>('edit-delete-$bookmarkId')), findsOneWidget);

    // 完成 leaves the mode.
    await tester.tap(find.byKey(homeEditDoneKey));
    await tester.pumpAndSettle();
    expect(state.homeEditMode, isFalse);
    expect(find.byKey(ValueKey<String>('edit-delete-$bookmarkId')), findsNothing);
  });

  testWidgets('edit mode renames, moves and deletes with the tile buttons', (
    tester,
  ) async {
    late Bookmark bookmark;
    late String newsId;
    await tester.runAsync(() async {
      final news = await state.addCategory('新闻');
      newsId = news.id;
      bookmark = await state.addBookmark(url: 'https://a.test/', title: '旧名字');
      state.setHomeEditMode(true);
    });

    await pumpHome(tester);
    final String id = bookmark.id;

    // 编辑书签名
    await tester.tap(find.byKey(ValueKey<String>('edit-rename-$id')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新名字');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    await settleIo(tester);
    expect(state.bookmarks.single.title, '新名字');

    // 变更分类
    await tester.tap(find.byKey(ValueKey<String>('edit-move-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(bookmarkTargetCategoryKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新闻').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移动'));
    await tester.pumpAndSettle();
    await settleIo(tester);
    expect(state.bookmarksIn(newsId).single.title, '新名字');

    // 删除书签
    await tester.tap(find.byKey(ValueKey<String>('edit-delete-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    await settleIo(tester);
    expect(state.bookmarks, isEmpty);
  });
}
