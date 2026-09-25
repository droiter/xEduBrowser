import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/log/log_export.dart';
import 'package:tablet_browser/log/request_log_screen.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// 日志：诊断日志与请求日志写进同一个文件，并且「导出日志到文件」按钮真的把
/// 文件写出来。
void main() {
  late Directory directory;
  late Directory exportDir;
  late AppState state;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tb_log_app');
    exportDir = Directory.systemTemp.createTempSync('tb_log_out');
    state = AppState(
      store: ConfigStore(directory),
      settings: AppSettings(
        localServerEnabled: false,
        localServerRoot: directory.path,
        parentalGateEnabled: false,
      ),
    );

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // No native layer: no all-files access, so the export falls back to the
    // app's own directory, which in a test is a temp folder we can inspect.
    messenger.setMockMethodCallHandler(
      const MethodChannel('tablet_browser/commands'),
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('tablet_browser/events'),
      (call) async => null,
    );
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('tablet_browser/commands'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('tablet_browser/events'),
      null,
    );
    for (final dir in [directory, exportDir]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  group('the diagnostic log', () {
    test('keeps the newest first and tags every line', () {
      state.logEvent('browser', '第一行');
      state.logEvent('capture', '第二行', level: LogLevel.warn);

      expect(state.appLog.map((e) => e.message), ['第二行', '第一行']);
      expect(state.appLog.first.level, LogLevel.warn);
      expect(state.appLog.first.tag, 'capture');
      expect(state.appLog.first.line, contains('[capture] 第二行'));
      expect(state.appLog.first.line, contains('警告'));
    });

    test('export text carries the header and both logs', () {
      state.logEvent('browser', '一条诊断记录');
      state.logDecision(
        'https://school.test/lessons',
        state.engine.decide('https://school.test/lessons'),
      );

      final text = state.exportLogText(now: DateTime(2026, 9, 25, 14, 30, 5, 7));
      expect(text, contains('xEduBrowser 日志导出'));
      expect(text, contains('导出时间：2026-09-25 14:30:05.007'));
      expect(text, contains('白名单规则：'));
      expect(text, contains('===== 诊断日志'));
      expect(text, contains('[browser] 一条诊断记录'));
      expect(text, contains('===== 请求日志'));
      expect(text, contains('https://school.test/lessons'));
    });

    test('clearAppLog empties only the diagnostic log', () {
      state.logEvent('app', '诊断');
      state.logDecision(
        'https://a.test/',
        state.engine.decide('https://a.test/'),
      );

      state.clearAppLog();
      expect(state.appLog, isEmpty);
      expect(state.log, isNotEmpty);
    });
  });

  group('writing the log file', () {
    test('prefers the shared folder and names the file with a timestamp', () async {
      final result = await writeLogFile(
        '内容',
        fallback: directory,
        sharedDirectory: exportDir,
        now: DateTime(2026, 9, 25, 14, 30, 5),
      );

      expect(result, isNotNull);
      expect(result!.shared, isTrue);
      expect(result.fileName, 'xEduBrowser-log-20260925-143005.txt');
      expect(result.file.parent.path, exportDir.path);
      expect(result.file.readAsStringSync(), '内容');
      expect(File('${directory.path}/${result.fileName}').existsSync(), isFalse);
    });

    test('falls back to the app folder when nothing shared is writable', () async {
      final result = await writeLogFile(
        '内容',
        fallback: directory,
        now: DateTime(2026, 9, 25, 14, 30, 5),
      );

      expect(result, isNotNull);
      expect(result!.shared, isFalse);
      expect(result.file.parent.path, directory.path);
      expect(result.file.readAsStringSync(), '内容');
    });
  });

  testWidgets('the log screen shows diagnostics and exports them to a file', (
    tester,
  ) async {
    state.logEvent('browser', '这是一条诊断记录');
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: AppTheme.light,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const RequestLogScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The diagnostic tab is the one shown first.
    expect(find.text('诊断日志'), findsWidgets);
    expect(find.text('这是一条诊断记录'), findsOneWidget);

    await tester.tap(find.byKey(exportLogButtonKey));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }

    expect(find.byKey(logExportDialogKey), findsOneWidget);
    expect(find.text('日志已导出'), findsOneWidget);

    final written = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('xEduBrowser-log-'))
        .toList();
    expect(written, hasLength(1), reason: '导出应写下一个日志文件');
    final text = written.single.readAsStringSync();
    expect(text, contains('这是一条诊断记录'));
    expect(text, contains('xEduBrowser 日志导出'));

    // The path is shown so it can be copied out of the dialog.
    expect(find.textContaining('xEduBrowser-log-'), findsWidgets);
  });
}
