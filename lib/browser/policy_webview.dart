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
class PolicyWebView extends StatelessWidget {
  const PolicyWebView({
    super.key,
    required this.viewId,
    required this.settings,
    required this.policy,
    this.onCreated,
  });

  final int viewId;

  /// WebView settings; see [AppSettings.toNativeSettings].
  final Map<String, dynamic> settings;

  /// The policy snapshot, including the `localServer` loopback mapping.
  final Map<String, dynamic> policy;

  final ValueChanged<int>? onCreated;

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
            'viewId': viewId,
            'settings': settings,
            'policy': policy,
          },
          creationParamsCodec: const StandardMessageCodec(),
        );
        controller.addOnPlatformViewCreatedListener((id) {
          params.onPlatformViewCreated(id);
          onCreated?.call(id);
        });
        controller.create();
        return controller;
      },
    );
  }
}

/// Owns the lifecycle of one browser tab's platform view.
class BrowserViewController extends ChangeNotifier {
  BrowserViewController({required this.viewId});

  final int viewId;
  bool _created = false;

  /// A navigation requested before the native view existed. Loading eagerly
  /// would be dropped by the native side, because it has no view with this id
  /// yet, so it is replayed once the view reports itself created.
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

  Future<void> loadUrl(String url) async {
    if (url == 'about:home') return;
    if (!_created) {
      _pendingUrl = url;
      return;
    }
    await BrowserBridge.loadUrl(viewId, url);
  }

  Future<void> goBack() => BrowserBridge.goBack(viewId);

  Future<void> goForward() => BrowserBridge.goForward(viewId);

  Future<void> reload() => BrowserBridge.reload(viewId);

  Future<void> stop() => BrowserBridge.stopLoading(viewId);

  Future<void> openSettings(Map<String, dynamic> settings) =>
      BrowserBridge.updateSettings(viewId, settings);
}
