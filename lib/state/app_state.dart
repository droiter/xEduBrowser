import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../bookmarks/bookmark.dart';
import '../bookmarks/bookmark_import.dart';
import '../local_server/local_http_server.dart';
import '../parental/parental_challenge.dart';
import '../parental/parental_password.dart';
import '../policy/policy_config.dart';
import '../policy/policy_engine.dart';

/// Browser engine settings that are pushed to the native WebView.
class AppSettings {
  final bool javaScript;
  final bool domStorage;
  final bool fileAccess;
  final bool allowFileUrlCrossAccess;
  final bool mediaAutoplay;
  final String? userAgent;
  final int textZoom;

  /// Start page. Defaults to the bundled local start page.
  final String homeUrl;

  final bool localServerEnabled;
  final int localServerPort;
  final String localServerRoot;

  /// Require an arithmetic question before the settings screen opens.
  final bool parentalGateEnabled;

  /// Which arithmetic the challenge asks.
  final ParentalOperation parentalGateOperation;

  /// How many questions must be answered correctly in a row.
  final int parentalGateQuestionCount;

  /// Which challenge the gate presents.
  final ParentalGateMode parentalGateMode;

  /// Salted hash of the parent password. Empty until one is set; the password
  /// itself is never stored.
  final String parentalPasswordHash;

  /// Salt for [parentalPasswordHash].
  final String parentalPasswordSalt;

  /// Also protect the whitelist/blacklist screen. **On by default**: leaving it
  /// off would let anyone change the rules from that screen without ever
  /// meeting the challenge, which would make the gate pointless.
  final bool parentalGateProtectRules;

  /// Pre-tick "add to whitelist" in the bookmark dialog.
  final bool bookmarkWhitelistByDefault;

  const AppSettings({
    this.javaScript = true,
    this.domStorage = true,
    this.fileAccess = true,
    this.allowFileUrlCrossAccess = true,
    this.mediaAutoplay = false,
    this.userAgent,
    this.textZoom = 100,
    this.homeUrl = 'about:home',
    this.localServerEnabled = true,
    this.localServerPort = LocalHttpServer.defaultPort,
    this.localServerRoot = '',
    this.parentalGateEnabled = true,
    this.parentalGateMode = ParentalGateMode.password,
    this.parentalPasswordHash = '',
    this.parentalPasswordSalt = '',
    this.parentalGateOperation = ParentalOperation.multiplication,
    this.parentalGateQuestionCount = 1,
    this.parentalGateProtectRules = true,
    this.bookmarkWhitelistByDefault = true,
  });

  /// True once a parent password has been configured. While false, the gate
  /// asks the parent to set one instead of asking them to enter it.
  bool get hasParentalPassword =>
      parentalPasswordHash.isNotEmpty && parentalPasswordSalt.isNotEmpty;

  AppSettings copyWith({
    bool? javaScript,
    bool? domStorage,
    bool? fileAccess,
    bool? allowFileUrlCrossAccess,
    bool? mediaAutoplay,
    String? userAgent,
    bool clearUserAgent = false,
    int? textZoom,
    String? homeUrl,
    bool? localServerEnabled,
    int? localServerPort,
    String? localServerRoot,
    bool? parentalGateEnabled,
    ParentalGateMode? parentalGateMode,
    String? parentalPasswordHash,
    String? parentalPasswordSalt,
    ParentalOperation? parentalGateOperation,
    int? parentalGateQuestionCount,
    bool? parentalGateProtectRules,
    bool? bookmarkWhitelistByDefault,
  }) =>
      AppSettings(
        javaScript: javaScript ?? this.javaScript,
        domStorage: domStorage ?? this.domStorage,
        fileAccess: fileAccess ?? this.fileAccess,
        allowFileUrlCrossAccess: allowFileUrlCrossAccess ?? this.allowFileUrlCrossAccess,
        mediaAutoplay: mediaAutoplay ?? this.mediaAutoplay,
        userAgent: clearUserAgent ? null : (userAgent ?? this.userAgent),
        textZoom: textZoom ?? this.textZoom,
        homeUrl: homeUrl ?? this.homeUrl,
        localServerEnabled: localServerEnabled ?? this.localServerEnabled,
        localServerPort: localServerPort ?? this.localServerPort,
        localServerRoot: localServerRoot ?? this.localServerRoot,
        parentalGateEnabled: parentalGateEnabled ?? this.parentalGateEnabled,
        parentalGateMode: parentalGateMode ?? this.parentalGateMode,
        parentalPasswordHash: parentalPasswordHash ?? this.parentalPasswordHash,
        parentalPasswordSalt: parentalPasswordSalt ?? this.parentalPasswordSalt,
        parentalGateOperation: parentalGateOperation ?? this.parentalGateOperation,
        parentalGateQuestionCount:
            parentalGateQuestionCount ?? this.parentalGateQuestionCount,
        parentalGateProtectRules: parentalGateProtectRules ?? this.parentalGateProtectRules,
        bookmarkWhitelistByDefault:
            bookmarkWhitelistByDefault ?? this.bookmarkWhitelistByDefault,
      );

  Map<String, dynamic> toJson() => {
        'javaScript': javaScript,
        'domStorage': domStorage,
        'fileAccess': fileAccess,
        'allowFileUrlCrossAccess': allowFileUrlCrossAccess,
        'mediaAutoplay': mediaAutoplay,
        'userAgent': userAgent,
        'textZoom': textZoom,
        'homeUrl': homeUrl,
        'localServerEnabled': localServerEnabled,
        'localServerPort': localServerPort,
        'localServerRoot': localServerRoot,
        'parentalGateEnabled': parentalGateEnabled,
        'parentalGateMode': parentalGateMode.wire,
        // Only the salt and the derived hash are persisted, never the password.
        'parentalPasswordHash': parentalPasswordHash,
        'parentalPasswordSalt': parentalPasswordSalt,
        'parentalGateOperation': parentalGateOperation.wire,
        'parentalGateQuestionCount': parentalGateQuestionCount,
        'parentalGateProtectRules': parentalGateProtectRules,
        'bookmarkWhitelistByDefault': bookmarkWhitelistByDefault,
      };

  /// The subset the native side consumes for the WebView.
  Map<String, dynamic> toNativeSettings() => {
        'javaScript': javaScript,
        'domStorage': domStorage,
        'fileAccess': fileAccess,
        'allowFileUrlCrossAccess': allowFileUrlCrossAccess,
        'mediaAutoplay': mediaAutoplay,
        'userAgent': userAgent,
        'textZoom': textZoom,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        javaScript: json['javaScript'] as bool? ?? true,
        domStorage: json['domStorage'] as bool? ?? true,
        fileAccess: json['fileAccess'] as bool? ?? true,
        allowFileUrlCrossAccess: json['allowFileUrlCrossAccess'] as bool? ?? true,
        mediaAutoplay: json['mediaAutoplay'] as bool? ?? false,
        userAgent: json['userAgent'] as String?,
        textZoom: (json['textZoom'] as num?)?.toInt() ?? 100,
        homeUrl: json['homeUrl'] as String? ?? 'about:home',
        localServerEnabled: json['localServerEnabled'] as bool? ?? true,
        localServerPort: (json['localServerPort'] as num?)?.toInt() ?? LocalHttpServer.defaultPort,
        localServerRoot: json['localServerRoot'] as String? ?? '',
        parentalGateEnabled: json['parentalGateEnabled'] as bool? ?? true,
        parentalGateMode: ParentalGateMode.fromWire(json['parentalGateMode'] as String?),
        parentalPasswordHash: json['parentalPasswordHash'] as String? ?? '',
        parentalPasswordSalt: json['parentalPasswordSalt'] as String? ?? '',
        parentalGateOperation:
            ParentalOperation.fromWire(json['parentalGateOperation'] as String?),
        parentalGateQuestionCount:
            (json['parentalGateQuestionCount'] as num?)?.toInt() ?? 1,
        // A missing key means "written before this field existed", so it takes
        // the new default (protected) rather than the old one.
        parentalGateProtectRules: json['parentalGateProtectRules'] as bool? ?? true,
        bookmarkWhitelistByDefault:
            json['bookmarkWhitelistByDefault'] as bool? ?? true,
      );
}

/// One entry of the in-app request log (the audit trail shown to the operator).
class RequestLogEntry {
  final DateTime time;
  final String url;
  final bool allowed;
  final String reason;
  final String explanation;
  final List<String> matched;
  final String kind; // navigation | request | localServer | download

  RequestLogEntry({
    required this.url,
    required this.allowed,
    required this.reason,
    this.explanation = '',
    this.matched = const [],
    this.kind = 'navigation',
    DateTime? time,
  }) : time = time ?? DateTime.now();

  factory RequestLogEntry.fromNative(Map<String, dynamic> event) => RequestLogEntry(
        url: event['url'] as String? ?? '',
        allowed: event['allowed'] as bool? ?? false,
        reason: event['reason'] as String? ?? '',
        explanation: event['explanation'] as String? ?? '',
        matched: [for (final m in (event['matched'] as List? ?? const [])) '$m'],
        kind: event['type'] == 'requestBlocked'
            ? (event['resourceType'] as String? ?? 'request')
            : 'navigation',
      );

  String get timeLabel {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}

/// Reads and writes configuration as JSON in the app documents directory.
class ConfigStore {
  final Directory directory;
  ConfigStore(this.directory);

  File get _policyFile => File('${directory.path}/policy.json');
  File get _settingsFile => File('${directory.path}/settings.json');

  Future<PolicyConfig> loadPolicy() async {
    try {
      if (!await _policyFile.exists()) return PolicyConfig.empty;
      final raw = jsonDecode(await _policyFile.readAsString());
      if (raw is! Map) return PolicyConfig.empty;
      return PolicyConfig.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      return PolicyConfig.empty;
    }
  }

  Future<void> savePolicy(PolicyConfig config) async {
    await _policyFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
      flush: true,
    );
  }

  Future<AppSettings> loadSettings() async {
    try {
      if (!await _settingsFile.exists()) return const AppSettings();
      final raw = jsonDecode(await _settingsFile.readAsString());
      if (raw is! Map) return const AppSettings();
      return AppSettings.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings settings) async {
    await _settingsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
  }

  /// Exports the policy for sharing with another tablet.
  String exportPolicy(PolicyConfig config) =>
      const JsonEncoder.withIndent('  ').convert(config.toJson());

  /// Imports a policy, rejecting anything that is not a JSON object.
  PolicyConfig importPolicy(String text) {
    final raw = jsonDecode(text);
    if (raw is! Map) throw const FormatException('规则文件必须是一个 JSON 对象');
    return PolicyConfig.fromJson(Map<String, dynamic>.from(raw));
  }
}

/// Application-wide state: policy, settings, the compiled engine, the local
/// server and the audit log.
///
/// Screens listen to this object; the native side is updated through
/// [onPolicyChanged] / [onSettingsChanged] callbacks which the browser screen
/// wires to the platform channel.
class AppState extends ChangeNotifier {
  AppState({required this.store, PolicyConfig? policy, AppSettings? settings})
      : _policy = policy ?? PolicyConfig.empty,
        _settings = settings ?? const AppSettings() {
    bookmarkStore = BookmarkStore(store.directory);
    _rebuildEngine();
  }

  final ConfigStore store;

  /// Persists bookmarks and their screenshots next to the configuration.
  late final BookmarkStore bookmarkStore;

  PolicyConfig _policy;
  AppSettings _settings;
  late PolicyEngine _engine;
  LocalHttpServer? _localServer;
  bool _localServerRunning = false;
  BookmarkLibrary _library = BookmarkLibrary.empty;

  final List<RequestLogEntry> _log = [];
  static const int _logLimit = 500;

  /// How long log notifications are coalesced for.
  static const Duration _logNotifyWindow = Duration(milliseconds: 200);

  Timer? _logNotifyTimer;

  /// Called when the policy changes so the native layer can update its copy.
  void Function(Map<String, dynamic> nativePolicy)? onPolicyChanged;

  /// Called when WebView settings change.
  void Function(Map<String, dynamic> nativeSettings)? onSettingsChanged;

  PolicyConfig get policy => _policy;

  AppSettings get settings => _settings;

  PolicyEngine get engine => _engine;

  LocalHttpServer? get localServer => _localServer;

  bool get localServerRunning => _localServerRunning;

  String get effectiveLocalRoot =>
      _settings.localServerRoot.isNotEmpty ? _settings.localServerRoot : store.directory.path;

  List<RequestLogEntry> get log => List.unmodifiable(_log);

  /// All bookmarks. Use [bookmarksIn] for display order within a category.
  List<Bookmark> get bookmarks => List.unmodifiable(_library.bookmarks);

  /// Categories, in the order they were created.
  List<BookmarkCategory> get categories => List.unmodifiable(_library.categories);

  /// Bookmarks of one category, in display order (see [uncategorizedId]).
  List<Bookmark> bookmarksIn(String categoryId) => _library.bookmarksIn(categoryId);

  BookmarkCategory? categoryById(String id) {
    for (final category in _library.categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  /// Label for a category id, falling back to 未分类.
  String categoryLabel(String id) => categoryById(id)?.name ?? uncategorizedLabel;

  /// Category ids that currently hold at least one bookmark, plus 未分类 when it
  /// does. Drives the home page sections.
  List<String> get populatedCategoryIds {
    final ids = <String>[
      for (final category in _library.categories)
        if (_library.bookmarksIn(category.id).isNotEmpty) category.id,
    ];
    if (_library.bookmarksIn(uncategorizedId).isNotEmpty) ids.add(uncategorizedId);
    return ids;
  }

  /// The policy map handed to the native layer: the configuration plus the
  /// loopback mapping it needs to gate locally served pages identically.
  Map<String, dynamic> nativePolicyPayload() => {
        ..._policy.toJson(),
        'localServer': localServerDescriptor(_localServer),
      };

  void _rebuildEngine() {
    _engine = PolicyEngine(_policy);
  }

  Future<void> load() async {
    _policy = await store.loadPolicy();
    _settings = await store.loadSettings();
    _library = await bookmarkStore.load();
    _rebuildEngine();
    // Screenshots whose bookmark is gone would otherwise accumulate forever.
    unawaited(bookmarkStore.pruneOrphanThumbnails(_library.bookmarks));
    if (_settings.localServerEnabled) {
      await startLocalServer();
    }
    notifyListeners();
  }

  Future<void> updatePolicy(PolicyConfig next) async {
    _policy = next;
    _rebuildEngine();
    await store.savePolicy(_policy);
    onPolicyChanged?.call(nativePolicyPayload());
    notifyListeners();
  }

  Future<void> updateSettings(AppSettings next) async {
    final serverWasEnabled = _settings.localServerEnabled;
    final portChanged = _settings.localServerPort != next.localServerPort;
    final rootChanged = effectiveLocalRoot != (next.localServerRoot.isNotEmpty
        ? next.localServerRoot
        : store.directory.path);
    _settings = next;
    // React immediately and push to the native layer, then persist: a settings
    // change must never wait on a disk write before the screen reflects it.
    onSettingsChanged?.call(_settings.toNativeSettings());
    notifyListeners();
    await store.saveSettings(_settings);
    if (next.localServerEnabled && (!serverWasEnabled || portChanged || rootChanged)) {
      await startLocalServer();
    } else if (!next.localServerEnabled && serverWasEnabled) {
      await stopLocalServer();
    }
  }

  // ------------------------------------------------------------ bookmarks

  Bookmark? _bookmarkByUrl(String normalizedUrl) {
    for (final bookmark in _library.bookmarks) {
      if (bookmark.url == normalizedUrl) return bookmark;
    }
    return null;
  }

  Bookmark? bookmarkFor(String url) => _bookmarkByUrl(PatternNormalizer.normalizeUrl(url));

  bool isBookmarked(String url) => bookmarkFor(url) != null;

  String _newBookmarkId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_library.bookmarks.length.toRadixString(36)}';

  /// Adds (or updates) a bookmark.
  ///
  /// By default the bookmark's URL is also added to the whitelist, which is the
  /// behaviour the requirement asks for: bookmarking a page is how you grant
  /// access to it. Pass [addToWhitelist] to override, and [wholeSite] to grant
  /// the origin instead of the exact URL prefix.
  Future<Bookmark> addBookmark({
    required String url,
    String title = '',
    Uint8List? thumbnail,
    bool? addToWhitelist,
    bool wholeSite = false,
    String categoryId = uncategorizedId,
  }) async {
    final normalizedUrl = PatternNormalizer.normalizeUrl(url);
    final existing = _bookmarkByUrl(normalizedUrl);
    final id = existing?.id ?? _newBookmarkId();

    var thumbnailPath = existing?.thumbnailPath;
    if (thumbnail != null && thumbnail.isNotEmpty) {
      thumbnailPath = await bookmarkStore.writeThumbnail(id, thumbnail) ?? thumbnailPath;
    }

    var whitelistPattern = existing?.whitelistPattern;
    final shouldWhitelist = addToWhitelist ?? _settings.bookmarkWhitelistByDefault;
    if (shouldWhitelist) {
      final raw = wholeSite
          ? BookmarkWhitelist.sitePattern(normalizedUrl)
          : BookmarkWhitelist.urlPattern(normalizedUrl);
      final pattern = PatternNormalizer.normalizeRulePattern(raw);
      await addRule(PolicyRule(
        pattern: pattern,
        kind: PolicyListKind.whitelist,
        note: '书签：${title.trim().isEmpty ? normalizedUrl : title.trim()}',
      ));
      whitelistPattern = pattern;
    }

    final bookmark = Bookmark(
      id: id,
      url: normalizedUrl,
      title: title.trim(),
      thumbnailPath: thumbnailPath,
      createdAt: existing?.createdAt ?? DateTime.now(),
      whitelistPattern: whitelistPattern,
      categoryId: categoryId,
      // Appended to the end of its category, unless it already had a slot.
      order: existing != null && existing.categoryId == categoryId
          ? existing.order
          : _nextOrderIn(categoryId),
    );
    _library = BookmarkLibrary(
      categories: _library.categories,
      bookmarks: [
        bookmark,
        for (final other in _library.bookmarks)
          if (other.id != id) other,
      ],
    );
    notifyListeners();
    await _persistBookmarks();
    return bookmark;
  }

  /// Removes a bookmark, and by default the whitelist entry it created.
  ///
  /// The rule is kept when another bookmark still relies on the same pattern,
  /// so deleting one bookmark can never silently revoke access granted for
  /// another.
  Future<void> removeBookmark(
    Bookmark bookmark, {
    bool removeWhitelistRule = true,
  }) async {
    final pattern = bookmark.whitelistPattern;
    _library = BookmarkLibrary(
      categories: _library.categories,
      bookmarks: [
        for (final other in _library.bookmarks)
          if (other.id != bookmark.id) other,
      ],
    );
    await bookmarkStore.deleteThumbnail(bookmark.thumbnailPath);

    if (removeWhitelistRule && pattern != null) {
      await _removeWhitelistRuleIfUnused(pattern);
    }

    notifyListeners();
    await _persistBookmarks();
  }

  /// Renames a bookmark and reconciles the whitelist entry it grants.
  Future<void> editBookmark(
    Bookmark bookmark, {
    required String title,
    required bool grantWhitelist,
    bool wholeSite = false,
  }) async {
    var pattern = bookmark.whitelistPattern;

    if (grantWhitelist) {
      final raw = wholeSite
          ? BookmarkWhitelist.sitePattern(bookmark.url)
          : BookmarkWhitelist.urlPattern(bookmark.url);
      final normalized = PatternNormalizer.normalizeRulePattern(raw);
      if (pattern != normalized) {
        // Drop a stale rule first, for example when switching to whole-site.
        if (pattern != null) {
          await _removeWhitelistRuleIfUnused(pattern, exceptBookmarkId: bookmark.id);
        }
        await addRule(PolicyRule(
          pattern: normalized,
          kind: PolicyListKind.whitelist,
          note: '书签：${title.trim().isEmpty ? bookmark.url : title.trim()}',
        ));
        pattern = normalized;
      }
    } else if (pattern != null) {
      await _removeWhitelistRuleIfUnused(pattern, exceptBookmarkId: bookmark.id);
      pattern = null;
    }

    await updateBookmark(bookmark.copyWith(
      title: title.trim(),
      whitelistPattern: pattern,
      clearWhitelistPattern: pattern == null,
    ));
  }

  /// Drops a whitelist rule unless another bookmark still needs the pattern.
  ///
  /// [exceptBookmarkId] is the bookmark whose own grant is being changed: it
  /// must not count as a user of the pattern, or the rule would look in-use
  /// forever and never be removed.
  Future<void> _removeWhitelistRuleIfUnused(
    String pattern, {
    String? exceptBookmarkId,
  }) async {
    if (_library.bookmarks.any(
      (b) => b.whitelistPattern == pattern && b.id != exceptBookmarkId,
    )) {
      return;
    }
    final rules = [
      for (final rule in _policy.rules)
        if (!(rule.kind == PolicyListKind.whitelist &&
            PatternNormalizer.normalizeRulePattern(rule.pattern) == pattern))
          rule,
    ];
    if (rules.length != _policy.rules.length) {
      await updatePolicy(_policy.copyWith(rules: rules));
    }
  }

  Future<void> updateBookmark(Bookmark updated) async {
    _library = BookmarkLibrary(
      categories: _library.categories,
      bookmarks: [
        for (final bookmark in _library.bookmarks)
          if (bookmark.id == updated.id) updated else bookmark,
      ],
    );
    notifyListeners();
    await _persistBookmarks();
  }

  /// Replaces a bookmark's screenshot (used when refreshing a stale tile).
  Future<void> setBookmarkThumbnail(Bookmark bookmark, Uint8List bytes) async {
    final path = await bookmarkStore.writeThumbnail(bookmark.id, bytes);
    if (path == null) return;
    await updateBookmark(bookmark.copyWith(thumbnailPath: path));
  }

  Future<void> _persistBookmarks() => bookmarkStore.save(_library);

  // ---------------------------------------------------------- categories

  Future<BookmarkCategory> addCategory(String name) async {
    final trimmed = name.trim();
    final category = BookmarkCategory(
      id: 'c${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      name: trimmed.isEmpty ? '新分类' : trimmed,
    );
    _library = BookmarkLibrary(
      categories: [..._library.categories, category],
      bookmarks: _library.bookmarks,
    );
    notifyListeners();
    await _persistBookmarks();
    return category;
  }

  Future<void> renameCategory(BookmarkCategory category, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _library = BookmarkLibrary(
      categories: [
        for (final existing in _library.categories)
          if (existing.id == category.id) existing.copyWith(name: trimmed) else existing,
      ],
      bookmarks: _library.bookmarks,
    );
    notifyListeners();
    await _persistBookmarks();
  }

  /// Deletes a category. Its bookmarks are **not** deleted: they move to
  /// 未分类, keeping their relative order, so a mis-tap never loses data.
  Future<void> removeCategory(BookmarkCategory category) async {
    final moved = _library.bookmarksIn(category.id);
    final orphaned = [
      for (var i = 0; i < moved.length; i++)
        moved[i].copyWith(categoryId: uncategorizedId, order: _nextOrderIn(uncategorizedId) + i),
    ];
    final byId = {for (final bookmark in orphaned) bookmark.id: bookmark};
    _library = BookmarkLibrary(
      categories: [
        for (final existing in _library.categories)
          if (existing.id != category.id) existing,
      ],
      bookmarks: [
        for (final bookmark in _library.bookmarks) byId[bookmark.id] ?? bookmark,
      ],
    );
    notifyListeners();
    await _persistBookmarks();
  }

  int _nextOrderIn(String categoryId) {
    final siblings = _library.bookmarksIn(categoryId);
    return siblings.isEmpty ? 0 : siblings.last.order + 1;
  }

  // ------------------------------------------------------------- ordering

  /// Moves a bookmark to [newIndex] inside its own category.
  Future<void> reorderBookmark(Bookmark bookmark, int newIndex) =>
      moveBookmark(bookmark, categoryId: bookmark.categoryId, index: newIndex);

  /// Moves a bookmark to [categoryId] at [index] (appended when null).
  ///
  /// Both the source and the target category are renumbered contiguously, so the
  /// stored order never develops gaps.
  Future<void> moveBookmark(
    Bookmark bookmark, {
    required String categoryId,
    int? index,
  }) async {
    final target = _library.bookmarksIn(categoryId)
      ..removeWhere((b) => b.id == bookmark.id);
    final at = (index ?? target.length).clamp(0, target.length);
    target.insert(at, bookmark.copyWith(categoryId: categoryId));

    final updated = <Bookmark>[
      for (var i = 0; i < target.length; i++)
        target[i].copyWith(categoryId: categoryId, order: i),
    ];

    if (bookmark.categoryId != categoryId) {
      final source = _library.bookmarksIn(bookmark.categoryId)
        ..removeWhere((b) => b.id == bookmark.id);
      updated.addAll([
        for (var i = 0; i < source.length; i++) source[i].copyWith(order: i),
      ]);
    }

    await _replaceBookmarks(updated);
  }

  /// Replaces bookmarks by id and persists once.
  Future<void> _replaceBookmarks(Iterable<Bookmark> updated) async {
    final byId = {for (final bookmark in updated) bookmark.id: bookmark};
    if (byId.isEmpty) return;
    _library = BookmarkLibrary(
      categories: _library.categories,
      bookmarks: [for (final bookmark in _library.bookmarks) byId[bookmark.id] ?? bookmark],
    );
    notifyListeners();
    await _persistBookmarks();
  }

  // --------------------------------------------------------------- import

  /// Imports every HTML page found in the **first-level subdirectories** of
  /// [directoryPath] into [categoryId].
  ///
  /// See [BookmarkImporter.scan] for the traversal rules and
  /// [BookmarkWhitelistScope] for what to grant. Pages already bookmarked are
  /// skipped rather than duplicated.
  Future<BookmarkImportOutcome> importBookmarksFromDirectory({
    required String directoryPath,
    required String categoryId,
    BookmarkWhitelistScope whitelistScope = BookmarkWhitelistScope.directory,
    int maxFiles = BookmarkImporter.defaultMaxFiles,
  }) async {
    final plan = await BookmarkImporter.scan(
      directoryPath,
      localServerBase: _localServer?.baseUrl,
      localServerRoot: effectiveLocalRoot,
      maxFiles: maxFiles,
    );
    return applyImportPlan(plan, categoryId: categoryId, whitelistScope: whitelistScope);
  }

  /// Writes an already-scanned plan. Split out so the UI can show a preview and
  /// confirm before anything changes.
  Future<BookmarkImportOutcome> applyImportPlan(
    BookmarkImportPlan plan, {
    required String categoryId,
    BookmarkWhitelistScope whitelistScope = BookmarkWhitelistScope.directory,
  }) async {
    final existingUrls = {for (final bookmark in _library.bookmarks) bookmark.url};
    var order = _nextOrderIn(categoryId);
    final added = <Bookmark>[];
    var skipped = 0;

    for (final candidate in plan.candidates) {
      if (existingUrls.contains(candidate.url)) {
        skipped++;
        continue;
      }
      existingUrls.add(candidate.url);
      added.add(Bookmark(
        id: 'b${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${added.length}',
        url: candidate.url,
        title: candidate.title,
        createdAt: DateTime.now(),
        categoryId: categoryId,
        order: order++,
      ));
    }

    var whitelistPattern = '';
    // Nothing was found, so there is nothing to allow: granting a rule here
    // would widen access for a directory the user got no bookmarks from.
    final shouldGrant = plan.candidates.isNotEmpty;
    switch (shouldGrant ? whitelistScope : BookmarkWhitelistScope.none) {
      case BookmarkWhitelistScope.none:
        break;
      case BookmarkWhitelistScope.directory:
        whitelistPattern = BookmarkWhitelist.directoryPattern(plan.rootPath);
        await addRule(PolicyRule(
          pattern: whitelistPattern,
          kind: PolicyListKind.whitelist,
          note: '本地目录导入：${_lastSegment(plan.rootPath)}',
        ));
      case BookmarkWhitelistScope.perFile:
        for (final candidate in added) {
          await addRule(PolicyRule(
            pattern: BookmarkWhitelist.urlPattern(candidate.url),
            kind: PolicyListKind.whitelist,
            note: '本地导入',
          ));
        }
        whitelistPattern = '（每个文件一条规则）';
    }

    if (added.isNotEmpty) {
      _library = BookmarkLibrary(
        categories: _library.categories,
        bookmarks: [..._library.bookmarks, ...added],
      );
      notifyListeners();
      await _persistBookmarks();
    }

    return BookmarkImportOutcome(
      added: added.length,
      skipped: skipped,
      subdirectoryCount: plan.subdirectories.length,
      rootPath: plan.rootPath,
      whitelistPattern: whitelistPattern,
      truncated: plan.truncated,
      targetCategoryId: categoryId,
    );
  }

  static String _lastSegment(String path) {
    final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final parts = trimmed.split('/').where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? trimmed : parts.last;
  }

  // ------------------------------------------------------ parental password

  /// Sets (or replaces) the parent password. Only the salt and the derived
  /// hash are persisted.
  Future<void> setParentalPassword(String password) async {
    final salt = ParentalPassword.newSalt();
    await updateSettings(_settings.copyWith(
      parentalPasswordSalt: salt,
      parentalPasswordHash: ParentalPassword.derive(password, salt),
    ));
  }

  /// Removes the parent password. The gate then asks the parent to set a new
  /// one the next time it is shown.
  Future<void> clearParentalPassword() => updateSettings(_settings.copyWith(
        parentalPasswordHash: '',
        parentalPasswordSalt: '',
      ));

  /// Checks a password attempt against the stored hash.
  bool verifyParentalPassword(String password) => ParentalPassword.verify(
        password: password,
        hash: _settings.parentalPasswordHash,
        salt: _settings.parentalPasswordSalt,
      );

  // ---------------------------------------------------------------- rules

  Future<void> addRule(PolicyRule rule) async {
    final normalized = PatternNormalizer.normalizeRulePattern(rule.pattern);
    if (normalized.isEmpty) return;
    final next = [
      for (final existing in _policy.rules)
        if (PatternNormalizer.normalizeRulePattern(existing.pattern) != normalized ||
            existing.kind != rule.kind)
          existing,
      rule.copyWith(pattern: normalized),
    ];
    await updatePolicy(_policy.copyWith(rules: next));
  }

  Future<void> removeRule(PolicyRule rule) async {
    final next = [
      for (final existing in _policy.rules)
        if (existing.id != rule.id) existing,
    ];
    await updatePolicy(_policy.copyWith(rules: next));
  }

  Future<void> replaceRules(List<PolicyRule> rules) =>
      updatePolicy(_policy.copyWith(rules: rules));

  Future<void> importPolicyText(String text) async {
    final imported = store.importPolicy(text);
    await updatePolicy(imported);
  }

  String exportPolicyText() => store.exportPolicy(_policy);

  // ---------------------------------------------------------- local server

  Future<int?> startLocalServer() async {
    final root = effectiveLocalRoot;
    final existing = _localServer;
    if (existing != null) {
      await existing.stop();
      _localServer = null;
    }
    final server = LocalHttpServer(
      policyProvider: () => _engine,
      rootPath: root,
      port: _settings.localServerPort,
      onEvent: handleNativeEvent,
    );
    final port = await server.start();
    if (port == null) {
      _localServerRunning = false;
      notifyListeners();
      return null;
    }
    _localServer = server;
    if (port != _settings.localServerPort) {
      _settings = _settings.copyWith(localServerPort: port);
      await store.saveSettings(_settings);
    }
    _localServerRunning = true;
    onPolicyChanged?.call(nativePolicyPayload());
    notifyListeners();
    return port;
  }

  Future<void> stopLocalServer() async {
    await _localServer?.stop();
    _localServer = null;
    _localServerRunning = false;
    onPolicyChanged?.call(nativePolicyPayload());
    notifyListeners();
  }

  // ------------------------------------------------------------------ log

  /// Receives events from the native layer and from the local server.
  void handleNativeEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? '';
    if (type == 'requestBlocked' || type == 'navigationBlocked' || type == 'notableDecision') {
      _appendLog(RequestLogEntry.fromNative(event));
    } else if (type == 'localServerStarted' || type == 'localServerStopped') {
      notifyListeners();
    }
  }

  void logDecision(String url, PolicyDecision decision, {String kind = 'navigation'}) {
    _appendLog(RequestLogEntry(
      url: url,
      allowed: decision.allowed,
      reason: decision.reason.name,
      explanation: decision.explanation,
      matched: [for (final m in decision.decisiveRules) m.rule.pattern],
      kind: kind,
    ));
  }

  /// Appends a log entry, coalescing notifications.
  ///
  /// A single page load can produce dozens of blocked-subresource events; each
  /// one rebuilding every listener (including the browser shell) would be
  /// wasteful, so bursts are collapsed into one notification. The entry itself
  /// is recorded immediately — only the rebuild is deferred.
  void _appendLog(RequestLogEntry entry) {
    _log.insert(0, entry);
    if (_log.length > _logLimit) _log.removeRange(_logLimit, _log.length);
    _logNotifyTimer ??= Timer(_logNotifyWindow, () {
      _logNotifyTimer = null;
      notifyListeners();
    });
  }

  void clearLog() {
    _log.clear();
    _logNotifyTimer?.cancel();
    _logNotifyTimer = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _logNotifyTimer?.cancel();
    unawaited(_localServer?.stop());
    super.dispose();
  }
}
