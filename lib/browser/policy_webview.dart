import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'browser_bridge.dart';

/// Hosts one native policy-aware WebView.
///
/// The platform view itself is created by `PolicyWebViewFactory` on the Android
/// side; Dart only supplies the creation parameters (settings + the current
/// policy snapshot) and the Flutter-side surface.
///
/// The widget is only mounted while the tab is actually showing a page: the
/// start page and the block panel replace it, which **destroys the native
/// WebView**. [onDisposed] reports that, so the owning
/// [BrowserViewController] stops believing the view is there and queues the
/// next navigation instead of sending it to a dead view (a load sent to a
/// disposed view is silently dropped and leaves a blank page).
class PolicyWebView extends StatefulWidget {
  const PolicyWebView({
    super.key,
    required this.viewId,
    required this.settings,
    required this.policy,
    this.onCreated,
    this.onDisposed,
  });

  final int viewId;

  /// WebView settings; see [AppSettings.toNativeSettings].
  final Map<String, dynamic> settings;

  /// The policy snapshot, including the `localServer` loopback mapping.
  final Map<String, dynamic> policy;

  final ValueChanged<int>? onCreated;

  /// Called when this widget leaves the tree, i.e. when the native view is
  /// being destroyed.
  final VoidCallback? onDisposed;

  @override
  State<PolicyWebView> createState() => _PolicyWebViewState();
}

class _PolicyWebViewState extends State<PolicyWebView> {
  @override
  void dispose() {
    widget.onDisposed?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: BrowserBridge.viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initSurfaceAndroidView(
          id: params.id,
          viewType: BrowserBridge.viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: <String, dynamic>{
            'viewId': widget.viewId,
            'settings': widget.settings,
            'policy': widget.policy,
          },
          creationParamsCodec: const StandardMessageCodec(),
        );
        controller.addOnPlatformViewCreatedListener((id) {
          params.onPlatformViewCreated(id);
          widget.onCreated?.call(id);
        });
        controller.create();
        return controller;
      },
    );
  }
}

/// Owns the lifecycle of one browser tab's platform view.
///
/// The native view only exists while a page is displayed; [markCreated] and
/// [markDisposed] follow the widget, and a navigation requested while there is
/// no view is queued and replayed once one exists. Loading eagerly would be
/// dropped by the native side, which has no live view with this id at that
/// moment, and the tab would sit blank.
class BrowserViewController extends ChangeNotifier {
  BrowserViewController({required this.viewId});

  final int viewId;
  bool _created = false;

  /// A navigation requested before the native view existed, replayed once the
  /// view reports itself created.
  String? _pendingUrl;

  bool get isCreated => _created;

  void markCreated() {
    if (_created) return;
    _created = true;
    final pending = _pendingUrl;
    _pendingUrl = null;
    if (pending != null) {
      unawaited(BrowserBridge.loadUrl(viewId, pending));
    }
    notifyListeners();
  }

  /// The widget (and with it the native view) went away: the next navigation
  /// must be queued again instead of being sent into the void.
  void markDisposed() {
    if (!_created) return;
    _created = false;
    notifyListeners();
  }

  Future<void> loadUrl(String url) async {
    if (url == 'about:home') return;
    if (!_created) {
      _pendingUrl = url;
      return;
    }
    await BrowserBridge.loadUrl(viewId, url);
  }

  /// Reloads the displayed page, or re-loads [url] when the view is gone.
  ///
  /// A plain reload against a disposed view is dropped, which is what made a
  /// blank tab impossible to recover with the toolbar's refresh button.
  Future<void> reloadOrLoad(String url) async {
    if (!_created) return loadUrl(url);
    await reload();
  }

  Future<void> goBack() => BrowserBridge.goBack(viewId);

  Future<void> goForward() => BrowserBridge.goForward(viewId);

  Future<void> reload() => BrowserBridge.reload(viewId);

  Future<void> stop() => BrowserBridge.stopLoading(viewId);

  Future<void> openSettings(Map<String, dynamic> settings) =>
      BrowserBridge.updateSettings(viewId, settings);
}
