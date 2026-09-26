import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark.dart';
import 'package:tablet_browser/bookmarks/bookmark_dialog.dart';
import 'package:tablet_browser/bookmarks/bookmark_manager.dart';
import 'package:tablet_browser/bookmarks/bookmark_preview_screen.dart';
import 'package:tablet_browser/bookmarks/category_dialogs.dart';
import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/settings/settings_screen.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// The settings screen is where bookmarks are added and managed now: the home
/// page is only the wall of tiles.
void main() {
  late Directory directory;
  late AppState state;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tb_settings_bm');
    state = AppState(
      store: ConfigStore(directory),
      settings: AppSettings(
        localServerEnabled: false,
        localServerRoot: directory.path,
        // The parental gate has its own tests; these are about the card.
        parentalGateEnabled: false,
      ),
    );

    // No native layer in a widget test; the preview hosts a platform view.
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('tablet_browser/commands'),
      (call) async => null,
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
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('tablet_browser/commands'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('tablet_browser/events'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter/platform_views'), null);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1600);
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
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Real file I/O only completes outside the widget test's fake-async zone, so
  /// real time is interleaved with pumps until [done] holds. A fixed number of
  /// iterations is flaky when the whole suite runs in parallel; waiting for the
  /// condition keeps it fast and deterministic.
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() done, {
    int tries = 250,
  }) async {
    for (var i = 0; i < tries && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  /// Advances a few frames; the preview's progress bar never settles.
  Future<void> settle(WidgetTester tester, [int frames = 8]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the add dialog can open the page to confirm its content',
      (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(addBookmarkButtonKey));
    await tester.pumpAndSettle();
    final promptField = find
        .descendant(of: find.byType(AlertDialog), matching: find.byType(TextField))
        .first;
    await tester.enterText(promptField, 'school.test/lessons');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    // The dialog offers both: add now, or look at the page first.
    expect(find.byKey(bookmarkPreviewButtonKey), findsOneWidget);
    expect(find.text('添加'), findsWidgets);

    await tester.tap(find.byKey(bookmarkPreviewButtonKey));
    await settle(tester);

    expect(find.byType(BookmarkPreviewScreen), findsOneWidget);
    expect(find.byKey(previewAddressKey), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(previewAddressKey)).controller?.text,
        'https://school.test/lessons');
    expect(find.textContaining('预览模式'), findsOneWidget);
  });

  testWidgets('the settings screen offers adding, importing and categories',
      (tester) async {
    await pumpSettings(tester);

    expect(find.byKey(addBookmarkButtonKey), findsOneWidget);
    expect(find.byKey(importBookmarksButtonKey), findsOneWidget);
    expect(find.byKey(manageCategoriesButtonKey), findsOneWidget);
    expect(find.text('还没有书签'), findsNothing);
  });

  testWidgets('adding a bookmark from settings whitelists the URL and its site',
      (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(addBookmarkButtonKey));
    await tester.pumpAndSettle();
    // The card button and the prompt dialog share the label.
    expect(find.text('添加书签'), findsWidgets);

    // Scope to the dialog: the settings screen has text fields of its own.
    final promptField = find
        .descendant(of: find.byType(AlertDialog), matching: find.byType(TextField))
        .first;
    await tester.enterText(promptField, 'school.test/lessons');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    // The form shows both rules it is about to grant.
    expect(find.textContaining('https://school.test/lessons'), findsWidgets);
    expect(find.textContaining('https://school.test'), findsWidgets);

    final titleField = find
        .descendant(of: find.byType(AlertDialog), matching: find.byType(TextField))
        .first;
    await tester.enterText(titleField, '课程平台');
    await tester.tap(find.text('添加'));
    await waitFor(tester, () => state.bookmarks.isNotEmpty);

    expect(state.bookmarks.single.url, 'https://school.test/lessons');
    expect(state.bookmarks.single.title, '课程平台');
    expect(state.bookmarks.single.whitelistPatterns,
        ['https://school.test/lessons', 'https://school.test']);
    final patterns = {
      for (final rule in state.policy.rulesOf(PolicyListKind.whitelist)) rule.pattern,
    };
    expect(patterns, {'https://school.test/lessons', 'https://school.test'});
    expect(state.decideUrl('https://school.test/lessons').allowed, isTrue);
    expect(state.decideUrl('https://other.test/').allowed, isFalse);
  });

  testWidgets('the card lists existing bookmarks and can delete one',
      (tester) async {
    late String bookmarkId;
    await tester.runAsync(() async {
      final bookmark = await state.addBookmark(
        url: 'https://school.test/lessons',
        title: '课程平台',
      );
      bookmarkId = bookmark.id;
    });

    await pumpSettings(tester);
    expect(find.byKey(ValueKey<String>('bookmark-row-$bookmarkId')), findsOneWidget);
    expect(find.text('课程平台'), findsOneWidget);
    expect(find.textContaining('白名单：https://school.test/lessons'), findsOneWidget);

    await tester.tap(find.byTooltip('书签操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除书签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    // The bookmark disappears from the list before its rules are written
    // away, so wait for the rules too.
    await waitFor(
      tester,
      () =>
          state.bookmarks.isEmpty &&
          state.policy.rulesOf(PolicyListKind.whitelist).isEmpty,
    );

    expect(state.bookmarks, isEmpty);
    expect(state.policy.rulesOf(PolicyListKind.whitelist), isEmpty);
  });

  testWidgets('the category manager opens from the card', (tester) async {
    await tester.runAsync(() => state.addCategory('语文'));

    await pumpSettings(tester);
    await tester.tap(find.byKey(manageCategoriesButtonKey));
    await tester.pumpAndSettle();

    expect(find.text('分类管理'), findsWidgets);
    expect(find.text('语文'), findsWidgets);
    expect(find.text('新建分类'), findsOneWidget);
  });

  testWidgets('the category manager can hide a category', (tester) async {
    late String categoryId;
    await tester.runAsync(() async {
      final category = await state.addCategory('旧课程');
      categoryId = category.id;
      await state.addBookmark(
        url: 'https://a.test/',
        title: 'A',
        categoryId: category.id,
      );
    });

    await pumpSettings(tester);
    await tester.tap(find.byKey(manageCategoriesButtonKey));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ValueKey<String>('category-hide-$categoryId')));
    // 状态是同步翻的，但面板要等写入完成后的 setSheetState 才刷新，所以等界面。
    await waitFor(
      tester,
      () => find.textContaining('已隐藏').evaluate().isNotEmpty,
    );

    expect(state.isCategoryHidden(categoryId), isTrue);
    expect(find.textContaining('已隐藏'), findsWidgets);
  });

  testWidgets('the list can move a multi-selection into another category',
      (tester) async {
    late String lessonsId;
    await tester.runAsync(() async {
      final lessons = await state.addCategory('课程');
      lessonsId = lessons.id;
      await state.addBookmark(url: 'https://a.test/', title: 'A');
      await state.addBookmark(url: 'https://b.test/', title: 'B');
      await state.addBookmark(url: 'https://c.test/', title: 'C');
    });

    await pumpSettings(tester);

    // Multi-select is opted into; a plain tap still renames.
    await tester.tap(find.byKey(multiSelectBookmarksKey));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 0 / 3'), findsOneWidget);

    await tester.tap(find.byKey(selectAllBookmarksKey));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 3 / 3'), findsOneWidget);

    await tester.tap(find.byKey(moveSelectedBookmarksKey));
    await tester.pumpAndSettle();
    expect(find.byKey(bookmarkTargetCategoryKey), findsOneWidget);

    await tester.tap(find.byKey(bookmarkTargetCategoryKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移动'));
    // Wait for the batch to land *and* for the mode to close itself: the library
    // is updated before the persist finishes, so the count alone is too early.
    await waitFor(
      tester,
      () => state.bookmarksIn(lessonsId).length == 3 &&
          find.textContaining('已选').evaluate().isEmpty,
    );

    // The whole selection arrived, in list order — the settings list shows the
    // most recently added bookmark first, so C, B, A is that order — and the
    // mode closed itself.
    expect(state.bookmarksIn(lessonsId).map((b) => b.title), ['C', 'B', 'A']);
    expect(state.bookmarksIn(uncategorizedId), isEmpty);
    expect(find.textContaining('已选'), findsNothing);
  });

  testWidgets('the list can delete a multi-selection at once', (tester) async {
    await tester.runAsync(() async {
      await state.addBookmark(url: 'https://a.test/', title: 'A');
      await state.addBookmark(url: 'https://b.test/', title: 'B');
      await state.addBookmark(url: 'https://c.test/', title: 'C');
    });

    await pumpSettings(tester);
    await tester.tap(find.byKey(multiSelectBookmarksKey));
    await tester.pumpAndSettle();

    // Tick only the first two rows, by tapping their tiles.
    await tester.tap(find.text('A'));
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 2 / 3'), findsOneWidget);

    await tester.tap(find.byKey(deleteSelectedBookmarksKey));
    await tester.pumpAndSettle();
    expect(find.textContaining('确定删除选中的 2 个书签'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除 2 个'));
    // As above: the library updates before the removal finishes and the mode
    // closes, so wait for both.
    await waitFor(
      tester,
      () => state.bookmarks.length == 1 &&
          find.textContaining('已选').evaluate().isEmpty,
    );

    expect(state.bookmarks.map((b) => b.title), ['C']);
    expect(find.textContaining('已选'), findsNothing);
  });

  testWidgets('deleting a category from the manager takes its bookmarks too',
      (tester) async {
    await tester.runAsync(() async {
      final category = await state.addCategory('旧课程');
      await state.addBookmark(
        url: 'https://old.test/1',
        title: '旧课',
        categoryId: category.id,
      );
      await state.addBookmark(url: 'https://keep.test/2', title: '保留');
    });

    await pumpSettings(tester);
    await tester.tap(find.byKey(manageCategoriesButtonKey));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('删除分类'));
    await tester.pumpAndSettle();

    // Deleting the bookmarks with the category is the default answer.
    expect(find.text('同时删除该分类下的 1 个书签'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除分类'));
    await waitFor(tester, () => state.categories.isEmpty);

    expect(state.categories, isEmpty);
    expect(state.bookmarks.map((b) => b.title), ['保留']);
  });
}
