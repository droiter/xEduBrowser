import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark.dart';
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

}
