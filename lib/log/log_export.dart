import 'dart:io';

import '../browser/browser_bridge.dart';
import '../state/app_state.dart';

/// Where an exported log file ended up.
class LogExportResult {
  const LogExportResult({required this.file, required this.shared});

  final File file;

  /// True when the file landed in the shared `Download` folder the user can open
  /// from any file manager or over USB; false when only the app's own folder was
  /// writable.
  final bool shared;

  String get path => file.path;

  String get fileName {
    final segments = file.uri.pathSegments;
    return segments.isEmpty ? file.path : segments.last;
  }
}

/// The folder a parent can actually reach: `/sdcard/Download`, but only when
/// all-files access is granted — without it Android happily accepts a write and
/// then hides the file, which is worse than falling back.
Future<Directory?> sharedLogDirectory() async {
  try {
    if (!await BrowserBridge.hasAllFilesAccess()) return null;
    final Directory directory = Directory('/sdcard/Download');
    if (!await directory.exists()) return null;
    return directory;
  } catch (_) {
    return null;
  }
}

/// Writes [text] to `xEduBrowser-log-<时间戳>.txt`.
///
/// Prefers [sharedDirectory] (the user-visible Download folder) and falls back
/// to [fallback]; returns null when neither could be written, so the caller can
/// still show the log on screen instead of pretending it saved something.
Future<LogExportResult?> writeLogFile(
  String text, {
  required Directory fallback,
  Directory? sharedDirectory,
  DateTime? now,
}) async {
  final String name = 'xEduBrowser-log-${_stamp(now ?? DateTime.now())}.txt';
  final List<(Directory, bool)> candidates = <(Directory, bool)>[
    if (sharedDirectory != null) (sharedDirectory, true),
    (fallback, false),
  ];

  for (final (Directory directory, bool shared) in candidates) {
    try {
      await directory.create(recursive: true);
      final File file = File('${directory.path}/$name');
      await file.writeAsString(text, flush: true);
      return LogExportResult(file: file, shared: shared);
    } catch (_) {
      // Try the next location.
    }
  }
  return null;
}

/// Exports everything the app logs, into the best folder available.
Future<LogExportResult?> exportLogs(AppState state, {DateTime? now}) async {
  final Directory? shared = await sharedLogDirectory();
  final LogExportResult? result = await writeLogFile(
    state.exportLogText(now: now),
    fallback: state.store.directory,
    sharedDirectory: shared,
    now: now,
  );
  state.logEvent(
    'log',
    result == null ? '日志导出失败：没有可写入的目录' : '日志已导出：${result.path}',
    level: result == null ? LogLevel.error : LogLevel.info,
  );
  return result;
}

String _stamp(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}${two(time.month)}${two(time.day)}-'
      '${two(time.hour)}${two(time.minute)}${two(time.second)}';
}
