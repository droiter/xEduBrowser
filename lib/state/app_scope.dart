import 'package:flutter/widgets.dart';

import 'app_state.dart';

/// Makes the single [AppState] available to every screen.
///
/// Screens are opened with plain `Navigator.push(MaterialPageRoute(builder: (_) => const SomeScreen()))`
/// and read state through `AppScope.of(context)`, so no screen needs
/// constructor plumbing.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing above this widget');
    return scope!.notifier!;
  }

  /// Reads the state without subscribing to rebuilds.
  static AppState read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing above this widget');
    return scope!.notifier!;
  }
}
