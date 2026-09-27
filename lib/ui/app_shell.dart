import 'package:flutter/material.dart';

import '../bookmarks/thumbnail_backfill.dart';
import '../state/app_scope.dart';

/// The frame every screen lives in.
///
/// It exists for one reason: the background thumbnail pass needs a WebView
/// mounted somewhere, and that view must never be in the child's way. So the
/// shell watches what the app is doing — is it in front, has the child just
/// touched the screen — and mounts [ThumbnailCaptureHost] (which parks itself
/// outside the window) only while [ThumbnailBackfill] asks for it.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  ThumbnailBackfill? _backfill;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final backfill = AppScope.read(context).thumbnailBackfill;
    if (identical(backfill, _backfill)) return;
    _backfill?.removeListener(_onBackfillChanged);
    _backfill = backfill..addListener(_onBackfillChanged);
    backfill.setForeground(
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused,
    );
    backfill.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backfill?.removeListener(_onBackfillChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Nothing is captured while the app is not in front: a background WebView
    // load would compete with whatever the child switched to.
    _backfill?.setForeground(state == AppLifecycleState.resumed);
  }

  void _onBackfillChanged() {
    if (mounted) setState(() {});
  }

  void _noteActivity(PointerEvent _) => _backfill?.noteUserActivity();

  @override
  Widget build(BuildContext context) {
    final request = _backfill?.request;
    return Listener(
      // Observing only: the events still reach whatever is underneath.
      behavior: HitTestBehavior.translucent,
      onPointerDown: _noteActivity,
      onPointerMove: _noteActivity,
      child: Stack(
        children: <Widget>[
          widget.child,
          if (request != null)
            ThumbnailCaptureHost(
              // Keyed by view id so a new capture always gets a new view (and the
              // old one is disposed with its native WebView).
              key: ValueKey<int>(request.viewId),
              request: request,
              onDone: (bytes) => _backfill?.complete(bytes),
            ),
        ],
      ),
    );
  }
}
