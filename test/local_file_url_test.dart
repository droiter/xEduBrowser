import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/files/local_file_url.dart';

/// Canonical local URLs: the filter compares strings, so these have to be
/// exactly what the WebView loads and reports.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tb_fileurl');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('canonicalises spaces and non-ASCII names, and is idempotent', () {
    final url = LocalFileUrl.canonical('${root.path}/课件/第 1 课.html');

    expect(url, contains('%E8%AF%BE%E4%BB%B6'));
    expect(url, contains('%E7%AC%AC%201%20%E8%AF%BE.html'));
    expect(LocalFileUrl.canonical(url), url, reason: '再次规范化应保持不变');
    expect(LocalFileUrl.pathOf(url), '${root.path}/课件/第 1 课.html');
  });

  test('keeps a query string', () {
    expect(
      LocalFileUrl.canonical('file:///sdcard/a.html?page=3'),
      'file:///sdcard/a.html?page=3',
    );
    // A literal % in a real file name survives.
    expect(LocalFileUrl.pathOf(LocalFileUrl.canonical('/sdcard/a%b.html')),
        '/sdcard/a%b.html');
  });

  test('a directory pattern ends with a slash', () {
    expect(LocalFileUrl.directoryPattern('/sdcard/课件/'),
        'file:///sdcard/%E8%AF%BE%E4%BB%B6/');
    expect(LocalFileUrl.directoryPattern('/sdcard/课件'),
        'file:///sdcard/%E8%AF%BE%E4%BB%B6/');
  });

  test('recognises directories and finds their index.html', () {
    Directory('${root.path}/book').createSync();
    File('${root.path}/book/index.html').writeAsStringSync('<h1>ok</h1>');
    Directory('${root.path}/empty').createSync();
    File('${root.path}/page.html').writeAsStringSync('<h1>page</h1>');

    final book = LocalFileUrl.canonical('${root.path}/book/');
    expect(LocalFileUrl.isDirectory(book), isTrue);
    expect(LocalFileUrl.indexHtmlFor(book),
        LocalFileUrl.canonical('${root.path}/book/index.html'));

    final empty = LocalFileUrl.canonical('${root.path}/empty/');
    expect(LocalFileUrl.isDirectory(empty), isTrue);
    expect(LocalFileUrl.indexHtmlFor(empty), isNull);

    // A plain file is not a directory, and has no index either.
    final page = LocalFileUrl.canonical('${root.path}/page.html');
    expect(LocalFileUrl.isDirectory(page), isFalse);
    expect(LocalFileUrl.indexHtmlFor(page), isNull);
  });
}
