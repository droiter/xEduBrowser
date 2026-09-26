import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark.dart';
import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/state/app_state.dart';

/// Categories, ordering inside a category, and the version 1 -> 2 upgrade of
/// `bookmarks.json`.
void main() {
  late Directory directory;
  late AppState state;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tablet_browser_cat');
    state = AppState(
      store: ConfigStore(directory),
      settings: AppSettings(localServerEnabled: false, localServerRoot: directory.path),
    );
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<Bookmark> add(String url, {String category = uncategorizedId, String title = ''}) =>
      state.addBookmark(url: url, title: title, categoryId: category);

  group('categories', () {
    test('creating, renaming and listing', () async {
      expect(state.categories, isEmpty);

      final lessons = await state.addCategory('课程');
      final news = await state.addCategory('新闻');
      expect(state.categories.map((c) => c.name), ['课程', '新闻']);
      expect(state.categoryLabel(lessons.id), '课程');
      expect(state.categoryLabel(uncategorizedId), uncategorizedLabel);
      expect(state.categoryById(news.id)?.name, '新闻');

      await state.renameCategory(lessons, '语文课程');
      expect(state.categoryLabel(lessons.id), '语文课程');
      // A blank rename is refused rather than clearing the name.
      await state.renameCategory(lessons, '   ');
      expect(state.categoryLabel(lessons.id), '语文课程');
    });

    test('an unnamed category still gets a usable default name', () async {
      final category = await state.addCategory('   ');
      expect(category.name, '新分类');
    });

    test('deleting a category keeps its bookmarks, moving them to 未分类', () async {
      final category = await state.addCategory('课程');
      await add('https://a.test/1', category: category.id, title: 'A');
      await add('https://b.test/2', category: category.id, title: 'B');
      await add('https://c.test/3', title: 'C');

      await state.removeCategory(category);

      expect(state.categories, isEmpty);
      expect(state.bookmarks.length, 3, reason: 'no bookmark may be lost');
      final uncategorized = state.bookmarksIn(uncategorizedId);
      expect(uncategorized.length, 3);
      // The moved bookmarks keep their relative order and are appended after
      // the ones that were already uncategorized.
      expect(uncategorized.map((b) => b.title), ['C', 'A', 'B']);
      expect(uncategorized.map((b) => b.order), [0, 1, 2]);
    });
    test('hiding a category hides its bookmarks, and survives a reload', () async {
      final category = await state.addCategory('课程');
      final other = await state.addCategory('新闻');
      final bookmark = await add('https://a.test/1', category: category.id, title: 'A');
      await state.toggleFavorite(bookmark);
      await add('https://b.test/2', category: other.id, title: 'B');

      await state.setCategoryHidden(category, true);

      expect(state.isCategoryHidden(category.id), isTrue);
      expect(state.isCategoryHidden(other.id), isFalse);
      // 分类隐藏会连带它的书签，包括被点星进了「我的最爱」的那个。
      expect(state.isHiddenOnHome(bookmark), isTrue);
      expect(state.favoriteBookmarks, isEmpty);

      final reloaded = AppState(
        store: ConfigStore(directory),
        settings: const AppSettings(localServerEnabled: false),
      );
      await reloaded.load();
      expect(reloaded.isCategoryHidden(category.id), isTrue);
      expect(
        reloaded.isHiddenOnHome(
          reloaded.bookmarks.firstWhere((b) => b.title == 'A'),
        ),
        isTrue,
      );
    });

    test('deleting a category can take its bookmarks with it', () async {
      final category = await state.addCategory('课程');
      final news = await state.addCategory('新闻');
      await add('https://a.test/1', category: category.id, title: 'A');
      await add('https://b.test/2', category: category.id, title: 'B');
      await add('https://c.test/3', category: news.id, title: 'C');

      await state.removeCategory(category, deleteBookmarks: true);

      expect(state.categories.map((c) => c.name), ['新闻']);
      expect(state.bookmarks.map((b) => b.title), ['C'],
          reason: '只有该分类下的书签被删除');
      expect(state.bookmarksIn(news.id).map((b) => b.title), ['C']);
    });

    test('deleting a category also drops the whitelist rules its bookmarks owned',
        () async {
      final category = await state.addCategory('课程');
      await state.addBookmark(
        url: 'https://gone.test/lesson',
        title: '旧课',
        categoryId: category.id,
        addToWhitelist: true,
      );
      // A second bookmark, in another category, grants the same site rule: that
      // one has to survive the category delete.
      await state.addBookmark(
        url: 'https://gone.test/other',
        title: '同站',
        addToWhitelist: true,
      );

      await state.removeCategory(category, deleteBookmarks: true);

      final patterns = {
        for (final rule in state.policy.rulesOf(PolicyListKind.whitelist))
          rule.pattern,
      };
      expect(patterns, {'https://gone.test', 'https://gone.test/other'});
      // The deleted bookmark's own rule is gone; the site rule stays because the
      // other bookmark still needs it — and it happens to cover /lesson too,
      // which is exactly why the rule must not be dropped wholesale.
      expect(state.decideUrl('https://gone.test/other').allowed, isTrue);
    });
  });

  group('ordering', () {
    test('bookmarks are appended to the end of their category', () async {
      final category = await state.addCategory('课程');
      await add('https://a.test/', category: category.id, title: 'A');
      await add('https://b.test/', category: category.id, title: 'B');
      await add('https://c.test/', category: category.id, title: 'C');

      expect(state.bookmarksIn(category.id).map((b) => b.title), ['A', 'B', 'C']);
      expect(state.bookmarksIn(category.id).map((b) => b.order), [0, 1, 2]);
    });

    test('reordering renumbers the whole category without gaps', () async {
      final category = await state.addCategory('课程');
      final a = await add('https://a.test/', category: category.id, title: 'A');
      await add('https://b.test/', category: category.id, title: 'B');
      await add('https://c.test/', category: category.id, title: 'C');

      // Move A to the last slot.
      await state.reorderBookmark(a, 2);

      final ordered = state.bookmarksIn(category.id);
      expect(ordered.map((b) => b.title), ['B', 'C', 'A']);
      expect(ordered.map((b) => b.order), [0, 1, 2]);
    });

    test('reordering to the front', () async {
      final category = await state.addCategory('课程');
      await add('https://a.test/', category: category.id, title: 'A');
      await add('https://b.test/', category: category.id, title: 'B');
      final c = await add('https://c.test/', category: category.id, title: 'C');

      await state.reorderBookmark(c, 0);
      expect(state.bookmarksIn(category.id).map((b) => b.title), ['C', 'A', 'B']);
    });

    test('an out-of-range index is clamped instead of throwing', () async {
      final category = await state.addCategory('课程');
      final a = await add('https://a.test/', category: category.id, title: 'A');
      await add('https://b.test/', category: category.id, title: 'B');

      await state.reorderBookmark(a, 99);
      expect(state.bookmarksIn(category.id).map((b) => b.title), ['B', 'A']);
      await state.reorderBookmark(a, -5);
      expect(state.bookmarksIn(category.id).map((b) => b.title), ['A', 'B']);
    });

    test('moving between categories renumbers both sides', () async {
      final lessons = await state.addCategory('课程');
      final news = await state.addCategory('新闻');
      await add('https://a.test/', category: lessons.id, title: 'A');
      await add('https://b.test/', category: lessons.id, title: 'B');
      await add('https://c.test/', category: news.id, title: 'C');

      final moved = state.bookmarksIn(lessons.id).first;
      await state.moveBookmark(moved, categoryId: news.id, index: 0);

      expect(state.bookmarksIn(lessons.id).map((b) => b.title), ['B']);
      expect(state.bookmarksIn(lessons.id).map((b) => b.order), [0]);
      expect(state.bookmarksIn(news.id).map((b) => b.title), ['A', 'C']);
      expect(state.bookmarksIn(news.id).map((b) => b.order), [0, 1]);
    });

    test('moving without an index appends to the target category', () async {
      final news = await state.addCategory('新闻');
      final a = await add('https://a.test/', title: 'A');
      await state.moveBookmark(a, categoryId: news.id);
      expect(state.bookmarksIn(news.id).single.title, 'A');
      expect(state.bookmarksIn(uncategorizedId), isEmpty);
    });

    test('a whole selection moves at once, in the order it was listed', () async {
      final lessons = await state.addCategory('课程');
      final news = await state.addCategory('新闻');
      await add('https://a.test/', category: lessons.id, title: 'A');
      await add('https://b.test/', category: lessons.id, title: 'B');
      await add('https://c.test/', category: lessons.id, title: 'C');
      await add('https://n.test/', category: news.id, title: 'N');

      // Deliberately not the display order: the caller's order is what wins.
      final chosen = [
        state.bookmarksIn(lessons.id)[2],
        state.bookmarksIn(lessons.id)[0],
      ];
      await state.moveBookmarksToCategory(chosen, categoryId: news.id);

      expect(state.bookmarksIn(lessons.id).map((b) => b.title), ['B']);
      expect(state.bookmarksIn(lessons.id).map((b) => b.order), [0]);
      expect(state.bookmarksIn(news.id).map((b) => b.title), ['N', 'C', 'A']);
      expect(state.bookmarksIn(news.id).map((b) => b.order), [0, 1, 2]);
    });

    test('a selection can move back into 未分类', () async {
      final lessons = await state.addCategory('课程');
      await add('https://a.test/', category: lessons.id, title: 'A');
      await add('https://b.test/', category: lessons.id, title: 'B');

      await state.moveBookmarksToCategory(
        state.bookmarksIn(lessons.id),
        categoryId: uncategorizedId,
      );

      expect(state.bookmarksIn(lessons.id), isEmpty);
      expect(state.bookmarksIn(uncategorizedId).map((b) => b.title), ['A', 'B']);
    });

    test('moving a selection skips bookmarks that no longer exist', () async {
      final news = await state.addCategory('新闻');
      final a = await add('https://a.test/', title: 'A');
      final b = await add('https://b.test/', title: 'B');
      await state.removeBookmark(b);

      await state.moveBookmarksToCategory([a, b], categoryId: news.id);
      expect(state.bookmarksIn(news.id).map((x) => x.title), ['A']);
    });

    test('order survives a reload from disk', () async {
      final category = await state.addCategory('课程');
      await add('https://a.test/', category: category.id, title: 'A');
      final b = await add('https://b.test/', category: category.id, title: 'B');
      await state.reorderBookmark(b, 0);

      final reloaded = AppState(
        store: ConfigStore(directory),
        settings: const AppSettings(localServerEnabled: false),
      );
      await reloaded.load();

      expect(reloaded.categories.single.name, '课程');
      expect(reloaded.bookmarksIn(category.id).map((b) => b.title), ['B', 'A']);
    });

    test('populatedCategoryIds skips empty categories', () async {
      final empty = await state.addCategory('空分类');
      final used = await state.addCategory('有书签');
      await add('https://a.test/', category: used.id, title: 'A');
      await add('https://b.test/', title: '未分类');

      expect(state.populatedCategoryIds, [used.id, uncategorizedId]);
      expect(state.populatedCategoryIds, isNot(contains(empty.id)));
    });
  });

  group('storage migration', () {
    test('a version 2 file keeps its stored order when read by v3', () async {
      // 落盘顺序是最新在最前，而 order 是"追加顺序"，两者并不一致：
      // 升级到 v3 时绝不能用文件顺序重排。
      File('${directory.path}/bookmarks.json').writeAsStringSync(jsonEncode({
        'version': 2,
        'categories': [
          {'id': 'c1', 'name': '课程'},
        ],
        'bookmarks': [
          {'id': 'b2', 'url': 'https://b.test/', 'title': 'B', 'createdAt': '2026-01-02T00:00:00.000', 'categoryId': 'c1', 'order': 1},
          {'id': 'b1', 'url': 'https://a.test/', 'title': 'A', 'createdAt': '2026-01-01T00:00:00.000', 'categoryId': 'c1', 'order': 0},
        ],
      }));

      final reloaded = AppState(
        store: ConfigStore(directory),
        settings: const AppSettings(localServerEnabled: false),
      );
      await reloaded.load();

      expect(reloaded.bookmarksIn('c1').map((b) => b.title), ['A', 'B']);
      // v2 文件没有这两个字段：默认 false。
      expect(reloaded.bookmarks.every((b) => !b.favorite && !b.hidden), isTrue);
    });

    test('a version 1 file upgrades to 未分类 with the order preserved', () async {
      // Written by hand: the old schema had no categories, categoryId or order.
      File('${directory.path}/bookmarks.json').writeAsStringSync(jsonEncode({
        'version': 1,
        'bookmarks': [
          {'id': 'b1', 'url': 'https://a.test/1', 'title': '第一', 'createdAt': '2026-01-01T00:00:00.000'},
          {'id': 'b2', 'url': 'https://b.test/2', 'title': '第二', 'createdAt': '2026-01-02T00:00:00.000'},
          {'id': 'b3', 'url': 'https://c.test/3', 'title': '第三', 'createdAt': '2026-01-03T00:00:00.000'},
        ],
      }));

      final library = await BookmarkStore(directory).load();
      expect(library.categories, isEmpty);
      expect(library.bookmarks.length, 3);
      expect(library.bookmarks.every((b) => b.categoryId == uncategorizedId), isTrue);
      // File order is turned into explicit order, so nothing is reshuffled.
      expect(library.bookmarksIn(uncategorizedId).map((b) => b.title),
          ['第一', '第二', '第三']);
      expect(library.bookmarksIn(uncategorizedId).map((b) => b.order), [0, 1, 2]);
    });

    test('a version 1 file without a version field is still upgraded', () async {
      File('${directory.path}/bookmarks.json').writeAsStringSync(jsonEncode({
        'bookmarks': [
          {'id': 'b1', 'url': 'https://a.test/', 'title': 'A', 'createdAt': '2026-01-01T00:00:00.000'},
        ],
      }));
      final library = await BookmarkStore(directory).load();
      expect(library.bookmarks.single.categoryId, uncategorizedId);
      expect(library.bookmarks.single.order, 0);
    });

    test('saving writes version 2 with categories', () async {
      final category = await state.addCategory('课程');
      await add('https://a.test/', category: category.id, title: 'A');

      final raw = jsonDecode(
        File('${directory.path}/bookmarks.json').readAsStringSync(),
      ) as Map<String, dynamic>;

      expect(raw['version'], BookmarkStore.schemaVersion);
      expect((raw['categories'] as List).single, {'id': category.id, 'name': '课程'});
      final saved = (raw['bookmarks'] as List).single as Map<String, dynamic>;
      expect(saved['categoryId'], category.id);
      expect(saved['order'], 0);
    });

    test('bookmarks pointing at a deleted category fold back to 未分类', () async {
      File('${directory.path}/bookmarks.json').writeAsStringSync(jsonEncode({
        'version': 2,
        'categories': [
          {'id': 'kept', 'name': '保留'},
        ],
        'bookmarks': [
          {
            'id': 'b1',
            'url': 'https://a.test/',
            'title': 'A',
            'createdAt': '2026-01-01T00:00:00.000',
            'categoryId': 'ghost',
            'order': 0,
          },
          {
            'id': 'b2',
            'url': 'https://b.test/',
            'title': 'B',
            'createdAt': '2026-01-02T00:00:00.000',
            'categoryId': 'kept',
            'order': 0,
          },
        ],
      }));

      final library = await BookmarkStore(directory).load();
      expect(library.categories.single.id, 'kept');
      expect(library.bookmarksIn(uncategorizedId).single.id, 'b1');
      expect(library.bookmarksIn('kept').single.id, 'b2');
    });

    test('garbage entries are dropped, not fatal', () async {
      File('${directory.path}/bookmarks.json').writeAsStringSync(jsonEncode({
        'version': 2,
        'categories': [
          {'id': 'ok', 'name': '好'},
          'nonsense',
        ],
        'bookmarks': [
          {'id': '', 'url': 'https://a.test/', 'title': 'no id', 'createdAt': '2026-01-01T00:00:00.000'},
          {'id': 'b2', 'url': '', 'title': 'no url', 'createdAt': '2026-01-01T00:00:00.000'},
          {'id': 'b3', 'url': 'https://c.test/', 'title': 'C', 'createdAt': '2026-01-01T00:00:00.000'},
        ],
      }));

      final library = await BookmarkStore(directory).load();
      expect(library.bookmarks.map((b) => b.id), ['b3']);
      expect(library.categories.single.id, 'ok');
    });
  });

  group('tile captions', () {
    test('a local file shows its folder, a site shows its host', () {
      final local = Bookmark(
        id: 'l',
        url: 'file:///sdcard/course/lesson1/a.html',
        title: '',
        createdAt: DateTime(2026),
      );
      expect(local.host, 'lesson1/');
      expect(local.displayTitle, 'a.html');

      final site = Bookmark(
        id: 's',
        url: 'https://school.test/lessons',
        title: '',
        createdAt: DateTime(2026),
      );
      expect(site.host, 'school.test');
      expect(site.displayTitle, 'school.test');
    });

    test('the directory pattern covers a subtree', () {
      expect(
        BookmarkWhitelist.directoryPattern('/sdcard/course/'),
        'file:///sdcard/course/',
      );
      expect(
        BookmarkWhitelist.directoryPattern('/sdcard/course'),
        'file:///sdcard/course/',
      );
    });
  });
}
