import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark.dart';
import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/state/app_state.dart';

/// Bookmarks, and the rule they grant: a bookmarked address must join the
/// whitelist by default, and deleting the bookmark must not leave the
/// permission behind (nor revoke one another bookmark still relies on).
void main() {
  late Directory directory;
  late ConfigStore store;
  late AppState state;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tablet_browser_bm');
    store = ConfigStore(directory);
    state = AppState(
      store: store,
      settings: AppSettings(localServerEnabled: false, localServerRoot: directory.path),
    );
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  group('BookmarkStore', () {
    test('round trips bookmarks through disk', () async {
      final bookmarkStore = BookmarkStore(directory);
      final saved = [
        Bookmark(
          id: 'a1',
          url: 'https://school.test/lessons',
          title: '课程',
          thumbnailPath: '/tmp/x.png',
          createdAt: DateTime(2026, 2, 3, 4, 5),
          whitelistPattern: 'https://school.test/lessons',
        ),
        Bookmark(
          id: 'a2',
          url: 'https://news.test/',
          title: '',
          createdAt: DateTime(2026, 2, 4),
        ),
      ];
      await bookmarkStore.save(BookmarkLibrary(bookmarks: saved));

      final loaded = (await BookmarkStore(directory).load()).bookmarks;
      expect(loaded.length, 2);
      expect(loaded.first.url, 'https://school.test/lessons');
      expect(loaded.first.thumbnailPath, '/tmp/x.png');
      expect(loaded.first.createdAt, DateTime(2026, 2, 3, 4, 5));
      expect(loaded.first.whitelistPattern, 'https://school.test/lessons');
      expect(loaded.last.whitelistPattern, isNull);
    });

    test('a corrupt or missing file yields an empty list', () async {
      final bookmarkStore = BookmarkStore(directory);
      expect((await bookmarkStore.load()).bookmarks, isEmpty);
      File('${directory.path}/bookmarks.json').writeAsStringSync('{ not json');
      expect((await bookmarkStore.load()).bookmarks, isEmpty);
    });

    test('writes, replaces and deletes screenshots', () async {
      final bookmarkStore = BookmarkStore(directory);
      final bytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
      final path = await bookmarkStore.writeThumbnail('b1', bytes);
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
      expect(File(path).readAsBytesSync(), bytes);

      expect(await bookmarkStore.writeThumbnail('b1', Uint8List(0)), isNull);

      await bookmarkStore.deleteThumbnail(path);
      expect(File(path).existsSync(), isFalse);
      // Deleting twice, or deleting null, must not throw.
      await bookmarkStore.deleteThumbnail(path);
      await bookmarkStore.deleteThumbnail(null);
    });

    test('prunes screenshots no bookmark references', () async {
      final bookmarkStore = BookmarkStore(directory);
      final kept = await bookmarkStore.writeThumbnail('kept', Uint8List.fromList([1]));
      final orphan = await bookmarkStore.writeThumbnail('orphan', Uint8List.fromList([2]));

      final removed = await bookmarkStore.pruneOrphanThumbnails([
        Bookmark(
          id: 'kept',
          url: 'https://a.test/',
          title: 'A',
          thumbnailPath: kept,
          createdAt: DateTime(2026),
        ),
      ]);

      expect(removed, 1);
      expect(File(kept!).existsSync(), isTrue);
      expect(File(orphan!).existsSync(), isFalse);
    });
  });

  group('Bookmark model', () {
    test('displayTitle falls back to the host, then the raw url', () {
      final named = Bookmark(
        id: '1',
        url: 'https://school.test/a',
        title: '  我的学校  ',
        createdAt: DateTime(2026),
      );
      expect(named.displayTitle, '我的学校');
      expect(named.host, 'school.test');

      final unnamed = Bookmark(
        id: '2',
        url: 'https://school.test/a',
        title: '',
        createdAt: DateTime(2026),
      );
      expect(unnamed.displayTitle, 'school.test');
    });

    test('monogram prefers the registrable label', () {
      Bookmark of(String url) =>
          Bookmark(id: 'x', url: url, title: '', createdAt: DateTime(2026));
      expect(of('https://www.school.test/a').monogram, 'SC');
      expect(of('https://school.test/a').monogram, 'SC');
      expect(of('https://example.com/a').monogram, 'EX');
      expect(of('https://127.0.0.1:8787/a').monogram, isNotEmpty);
    });

    test('whitelist patterns: url prefix by default, origin for whole site', () {
      expect(
        BookmarkWhitelist.urlPattern('https://School.test/Lessons/1'),
        'https://school.test/Lessons/1',
      );
      expect(
        BookmarkWhitelist.sitePattern('https://School.test/Lessons/1'),
        'https://school.test',
      );
    });
  });

  group('bookmark grants whitelist access', () {
    test('adding a bookmark whitelists its URL by default', () async {
      final bookmark = await state.addBookmark(
        url: 'https://school.test/lessons/1',
        title: '课程',
      );

      expect(bookmark.whitelistPattern, 'https://school.test/lessons/1');
      expect(state.policy.rulesOf(PolicyListKind.whitelist).length, 1);
      // Whitelist mode is active now, and the bookmarked page is reachable...
      expect(state.engine.decide('https://school.test/lessons/1').allowed, isTrue);
      expect(state.engine.decide('https://school.test/lessons/1/page2').allowed, isTrue);
      // ...while anything else is refused.
      expect(state.engine.decide('https://other.test/').allowed, isFalse);
    });

    test('unticking the whitelist switch grants nothing', () async {
      final bookmark = await state.addBookmark(
        url: 'https://school.test/lessons/1',
        title: '课程',
        addToWhitelist: false,
      );

      expect(bookmark.whitelistPattern, isNull);
      expect(state.policy.rulesOf(PolicyListKind.whitelist), isEmpty);
      // No whitelist configured, so the default action allows everything.
      expect(state.engine.decide('https://school.test/lessons/1').allowed, isTrue);
    });

    test('whole-site grants the origin', () async {
      final bookmark = await state.addBookmark(
        url: 'https://school.test/lessons/1',
        title: '课程',
        wholeSite: true,
      );

      expect(bookmark.whitelistPattern, 'https://school.test');
      expect(state.engine.decide('https://school.test/other').allowed, isTrue);
      expect(state.engine.decide('https://elsewhere.test/').allowed, isFalse);
    });

    test('the default switch comes from settings', () async {
      state = AppState(
        store: store,
        settings: const AppSettings(
          localServerEnabled: false,
          bookmarkWhitelistByDefault: false,
        ),
      );
      final bookmark = await state.addBookmark(url: 'https://a.test/x', title: 'A');
      expect(bookmark.whitelistPattern, isNull);
    });

    test('re-adding the same URL updates instead of duplicating', () async {
      final first = await state.addBookmark(url: 'https://a.test/x', title: '旧名字');
      final second = await state.addBookmark(url: 'https://a.test/x', title: '新名字');

      expect(state.bookmarks.length, 1);
      expect(second.id, first.id);
      expect(second.title, '新名字');
      expect(second.createdAt, first.createdAt);
      expect(state.policy.rulesOf(PolicyListKind.whitelist).length, 1);
    });
  });

  group('local pages need their whole folder', () {
    test('sitePattern maps a local file to the folder it lives in', () {
      expect(
        BookmarkWhitelist.sitePattern(
            'file:///sdcard/Books/Caterpillar/Caterpillar%20ebook.html'),
        'file:///sdcard/Books/Caterpillar/',
      );
      expect(BookmarkWhitelist.sitePattern('https://school.test/a/b'),
          'https://school.test');
    });

    test('a local bookmark can grant the folder so its assets load', () async {
      // This is the flipbook case: the page pulls CSS, scripts and page images
      // from siblings. Granting only the .html file renders it blank.
      final bookmark = await state.addBookmark(
        url: 'file:///sdcard/Books/Caterpillar/Caterpillar%20ebook.html',
        title: 'Caterpillar ebook',
        wholeSite: true,
      );

      expect(bookmark.whitelistPattern, 'file:///sdcard/Books/Caterpillar/');
      // The page's own assets are reachable...
      expect(
        state.engine
            .decide('file:///sdcard/Books/Caterpillar/mobile/style/style.css')
            .allowed,
        isTrue,
      );
      expect(
        state.engine
            .decide('file:///sdcard/Books/Caterpillar/files/page/1.jpg')
            .allowed,
        isTrue,
      );
      // ...and anything outside the folder stays blocked.
      expect(
        state.engine.decide('file:///sdcard/Other/secret.html').allowed,
        isFalse,
      );
    });

    test('granting only the file leaves its assets blocked', () async {
      // The old behaviour, kept as a regression guard so the blank-page cause
      // stays documented.
      final bookmark = await state.addBookmark(
        url: 'file:///sdcard/Books/Caterpillar/Caterpillar%20ebook.html',
        title: 'Caterpillar ebook',
      );
      expect(bookmark.whitelistPattern,
          'file:///sdcard/Books/Caterpillar/Caterpillar%20ebook.html');
      expect(
        state.engine
            .decide('file:///sdcard/Books/Caterpillar/mobile/javascript/main.js')
            .allowed,
        isFalse,
      );
    });
  });

  group('removing a bookmark', () {
    test('removes the rule it created', () async {
      final bookmark = await state.addBookmark(
        url: 'https://school.test/lessons/1',
        title: '课程',
      );
      expect(state.policy.rulesOf(PolicyListKind.whitelist), isNotEmpty);

      await state.removeBookmark(bookmark);
      expect(state.bookmarks, isEmpty);
      expect(state.policy.rulesOf(PolicyListKind.whitelist), isEmpty);
      // Back to no whitelist at all, so browsing is unrestricted again.
      expect(state.engine.decide('https://anything.test/').allowed, isTrue);
    });

    test('can keep the rule when the user asks to', () async {
      final bookmark = await state.addBookmark(url: 'https://a.test/x', title: 'A');
      await state.removeBookmark(bookmark, removeWhitelistRule: false);
      expect(state.bookmarks, isEmpty);
      expect(state.policy.rulesOf(PolicyListKind.whitelist).length, 1);
    });

    test('never revokes access another bookmark still relies on', () async {
      final first = await state.addBookmark(
        url: 'https://school.test/a',
        title: 'A',
        wholeSite: true,
      );
      await state.addBookmark(
        url: 'https://school.test/b',
        title: 'B',
        wholeSite: true,
      );
      expect(state.policy.rulesOf(PolicyListKind.whitelist).length, 1);

      await state.removeBookmark(first);
      expect(state.bookmarks.length, 1);
      expect(state.policy.rulesOf(PolicyListKind.whitelist).length, 1);
      expect(state.engine.decide('https://school.test/b').allowed, isTrue);
    });
  });

  group('editing a bookmark', () {
    test('can revoke the whitelist entry', () async {
      final bookmark = await state.addBookmark(url: 'https://a.test/x', title: 'A');
      await state.editBookmark(bookmark, title: '新名字', grantWhitelist: false);

      expect(state.bookmarks.single.title, '新名字');
      expect(state.bookmarks.single.whitelistPattern, isNull);
      expect(state.policy.rulesOf(PolicyListKind.whitelist), isEmpty);
    });

    test('can grant access to a bookmark that had none', () async {
      final bookmark = await state.addBookmark(
        url: 'https://a.test/x',
        title: 'A',
        addToWhitelist: false,
      );
      await state.editBookmark(bookmark, title: 'A', grantWhitelist: true);

      expect(state.bookmarks.single.whitelistPattern, 'https://a.test/x');
      expect(state.policy.rulesOf(PolicyListKind.whitelist).length, 1);
    });

    test('switching to whole-site replaces the narrow rule', () async {
      final bookmark = await state.addBookmark(url: 'https://a.test/x', title: 'A');
      await state.editBookmark(
        bookmark,
        title: 'A',
        grantWhitelist: true,
        wholeSite: true,
      );

      final rules = state.policy.rulesOf(PolicyListKind.whitelist);
      expect(rules.length, 1);
      expect(rules.single.pattern, 'https://a.test');
      expect(state.bookmarks.single.whitelistPattern, 'https://a.test');
    });
  });

  group('lookups and thumbnails', () {
    test('bookmarkFor and isBookmarked match the normalised URL', () async {
      await state.addBookmark(url: 'HTTPS://Example.COM:443/Path', title: 'P');
      expect(state.isBookmarked('https://example.com/Path'), isTrue);
      // Lookup is over the normalised URL, so a different path is not a hit.
      expect(state.isBookmarked('https://example.com/Path/'), isFalse);
      expect(state.isBookmarked('https://example.com/other'), isFalse);
      // Case and the default port are normalised away, so these do match.
      expect(state.bookmarkFor('https://EXAMPLE.com:443/Path')?.title, 'P');
    });

    test('a screenshot is stored and referenced by the bookmark', () async {
      final bytes = Uint8List.fromList(utf8.encode('not-a-real-png'));
      final bookmark = await state.addBookmark(
        url: 'https://a.test/x',
        title: 'A',
        thumbnail: bytes,
      );

      expect(bookmark.thumbnailPath, isNotNull);
      expect(File(bookmark.thumbnailPath!).existsSync(), isTrue);
      expect(File(bookmark.thumbnailPath!).readAsBytesSync(), bytes);
      // The path survives a reload from disk.
      final reloaded = (await BookmarkStore(directory).load()).bookmarks;
      expect(reloaded.single.thumbnailPath, bookmark.thumbnailPath);
    });

    test('deleting a bookmark deletes its screenshot', () async {
      final bookmark = await state.addBookmark(
        url: 'https://a.test/x',
        title: 'A',
        thumbnail: Uint8List.fromList([1, 2, 3]),
      );
      final path = bookmark.thumbnailPath!;
      await state.removeBookmark(bookmark);
      expect(File(path).existsSync(), isFalse);
    });

    test('setBookmarkThumbnail replaces the file', () async {
      final bookmark = await state.addBookmark(url: 'https://a.test/x', title: 'A');
      expect(bookmark.thumbnailPath, isNull);

      await state.setBookmarkThumbnail(bookmark, Uint8List.fromList([9, 9]));
      final updated = state.bookmarks.single;
      expect(updated.thumbnailPath, isNotNull);
      expect(File(updated.thumbnailPath!).readAsBytesSync(), [9, 9]);
    });
  });
}
