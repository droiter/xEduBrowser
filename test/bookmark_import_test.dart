import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark.dart';
import 'package:tablet_browser/bookmarks/bookmark_import.dart';
import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/state/app_state.dart';

/// Importing bookmarks from a local directory.
///
/// The rule under test: walk the **first-level subdirectories** of the chosen
/// directory and take the HTML pages inside them, into a chosen category.
void main() {
  late Directory root;
  late Directory appDir;

  void writeHtml(String path, {String? title}) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '<!doctype html><html><head>${title == null ? '' : '<title>$title</title>'}'
      '</head><body>hi</body></html>',
    );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('tb_import_root');
    appDir = Directory.systemTemp.createTempSync('tb_import_app');

    // Two first-level subdirectories, one with a nested folder.
    writeHtml('${root.path}/math/lesson1.html', title: '第一课 加法');
    writeHtml('${root.path}/math/deep/lesson2.html', title: '第二课 减法');
    File('${root.path}/math/notes.txt').writeAsStringSync('not a page');
    writeHtml('${root.path}/science/lesson3.htm');
    // Hidden directory: skipped.
    writeHtml('${root.path}/.hidden/secret.html', title: '不该导入');
    // Directly in the chosen directory: not part of the first-level walk.
    writeHtml('${root.path}/top.html', title: '顶层页面');
  });

  tearDown(() {
    for (final dir in [root, appDir]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  group('scan', () {
    test('collects the HTML of the chosen directory and of its subdirectories',
        () async {
      final plan = await BookmarkImporter.scan(root.path);

      expect(plan.subdirectories, ['math', 'science']);
      expect(plan.fileCount, 4);
      expect(
        plan.candidates.map((c) => c.filePath.split('/').last).toSet(),
        {'top.html', 'lesson1.html', 'lesson2.html', 'lesson3.htm'},
      );
      expect(plan.truncated, isFalse);
      // The chosen directory's own pages come first.
      expect(plan.candidates.first.filePath.endsWith('top.html'), isTrue);
    });

    test('a page of the chosen directory is attributed to the directory itself',
        () async {
      final plan = await BookmarkImporter.scan(root.path);
      final top = plan.candidates.firstWhere((c) => c.filePath.endsWith('top.html'));
      expect(top.subdirectory, isEmpty);
      expect(top.title, '顶层页面');
    });

    test('walks nested folders inside a subdirectory', () async {
      final plan = await BookmarkImporter.scan(root.path);
      final nested = plan.candidates.firstWhere((c) => c.filePath.endsWith('lesson2.html'));
      expect(nested.subdirectory, 'math');
    });

    test('skips hidden directories and non-HTML files', () async {
      final plan = await BookmarkImporter.scan(root.path);
      expect(plan.candidates.any((c) => c.filePath.contains('.hidden')), isFalse);
      expect(plan.candidates.any((c) => c.filePath.endsWith('.txt')), isFalse);
    });

    test('imports the HTML sitting directly in the chosen directory', () async {
      final plan = await BookmarkImporter.scan(root.path);
      expect(plan.rootLevelHtmlCount, 1);
      expect(plan.candidates.any((c) => c.filePath.endsWith('top.html')), isTrue);
    });

    test('reads the <title> and falls back to the file name', () async {
      final plan = await BookmarkImporter.scan(root.path);
      final byName = {
        for (final candidate in plan.candidates)
          candidate.filePath.split('/').last: candidate.title,
      };
      expect(byName['lesson1.html'], '第一课 加法');
      // No <title> tag: the file name, tidied up.
      expect(byName['lesson3.htm'], 'lesson3');
    });

    test('the file cap stops the walk and is reported', () async {
      final plan = await BookmarkImporter.scan(root.path, maxFiles: 2);
      expect(plan.fileCount, 2);
      expect(plan.truncated, isTrue);
    });

    test('a missing directory is not an error', () async {
      final plan = await BookmarkImporter.scan('${root.path}/does-not-exist');
      expect(plan.isEmpty, isTrue);
      expect(plan.subdirectories, isEmpty);
    });

    test('a directory with no subdirectories still yields its own pages', () async {
      final flat = Directory('${root.path}/science');
      expect(flat.existsSync(), isTrue);
      final plan = await BookmarkImporter.scan(flat.path);
      expect(plan.isEmpty, isFalse);
      expect(plan.subdirectories, isEmpty);
      expect(plan.fileCount, 1);
      expect(plan.rootLevelHtmlCount, 1);
      expect(plan.candidates.single.filePath.endsWith('lesson3.htm'), isTrue);
      expect(plan.candidates.single.subdirectory, isEmpty);
    });

    test('URLs default to file:// and switch to loopback inside the served root',
        () async {
      final plain = await BookmarkImporter.scan(root.path);
      expect(plain.candidates.every((c) => c.url.startsWith('file://')), isTrue);

      final served = await BookmarkImporter.scan(
        root.path,
        localServerBase: 'http://127.0.0.1:8787',
        localServerRoot: root.path,
      );
      expect(
        served.candidates.every((c) => c.url.startsWith('http://127.0.0.1:8787/')),
        isTrue,
      );
    });
  });

  group('title extraction', () {
    test('collapses whitespace, drops tags and decodes entities', () {
      final file = File('${root.path}/math/entities.html');
      file.writeAsStringSync(
        '<html><head><title>\n  A &amp; B <b>bold</b>\n  C&#39;s  \n</title></head></html>',
      );
      expect(BookmarkImporter.readHtmlTitle(file.path), "A & B bold C's");
    });

    test('a UTF-8 Chinese title survives', () {
      final file = File('${root.path}/math/zh.html');
      file.writeAsStringSync('<title>数学练习册</title>');
      expect(BookmarkImporter.readHtmlTitle(file.path), '数学练习册');
    });

    test('no title, an empty title, or a missing file gives null', () {
      final bare = File('${root.path}/math/bare.html')..writeAsStringSync('<html></html>');
      expect(BookmarkImporter.readHtmlTitle(bare.path), isNull);

      final empty = File('${root.path}/math/empty.html')
        ..writeAsStringSync('<title>   </title>');
      expect(BookmarkImporter.readHtmlTitle(empty.path), isNull);

      expect(BookmarkImporter.readHtmlTitle('${root.path}/nope.html'), isNull);
    });
  });

  group('title candidates for one local page', () {
    test('offers the file name, the folder name and the <title>', () {
      writeHtml('${root.path}/课件/第一课.html', title: '拼音第一课');

      final titles = LocalPageTitles.forPath('${root.path}/课件/第一课.html');
      expect(titles.fileName, '第一课');
      expect(titles.directoryName, '课件');
      expect(titles.internalTitle, '拼音第一课');
      expect(titles.hasInternalTitle, isTrue);
    });

    test('a page without a title still offers a name and a folder', () {
      writeHtml('${root.path}/课件/无标题.html');

      final titles = LocalPageTitles.forPath('${root.path}/课件/无标题.html');
      expect(titles.fileName, '无标题');
      expect(titles.directoryName, '课件');
      expect(titles.internalTitle, isNull);
      expect(titles.hasInternalTitle, isFalse);
    });

    test('a missing file or an extension-less name is handled', () {
      final missing = LocalPageTitles.forPath('${root.path}/课件/nope.html');
      expect(missing.fileName, 'nope');
      expect(missing.directoryName, '课件');
      expect(missing.internalTitle, isNull);

      // No dot: the whole name is the title candidate.
      expect(LocalPageTitles.forPath('/sdcard/README').fileName, 'README');
    });

    test('works from a file URL and from a loopback URL', () {
      writeHtml('${root.path}/课件/第一课.html', title: '拼音第一课');

      final fromFile = LocalPageTitles.forUrl(
        'file://${root.path}/课件/第一课.html',
      );
      expect(fromFile?.internalTitle, '拼音第一课');
      // Percent-encoded paths are decoded before the file is read.
      final encoded = Uri.file('${root.path}/课件/第一课.html').toString();
      expect(LocalPageTitles.forUrl(encoded)?.internalTitle, '拼音第一课');
      // A remote page has none of these candidates.
      expect(LocalPageTitles.forUrl('https://school.test/lessons'), isNull);
    });
  });

  group('import into a category', () {
    late AppState state;

    setUp(() {
      state = AppState(
        store: ConfigStore(appDir),
        settings: AppSettings(localServerEnabled: false, localServerRoot: appDir.path),
      );
    });

    test('adds every page to the chosen category, in scan order', () async {
      final category = await state.addCategory('课程');
      final outcome = await state.importBookmarksFromDirectory(
        directoryPath: root.path,
        categoryId: category.id,
        whitelistScope: BookmarkWhitelistScope.none,
      );

      expect(outcome.added, 4);
      expect(outcome.skipped, 0);
      expect(outcome.subdirectoryCount, 2);

      final imported = state.bookmarksIn(category.id);
      expect(imported.length, 4);
      expect(imported.map((b) => b.order), [0, 1, 2, 3]);
      // The chosen directory's own page is imported first, then the subdirectories.
      expect(imported.first.title, '顶层页面');
      expect(imported.map((b) => b.title),
          ['顶层页面', '第一课 加法', '第二课 减法', 'lesson3']);
      expect(imported.every((b) => b.url.startsWith('file://')), isTrue);
      // Nothing was granted.
      expect(state.policy.rulesOf(PolicyListKind.whitelist), isEmpty);
    });

    test('imports into 未分类 when asked to', () async {
      final outcome = await state.importBookmarksFromDirectory(
        directoryPath: root.path,
        categoryId: uncategorizedId,
      );
      expect(outcome.added, 4);
      expect(state.bookmarksIn(uncategorizedId).length, 4);
    });

    test('the directory scope adds one rule covering the whole subtree', () async {
      final category = await state.addCategory('课程');
      final outcome = await state.importBookmarksFromDirectory(
        directoryPath: root.path,
        categoryId: category.id,
        whitelistScope: BookmarkWhitelistScope.directory,
      );

      final rules = state.policy.rulesOf(PolicyListKind.whitelist);
      expect(rules.single.pattern, 'file://${root.path}/');
      expect(outcome.whitelistPattern, 'file://${root.path}/');

      // With a whitelist configured, only the imported subtree is reachable.
      expect(state.engine.decide('file://${root.path}/math/lesson1.html').allowed, isTrue);
      expect(state.engine.decide('file://${root.path}/science/deep/x.png').allowed, isTrue);
      expect(state.engine.decide('file:///sdcard/other.html').allowed, isFalse);
      expect(state.engine.decide('https://example.com/').allowed, isFalse);
    });

    test('the per-file scope adds one rule per page', () async {
      final outcome = await state.importBookmarksFromDirectory(
        directoryPath: root.path,
        categoryId: uncategorizedId,
        whitelistScope: BookmarkWhitelistScope.perFile,
      );
      expect(outcome.added, 4);
      expect(state.policy.rulesOf(PolicyListKind.whitelist).length, 4);
    });

    test('re-importing skips pages that are already bookmarked', () async {
      final first = await state.importBookmarksFromDirectory(
        directoryPath: root.path,
        categoryId: uncategorizedId,
        whitelistScope: BookmarkWhitelistScope.none,
      );
      final second = await state.importBookmarksFromDirectory(
        directoryPath: root.path,
        categoryId: uncategorizedId,
        whitelistScope: BookmarkWhitelistScope.none,
      );

      expect(first.added, 4);
      expect(second.added, 0);
      expect(second.skipped, 4);
      expect(state.bookmarks.length, 4);
    });

    test('an empty directory imports nothing and grants nothing', () async {
      final empty = Directory('${root.path}/empty')..createSync();
      final outcome = await state.importBookmarksFromDirectory(
        directoryPath: empty.path,
        categoryId: uncategorizedId,
      );
      expect(outcome.added, 0);
      // No pointless directory rule when there is nothing to allow.
      expect(state.policy.rulesOf(PolicyListKind.whitelist), isEmpty);
    });

    test('the outcome summary reads sensibly', () async {
      final outcome = await state.importBookmarksFromDirectory(
        directoryPath: root.path,
        categoryId: uncategorizedId,
        whitelistScope: BookmarkWhitelistScope.none,
      );
      expect(outcome.summary, '已导入 4 个书签');

      final again = await state.importBookmarksFromDirectory(
        directoryPath: root.path,
        categoryId: uncategorizedId,
        whitelistScope: BookmarkWhitelistScope.none,
      );
      expect(again.summary, contains('已导入 0 个书签'));
      expect(again.summary, contains('跳过 4 个'));
    });

    test('imported bookmarks can be reordered and moved like any other', () async {
      final category = await state.addCategory('课程');
      await state.importBookmarksFromDirectory(
        directoryPath: root.path,
        categoryId: category.id,
        whitelistScope: BookmarkWhitelistScope.none,
      );

      final second = state.bookmarksIn(category.id)[1];
      await state.reorderBookmark(second, 0);
      expect(state.bookmarksIn(category.id).first.id, second.id);
    });

    test('a plan can be applied directly, which is what the preview dialog does',
        () async {
      final plan = await BookmarkImporter.scan(root.path);
      final category = await state.addCategory('课程');
      final outcome = await state.applyImportPlan(
        plan,
        categoryId: category.id,
        whitelistScope: BookmarkWhitelistScope.none,
      );
      expect(outcome.added, plan.fileCount);
      expect(state.bookmarksIn(category.id).length, plan.fileCount);
    });
  });
}
