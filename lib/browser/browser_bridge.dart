import 'dart:async';

import 'package:flutter/services.dart';

/// The Dart side of the native channel contract described in
/// `docs/CONTRACT.md`. Nothing else in the app talks to the channels directly.
abstract final class BrowserBridge {
  static const String viewType = 'tablet_browser/webview';
  static const MethodChannel _commands = MethodChannel('tablet_browser/commands');
  static const EventChannel _events = EventChannel('tablet_browser/events');

  /// All page and filtering events from every WebView, tagged with `viewId`.
  ///
  /// The stream is created once and shared: `receiveBroadcastStream()` installs
  /// a single method-call handler per channel, so a second call would steal the
  /// first subscriber's events. The browser shell and the bookmark preview both
  /// listen, each filtering on its own `viewId`.
  static Stream<Map<String, dynamic>>? _eventStream;

  static Stream<Map<String, dynamic>> eventStream() => _eventStream ??= _events
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));

  /// Invokes a native command.
  ///
  /// The result is deliberately untyped: the contract mixes map-returning
  /// commands (`loadUrl`, `setPolicy`, ...) with scalar-returning ones
  /// (`canGoBack` → bool, `currentUrl` → String). Casting everything to a Map
  /// would throw for the scalar methods.
  static Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _commands.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // A non-Android host (desktop preview, tests) has no native layer.
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<void> loadUrl(int viewId, String url) =>
      _invoke<void>('loadUrl', {'viewId': viewId, 'url': url});

  static Future<void> goBack(int viewId) => _invoke<void>('goBack', {'viewId': viewId});

  static Future<void> goForward(int viewId) =>
      _invoke<void>('goForward', {'viewId': viewId});

  static Future<void> reload(int viewId) => _invoke<void>('reload', {'viewId': viewId});

  static Future<void> stopLoading(int viewId) =>
      _invoke<void>('stopLoading', {'viewId': viewId});

  static Future<bool> canGoBack(int viewId) async =>
      await _invoke<bool>('canGoBack', {'viewId': viewId}) ?? false;

  static Future<bool> canGoForward(int viewId) async =>
      await _invoke<bool>('canGoForward', {'viewId': viewId}) ?? false;

  static Future<String?> currentUrl(int viewId) =>
      _invoke<String>('currentUrl', {'viewId': viewId});

  static Future<String?> pageTitle(int viewId) =>
      _invoke<String>('pageTitle', {'viewId': viewId});

  static Future<String?> userAgent(int viewId) =>
      _invoke<String>('userAgent', {'viewId': viewId});

  static Future<String?> evaluateJavascript(int viewId, String script) =>
      _invoke<String>('evaluateJavascript', {'viewId': viewId, 'script': script});

  /// Screenshots the page for a bookmark tile.
  ///
  /// Returns PNG bytes, or null when the native side could not capture (view
  /// gone, blank frame, not implemented yet). Callers must treat null as
  /// "fall back to the generated tile", never as an error.
  static Future<Uint8List?> captureThumbnail(int viewId, {int maxWidth = 320}) =>
      _invoke<Uint8List>('captureThumbnail', {'viewId': viewId, 'maxWidth': maxWidth});

  /// Pushes the whole policy (including the loopback mapping) to the native
  /// engine. Called on every policy change and after the local server starts.
  static Future<void> setPolicy(Map<String, dynamic> policy) =>
      _invoke<void>('setPolicy', {'policy': policy});

  static Future<void> updateSettings(int viewId, Map<String, dynamic> settings) =>
      _invoke<void>('updateSettings', {'viewId': viewId, 'settings': settings});

  static Future<void> disposeView(int viewId) =>
      _invoke<void>('disposeView', {'viewId': viewId});

  static Future<void> clearCache() => _invoke<void>('clearCache');

  static Future<void> clearCookies() => _invoke<void>('clearCookies');

  static Future<void> clearHistory() => _invoke<void>('clearHistory');

  static Future<void> openManageStorageSettings() =>
      _invoke<void>('openManageStorageSettings');

  /// True when the app may actually list `/sdcard`. Without all-files access
  /// Android returns an *empty* listing instead of throwing, so the UI cannot
  /// tell "empty folder" from "not allowed" without asking this.
  static Future<bool> hasAllFilesAccess() async =>
      await _invoke<bool>('hasAllFilesAccess') ?? false;
}

/// A normalised view of a native event, so the UI never digs into raw maps.
class BrowserEvent {
  final String type;
  final int viewId;
  final String url;
  final String title;
  final int progress;
  final bool allowed;
  final String reason;
  final String explanation;
  final List<String> matched;
  final bool canGoBack;
  final bool canGoForward;
  final String message;
  final int errorCode;
  final Map<String, dynamic> raw;

  const BrowserEvent({
    required this.type,
    required this.viewId,
    this.url = '',
    this.title = '',
    this.progress = 0,
    this.allowed = true,
    this.reason = '',
    this.explanation = '',
    this.matched = const [],
    this.canGoBack = false,
    this.canGoForward = false,
    this.message = '',
    this.errorCode = 0,
    this.raw = const {},
  });

  factory BrowserEvent.fromMap(Map<String, dynamic> map) => BrowserEvent(
        type: map['type'] as String? ?? '',
        viewId: (map['viewId'] as num?)?.toInt() ?? 0,
        url: map['url'] as String? ?? '',
        title: map['title'] as String? ?? '',
        progress: (map['progress'] as num?)?.toInt() ?? 0,
        allowed: map['allowed'] as bool? ?? true,
        reason: map['reason'] as String? ?? '',
        explanation: map['explanation'] as String? ?? '',
        matched: [for (final m in (map['matched'] as List? ?? const [])) '$m'],
        canGoBack: map['canGoBack'] as bool? ?? false,
        canGoForward: map['canGoForward'] as bool? ?? false,
        message: map['message'] as String? ?? map['description'] as String? ?? '',
        errorCode: (map['code'] as num?)?.toInt() ?? 0,
        raw: map,
      );
}
