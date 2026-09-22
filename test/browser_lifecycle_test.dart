import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/browser/policy_webview.dart';

/// The platform view of a tab only exists while a page is displayed (the start
/// page and the block panel replace it, destroying the native WebView). A
/// navigation sent while there is no view is silently dropped by the native
/// side, which is what left tabs blank; it must be queued and replayed instead.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  const channel = MethodChannel('tablet_browser/commands');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Lets the unawaited replay reach the mock channel.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

  List<String> methods() => [for (final call in calls) call.method];

  String urlOf(MethodCall call) =>
      (call.arguments as Map<Object?, Object?>)['url'] as String;

  test('a navigation before the view exists is queued and replayed', () async {
    final controller = BrowserViewController(viewId: 3);

    await controller.loadUrl('https://a.test/x');
    expect(calls, isEmpty, reason: '视图还不存在，此刻发送会被丢弃');

    controller.markCreated();
    await settle();
    expect(methods(), ['loadUrl']);
    expect(urlOf(calls.single), 'https://a.test/x');
  });

  test('a navigation after the view went away is queued, not dropped', () async {
    final controller = BrowserViewController(viewId: 4);
    controller.markCreated();
    await controller.loadUrl('https://a.test/first');
    expect(methods(), ['loadUrl']);

    // Going back to the start page disposes the platform view.
    controller.markDisposed();
    await controller.loadUrl('https://a.test/second');
    expect(calls.length, 1, reason: '视图已销毁，不能直接发');

    controller.markCreated();
    await settle();
    expect(methods(), ['loadUrl', 'loadUrl']);
    expect(urlOf(calls.last), 'https://a.test/second');
  });

  test('refresh re-loads the URL when the view is gone', () async {
    final controller = BrowserViewController(viewId: 5);
    controller.markCreated();

    await controller.reloadOrLoad('https://a.test/page');
    expect(methods(), ['reload']);

    controller.markDisposed();
    await controller.reloadOrLoad('https://a.test/page');
    expect(methods(), ['reload'], reason: '视图没了，reload 同样是空操作');

    controller.markCreated();
    await settle();
    expect(methods(), ['reload', 'loadUrl']);
    expect(urlOf(calls.last), 'https://a.test/page');
  });

  test('the last queued navigation wins', () async {
    final controller = BrowserViewController(viewId: 6);
    await controller.loadUrl('https://a.test/first');
    await controller.loadUrl('https://a.test/second');

    controller.markCreated();
    await settle();
    expect(calls.length, 1);
    expect(urlOf(calls.single), 'https://a.test/second');
  });
}
