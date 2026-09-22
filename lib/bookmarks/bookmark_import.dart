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

/// One HTML page found by the scan.
class ImportCandidate {
  final String filePath;
  final String url;
  final String title;

  /// The first-level subdirectory this page came from.
  final String subdirectory;

  const ImportCandidate({
    required this.filePath,
    required this.url,
    required this.title,
    required this.subdirectory,
  });
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
          title: readHtmlTitle(file.path) ?? _titleFromFileName(file.path),
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
          title: readHtmlTitle(page.path) ?? _titleFromFileName(page.path),
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

  static String _titleFromFileName(String filePath) {
    final name = _baseName(filePath);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    return stem.replaceAll(RegExp(r'[_-]+'), ' ').trim();
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

/// What an import actually did.
class BookmarkImportOutcome {
  final int added;
  final int skipped;
  final int subdirectoryCount;
  final String rootPath;
  final String whitelistPattern;
  final bool truncated;
  final String targetCategoryId;

  const BookmarkImportOutcome({
    required this.added,
    required this.skipped,
    required this.subdirectoryCount,
    required this.rootPath,
    required this.whitelistPattern,
    required this.truncated,
    required this.targetCategoryId,
  });

  /// One-line summary for a snackbar.
  String get summary {
    final buffer = StringBuffer('已导入 $added 个书签');
    if (skipped > 0) buffer.write('，跳过 $skipped 个（已存在）');
    if (truncated) buffer.write('，已达数量上限');
    return buffer.toString();
  }
}
