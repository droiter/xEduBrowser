import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/local_server/local_http_server.dart';
import 'package:tablet_browser/policy/policy_config.dart';
import 'package:tablet_browser/policy/policy_engine.dart';

/// Exercises the loopback server: it must serve local dynamic pages, refuse
/// traversal, and apply exactly the same policy as online browsing.
void main() {
  late Directory root;
  late PolicyEngine engine;
  late LocalHttpServer server;
  final events = <Map<String, dynamic>>[];

  /// A client that ignores the container's HTTP proxy environment, which would
  /// otherwise swallow loopback requests.
  HttpClient directClient() => HttpClient()..findProxy = (uri) => 'DIRECT';

  Future<({int status, String body, String? contentType})> get(String path) async {
    final client = directClient();
    try {
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}$path'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return (
        status: response.statusCode,
        body: body,
        contentType: response.headers.contentType?.mimeType,
      );
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tablet_browser_test');
    File('${root.path}/index.html').writeAsStringSync('<h1>索引</h1>');
    File('${root.path}/app.js').writeAsStringSync('export const x = 1;');
    File('${root.path}/data.json').writeAsStringSync('{"a":1}');
    Directory('${root.path}/sub').createSync();
    File('${root.path}/sub/page.html').writeAsStringSync('<p>子页面</p>');
    Directory('${root.path}/nolisting').createSync();
    File('${root.path}/nolisting/a.txt').writeAsStringSync('A');

    engine = PolicyEngine(PolicyConfig.empty);
    events.clear();
    server = LocalHttpServer(
      policyProvider: () => engine,
      rootPath: root.path,
      port: 0,
      onEvent: events.add,
    );
  });

  tearDown(() async {
    await server.stop();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('binds a free port and reports its base URL', () async {
    final port = await server.start();
    expect(port, isNotNull);
    expect(port, greaterThan(0));
    expect(server.isRunning, isTrue);
    expect(server.baseUrl, 'http://127.0.0.1:$port');
    expect(events.any((e) => e['type'] == 'localServerStarted'), isTrue);
  });

  test('serves index.html for the root', () async {
    await server.start();
    final response = await get('/');
    expect(response.status, 200);
    expect(response.body, contains('索引'));
    expect(response.contentType, 'text/html');
  });

  test('serves a file with a correct module MIME type', () async {
    await server.start();
    final response = await get('/app.js');
    expect(response.status, 200);
    expect(response.contentType, 'text/javascript');
  });

  test('serves JSON', () async {
    await server.start();
    final response = await get('/data.json');
    expect(response.status, 200);
    expect(response.contentType, 'application/json');
  });

  test('lists a directory that has no index.html', () async {
    await server.start();
    final response = await get('/nolisting/');
    expect(response.status, 200);
    expect(response.body, contains('a.txt'));
  });

  test('returns 404 for a missing file', () async {
    await server.start();
    final response = await get('/missing.html');
    expect(response.status, 404);
  });

  test('refuses path traversal outside the root', () async {
    await server.start();
    final response = await get('/../../etc/passwd');
    expect(response.status, anyOf(403, 404));
    expect(response.body, isNot(contains('root:')));
  });

  test('applies the policy to served files', () async {
    await server.start();
    // A blacklist rule naming a real path under this temporary root.
    engine = PolicyEngine(PolicyConfig(
      rules: [
        PolicyRule(
          pattern: 'file://${root.path}/sub/',
          kind: PolicyListKind.blacklist,
        ),
      ],
    ));

    expect(engine.decide('file://${root.path}/sub/page.html').allowed, isFalse);

    final blocked = await get('/sub/page.html');
    expect(blocked.status, 403);
    expect(blocked.body, contains('已拦截'));

    // A sibling file is unaffected.
    final allowed = await get('/index.html');
    expect(allowed.status, 200);

    expect(events.any((e) => e['type'] == 'requestBlocked'), isTrue);
  });

  test('whitelist mode denies everything not listed', () async {
    await server.start();
    engine = PolicyEngine(PolicyConfig(
      rules: [
        PolicyRule(pattern: 'file://${root.path}/sub/', kind: PolicyListKind.whitelist),
      ],
    ));

    final denied = await get('/index.html');
    expect(denied.status, 403);

    final allowed = await get('/sub/page.html');
    expect(allowed.status, 200);
  });

  test('maps a loopback URL back to the file URL it represents', () async {
    await server.start();
    expect(
      server.fileUrlFor('http://127.0.0.1:${server.port}/sub/page.html'),
      'file://${root.path}/sub/page.html',
    );
    expect(
      server.fileUrlFor('http://127.0.0.1:${server.port}/a.html?x=1'),
      'file://${root.path}/a.html?x=1',
    );
    expect(server.fileUrlFor('http://127.0.0.1:${server.port + 1}/a.html'), isNull);
    expect(server.fileUrlFor('https://example.com/a.html'), isNull);
  });

  test('the shared loopback mapping helper agrees with the server', () async {
    await server.start();
    final descriptor = localServerDescriptor(server);
    expect(
      mapLoopbackToFileUrl('http://127.0.0.1:${server.port}/x/y.html', descriptor),
      'file://${root.path}/x/y.html',
    );
    expect(mapLoopbackToFileUrl('https://example.com/', descriptor), isNull);
    expect(
      mapLoopbackToFileUrl('http://127.0.0.1:${server.port}/a', {'port': -1, 'rootPath': ''}),
      isNull,
    );
  });

  test('stop() releases the port', () async {
    final port = await server.start();
    await server.stop();
    expect(server.isRunning, isFalse);
    // The port is free again: binding it must succeed.
    final rebind = await ServerSocket.bind(InternetAddress.loopbackIPv4, port!);
    await rebind.close();
  });
}
