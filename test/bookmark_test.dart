import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark.dart';
import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/state/app_state.dart';

/// Bookmarks, and the rules they grant: a bookmarked address joins the
/// whitelist by default **together with the site (or local folder) that holds
/// it**, and deleting the bookmark must not leave the permission behind (nor
/// revoke one another bookmark still relies on).
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
          whitelistPatterns: ['https://school.test/lessons', 'https://school.test'],
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
      expect(loaded.first.whitelistPatterns,
          ['https://school.test/lessons', 'https://school.test']);
      expect(loaded.first.whitelistPattern, 'https://school.test/lessons');
      expect(loaded.last.whitelistPatterns, isEmpty);
    });

    test('reads the single-pattern field written by an older build', () async {
      File('${directory.path}/bookmarks.json').writeAsStringSync(jsonEncode({
        'version': 2,
        'categories': const <Object>[],
        'bookmarks': [
          {
            'id': 'old',
            'url': 'https://school.test/lessons',
            'title': '旧数据',
            'createdAt': DateTime(2026, 2, 3).toIso8601String(),
            'whitelistPattern': 'https://school.test/lessons',
            'order': 0,
          }
        ],
      }));

      final loaded = (await BookmarkStore(directory).load()).bookmarks;
      expect(loaded.single.whitelistPatterns, ['https://school.test/lessons']);
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

    test('every capture gets its own file name', () async {
      final bookmarkStore = BookmarkStore(directory);
      final first = await bookmarkStore.writeThumbnail('b1', Uint8List.fromList([1]));
      final second = await bookmarkStore.writeThumbnail('b1', Uint8List.fromList([2]));

      // The tile renders through `Image.file`, whose cache is keyed by path:
      // rewriting one path would keep showing the previous preview.
      expect(second, isNot(first));
      expect(File(first!).readAsBytesSync(), [1]);
      expect(File(second!).readAsBytesSync(), [2]);
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

    test('whitelist patterns: url prefix first, then the origin', () {
      expect(
        BookmarkWhitelist.urlPattern('https://School.test/Lessons/1'),
        'https://school.test/Lessons/1',
      );
      expect(
        BookmarkWhitelist.sitePattern('https://School.test/Lessons/1'),
        'https://school.test',
      );
      expect(
        BookmarkWhitelist.grantPatterns('https://School.test/Lessons/1'),
        ['https://school.test/Lessons/1', 'https://school.test'],
      );
    });
  });

  group('bookmark grants whitelist access', () {
    test('adding a bookmark whitelists its URL and its site', () async {
      final bookmark = await state.addBookmark(
        url: 'https://school.test/lessons/1',
        title: '课程',
      );

      expect(bookmark.whitelistPattern, 'https://school.test/lessons/1');
      expect(bookmark.whitelistPatterns,
          ['https://school.test/lessons/1', 'https://school.test']);
      expect(state.policy.rulesOf(PolicyListKind.whitelist).length, 2);
      // Whitelist mode is active now, and the bookmarked page is reachable...
      expect(state.decideUrl('https://school.test/lessons/1').allowed, isTrue);
      expect(state.decideUrl('https://school.test/lessons/1/page2').allowed, isTrue);
      // ...along with the rest of the site it belongs to...
      expect(state.decideUrl('https://school.test/other').allowed, isTrue);
      // ...while anything else is refused.
      expect(state.decideUrl('https://other.test/').allowed, isFalse);
    });

    test('unticking the whitelist switch grants nothing', () async {
      final bookmark = await state.addBookmark(
        url: 'https://school.test/lessons/1',
        title: '课程',
        addToWhitelist: false,
      );

      expect(bookmark.whitelistPatterns, isEmpty);
      expect(state.policy.rulesOf(PolicyListKind.whitelist), isEmpty);
      // No whitelist configured, so the default action allows everything.
      expect(state.decideUrl('https://school.test/lessons/1').allowed, isTrue);
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
      expect(bookmark.whitelistPatterns, isEmpty);
    });

    test('re-adding the same URL updates instead of duplicating', () async {
      final first = await state.addBookmark(url: 'https://a.test/x', title: '旧名字');
      final second = await state.addBookmark(url: 'https://a.test/x', title: '新名字');

      expect(state.bookmarks.length, 1);
      expect(second.id, first.id);
      expect(second.title, '新名字');
      expect(second.createdAt, first.createdAt);
      expect(state.policy.rulesOf(PolicyListKind.whitelist).length, 2);
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

    test('a file in a storage root never widens to the whole device', () {
      // Granting "its folder" here would allow all of /sdcard.
      for (final url in [
        'file:///sdcard/page.html',
        'file:///storage/emulated/0/page.html',
        'file:///mnt/sdcard/page.html',
        'file:///storage/1A2B-3C4D/page.html',
      ]) {
        expect(BookmarkWhitelist.sitePattern(url),
            BookmarkWhitelist.urlPattern(url),
            reason: url);
        expect(BookmarkWhitelist.grantPatterns(url),
            [BookmarkWhitelist.urlPattern(url)],
            reason: url);
        expect(BookmarkWhitelist.wholeSiteWidens(url), isFalse, reason: url);
      }
      // One level in, the folder scope is meaningful again.
      expect(BookmarkWhitelist.sitePattern('file:///sdcard/Books/page.html'),
          'file:///sdcard/Books/');
      expect(BookmarkWhitelist.wholeSiteWidens('file:///sdcard/Books/page.html'),
          isTrue);
      expect(BookmarkWhitelist.wholeSiteWidens('https://school.test/a'), isTrue);
    });

    test('a local bookmark grants the file and its folder', () async {
      // The flipbook case: the page pulls CSS, scripts and page images from
      // siblings, so granting only the .html file renders it blank.
      final bookmark = await state.addBookmark(
        url: 'file:///sdcard/Books/Caterpillar/Caterpillar%20ebook.html',
        title: 'Caterpillar ebook',
      );

      expect(bookmark.whitelistPatterns, [
        'file:///sdcard/Books/Caterpillar/Caterpillar%20ebook.html',
        'file:///sdcard/Books/Caterpillar/',
      ]);
      // The page's own assets are reachable...
      expect(
        state.decideUrl('file:///sdcard/Books/Caterpillar/mobile/style/style.css')
            .allowed,
        isTrue,
      );
      expect(
        state.decideUrl('file:///sdcard/Books/Caterpillar/files/page/1.jpg').allowed,
        isTrue,
      );
      // ...and anything outside the folder stays blocked.
      expect(
        state.decideUrl('file:///sdcard/Other/secret.html').allowed,
        isFalse,
      );
    });

    test('non-ASCII local paths are stored percent-encoded', () async {
      final bookmark = await state.addBookmark(
        url: 'file:///sdcard/课件/第 1 课.html',
        title: '第一课',
      );

      // Encoded exactly the way the WebView reports the URL it loaded, which is
      // what the filter compares against.
      expect(bookmark.url, 'file:///sdcard/%E8%AF%BE%E4%BB%B6/%E7%AC%AC%201%20%E8%AF%BE.html');
      expect(bookmark.whitelistPatterns, [
        'file:///sdcard/%E8%AF%BE%E4%BB%B6/%E7%AC%AC%201%20%E8%AF%BE.html',
        'file:///sdcard/%E8%AF%BE%E4%BB%B6/',
      ]);
      expect(state.decideUrl(bookmark.url).allowed, isTrue);
    });
  });

  group('loopback bookmarks are judged as the file they serve', () {
    test('a locally served page grants file rules, not loopback ones', () async {
      // The bug: the bookmark kept `http://127.0.0.1:8787/...` and granted a
      // rule in that spelling, while the local server and the native engine
      // both judge the request as `file://<root>/pages/a.html`. The rule never
      // matched, so the bookmark opened blocked.
      const loopback = 'http://127.0.0.1:8787/pages/a.html';
      final expected = 'file://${directory.path}/pages/a.html';

      final bookmark = await state.addBookmark(url: loopback, title: '本地页');

      expect(bookmark.url, expected);
      expect(bookmark.whitelistPatterns, [expected, 'file://${directory.path}/pages/']);
      // What the two engines actually check is allowed now...
      expect(state.decideUrl(loopback).allowed, isTrue);
      expect(state.engine.decide(expected).allowed, isTrue);
      expect(state.engine.decide('file://${directory.path}/pages/style.css').allowed, isTrue);
      // ...and a page outside the granted folder is still refused.
      expect(state.decideUrl('http://127.0.0.1:8787/other/b.html').allowed, isFalse);
    });

    test('a query string survives canonicalisation', () {
      expect(
        state.policyUrl('http://127.0.0.1:8787/pages/a.html?page=3'),
        'file://${directory.path}/pages/a.html?page=3',
      );
    });

    test('an existing install is repaired on load', () async {
      const loopback = 'http://127.0.0.1:8787/pages/a.html';
      await store.savePolicy(const PolicyConfig(rules: [
        PolicyRule(pattern: loopback, kind: PolicyListKind.whitelist, note: '书签'),
      ]));
      await BookmarkStore(directory).save(BookmarkLibrary(bookmarks: [
        Bookmark(
          id: 'b1',
          url: loopback,
          title: '本地页',
          createdAt: DateTime(2026),
          whitelistPatterns: const [loopback],
        ),
      ]));

      final repaired = AppState(
        store: store,
        settings: AppSettings(localServerEnabled: false, localServerRoot: directory.path),
      );
      await repaired.load();

      final expected = 'file://${directory.path}/pages/a.html';
      expect(repaired.bookmarks.single.url, expected);
      expect(repaired.bookmarks.single.whitelistPatterns, [expected]);
      expect(repaired.policy.rulesOf(PolicyListKind.whitelist).single.pattern, expected);
      expect(repaired.decideUrl(loopback).allowed, isTrue);
    });
  });

  group('removing a bookmark', () {
    test('removes the rules it created', () async {
      final bookmark = await state.addBookmark(
        url: 'https://school.test/lessons/1',
        title: '课程',
      );
      expect(state.policy.rulesOf(PolicyListKind.whitelist), isNotEmpty);

      await state.removeBookmark(bookmark);
      expect(state.bookmarks, isEmpty);
      expect(state.policy.rulesOf(PolicyListKind.whitelist), isEmpty);
      // Back to no whitelist at all, so browsing is unrestricted again.
      expect(state.decideUrl('https://anything.test/').allowed, isTrue);
    });

    test('can keep the rules when the user asks to', () async {
      final bookmark = await state.addBookmark(url: 'https://a.test/x', title: 'A');
      await state.removeBookmark(bookmark, removeWhitelistRule: false);
      expect(state.bookmarks, isEmpty);
      expect(state.policy.rulesOf(PolicyListKind.whitelist).length, 2);
    });

    test('never revokes access another bookmark still relies on', () async {
      final first = await state.addBookmark(url: 'https://school.test/a', title: 'A');
      await state.addBookmark(url: 'https://school.test/b', title: 'B');
      // Both bookmarks grant `https://school.test`, which collapses to one rule.
      expect(state.policy.rulesOf(PolicyListKind.whitelist).length, 3);

      await state.removeBookmark(first);
      expect(state.bookmarks.length, 1);
      // The site rule survives because the second bookmark still needs it; only
      // the first bookmark's own URL rule is gone.
      final patterns = {
        for (final rule in state.policy.rulesOf(PolicyListKind.whitelist)) rule.pattern,
      };
      expect(patterns, {'https://school.test/b', 'https://school.test'});
      expect(state.decideUrl('https://school.test/b').allowed, isTrue);
      expect(state.decideUrl('https://school.test/a').allowed, isTrue);
    });
  });

  group('editing a bookmark', () {
    test('can revoke every whitelist entry it granted', () async {
      final bookmark = await state.addBookmark(url: 'https://a.test/x', title: 'A');
      await state.editBookmark(bookmark, title: '新名字', grantWhitelist: false);

      expect(state.bookmarks.single.title, '新名字');
      expect(state.bookmarks.single.whitelistPatterns, isEmpty);
      expect(state.policy.rulesOf(PolicyListKind.whitelist), isEmpty);
    });

    test('can grant access to a bookmark that had none', () async {
      final bookmark = await state.addBookmark(
        url: 'https://a.test/x',
        title: 'A',
        addToWhitelist: false,
      );
      await state.editBookmark(bookmark, title: 'A', grantWhitelist: true);

      expect(state.bookmarks.single.whitelistPatterns,
          ['https://a.test/x', 'https://a.test']);
      expect(state.policy.rulesOf(PolicyListKind.whitelist).length, 2);
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

    test('bookmarkFor finds a loopback page under its file URL', () async {
      await state.addBookmark(
        url: 'http://127.0.0.1:8787/pages/a.html',
        title: '本地页',
      );
      expect(state.isBookmarked('http://127.0.0.1:8787/pages/a.html'), isTrue);
      expect(
        state.isBookmarked('file://${directory.path}/pages/a.html'),
        isTrue,
      );
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

    test('a fresh capture retires the old preview file', () async {
      final bookmark = await state.addBookmark(
        url: 'https://a.test/x',
        title: 'A',
        thumbnail: Uint8List.fromList([1, 2, 3]),
      );
      final firstPath = bookmark.thumbnailPath!;

      await state.setBookmarkThumbnail(bookmark, Uint8List.fromList([9, 9, 9]));

      final updated = state.bookmarks.single;
      expect(updated.thumbnailPath, isNot(firstPath));
      expect(File(updated.thumbnailPath!).readAsBytesSync(), [9, 9, 9]);
      expect(File(firstPath).existsSync(), isFalse,
          reason: '旧的预览图文件应被删除，避免残留与缓存错乱');
    });
  });
}
