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

  Future<void> pumpHome(
    WidgetTester tester, {
    ValueChanged<String>? onNavigate,
  }) async {
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
            body: StartView(onNavigate: onNavigate ?? (_) {}),
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

    // The right one opens it and shows all six actions.
    await tester.enterText(find.byType(TextField), 'parent-2026');
    await tester.tap(find.widgetWithText(FilledButton, '进入编辑模式'));
    await tester.pumpAndSettle();

    expect(state.homeEditMode, isTrue);
    for (final String action in <String>[
      'favorite',
      'hide',
      'rename',
      'move',
      'thumbnail',
      'delete',
    ]) {
      expect(
        find.byKey(ValueKey<String>('edit-$action-$bookmarkId')),
        findsOneWidget,
        reason: '编辑模式应给出 $action 按钮',
      );
    }

    // 完成 leaves the mode.
    await tester.tap(find.byKey(homeEditDoneKey));
    await tester.pumpAndSettle();
    expect(state.homeEditMode, isFalse);
    expect(find.byKey(ValueKey<String>('edit-delete-$bookmarkId')), findsNothing);
  });

  testWidgets('编辑模式下点书签行本身也能打开网页', (tester) async {
    final opened = <String>[];
    late Bookmark bookmark;
    await tester.runAsync(() async {
      bookmark = await state.addBookmark(
        url: 'https://school.test/lessons',
        title: '课程平台',
      );
      state.setHomeEditMode(true);
    });

    await pumpHome(tester, onNavigate: opened.add);

    // 编辑模式仍然是方块墙（就在原地加了按钮），方块本身还是通往网页的入口：
    // 点书名（缩略图同理）就该打开它。
    expect(
      find.byKey(ValueKey<String>('edit-item-${bookmark.id}')),
      findsOneWidget,
    );
    await tester.tap(find.text('课程平台'));
    await tester.pumpAndSettle();

    expect(opened, <String>['https://school.test/lessons']);
    // 打开网页**不**退出编辑模式：家长点开是为了看页面对不对，回来还要接着改。
    expect(state.homeEditMode, isTrue);
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

  testWidgets('编辑模式原地加按钮：还是那面方块墙，按钮加在方块下方', (tester) async {
    late Bookmark bookmark;
    await tester.runAsync(() async {
      bookmark = await state.addBookmark(
        url: 'https://school.test/lessons',
        title: '课程平台',
      );
      await state.addBookmark(url: 'https://b.test/', title: '隔壁那块');
    });

    await pumpHome(tester);
    final Rect firstBefore = tester.getRect(find.byTooltip('课程平台'));
    final Rect secondBefore = tester.getRect(find.byTooltip('隔壁那块'));
    expect(secondBefore.left, greaterThan(firstBefore.left));
    expect(secondBefore.top, firstBefore.top, reason: '非编辑模式是同一行的两块方块');

    await tester.runAsync(() async => state.setHomeEditMode(true));
    await tester.pumpAndSettle();

    // 还是在首页原地：方块大小、所在列都没变，两块**仍然并排在同一行**——
    // 编辑模式没有把墙换成另一种布局（以前是一行行书签），按钮只是加在方块下方。
    final Rect firstInEdit = tester.getRect(find.byTooltip('课程平台'));
    final Rect secondInEdit = tester.getRect(find.byTooltip('隔壁那块'));
    expect(firstInEdit.size, firstBefore.size);
    expect(firstInEdit.left, firstBefore.left);
    expect(secondInEdit.size, secondBefore.size);
    expect(secondInEdit.left, secondBefore.left);
    expect(secondInEdit.top, firstInEdit.top, reason: '编辑模式仍是同一行的方块墙');

    for (final String action in <String>[
      'favorite',
      'hide',
      'rename',
      'move',
      'thumbnail',
      'delete',
    ]) {
      final Finder button =
          find.byKey(ValueKey<String>('edit-$action-${bookmark.id}'));
      expect(button, findsOneWidget, reason: '缺少 $action 按钮');
      expect(
        tester.getRect(button).top,
        greaterThanOrEqualTo(firstInEdit.bottom - 1),
        reason: '$action 按钮应排在方块下方',
      );
    }

    // 退出编辑模式：按钮消失，方块位置照旧。
    await tester.runAsync(() async => state.setHomeEditMode(false));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('edit-delete-${bookmark.id}')),
      findsNothing,
    );
    expect(tester.getRect(find.byTooltip('课程平台')).size, firstBefore.size);
    expect(
      tester.getRect(find.byTooltip('隔壁那块')).top,
      tester.getRect(find.byTooltip('课程平台')).top,
      reason: '退出后两块仍在同一行',
    );
  });

  testWidgets('墙是懒加载的：一百多个书签也只构建看得见的那几行', (tester) async {
    // The wall used to be one giant Column: every bookmark — and in edit mode
    // every one of its six buttons — was built and laid out on every scroll
    // frame. A 150-bookmark wall took 1666ms to build and stuttered; as slivers
    // only the visible rows exist.
    late List<Bookmark> many;
    await tester.runAsync(() async {
      final lessons = await state.addCategory('课程');
      many = <Bookmark>[
        for (int i = 0; i < 120; i++)
          await state.addBookmark(
            url: 'https://site$i.test/page',
            title: '书签 $i',
            categoryId: lessons.id,
          ),
      ];
    });

    await pumpHome(tester);
    final int tiles = find.byType(BookmarkTile).evaluate().length;
    expect(tiles, greaterThan(0), reason: '看得见的那些当然要建出来');
    expect(tiles, lessThan(60), reason: '120 个书签不该整面墙都建出来');
    expect(find.text('书签 119', skipOffstage: false), findsNothing);

    await tester.runAsync(() async => state.setHomeEditMode(true));
    await tester.pumpAndSettle();
    final int editItems = find
        .byWidgetPredicate(
          (Widget widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('edit-item-'),
        )
        .evaluate()
        .length;
    expect(editItems, greaterThan(0));
    expect(editItems, lessThan(60), reason: '编辑模式同样只建看得见的那几行');
    expect(
      find.byKey(ValueKey<String>('edit-item-${many.last.id}'), skipOffstage: false),
      findsNothing,
      reason: '最后一条远在屏幕外，不该被构建',
    );
  });

  testWidgets('编辑模式下隐藏的书签排到所属分类最后，退出后又消失', (tester) async {
    await tester.runAsync(() async {
      final lessons = await state.addCategory('课程');
      await state.addBookmark(
          url: 'https://a.test/', title: '甲', categoryId: lessons.id);
      final middle = await state.addBookmark(
          url: 'https://b.test/', title: '乙', categoryId: lessons.id);
      await state.addBookmark(
          url: 'https://c.test/', title: '丙', categoryId: lessons.id);
      await state.setHidden(middle, true);
    });

    await pumpHome(tester);
    expect(find.text('乙'), findsNothing, reason: '非编辑状态不显示隐藏的书签');

    await tester.runAsync(() async => state.setHomeEditMode(true));
    await tester.pumpAndSettle();

    // 阅读顺序：同一行比 x，换行比 y。
    Offset pos(String title) => tester.getTopLeft(find.text(title));
    bool before(Offset a, Offset b) =>
        a.dy < b.dy - 1 || ((a.dy - b.dy).abs() <= 1 && a.dx < b.dx);

    expect(find.text('乙'), findsOneWidget, reason: '编辑模式要能看到它才能恢复');
    expect(before(pos('甲'), pos('乙')), isTrue);
    expect(before(pos('丙'), pos('乙')), isTrue, reason: '隐藏的书签排在分类最后');
    expect(find.text('已隐藏'), findsWidgets);

    await tester.runAsync(() async => state.setHomeEditMode(false));
    await tester.pumpAndSettle();
    expect(find.text('乙'), findsNothing);
    expect(before(pos('甲'), pos('丙')), isTrue, reason: '可见的仍按原顺序');
  });

  testWidgets('编辑模式下隐藏的分类整段排到首页最后', (tester) async {
    await tester.runAsync(() async {
      final lessons = await state.addCategory('课程');
      await state.addBookmark(
          url: 'https://course.test/', title: '课件', categoryId: lessons.id);
      await state.addBookmark(url: 'https://news.test/', title: '日报');
      await state.setCategoryHidden(lessons, true);
    });

    await pumpHome(tester);
    expect(find.text('课程'), findsNothing, reason: '非编辑状态整段不显示');

    await tester.runAsync(() async => state.setHomeEditMode(true));
    await tester.pumpAndSettle();

    expect(find.text('课程'), findsOneWidget, reason: '编辑模式要能看到才能恢复');
    expect(
      tester.getRect(find.text('课程')).top,
      greaterThan(tester.getRect(find.text('未分类')).top),
      reason: '隐藏的分类排到首页最后',
    );

    await tester.runAsync(() async => state.setHomeEditMode(false));
    await tester.pumpAndSettle();
    expect(find.text('课程'), findsNothing);
    expect(find.text('课件'), findsNothing);
  });

  testWidgets('starred bookmarks get a pinned 我的最爱 section on top', (tester) async {
    await tester.runAsync(() async {
      final lessons = await state.addCategory('课程');
      final starred = await state.addBookmark(
          url: 'https://fav.test/', title: '收藏页', categoryId: lessons.id);
      await state.addBookmark(
          url: 'https://plain.test/', title: '普通页', categoryId: lessons.id);
      await state.toggleFavorite(starred);
    });

    await pumpHome(tester);

    // 最爱的段在最上面，同一个书签同时也留在原分类里。
    expect(find.text('我的最爱'), findsOneWidget);
    expect(find.text('收藏页'), findsNWidgets(2));
    expect(
      tester.getRect(find.text('我的最爱')).top,
      lessThan(tester.getRect(find.text('课程')).top),
    );
  });

  testWidgets('hiding a category hides its section and every tile in it', (tester) async {
    late String lessonsId;
    await tester.runAsync(() async {
      final lessons = await state.addCategory('课程');
      lessonsId = lessons.id;
      final courseware = await state.addBookmark(
          url: 'https://course.test/', title: '课件', categoryId: lessons.id);
      await state.addBookmark(url: 'https://news.test/', title: '日报');
      // 点星进「我的最爱」：分类一隐藏，它也跟着从首页消失。
      await state.toggleFavorite(courseware);
    });

    await pumpHome(tester);
    expect(find.text('课程'), findsWidgets);
    expect(find.text('课件'), findsNWidgets(2));

    // 编辑模式：分类段带一个眼睛按钮，点它隐藏整个分类。
    await tester.runAsync(() async => state.setHomeEditMode(true));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey<String>('section-hide-$lessonsId')));
    await tester.pumpAndSettle();
    await settleIo(tester);

    expect(state.isCategoryHidden(lessonsId), isTrue);
    expect(find.text('已隐藏'), findsWidgets);
    expect(find.text('课件'), findsOneWidget, reason: '编辑模式下仍看得到，方便恢复');

    // 退出编辑模式：分类段和它下面的书签（含「我的最爱」里的那个）都不显示。
    await tester.runAsync(() async => state.setHomeEditMode(false));
    await tester.pump();
    expect(find.text('课程'), findsNothing);
    expect(find.text('课件'), findsNothing);
    expect(find.text('我的最爱'), findsNothing);
    expect(find.text('日报'), findsOneWidget, reason: '其它分类不受影响');
  });

  testWidgets('a hidden bookmark is only visible while editing', (tester) async {
    late String id;
    await tester.runAsync(() async {
      final bookmark = await state.addBookmark(
          url: 'https://hidden.test/', title: '藏起来');
      id = bookmark.id;
      await state.setHidden(bookmark, true);
    });

    await pumpHome(tester);
    expect(find.text('藏起来'), findsNothing, reason: '非编辑状态不显示');
    expect(find.textContaining('都被隐藏了'), findsOneWidget);

    await tester.runAsync(() async => state.setHomeEditMode(true));
    await tester.pump();
    expect(find.text('藏起来'), findsOneWidget);
    expect(find.byKey(ValueKey<String>('edit-hide-$id')), findsOneWidget);
  });

  testWidgets('the edit-mode star adds and removes 我的最爱', (tester) async {
    late String id;
    await tester.runAsync(() async {
      final bookmark = await state.addBookmark(
          url: 'https://star.test/', title: '点星');
      id = bookmark.id;
      state.setHomeEditMode(true);
    });

    await pumpHome(tester);
    // 编辑模式下不重复显示置顶段，星标就在每一块的按钮里。
    expect(find.text('我的最爱'), findsNothing);

    await tester.tap(find.byKey(ValueKey<String>('edit-favorite-$id')));
    await tester.pumpAndSettle();
    await settleIo(tester);
    expect(state.bookmarks.single.favorite, isTrue);
    expect(find.textContaining('★ 我的最爱'), findsOneWidget);

    // 退出编辑模式：置顶的「我的最爱」段出现，原分类里也还在。
    await tester.runAsync(() async => state.setHomeEditMode(false));
    await tester.pump();
    expect(find.text('我的最爱'), findsOneWidget);
    expect(find.text('点星'), findsNWidgets(2));

    // 再取消星标，段就消失。
    await tester.runAsync(() async => state.setHomeEditMode(true));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey<String>('edit-favorite-$id')));
    await tester.pumpAndSettle();
    await settleIo(tester);
    await tester.runAsync(() async => state.setHomeEditMode(false));
    await tester.pump();
    expect(state.bookmarks.single.favorite, isFalse);
    expect(find.text('我的最爱'), findsNothing);
  });
}
