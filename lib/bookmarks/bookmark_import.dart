import 'dart:convert';
import 'dart:io';

import '../files/local_file_url.dart';

/// What to do about the whitelist when importing a directory of local pages.
enum BookmarkWhitelistScope {
  /// Import bookmarks only; nothing is granted.
  none('none', '不加入白名单'),

  /// One rule per imported page.
  perFile('perFile', '每个文件各自放行'),

  /// One rule for the whole imported directory. The default, because a single
  /// rule also covers the sibling assets those pages load, and because a
  /// courseware folder can hold dozens of pages.
  directory('directory', '整个导入目录');

  const BookmarkWhitelistScope(this.wire, this.labelZh);
  final String wire;
  final String labelZh;

  static BookmarkWhitelistScope fromWire(String? value) =>
      BookmarkWhitelistScope.values.firstWhere(
        (s) => s.wire == value,
        orElse: () => BookmarkWhitelistScope.directory,
      );
}

/// Where a local page takes its bookmark name from.
///
/// The single-bookmark dialog's 标题来源 dropdown and the directory-import
/// dialog's 标题来源 dropdown both offer exactly these four choices, so the
/// wording lives here once and the two flows cannot drift apart.
enum LocalPageTitleSource {
  /// The HTML file's own name, without its extension.
  fileName('HTML 文件名'),

  /// The folder the file sits in.
  directoryName('所在目录名'),

  /// The page's `<title>`.
  internalTitle('网页内部标题'),

  /// Nothing: the tile falls back to the address or the host.
  blank('留空');

  const LocalPageTitleSource(this.labelZh);

  /// The dropdown label, identical in both dialogs.
  final String labelZh;
}

/// One HTML page found by the scan.
class ImportCandidate {
  final String filePath;
  final String url;

  /// Every name this page could be titled with: the import dialog's 标题来源
  /// dropdown picks one of them, and the preview re-renders without rescanning.
  final LocalPageTitles titles;

  /// The first-level subdirectory this page came from.
  final String subdirectory;

  const ImportCandidate({
    required this.filePath,
    required this.url,
    required this.titles,
    required this.subdirectory,
  });

  /// The name this page gets when the chosen 标题来源 is [source].
  String titleFor(LocalPageTitleSource source) => titles.importTitle(source);

  /// The default name — the page's `<title>`, or its file name — which is what
  /// the importer produced before the choice existed.
  String get title => titleFor(LocalPageTitleSource.internalTitle);
}

/// The key two bookmark names are compared by: trimmed and case-folded, so
/// `Math` and `math` are the same name and a stray space never hides a clash.
///
/// An empty key means the bookmark has no name of its own — its tile falls back
/// to the address or the host — and reserves nothing.
String bookmarkTitleKey(String title) => title.trim().toLowerCase();

/// A scanned page an import left out because its bookmark name was already
/// taken — by a bookmark already in the library, or by an earlier page of the
/// same batch.
class ImportNameConflict {
  const ImportNameConflict({required this.filePath, required this.title});

  /// The page that was not imported.
  final String filePath;

  /// The name it would have taken, exactly as the chosen 标题来源 produced it.
  final String title;

  /// Just the file's name, for the report.
  String get fileName {
    final slash = filePath.lastIndexOf('/');
    return slash < 0 ? filePath : filePath.substring(slash + 1);
  }

  @override
  bool operator ==(Object other) =>
      other is ImportNameConflict &&
      other.filePath == filePath &&
      other.title == title;

  @override
  int get hashCode => Object.hash(filePath, title);
}

/// What an import would do with a plan, worked out before anything is written.
///
/// The import dialog previews this and `AppState.applyImportPlan` writes it, so
/// the preview and the write can never disagree about what will be imported.
class BookmarkImportDecision {
  const BookmarkImportDecision({
    this.additions = const [],
    this.nameConflicts = const [],
    this.alreadyBookmarked = 0,
  });

  /// The pages that become bookmarks, in scan order.
  final List<ImportCandidate> additions;

  /// Pages left out because another bookmark already carries their name.
  final List<ImportNameConflict> nameConflicts;

  /// How many pages were left out because their address is already bookmarked.
  final int alreadyBookmarked;

  int get nameConflictCount => nameConflicts.length;
}

/// The result of scanning a directory, before anything is written.
class BookmarkImportPlan {
  final String rootPath;

  /// First-level subdirectories that were walked, by name.
  final List<String> subdirectories;

  final List<ImportCandidate> candidates;

  /// The scan stopped at the file cap; the remainder was not read.
  final bool truncated;

  /// HTML files sitting directly in the chosen directory. They are imported
  /// too — a folder of hand-made pages usually keeps its `index.html` beside
  /// its subfolders, and skipping those surprised people.
  final int rootLevelHtmlCount;

  const BookmarkImportPlan({
    required this.rootPath,
    this.subdirectories = const [],
    this.candidates = const [],
    this.truncated = false,
    this.rootLevelHtmlCount = 0,
  });

  int get fileCount => candidates.length;

  bool get isEmpty => candidates.isEmpty;
}

/// Walks a directory and works out which local pages would become bookmarks.
///
/// Deliberately free of Flutter imports so the whole scan is unit testable
/// against a temporary directory tree.
abstract final class BookmarkImporter {
  /// Extensions treated as importable pages.
  static const Set<String> pageExtensions = {'html', 'htm', 'xhtml'};

  /// Default cap, so pointing at a huge tree cannot freeze the app.
  static const int defaultMaxFiles = 200;

  /// Bytes read from each file when looking for `<title>`.
  static const int _titleReadBytes = 16384;

  /// Scans [rootPath].
  ///
  /// Collects the HTML pages of the chosen directory itself **and** of its
  /// first-level subdirectories (each walked recursively, so a nested
  /// static-site export still imports). Hidden directories are skipped.
  static Future<BookmarkImportPlan> scan(
    String rootPath, {
    String? localServerBase,
    String? localServerRoot,
    int maxFiles = defaultMaxFiles,
  }) async {
    final root = Directory(rootPath);
    if (!await root.exists()) {
      return BookmarkImportPlan(rootPath: rootPath);
    }

    List<FileSystemEntity> rootEntries;
    try {
      rootEntries = await root.list(followLinks: false).toList();
    } catch (_) {
      return BookmarkImportPlan(rootPath: rootPath);
    }

    final subdirectoryNames = <String>[
      for (final entity in rootEntries)
        if (entity is Directory && !_isHidden(entity.path)) _baseName(entity.path),
    ]..sort();

    // Pages sitting directly in the chosen directory, in name order.
    final rootFiles = <File>[
      for (final entity in rootEntries)
        if (entity is File && _isPage(entity.path)) entity,
    ]..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    final rootLevelHtml = rootFiles.length;

    final candidates = <ImportCandidate>[
      for (final file in rootFiles)
        ImportCandidate(
          filePath: file.path,
          url: _urlFor(file.path, localServerBase, localServerRoot),
          titles: LocalPageTitles.forPath(file.path),
          subdirectory: '',
        ),
    ];
    if (candidates.length > maxFiles) {
      candidates.removeRange(maxFiles, candidates.length);
    }
    var truncated = candidates.length >= maxFiles;

    for (final name in subdirectoryNames) {
      if (candidates.length >= maxFiles) {
        truncated = true;
        break;
      }
      final directory = Directory('${_trimSlash(rootPath)}/$name');
      final found = await _collectPages(
        directory,
        rootPath: rootPath,
        subdirectory: name,
        localServerBase: localServerBase,
        localServerRoot: localServerRoot,
        remaining: maxFiles - candidates.length,
      );
      candidates.addAll(found);
      if (candidates.length >= maxFiles) truncated = true;
    }

    return BookmarkImportPlan(
      rootPath: rootPath,
      subdirectories: subdirectoryNames,
      candidates: candidates,
      truncated: truncated,
      rootLevelHtmlCount: rootLevelHtml,
    );
  }

  static Future<List<ImportCandidate>> _collectPages(
    Directory directory, {
    required String rootPath,
    required String subdirectory,
    required String? localServerBase,
    required String? localServerRoot,
    required int remaining,
  }) async {
    if (remaining <= 0) return const [];
    final pages = <File>[];

    Future<void> walk(Directory current) async {
      if (pages.length >= remaining) return;
      List<FileSystemEntity> entries;
      try {
        entries = await current.list(followLinks: false).toList();
      } catch (_) {
        return;
      }
      entries.sort((a, b) {
        final aDir = a is Directory ? 1 : 0;
        final bDir = b is Directory ? 1 : 0;
        if (aDir != bDir) return aDir - bDir;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      for (final entity in entries) {
        if (pages.length >= remaining) return;
        if (entity is Directory) {
          if (_isHidden(entity.path)) continue;
          await walk(entity);
        } else if (entity is File && _isPage(entity.path)) {
          pages.add(entity);
        }
      }
    }

    await walk(directory);

    return [
      for (final page in pages)
        ImportCandidate(
          filePath: page.path,
          url: _urlFor(page.path, localServerBase, localServerRoot),
          titles: LocalPageTitles.forPath(page.path),
          subdirectory: subdirectory,
        ),
    ];
  }

  /// A file inside the served root is addressed over loopback so dynamic pages
  /// keep working; anything else becomes a `file://` URL. Local paths are
  /// canonicalised (percent-encoded) so the stored URL is exactly what the
  /// WebView loads and the policy compares.
  static String _urlFor(String filePath, String? localServerBase, String? localServerRoot) {
    if (localServerBase != null && localServerRoot != null && localServerRoot.isNotEmpty) {
      final root = _trimSlash(localServerRoot);
      if (filePath.startsWith(root)) {
        // Keep the encoded path of the canonical file URL, so both access
        // routes name the same resource.
        final path = Uri.parse(LocalFileUrl.canonical(filePath)).path;
        return '$localServerBase$path';
      }
    }
    return LocalFileUrl.canonical(filePath);
  }

  /// Reads `<title>` out of an HTML file, or null when there is none.
  ///
  /// Only the head of the file is read, so pointing this at a large export
  /// stays cheap.
  static String? readHtmlTitle(String filePath) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      final handle = file.openSync();
      try {
        final bytes = handle.readSync(_titleReadBytes);
        // allowMalformed: the read can cut a multi-byte character in half.
        final text = utf8.decode(bytes, allowMalformed: true);
        final match = RegExp(r'<title[^>]*>(.*?)</title>',
                caseSensitive: false, dotAll: true)
            .firstMatch(text);
        if (match == null) return null;
        final cleaned = _cleanTitle(match.group(1) ?? '');
        return cleaned.isEmpty ? null : cleaned;
      } finally {
        handle.closeSync();
      }
    } catch (_) {
      return null;
    }
  }

  static String _cleanTitle(String raw) {
    var text = raw
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    const entities = {
      '&amp;': '&',
      '&lt;': '<',
      '&gt;': '>',
      '&quot;': '"',
      '&#39;': "'",
      '&apos;': "'",
      '&nbsp;': ' ',
    };
    entities.forEach((entity, value) => text = text.replaceAll(entity, value));
    if (text.length > 80) text = '${text.substring(0, 79)}…';
    return text.trim();
  }

  static bool _isPage(String path) {
    final name = _baseName(path).toLowerCase();
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return pageExtensions.contains(name.substring(dot + 1));
  }

  static bool _isHidden(String path) => _baseName(path).startsWith('.');

  static String _baseName(String path) =>
      path.endsWith('/') ? path.substring(0, path.length - 1).split('/').last : path.split('/').last;

  static String _trimSlash(String path) =>
      path.endsWith('/') ? path.substring(0, path.length - 1) : path;
}

/// The names a local page can be titled with.
///
/// The bookmark dialog offers them as a 标题来源 dropdown: the file's own name,
/// the folder it sits in, the page's `<title>`, or nothing at all. Picking one
/// fills the title field, which the user can still edit. The directory-import
/// dialog offers the very same choices for the names it writes in bulk.
class LocalPageTitles {
  const LocalPageTitles({
    required this.fileName,
    required this.directoryName,
    required this.internalTitle,
  });

  /// File name without its extension, e.g. `Caterpillar ebook`.
  final String fileName;

  /// Name of the folder the file sits in, e.g. `好奇的毛毛虫`.
  final String directoryName;

  /// The page's own `<title>`, or null when it has none (or cannot be read).
  final String? internalTitle;

  bool get hasInternalTitle =>
      internalTitle != null && internalTitle!.trim().isNotEmpty;

  /// The text [source] names this page with, or an empty string when the page
  /// has no such name (`网页内部标题` on a file without a `<title>`, or
  /// `留空`). This is what the single-bookmark form fills its field with.
  String textFor(LocalPageTitleSource source) {
    switch (source) {
      case LocalPageTitleSource.fileName:
        return fileName.trim();
      case LocalPageTitleSource.directoryName:
        return directoryName.trim();
      case LocalPageTitleSource.internalTitle:
        return (internalTitle ?? '').trim();
      case LocalPageTitleSource.blank:
        return '';
    }
  }

  /// The name an **imported** page gets from [source].
  ///
  /// A batch import cannot stop at a file whose chosen source is empty, so an
  /// empty candidate falls back to the file name — which is also exactly what
  /// the importer produced before the choice existed. `留空` stays deliberately
  /// empty: those tiles show the address or the host instead.
  String importTitle(LocalPageTitleSource source) {
    final text = textFor(source);
    if (text.isNotEmpty) return text;
    return source == LocalPageTitleSource.blank ? '' : fileName.trim();
  }

  /// Candidates for a local page URL, or null when [url] is not a local file.
  static LocalPageTitles? forUrl(String url) {
    final path = LocalFileUrl.pathOf(url);
    if (path == null || path.isEmpty) return null;
    return forPath(path);
  }

  /// Candidates for a filesystem path. Reading the `<title>` is one small
  /// synchronous read, exactly like the directory scan does.
  static LocalPageTitles forPath(String filePath) {
    final name = _pathBaseName(filePath);
    final dot = name.lastIndexOf('.');
    return LocalPageTitles(
      fileName: dot > 0 ? name.substring(0, dot) : name,
      directoryName: _pathParentName(filePath),
      internalTitle: BookmarkImporter.readHtmlTitle(filePath),
    );
  }
}

String _pathBaseName(String path) {
  final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final slash = trimmed.lastIndexOf('/');
  return slash < 0 ? trimmed : trimmed.substring(slash + 1);
}

String _pathParentName(String path) {
  final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final slash = trimmed.lastIndexOf('/');
  if (slash <= 0) return trimmed;
  return _pathBaseName(trimmed.substring(0, slash));
}

/// What an import actually did.
class BookmarkImportOutcome {
  final int added;

  /// Pages left out because their address is already bookmarked.
  final int skipped;

  final int subdirectoryCount;
  final String rootPath;
  final String whitelistPattern;
  final bool truncated;
  final String targetCategoryId;

  /// Pages left out because their name was already taken, in scan order.
  final List<ImportNameConflict> nameConflicts;

  const BookmarkImportOutcome({
    required this.added,
    required this.skipped,
    required this.subdirectoryCount,
    required this.rootPath,
    required this.whitelistPattern,
    required this.truncated,
    required this.targetCategoryId,
    this.nameConflicts = const [],
  });

  int get nameConflictCount => nameConflicts.length;

  /// One-line summary for a snackbar.
  String get summary {
    final buffer = StringBuffer('已导入 $added 个书签');
    if (skipped > 0) buffer.write('，跳过 $skipped 个（已存在）');
    if (nameConflicts.isNotEmpty) {
      buffer.write('，跳过 $nameConflictCount 个（重名）');
    }
    if (truncated) buffer.write('，已达数量上限');
    return buffer.toString();
  }
}
