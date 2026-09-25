import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark.dart';
import 'package:tablet_browser/bookmarks/bookmark_import.dart';
import 'package:tablet_browser/bookmarks/category_dialogs.dart';
import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// End-to-end check of the import flow a user actually performs: pick a
/// directory, read the preview, confirm, and get bookmarks in a category.
void main() {
  late Directory root;
  late Directory appDir;
  late AppState state;

  void writeHtml(String path, String title) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('<html><head><title>$title</title></head><body></body></html>');
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('tb_import_ui_root');
    appDir = Directory.systemTemp.createTempSync('tb_import_ui_app');
    writeHtml('${root.path}/语文/第一课.html', '第一课 拼音');
    writeHtml('${root.path}/语文/第二课.html', '第二课 汉字');
    writeHtml('${root.path}/数学/第一课.html', '数学第一课');
    File('${root.path}/语文/readme.txt').writeAsStringSync('not a page');

    state = AppState(
      store: ConfigStore(appDir),
      settings: AppSettings(localServerEnabled: false, localServerRoot: appDir.path),
    );
  });

  tearDown(() {
    for (final dir in [root, appDir]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  Future<void> pumpHost(WidgetTester tester, {String? directory}) async {
    final target = directory ?? root.path;
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
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showBookmarkImportDialog(
                    context,
                    directoryPath: target,
                  ),
                  child: const Text('打开导入'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The dialog scans real directories from `initState`, and real file I/O only
  /// completes outside the widget test's fake-async zone. Real time is therefore
  /// interleaved with pumps, which also avoids `pumpAndSettle` never settling on
  /// the scanning spinner.
  Future<void> letScanFinish(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('the dialog previews what it found before importing', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('打开导入'));
    await tester.pump();
    await letScanFinish(tester);

    // The preview names the pages and says how many were found.
    expect(find.textContaining('第一课 拼音'), findsWidgets);
    expect(find.textContaining('第二课 汉字'), findsWidgets);
    expect(find.textContaining('找到 3 个'), findsOneWidget);
    expect(find.textContaining('一级子目录 2 个'), findsOneWidget);
    // Nothing is written until the user confirms.
    expect(state.bookmarks, isEmpty);
  });

  testWidgets('confirming imports into the chosen category with one rule',
      (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('打开导入'));
    await tester.pump();
    await letScanFinish(tester);

    await tester.tap(find.text('开始导入'));
    await letScanFinish(tester);

    expect(state.bookmarks.length, 3);
    final imported = state.bookmarksIn(uncategorizedId);
    expect(imported.map((b) => b.title).toSet(),
        {'第一课 拼音', '第二课 汉字', '数学第一课'});
    // Default scope is the whole imported directory: one rule, covering the
    // pages and the assets they load.
    final rules = state.policy.rulesOf(PolicyListKind.whitelist);
    expect(rules.single.pattern, 'file://${root.path}/');
    expect(
      state.engine.decide('file://${root.path}/语文/第一课.html').allowed,
      isTrue,
    );
  });

  testWidgets('cancelling changes nothing', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('打开导入'));
    await tester.pump();
    await letScanFinish(tester);

    await tester.tap(find.text('取消'));
    await tester.pump();

    expect(state.bookmarks, isEmpty);
    expect(state.policy.rulesOf(PolicyListKind.whitelist), isEmpty);
  });

  testWidgets('the dialog offers the same 标题来源 as the add-bookmark form',
      (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('打开导入'));
    await tester.pump();
    await letScanFinish(tester);

    // The four sources of the add-bookmark dialog, and the preview starts on
    // the page's own <title>.
    expect(find.byKey(importTitleSourceKey), findsOneWidget);
    expect(find.textContaining('第一课 拼音'), findsWidgets);

    await tester.tap(find.byKey(importTitleSourceKey));
    await tester.pumpAndSettle();
    expect(find.text('HTML 文件名'), findsWidgets);
    expect(find.text('所在目录名'), findsWidgets);
    expect(find.text('网页内部标题'), findsWidgets);
    expect(find.text('留空'), findsWidgets);

    // Picking the folder name renames the preview without a rescan...
    await tester.tap(find.text('所在目录名').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('第一课 拼音'), findsNothing);
    // ...and it exposes the clash it creates: two pages now want the name 语文.
    // The clash is flagged *before* importing, not only reported afterwards.
    expect(find.text('重名'), findsOneWidget);
    expect(find.textContaining('其中 1 个与已有书签重名'), findsOneWidget);

    // ...and that is the name the import writes — the clashing page is left out.
    await tester.tap(find.text('开始导入'));
    await letScanFinish(tester);

    expect(state.bookmarks.length, 2);
    expect(
      state.bookmarksIn(uncategorizedId).map((b) => b.title).toSet(),
      {'语文', '数学'},
    );
  });

  testWidgets('the 重名 report lists the pages that were left out',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showImportNameConflictDialog(
                    context,
                    outcome: const BookmarkImportOutcome(
                      added: 2,
                      skipped: 0,
                      subdirectoryCount: 2,
                      rootPath: '/sdcard/course',
                      whitelistPattern: 'file:///sdcard/course/',
                      truncated: false,
                      targetCategoryId: uncategorizedId,
                      nameConflicts: [
                        ImportNameConflict(
                          filePath: '/sdcard/course/语文/第二课.html',
                          title: '语文',
                        ),
                      ],
                    ),
                  ),
                  child: const Text('打开报告'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开报告'));
    await tester.pumpAndSettle();

    expect(find.byKey(importNameConflictDialogKey), findsOneWidget);
    expect(find.text('1 个书签重名，未导入'), findsOneWidget);
    // Which bookmark was left out: the name, and the file it came from.
    expect(find.text('语文'), findsWidgets);
    expect(find.text('第二课.html'), findsOneWidget);
    // The summary and the rule that was granted are on the same screen.
    expect(find.text('已导入 2 个书签，跳过 1 个（重名）'), findsOneWidget);
    expect(find.text('白名单：file:///sdcard/course/'), findsOneWidget);
  });

  testWidgets('a directory with nothing to import says so', (tester) async {
    final flat = Directory('${root.path}/空目录')..createSync();

    await pumpHost(tester, directory: flat.path);
    await tester.tap(find.text('打开导入'));
    await tester.pump();
    await letScanFinish(tester);

    expect(find.textContaining('没有找到'), findsWidgets);
    expect(find.text('开始导入'), findsOneWidget);
    expect(state.bookmarks, isEmpty);
    expect(state.policy.rulesOf(PolicyListKind.whitelist), isEmpty);
  });
}
