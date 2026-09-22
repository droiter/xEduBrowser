import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../files/local_file_url.dart';
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
/// A bookmark optionally owns the whitelist entries it created, so that
/// removing the bookmark can also drop the permission it granted instead of
/// leaving a stale rule behind. There is normally more than one: the
/// bookmarked address itself **and** the site (or local folder) that contains
/// it, which is what makes a bookmarked page actually render.
class Bookmark {
  final String id;
  final String url;
  final String title;

  /// Absolute path of the captured screenshot, or null when the tile should use
  /// the generated fallback.
  final String? thumbnailPath;

  final DateTime createdAt;

  /// The normalised whitelist patterns added for this bookmark, in the order
  /// they were granted. Empty means the bookmark grants nothing.
  final List<String> whitelistPatterns;

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
    this.whitelistPatterns = const [],
    this.categoryId = uncategorizedId,
    this.order = 0,
  });

  /// The bookmark's own URL prefix rule — the first pattern it granted, or null
  /// when it granted nothing. Kept as a convenience for the tile badge and for
  /// reading older data.
  String? get whitelistPattern =>
      whitelistPatterns.isEmpty ? null : whitelistPatterns.first;

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
    List<String>? whitelistPatterns,
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
        whitelistPatterns: clearWhitelistPattern
            ? const []
            : (whitelistPatterns ?? this.whitelistPatterns),
        categoryId: categoryId ?? this.categoryId,
        order: order ?? this.order,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        if (thumbnailPath != null) 'thumbnailPath': thumbnailPath,
        'createdAt': createdAt.toIso8601String(),
        // Both keys are written: `whitelistPattern` keeps the file readable by
        // older builds, `whitelistPatterns` carries the full grant.
        if (whitelistPatterns.isNotEmpty) 'whitelistPattern': whitelistPatterns.first,
        if (whitelistPatterns.isNotEmpty) 'whitelistPatterns': whitelistPatterns,
        if (categoryId.isNotEmpty) 'categoryId': categoryId,
        'order': order,
      };

  factory Bookmark.fromJson(Map<String, dynamic> json) {
    final listed = [
      for (final raw in (json['whitelistPatterns'] as List? ?? const []))
        if (raw is String && raw.trim().isNotEmpty) raw.trim(),
    ];
    final single = json['whitelistPattern'] as String?;
    return Bookmark(
      id: json['id'] as String? ?? '',
      url: json['url'] as String? ?? '',
      title: json['title'] as String? ?? '',
      thumbnailPath: json['thumbnailPath'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      whitelistPatterns: listed.isNotEmpty
          ? listed
          : (single != null && single.trim().isNotEmpty ? [single.trim()] : const []),
      categoryId: json['categoryId'] as String? ?? uncategorizedId,
      order: (json['order'] as num?)?.toInt() ?? 0,
    );
  }
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

  /// Makes every capture's file name unique even within the same microsecond.
  int _thumbnailSequence = 0;

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
  ///
  /// Every capture gets a **fresh file name**: the tile renders the picture
  /// through `Image.file`, whose cache is keyed by path, so rewriting the same
  /// path would keep showing the old preview. Callers replace the bookmark's
  /// `thumbnailPath` and delete the file it pointed at before.
  Future<String?> writeThumbnail(String bookmarkId, Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    try {
      await thumbnailDirectory.create(recursive: true);
      final stamp = '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          '${(_thumbnailSequence++).toRadixString(36)}';
      final file = File('${thumbnailDirectory.path}/$bookmarkId-$stamp.png');
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
  /// Everything a bookmark grants: its **own URL** first, then the **site (or
  /// local folder) that contains it**.
  ///
  /// The requirement is "把 url 及包含该 url 的网站都加入白名单": the exact
  /// address alone is not enough in practice, because a page pulls its styles,
  /// scripts and images from elsewhere on the same site — and a local page
  /// pulls them from its own folder. Duplicates (a URL that already *is* its
  /// site, or a file directly in a storage root) collapse into one rule.
  static List<String> grantPatterns(String url) {
    final own = urlPattern(url);
    if (own.isEmpty) return const [];
    final site = sitePattern(url);
    if (site.isEmpty || site == own) return [own];
    return [own, site];
  }

  /// The bookmark's own URL as a prefix rule — the default, and what
  /// "书签网址缺省进入白名单" asks for.
  static String urlPattern(String url) =>
      PatternNormalizer.normalizeRulePattern(_canonicalLocal(url));

  /// The whole site: scheme + host, so sibling paths work too.
  static String sitePattern(String url) {
    final normalized = PatternNormalizer.normalizeUrl(_canonicalLocal(url));
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
      // A page sitting directly in a storage root would turn "its folder" into
      // the whole shared storage — far wider than the user asked for. Keep the
      // rule on the file and let them widen it deliberately.
      if (isStorageRoot(directory)) return urlPattern(url);
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
    return LocalFileUrl.directoryPattern(trimmed);
  }

  /// Percent-encodes a `file://` URL or absolute path, leaving remote URLs and
  /// rule text untouched. See [LocalFileUrl].
  static String _canonicalLocal(String url) {
    final trimmed = url.trim();
    if (LocalFileUrl.isFileUrl(trimmed) || trimmed.startsWith('/')) {
      return LocalFileUrl.canonical(trimmed);
    }
    return url;
  }

  /// Whether granting [url]'s "whole site" actually widens the rule beyond the
  /// URL itself — false when the scope cannot be widened safely (a local file
  /// directly in a storage root, or a malformed URL).
  static bool wholeSiteWidens(String url) => sitePattern(url) != urlPattern(url);

  /// Storage roots (`/sdcard`, `/storage/emulated/0`, `/mnt/sdcard`, …): a rule
  /// for a folder here would grant everything on the device.
  static bool isStorageRoot(String directoryPath) {
    final dir = directoryPath.endsWith('/') && directoryPath.length > 1
        ? directoryPath.substring(0, directoryPath.length - 1)
        : directoryPath;
    if (dir.isEmpty || dir == '/') return true;
    if (dir == '/sdcard' || dir == '/mnt/sdcard' || dir == '/storage/self/primary') {
      return true;
    }
    return RegExp(r'^/storage/(emulated/\d+|[^/]+)$').hasMatch(dir);
  }
}
