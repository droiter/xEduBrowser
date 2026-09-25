import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../bookmarks/bookmark.dart';
import '../bookmarks/bookmark_import.dart';
import '../files/local_file_url.dart';
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

/// Severity of one diagnostic log line.
enum LogLevel {
  debug('调试'),
  info('信息'),
  warn('警告'),
  error('错误');

  const LogLevel(this.labelZh);

  final String labelZh;
}

/// One line of the diagnostic log.
///
/// The request log answers "why was this address allowed or blocked"; this one
/// answers "what did the app itself do" — page life cycle, bookmark edits,
/// thumbnail captures, load retries. Together they are what a bug report needs,
/// which is why 导出日志 writes both into one file.
class AppLogEntry {
  AppLogEntry(
    this.tag,
    this.message, {
    this.level = LogLevel.info,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  final DateTime time;
  final LogLevel level;

  /// Short area the line came from, e.g. `browser`, `bookmark`, `capture`.
  final String tag;

  final String message;

  String get timeLabel {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        '.${three(time.millisecond)}';
  }

  /// `HH:mm:ss.mmm 信息 [browser] 页面开始加载 …` — one grep-able line.
  String get line => '$timeLabel ${level.labelZh} [$tag] $message';
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

  /// The diagnostic log, newest first. Larger than the request log: a bug report
  /// usually needs the app's own steps, and each line is short.
  final List<AppLogEntry> _appLog = [];
  static const int _appLogLimit = 800;

  /// Home page edit mode: tiles show their action buttons. Kept here (not in the
  /// widget) so it survives the shell rebuilding the start page, and so the log
  /// can record who turned it on.
  bool _homeEditMode = false;

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

  /// Diagnostic log, newest first.
  List<AppLogEntry> get appLog => List.unmodifiable(_appLog);

  /// Whether the home page is in edit mode (tile action buttons visible).
  bool get homeEditMode => _homeEditMode;

  void setHomeEditMode(bool value) {
    if (_homeEditMode == value) return;
    _homeEditMode = value;
    logEvent('home', value ? '进入首页编辑模式' : '退出首页编辑模式');
    notifyListeners();
  }

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
    logEvent(
      'app',
      '配置已加载：书签 ${_library.bookmarks.length} 个、分类 ${_library.categories.length} 个、'
          '白名单 ${_policy.rulesOf(PolicyListKind.whitelist).length} 条、'
          '黑名单 ${_policy.rulesOf(PolicyListKind.blacklist).length} 条',
    );
    // Screenshots whose bookmark is gone would otherwise accumulate forever.
    unawaited(bookmarkStore.pruneOrphanThumbnails(_library.bookmarks));
    if (_settings.localServerEnabled) {
      await startLocalServer();
    }
    await _migrateLocalUrls();
    notifyListeners();
  }

  /// Rewrites stored loopback URLs to the `file://` form the policy matches.
  ///
  /// An older build bookmarked a locally served page as
  /// `http://127.0.0.1:<port>/…` and granted a whitelist rule in that spelling,
  /// while the local server and the native engine both judge such a request as
  /// the `file://` address it stands for. The rule therefore never matched and
  /// the bookmark opened blocked. Existing installs only recover if the stored
  /// data is fixed, so this runs once at startup (and is a no-op afterwards).
  ///
  /// The port is deliberately ignored: the app's own server is the only source
  /// of loopback URLs here, and its port changes between runs whenever 8787 was
  /// taken. This mirrors the assumption `AppState.policyUrl` makes everywhere
  /// else.
  Future<void> _migrateLocalUrls() async {
    final root = effectiveLocalRoot;
    if (root.isEmpty) return;

    var policyChanged = false;
    final rules = <PolicyRule>[];
    final seenRules = <String>{};
    for (final rule in _policy.rules) {
      final pattern = rule.kind == PolicyListKind.whitelist
          ? _loopbackToFilePattern(rule.pattern, root) ?? rule.pattern
          : rule.pattern;
      if (pattern != rule.pattern) policyChanged = true;
      final key = '${rule.kind.wire}\u0000${PatternNormalizer.normalizeRulePattern(pattern)}';
      if (!seenRules.add(key)) {
        // The rewrite collapsed two spellings of the same rule into one.
        policyChanged = true;
        continue;
      }
      rules.add(pattern == rule.pattern ? rule : rule.copyWith(pattern: pattern));
    }

    var bookmarksChanged = false;
    final bookmarks = <Bookmark>[];
    for (final bookmark in _library.bookmarks) {
      final url = mapAnyLoopbackToFileUrl(bookmark.url, root) ?? bookmark.url;
      final patterns = [
        for (final pattern in bookmark.whitelistPatterns)
          _loopbackToFilePattern(pattern, root) ?? pattern,
      ];
      final changed = url != bookmark.url ||
          !listEquals(patterns, bookmark.whitelistPatterns);
      if (changed) bookmarksChanged = true;
      bookmarks.add(changed
          ? bookmark.copyWith(
              url: url,
              whitelistPatterns: patterns,
              clearWhitelistPattern: patterns.isEmpty,
            )
          : bookmark);
    }

    if (bookmarksChanged) {
      _library = BookmarkLibrary(categories: _library.categories, bookmarks: bookmarks);
      await _persistBookmarks();
    }
    if (policyChanged) {
      await updatePolicy(_policy.copyWith(rules: rules));
    }
  }

  /// Maps a whitelist pattern written as a loopback URL onto its file form.
  /// Wildcards are left alone: they are rule language, not an address.
  static String? _loopbackToFilePattern(String pattern, String root) {
    if (pattern.contains('*')) return null;
    if (!pattern.startsWith('http://127.0.0.1') &&
        !pattern.startsWith('http://localhost') &&
        !pattern.startsWith('https://127.0.0.1') &&
        !pattern.startsWith('https://localhost')) {
      return null;
    }
    return mapAnyLoopbackToFileUrl(pattern, root);
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

  /// The form of [url] the policy must judge.
  ///
  /// A page served by the built-in loopback server is evaluated as the
  /// `file://` address it represents — the local HTTP server and the native
  /// engine both map it that way — so bookmarks and whitelist rules are stored
  /// in that same form. A bookmark of a locally served page that kept the
  /// `http://127.0.0.1:<port>/…` spelling granted a rule which never matched
  /// what was actually checked, and the page opened blocked.
  ///
  /// Local paths are canonicalised (percent-encoded) for the same reason: the
  /// WebView reports an encoded address, and the filter compares strings.
  String policyUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty || trimmed.startsWith('about:')) return trimmed;
    final normalized = PatternNormalizer.normalizeUrl(trimmed);
    final mapped = mapLoopbackToFileUrl(normalized, localServerDescriptor(_localServer)) ??
        mapAnyLoopbackToFileUrl(normalized, effectiveLocalRoot);
    final resolved = mapped ?? normalized;
    return resolved.startsWith('file://') ? LocalFileUrl.canonical(resolved) : resolved;
  }

  /// Decides [url] exactly the way the native engine and the local server do.
  PolicyDecision decideUrl(String url) => _engine.decide(policyUrl(url));

  Bookmark? _bookmarkByUrl(String normalizedUrl) {
    for (final bookmark in _library.bookmarks) {
      if (bookmark.url == normalizedUrl) return bookmark;
    }
    return null;
  }

  Bookmark? bookmarkFor(String url) => _bookmarkByUrl(policyUrl(url));

  bool isBookmarked(String url) => bookmarkFor(url) != null;

  String _newBookmarkId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_library.bookmarks.length.toRadixString(36)}';

  /// Adds (or updates) a bookmark.
  ///
  /// By default the bookmark's URL **and the site (or local folder) containing
  /// it** both join the whitelist: the exact address alone is not enough, since
  /// a page pulls its styles, scripts and images from elsewhere on the same
  /// site. Pass [addToWhitelist] to override.
  Future<Bookmark> addBookmark({
    required String url,
    String title = '',
    Uint8List? thumbnail,
    bool? addToWhitelist,
    String categoryId = uncategorizedId,
  }) async {
    final normalizedUrl = policyUrl(url);
    final existing = _bookmarkByUrl(normalizedUrl);
    final id = existing?.id ?? _newBookmarkId();

    var thumbnailPath = existing?.thumbnailPath;
    if (thumbnail != null && thumbnail.isNotEmpty) {
      final written = await bookmarkStore.writeThumbnail(id, thumbnail);
      if (written != null) {
        // Same reason as setBookmarkThumbnail: a new file name, old file gone.
        if (thumbnailPath != null && thumbnailPath != written) {
          await bookmarkStore.deleteThumbnail(thumbnailPath);
        }
        thumbnailPath = written;
      }
    }

    var whitelistPatterns = existing?.whitelistPatterns ?? const <String>[];
    final shouldWhitelist = addToWhitelist ?? _settings.bookmarkWhitelistByDefault;
    if (shouldWhitelist) {
      whitelistPatterns = await _grantWhitelist(normalizedUrl, title);
    }

    final bookmark = Bookmark(
      id: id,
      url: normalizedUrl,
      title: title.trim(),
      thumbnailPath: thumbnailPath,
      createdAt: existing?.createdAt ?? DateTime.now(),
      whitelistPatterns: whitelistPatterns,
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
    logEvent(
      'bookmark',
      '${existing != null ? '更新' : '新增'}书签「${bookmark.displayTitle}」'
          '${whitelistPatterns.isEmpty ? '（未加入白名单）' : '（白名单：${whitelistPatterns.join('、')}）'}',
    );
    return bookmark;
  }

  /// Adds every rule a bookmark grants — its own URL and the site/folder that
  /// contains it — and returns the patterns in grant order.
  Future<List<String>> _grantWhitelist(String url, String title) async {
    final patterns = BookmarkWhitelist.grantPatterns(url);
    final note = '书签：${title.trim().isEmpty ? url : title.trim()}';
    for (final pattern in patterns) {
      if (pattern.isEmpty) continue;
      await addRule(PolicyRule(
        pattern: pattern,
        kind: PolicyListKind.whitelist,
        note: note,
      ));
    }
    return patterns;
  }

  /// Removes a bookmark, and by default the whitelist entries it created.
  ///
  /// A rule is kept when another bookmark still relies on the same pattern, so
  /// deleting one bookmark can never silently revoke access granted for
  /// another.
  Future<void> removeBookmark(
    Bookmark bookmark, {
    bool removeWhitelistRule = true,
  }) =>
      removeBookmarks([bookmark], removeWhitelistRule: removeWhitelistRule);

  /// Removes a batch of bookmarks with a single write.
  ///
  /// Used by the settings list's multi-select delete: the [removeWhitelistRule]
  /// rule and the preview cleanup are exactly those of [removeBookmark], only
  /// done once for the whole selection so a twenty-bookmark delete is not twenty
  /// file writes.
  Future<void> removeBookmarks(
    Iterable<Bookmark> bookmarks, {
    bool removeWhitelistRule = true,
  }) async {
    final ids = {for (final bookmark in bookmarks) bookmark.id};
    if (ids.isEmpty) return;
    final removed = [
      for (final bookmark in _library.bookmarks)
        if (ids.contains(bookmark.id)) bookmark,
    ];
    if (removed.isEmpty) return;

    _library = BookmarkLibrary(
      categories: _library.categories,
      bookmarks: [
        for (final bookmark in _library.bookmarks)
          if (!ids.contains(bookmark.id)) bookmark,
      ],
    );
    await _finishRemoval(removed, removeWhitelistRule: removeWhitelistRule);
  }

  /// Deletes the previews of already-removed bookmarks, drops the whitelist
  /// entries nobody else needs any more, then notifies and persists once.
  Future<void> _finishRemoval(
    List<Bookmark> removed, {
    required bool removeWhitelistRule,
  }) async {
    for (final bookmark in removed) {
      await bookmarkStore.deleteThumbnail(bookmark.thumbnailPath);
    }
    if (removeWhitelistRule) {
      final patterns = {for (final bookmark in removed) ...bookmark.whitelistPatterns};
      for (final pattern in patterns) {
        await _removeWhitelistRuleIfUnused(pattern);
      }
    }
    notifyListeners();
    await _persistBookmarks();
    logEvent(
      'bookmark',
      '删除 ${removed.length} 个书签：${removed.map((b) => b.displayTitle).join('、')}'
          '${removeWhitelistRule ? '（同时清理未再使用的白名单条目）' : '（保留白名单条目）'}',
    );
  }

  /// Renames a bookmark and reconciles the whitelist entries it grants.
  Future<void> editBookmark(
    Bookmark bookmark, {
    required String title,
    required bool grantWhitelist,
  }) async {
    final url = policyUrl(bookmark.url);
    var patterns = bookmark.whitelistPatterns;

    if (grantWhitelist) {
      final wanted = BookmarkWhitelist.grantPatterns(url);
      // Drop a stale rule first, for example one written in the old loopback
      // spelling or a folder scope the user no longer wants.
      for (final stale in patterns.where((p) => !wanted.contains(p))) {
        await _removeWhitelistRuleIfUnused(stale, exceptBookmarkId: bookmark.id);
      }
      patterns = await _grantWhitelist(url, title);
    } else if (patterns.isNotEmpty) {
      for (final stale in patterns) {
        await _removeWhitelistRuleIfUnused(stale, exceptBookmarkId: bookmark.id);
      }
      patterns = const [];
    }

    await updateBookmark(bookmark.copyWith(
      url: url,
      title: title.trim(),
      whitelistPatterns: patterns,
      clearWhitelistPattern: patterns.isEmpty,
    ));
    logEvent(
      'bookmark',
      '修改书签「${title.trim().isEmpty ? bookmark.url : title.trim()}」'
          '${grantWhitelist ? '，白名单：${patterns.join('、')}' : '，未加入白名单'}',
    );
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
      (b) => b.whitelistPatterns.contains(pattern) && b.id != exceptBookmarkId,
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

  /// Replaces a bookmark's screenshot (a fresher capture of the same page).
  ///
  /// The old file is deleted once the new path is in place, so the preview
  /// cache cannot serve the previous image.
  Future<void> setBookmarkThumbnail(Bookmark bookmark, Uint8List bytes) async {
    final previous = bookmark.thumbnailPath;
    final path = await bookmarkStore.writeThumbnail(bookmark.id, bytes);
    if (path == null) {
      logEvent('capture', '预览图写入失败：「${bookmark.displayTitle}」', level: LogLevel.warn);
      return;
    }
    await updateBookmark(bookmark.copyWith(thumbnailPath: path));
    if (previous != null && previous != path) {
      await bookmarkStore.deleteThumbnail(previous);
    }
    logEvent(
      'capture',
      '预览图已更新：「${bookmark.displayTitle}」${bytes.length ~/ 1024} KB'
          '${previous == null ? '（首次）' : '（替换旧图）'}',
    );
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

  /// Deletes a category.
  ///
  /// By default its bookmarks are **not** deleted: they move to 未分类, keeping
  /// their relative order, so a mis-tap never loses data. With
  /// [deleteBookmarks] the category and everything filed under it go together —
  /// what the 分类管理 sheet offers — and the previews and now-unused whitelist
  /// entries of those bookmarks are cleaned up as well.
  Future<void> removeCategory(
    BookmarkCategory category, {
    bool deleteBookmarks = false,
  }) async {
    if (deleteBookmarks) {
      final children = _library.bookmarksIn(category.id);
      _library = BookmarkLibrary(
        categories: [
          for (final existing in _library.categories)
            if (existing.id != category.id) existing,
        ],
        bookmarks: [
          for (final bookmark in _library.bookmarks)
            if (bookmark.categoryId != category.id) bookmark,
        ],
      );
      await _finishRemoval(children, removeWhitelistRule: true);
      logEvent(
        'bookmark',
        '删除分类「${category.name}」及其 ${children.length} 个书签',
        level: children.isEmpty ? LogLevel.info : LogLevel.warn,
      );
      return;
    }

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

  /// Moves several bookmarks into [categoryId] with a single write, appending
  /// them in the order the caller listed them.
  ///
  /// Used by the settings list's multi-select move: the bookmarks keep the order
  /// they had in the list, and every category they left or entered is renumbered
  /// contiguously, exactly like [moveBookmark] does for one bookmark.
  Future<void> moveBookmarksToCategory(
    Iterable<Bookmark> bookmarks, {
    required String categoryId,
  }) async {
    final known = {for (final bookmark in _library.bookmarks) bookmark.id: bookmark};
    final moving = <Bookmark>[];
    final seen = <String>{};
    for (final bookmark in bookmarks) {
      final current = known[bookmark.id];
      if (current == null || !seen.add(current.id)) continue;
      moving.add(current);
    }
    if (moving.isEmpty) return;

    final movingIds = {for (final bookmark in moving) bookmark.id};
    final target = [
      for (final bookmark in _library.bookmarksIn(categoryId))
        if (!movingIds.contains(bookmark.id)) bookmark,
    ];
    final updated = <Bookmark>[
      for (var i = 0; i < target.length; i++) target[i].copyWith(order: i),
      for (var i = 0; i < moving.length; i++)
        moving[i].copyWith(categoryId: categoryId, order: target.length + i),
    ];

    for (final sourceId in {
      for (final bookmark in moving)
        if (bookmark.categoryId != categoryId) bookmark.categoryId,
    }) {
      final rest = [
        for (final bookmark in _library.bookmarksIn(sourceId))
          if (!movingIds.contains(bookmark.id)) bookmark,
      ];
      for (var i = 0; i < rest.length; i++) {
        updated.add(rest[i].copyWith(order: i));
      }
    }

    await _replaceBookmarks(updated);
    logEvent(
      'bookmark',
      '移动 ${moving.length} 个书签到「${categoryLabel(categoryId)}」：'
          '${moving.map((b) => b.displayTitle).join('、')}',
    );
  }

  // ---------------------------------------------------------- display state

  /// Categories whose home-page section is folded shut.
  ///
  /// Pure view state, deliberately not persisted: a restart shows the whole wall
  /// again, and no parent can be confused by a category that "vanished" after an
  /// update.
  final Set<String> _collapsedCategories = <String>{};

  bool isCategoryCollapsed(String categoryId) =>
      _collapsedCategories.contains(categoryId);

  /// Folds a category section shut, or opens it again.
  void toggleCategoryCollapsed(String categoryId) {
    if (!_collapsedCategories.remove(categoryId)) {
      _collapsedCategories.add(categoryId);
    }
    notifyListeners();
  }

  // --------------------------------------------------------------- import

  /// Imports every HTML page found in the **first-level subdirectories** of
  /// [directoryPath] into [categoryId].
  ///
  /// See [BookmarkImporter.scan] for the traversal rules and
  /// [BookmarkWhitelistScope] for what to grant. Pages already bookmarked are
  /// skipped rather than duplicated. [titleSource] picks the bookmark name the
  /// way the add-bookmark dialog's 标题来源 dropdown does; a page whose chosen
  /// source is empty falls back to its file name.
  Future<BookmarkImportOutcome> importBookmarksFromDirectory({
    required String directoryPath,
    required String categoryId,
    BookmarkWhitelistScope whitelistScope = BookmarkWhitelistScope.directory,
    LocalPageTitleSource titleSource = LocalPageTitleSource.internalTitle,
    int maxFiles = BookmarkImporter.defaultMaxFiles,
  }) async {
    final plan = await BookmarkImporter.scan(
      directoryPath,
      localServerBase: _localServer?.baseUrl,
      localServerRoot: effectiveLocalRoot,
      maxFiles: maxFiles,
    );
    return applyImportPlan(
      plan,
      categoryId: categoryId,
      whitelistScope: whitelistScope,
      titleSource: titleSource,
    );
  }

  /// What [applyImportPlan] would do with [plan], without writing anything.
  ///
  /// The import dialog shows this (so the preview can mark the pages that will
  /// be left out) and [applyImportPlan] reuses it, which keeps the two in step.
  ///
  /// A page is left out when its address is already bookmarked, or when the
  /// name the chosen [titleSource] gives it is **already taken** — by a bookmark
  /// in the library, or by an earlier page of the same batch, so a single import
  /// never produces two same-named tiles. Names are compared through
  /// [bookmarkTitleKey]; a `留空` name reserves nothing and never clashes.
  BookmarkImportDecision previewImport(
    BookmarkImportPlan plan, {
    LocalPageTitleSource titleSource = LocalPageTitleSource.internalTitle,
  }) {
    final existingUrls = {for (final bookmark in _library.bookmarks) bookmark.url};
    final takenNames = <String>{
      for (final bookmark in _library.bookmarks)
        if (bookmarkTitleKey(bookmark.title).isNotEmpty)
          bookmarkTitleKey(bookmark.title),
    };

    final additions = <ImportCandidate>[];
    final conflicts = <ImportNameConflict>[];
    var alreadyBookmarked = 0;

    for (final candidate in plan.candidates) {
      final url = policyUrl(candidate.url);
      if (existingUrls.contains(url)) {
        alreadyBookmarked++;
        continue;
      }
      final title = candidate.titleFor(titleSource);
      final key = bookmarkTitleKey(title);
      if (key.isNotEmpty && takenNames.contains(key)) {
        conflicts.add(
          ImportNameConflict(filePath: candidate.filePath, title: title),
        );
        continue;
      }
      existingUrls.add(url);
      if (key.isNotEmpty) takenNames.add(key);
      additions.add(candidate);
    }

    return BookmarkImportDecision(
      additions: additions,
      nameConflicts: conflicts,
      alreadyBookmarked: alreadyBookmarked,
    );
  }

  /// Writes an already-scanned plan. Split out so the UI can show a preview and
  /// confirm before anything changes.
  Future<BookmarkImportOutcome> applyImportPlan(
    BookmarkImportPlan plan, {
    required String categoryId,
    BookmarkWhitelistScope whitelistScope = BookmarkWhitelistScope.directory,
    LocalPageTitleSource titleSource = LocalPageTitleSource.internalTitle,
  }) async {
    final decision = previewImport(plan, titleSource: titleSource);
    var order = _nextOrderIn(categoryId);
    final added = <Bookmark>[];

    for (final candidate in decision.additions) {
      added.add(Bookmark(
        id: 'b${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${added.length}',
        url: policyUrl(candidate.url),
        title: candidate.titleFor(titleSource),
        createdAt: DateTime.now(),
        categoryId: categoryId,
        order: order++,
      ));
    }

    var whitelistPattern = '';
    // Nothing is added, so there is nothing to allow: granting a rule here
    // would widen access for a directory the user got no new bookmarks from.
    // (Pages skipped for a name clash count as "nothing new" too.)
    final shouldGrant = added.isNotEmpty;
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
        for (final bookmark in added) {
          await addRule(PolicyRule(
            pattern: BookmarkWhitelist.urlPattern(bookmark.url),
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

    logEvent(
      'import',
      '导入「${_lastSegment(plan.rootPath)}」：新增 ${added.length} 个'
          '${decision.alreadyBookmarked > 0 ? '，跳过 ${decision.alreadyBookmarked} 个（已存在）' : ''}'
          '${decision.nameConflicts.isNotEmpty ? '，跳过 ${decision.nameConflicts.length} 个（重名）' : ''}'
          '${whitelistPattern.isEmpty ? '' : '，白名单：$whitelistPattern'}',
    );

    return BookmarkImportOutcome(
      added: added.length,
      skipped: decision.alreadyBookmarked,
      subdirectoryCount: plan.subdirectories.length,
      rootPath: plan.rootPath,
      whitelistPattern: whitelistPattern,
      truncated: plan.truncated,
      targetCategoryId: categoryId,
      nameConflicts: decision.nameConflicts,
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
    final normalized = canonicalizeRulePattern(rule.pattern);
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

  /// Canonicalises a rule that is a plain local address.
  ///
  /// `file:///sdcard/课件/` is stored percent-encoded, because that is the URL
  /// the WebView reports and the filter compares strings. A `*` is preserved
  /// (it is allowed in a path); a `?` — wildcard or query separator, it cannot
  /// be told apart — leaves the text untouched. Bookmarks and imports already
  /// write canonical patterns, so this is about hand-typed entries in the rules
  /// screen.
  static String canonicalizeRulePattern(String raw) {
    final normalized = PatternNormalizer.normalizeRulePattern(raw);
    if (normalized.isEmpty || !normalized.startsWith('file://')) return normalized;
    if (normalized.contains('?')) return normalized;
    return PatternNormalizer.normalizeRulePattern(LocalFileUrl.canonical(normalized));
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
      logEvent('server', '本地服务器启动失败（端口 ${_settings.localServerPort} 起都被占用）',
          level: LogLevel.error);
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
    logEvent('server', '本地服务器已启动：http://127.0.0.1:$port/ → $root');
    notifyListeners();
    return port;
  }

  Future<void> stopLocalServer() async {
    await _localServer?.stop();
    _localServer = null;
    _localServerRunning = false;
    onPolicyChanged?.call(nativePolicyPayload());
    logEvent('server', '本地服务器已停止');
    notifyListeners();
  }

  // ------------------------------------------------------------------ log

  /// Receives events from the native layer and from the local server.
  void handleNativeEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? '';
    if (type == 'requestBlocked' || type == 'navigationBlocked' || type == 'notableDecision') {
      _appendLog(RequestLogEntry.fromNative(event));
      if (type == 'navigationBlocked') {
        logEvent(
          'browser',
          '导航被拦截：${event['url'] ?? ''}（${event['explanation'] ?? event['reason'] ?? ''}）',
          level: LogLevel.warn,
        );
      }
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
    _scheduleLogNotify();
  }

  /// Records one diagnostic line. Cheap and safe to call from anywhere: the
  /// rebuild it may trigger is coalesced, and the buffer is bounded.
  void logEvent(String tag, String message, {LogLevel level = LogLevel.info}) {
    _appLog.insert(0, AppLogEntry(tag, message, level: level));
    if (_appLog.length > _appLogLimit) {
      _appLog.removeRange(_appLogLimit, _appLog.length);
    }
    _scheduleLogNotify();
  }

  void _scheduleLogNotify() {
    _logNotifyTimer ??= Timer(_logNotifyWindow, () {
      _logNotifyTimer = null;
      notifyListeners();
    });
  }

  /// Drops the pending coalesced notification once the last listener is gone.
  ///
  /// The entries are already in the buffer and the timer only drives a rebuild,
  /// so with nobody listening there is nothing to rebuild — and a timer left
  /// running past the widget tree that created it is both a small leak and a
  /// "timer still pending" failure in the test binding.
  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (hasListeners) return;
    _logNotifyTimer?.cancel();
    _logNotifyTimer = null;
  }

  void clearLog() {
    _log.clear();
    _logNotifyTimer?.cancel();
    _logNotifyTimer = null;
    notifyListeners();
  }

  void clearAppLog() {
    _appLog.clear();
    _logNotifyTimer?.cancel();
    _logNotifyTimer = null;
    notifyListeners();
  }

  /// Everything the two logs hold, as one text file.
  ///
  /// The header carries the state a support question always starts with
  /// (counts, rules, server, port), then the diagnostic log, then the request
  /// log — the order someone reads them in.
  String exportLogText({DateTime? now}) {
    final stamp = now ?? DateTime.now();
    final buffer = StringBuffer()
      ..writeln('xEduBrowser 日志导出')
      ..writeln('导出时间：${_fullStamp(stamp)}')
      ..writeln('书签：${_library.bookmarks.length} 个；分类：${_library.categories.length} 个')
      ..writeln('白名单规则：${_policy.rulesOf(PolicyListKind.whitelist).length} 条；'
          '黑名单规则：${_policy.rulesOf(PolicyListKind.blacklist).length} 条')
      ..writeln('过滤总开关：${_policy.enabled ? '开启' : '关闭'}；'
          '本地服务器：${_localServerRunning ? '运行中（${_localServer?.baseUrl ?? ''}）' : '未运行'}')
      ..writeln('家长密码：${_settings.hasParentalPassword ? '已设置' : '未设置'}；'
          '家长验证：${_settings.parentalGateEnabled ? '开启' : '关闭'}')
      ..writeln()
      ..writeln('===== 诊断日志（最新在最前，共 ${_appLog.length} 条）=====');
    if (_appLog.isEmpty) {
      buffer.writeln('（无）');
    } else {
      for (final entry in _appLog) {
        buffer.writeln('${_fullStamp(entry.time)} ${entry.level.labelZh} '
            '[${entry.tag}] ${entry.message}');
      }
    }
    buffer
      ..writeln()
      ..writeln('===== 请求日志（最新在最前，共 ${_log.length} 条）=====');
    if (_log.isEmpty) {
      buffer.writeln('（无）');
    } else {
      for (final entry in _log) {
        buffer.writeln('${_fullStamp(entry.time)} ${entry.allowed ? '允许' : '拒绝'} '
            '[${entry.kind}] ${entry.url}');
        buffer.writeln('    原因：${entry.reason}'
            '${entry.explanation.isEmpty ? '' : '（${entry.explanation}）'}');
        if (entry.matched.isNotEmpty) {
          buffer.writeln('    命中规则：${entry.matched.join('、')}');
        }
      }
    }
    return buffer.toString();
  }

  static String _fullStamp(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        '.${three(time.millisecond)}';
  }

  @override
  void dispose() {
    _logNotifyTimer?.cancel();
    unawaited(_localServer?.stop());
    super.dispose();
  }
}
