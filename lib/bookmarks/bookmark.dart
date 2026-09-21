import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../policy/policy_config.dart';

/// The pseudo-category every bookmark starts in. Never stored as a real
/// category, so it cannot be renamed or deleted away.
const String uncategorizedId = '';

/// Label shown for [uncategorizedId].
const String uncategorizedLabel = '未分类';

/// A user-defined group of bookmarks, shown as a section on the home page.
class BookmarkCategory {
  final String id;
  final String name;

  const BookmarkCategory({required this.id, required this.name});

  BookmarkCategory copyWith({String? name}) =>
      BookmarkCategory(id: id, name: name ?? this.name);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory BookmarkCategory.fromJson(Map<String, dynamic> json) => BookmarkCategory(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) => other is BookmarkCategory && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A bookmark shown as a square tile (thumbnail above, title below).
///
/// A bookmark optionally owns the whitelist entry it created, so that removing
/// the bookmark can also drop the permission it granted instead of leaving a
/// stale rule behind.
class Bookmark {
  final String id;
  final String url;
  final String title;

  /// Absolute path of the captured screenshot, or null when the tile should use
  /// the generated fallback.
  final String? thumbnailPath;

  final DateTime createdAt;

  /// The normalised whitelist pattern added for this bookmark, when the user
  /// chose to add one. Null means the bookmark grants nothing.
  final String? whitelistPattern;

  /// Category this bookmark belongs to, or [uncategorizedId].
  final String categoryId;

  /// Position inside [categoryId]. Contiguous, starting at 0.
  final int order;

  const Bookmark({
    required this.id,
    required this.url,
    required this.title,
    this.thumbnailPath,
    required this.createdAt,
    this.whitelistPattern,
    this.categoryId = uncategorizedId,
    this.order = 0,
  });

  bool get isUncategorized => categoryId == uncategorizedId;

  /// What the user sees under the thumbnail.
  String get displayTitle {
    if (title.trim().isNotEmpty) return title.trim();
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return _fileNameFallback();
    return uri.host;
  }

  String _fileNameFallback() {
    final segments = url.split('/').where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? url : Uri.decodeComponent(segments.last);
  }

  /// Host shown as the tile subtitle; a local file shows its parent folder.
  String get host {
    if (url.startsWith('file://')) {
      final path = Uri.decodeComponent(url.substring('file://'.length));
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.length >= 2) return '${segments[segments.length - 2]}/';
      return segments.isEmpty ? path : segments.last;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.host;
  }

  /// Two-letter monogram for the generated fallback tile.
  ///
  /// Taken from the registrable label rather than the label pair, so
  /// `school.test` and `www.school.test` both render "SC" instead of "ST".
  String get monogram {
    final source = host.replaceFirst('www.', '');
    if (source.isEmpty) return '?';
    final parts = source.split('.').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final label = parts.length >= 2 ? parts[parts.length - 2] : parts.first;
    if (label.isEmpty) return '?';
    return label.substring(0, label.length >= 2 ? 2 : 1).toUpperCase();
  }

  Bookmark copyWith({
    String? url,
    String? title,
    String? thumbnailPath,
    bool clearThumbnail = false,
    String? whitelistPattern,
    bool clearWhitelistPattern = false,
    String? categoryId,
    int? order,
  }) =>
      Bookmark(
        id: id,
        url: url ?? this.url,
        title: title ?? this.title,
        thumbnailPath: clearThumbnail ? null : (thumbnailPath ?? this.thumbnailPath),
        createdAt: createdAt,
        whitelistPattern:
            clearWhitelistPattern ? null : (whitelistPattern ?? this.whitelistPattern),
        categoryId: categoryId ?? this.categoryId,
        order: order ?? this.order,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        if (thumbnailPath != null) 'thumbnailPath': thumbnailPath,
        'createdAt': createdAt.toIso8601String(),
        if (whitelistPattern != null) 'whitelistPattern': whitelistPattern,
        if (categoryId.isNotEmpty) 'categoryId': categoryId,
        'order': order,
      };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        id: json['id'] as String? ?? '',
        url: json['url'] as String? ?? '',
        title: json['title'] as String? ?? '',
        thumbnailPath: json['thumbnailPath'] as String?,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
        whitelistPattern: json['whitelistPattern'] as String?,
        categoryId: json['categoryId'] as String? ?? uncategorizedId,
        order: (json['order'] as num?)?.toInt() ?? 0,
      );
}

/// Everything in `bookmarks.json`.
class BookmarkLibrary {
  final List<BookmarkCategory> categories;
  final List<Bookmark> bookmarks;

  const BookmarkLibrary({this.categories = const [], this.bookmarks = const []});

  static const BookmarkLibrary empty = BookmarkLibrary();

  /// Bookmarks of one category, in display order.
  List<Bookmark> bookmarksIn(String categoryId) {
    final list = [
      for (final bookmark in bookmarks)
        if (bookmark.categoryId == categoryId) bookmark,
    ]..sort((a, b) {
        final byOrder = a.order.compareTo(b.order);
        // Stable tie-break, so a hand-edited file still renders predictably.
        return byOrder != 0 ? byOrder : a.createdAt.compareTo(b.createdAt);
      });
    return list;
  }

  /// Bookmarks whose category no longer exists, folded back into 未分类.
  BookmarkLibrary withOrphansFolded() {
    final known = {for (final category in categories) category.id};
    final folded = [
      for (final bookmark in bookmarks)
        if (bookmark.categoryId.isEmpty || known.contains(bookmark.categoryId))
          bookmark
        else
          bookmark.copyWith(categoryId: uncategorizedId),
    ];
    return BookmarkLibrary(categories: categories, bookmarks: folded);
  }
}

/// Persists bookmarks as JSON and their screenshots as PNG files.
///
/// Storage is versioned. Version 1 had no categories and no explicit order;
/// such a file is upgraded on load (bookmarks land in 未分类, keeping the order
/// they were written in) and written back as version 2 on the next save.
class BookmarkStore {
  BookmarkStore(this.directory);

  /// Current on-disk schema version.
  static const int schemaVersion = 2;

  final Directory directory;

  File get _file => File('${directory.path}/bookmarks.json');

  Directory get thumbnailDirectory => Directory('${directory.path}/thumbnails');

  Future<BookmarkLibrary> load() async {
    try {
      if (!await _file.exists()) return BookmarkLibrary.empty;
      final raw = jsonDecode(await _file.readAsString());
      if (raw is! Map) return BookmarkLibrary.empty;

      final categories = <BookmarkCategory>[
        for (final item in (raw['categories'] as List? ?? const []))
          if (item is Map) BookmarkCategory.fromJson(Map<String, dynamic>.from(item)),
      ];
      final bookmarks = <Bookmark>[
        for (final item in (raw['bookmarks'] as List? ?? const []))
          if (item is Map) Bookmark.fromJson(Map<String, dynamic>.from(item)),
      ]..removeWhere((b) => b.url.isEmpty || b.id.isEmpty);

      // Version 1 had neither field: fromJson defaults them to 未分类 / 0, and
      // the order is renumbered from the file order so nothing is lost.
      final legacy = (raw['version'] as num?)?.toInt() != schemaVersion;
      final normalised = legacy
          ? [for (var i = 0; i < bookmarks.length; i++) bookmarks[i].copyWith(order: i)]
          : bookmarks;

      return BookmarkLibrary(categories: categories, bookmarks: normalised)
          .withOrphansFolded();
    } catch (_) {
      return BookmarkLibrary.empty;
    }
  }

  Future<void> save(BookmarkLibrary library) async {
    await _file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': schemaVersion,
        'categories': [for (final c in library.categories) c.toJson()],
        'bookmarks': [for (final b in library.bookmarks) b.toJson()],
      }),
      flush: true,
    );
  }

  /// Writes a screenshot next to the bookmark and returns its path.
  Future<String?> writeThumbnail(String bookmarkId, Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    try {
      await thumbnailDirectory.create(recursive: true);
      final file = File('${thumbnailDirectory.path}/$bookmarkId.png');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Deletes a screenshot, ignoring a missing file.
  Future<void> deleteThumbnail(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A stale file is harmless; never fail a bookmark edit over it.
    }
  }

  /// Screenshots no bookmark references any more.
  Future<int> pruneOrphanThumbnails(List<Bookmark> bookmarks) async {
    var removed = 0;
    try {
      if (!await thumbnailDirectory.exists()) return 0;
      final referenced = {
        for (final b in bookmarks)
          if (b.thumbnailPath != null) b.thumbnailPath,
      };
      await for (final entity in thumbnailDirectory.list()) {
        if (entity is! File) continue;
        if (referenced.contains(entity.path)) continue;
        await entity.delete();
        removed++;
      }
    } catch (_) {
      // Best effort only.
    }
    return removed;
  }
}

/// Builds the whitelist pattern a bookmark should grant.
abstract final class BookmarkWhitelist {
  /// The bookmark's own URL as a prefix rule — the default, and what
  /// "书签网址缺省进入白名单" asks for.
  static String urlPattern(String url) => PatternNormalizer.normalizeRulePattern(url);

  /// The whole site: scheme + host, so sibling paths work too.
  static String sitePattern(String url) {
    final normalized = PatternNormalizer.normalizeUrl(url);
    final uri = Uri.tryParse(normalized);
    if (uri == null) return urlPattern(url);
    if (uri.scheme == 'file') {
      // "The whole site" for a local page means the folder it lives in: a
      // flipbook or courseware page loads its CSS, scripts and page images from
      // siblings, and a rule covering only the .html file itself makes the page
      // render blank.
      final path = Uri.decodeComponent(uri.path);
      final slash = path.lastIndexOf('/');
      final directory = slash <= 0 ? '/' : path.substring(0, slash);
      return directoryPattern(directory);
    }
    if (uri.host.isEmpty) return urlPattern(url);
    return '${uri.scheme}://${uri.host}';
  }

  /// A whole local directory, for bulk imports: one rule instead of one per
  /// file, and it also covers the sibling assets those pages reference.
  static String directoryPattern(String directoryPath) {
    final trimmed = directoryPath.endsWith('/')
        ? directoryPath.substring(0, directoryPath.length - 1)
        : directoryPath;
    return 'file://$trimmed/';
  }
}
