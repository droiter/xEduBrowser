import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark_manager.dart';
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
  });

  tearDown(() {
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
    int tries = 80,
  }) async {
    for (var i = 0; i < tries && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

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
}
