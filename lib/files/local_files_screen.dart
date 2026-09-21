import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_scope.dart';
import '../ui/theme.dart';

/// 与原生通信的通道（由浏览器外壳实现），用于打开系统的存储权限页面。
const MethodChannel _commands = MethodChannel('tablet_browser/commands');

/// 本地文件浏览器。
///
/// 默认从应用文档目录开始，可跳转到 `/sdcard` 等公共目录。
/// 点击文件时通过 `Navigator.pop(context, url)` 返回该文件的 `file://` 网址，
/// 因此调用方必须按 `Future<String?>` 接收返回值；点击目录则进入该目录。
class LocalFilesScreen extends StatefulWidget {
  const LocalFilesScreen({super.key, this.pickDirectory = false, this.startPath});

  /// 选择目录模式：目录行右侧出现“选择”按钮，返回目录的 `file://` 网址。
  /// 此时点击文件不会返回，只给出提示。
  final bool pickDirectory;

  /// 起始目录，默认为应用文档目录。
  final String? startPath;

  @override
  State<LocalFilesScreen> createState() => _LocalFilesScreenState();
}

class _LocalFilesScreenState extends State<LocalFilesScreen> {
  static const int _maxEntries = 500;

  String? _path;
  List<FileSystemEntity> _entries = const <FileSystemEntity>[];
  List<FileSystemEntity> _directories = const <FileSystemEntity>[];
  List<FileSystemEntity> _files = const <FileSystemEntity>[];
  String? _error;
  bool _truncated = false;
  bool _storageReadable = true;

  @override
  void initState() {
    super.initState();
    _checkStorageAccess();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_path == null) {
      final state = AppScope.read(context);
      _load(widget.startPath ?? state.store.directory.path, notify: false);
    }
  }

  /// 检查 /sdcard 是否可读，用于给出“所有文件访问权限”的提示。
  Future<void> _checkStorageAccess() async {
    bool readable = false;
    try {
      final Directory dir = Directory('/sdcard');
      if (await dir.exists()) {
        await for (final FileSystemEntity _ in dir.list(followLinks: false)) {
          readable = true;
          break;
        }
      }
    } catch (_) {
      readable = false;
    }
    if (mounted) setState(() => _storageReadable = readable);
  }

  void _load(String path, {bool notify = true}) {
    List<FileSystemEntity> entries = const <FileSystemEntity>[];
    String? error;
    bool truncated = false;
    try {
      final Directory dir = Directory(path);
      if (!dir.existsSync()) {
        error = '目录不存在：$path';
      } else {
        final List<FileSystemEntity> all = dir.listSync(followLinks: false);
        all.sort((FileSystemEntity a, FileSystemEntity b) {
          final bool aDir = a is Directory;
          final bool bDir = b is Directory;
          if (aDir != bDir) return aDir ? -1 : 1;
          return _basename(a.path).toLowerCase().compareTo(_basename(b.path).toLowerCase());
        });
        if (all.length > _maxEntries) {
          truncated = true;
          entries = all.sublist(0, _maxEntries);
        } else {
          entries = all;
        }
      }
    } on FileSystemException catch (e) {
      error = e.osError?.message ?? e.message;
      if (error.isEmpty) error = '无法读取该目录';
    } catch (e) {
      error = e.toString();
    }

    final List<FileSystemEntity> dirs = <FileSystemEntity>[
      for (final FileSystemEntity entity in entries)
        if (_isDirectory(entity)) entity,
    ];
    final List<FileSystemEntity> files = <FileSystemEntity>[
      for (final FileSystemEntity entity in entries)
        if (!_isDirectory(entity)) entity,
    ];

    if (notify) {
      setState(() {
        _path = path;
        _entries = entries;
        _directories = dirs;
        _files = files;
        _error = error;
        _truncated = truncated;
      });
    } else {
      _path = path;
      _entries = entries;
      _directories = dirs;
      _files = files;
      _error = error;
      _truncated = truncated;
    }
  }

  bool _isDirectory(FileSystemEntity entity) {
    if (entity is Directory) return true;
    if (entity is Link) {
      try {
        return FileSystemEntity.isDirectorySync(entity.resolveSymbolicLinksSync());
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  static String _basename(String path) {
    final int index = path.lastIndexOf('/');
    return index < 0 ? path : path.substring(index + 1);
  }

  /// 生成 `file://` 网址；仅当路径含空格等特殊字符时才做百分号编码，
  /// 其余情况保持原样，便于与手写的规则文本对照。
  static String fileUrlOf(String path) {
    final bool needsEncoding = path.contains(' ') ||
        path.contains('#') ||
        path.contains('?') ||
        path.contains('%');
    if (!needsEncoding) return 'file://$path';
    return 'file://${path.split('/').map(Uri.encodeComponent).join('/')}';
  }

  void _openDirectory(String path) {
    FocusScope.of(context).unfocus();
    _load(path);
  }

  void _goUp() {
    final String? path = _path;
    if (path == null) return;
    final int index = path.lastIndexOf('/');
    if (index <= 0) return;
    _openDirectory(path.substring(0, index));
  }

  void _handleTap(FileSystemEntity entity) {
    if (_isDirectory(entity)) {
      _openDirectory(entity.path);
      return;
    }
    if (widget.pickDirectory) {
      showAppSnackBar(context, '请选择一个目录（文件夹），而不是文件。');
      return;
    }
    Navigator.of(context).pop(fileUrlOf(entity.path));
  }

  Future<void> _openStorageSettings() async {
    try {
      await _commands.invokeMethod<Object?>('openManageStorageSettings');
      if (!mounted) return;
      showAppSnackBar(context, '已请求打开系统的存储权限设置页面');
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        '无法打开系统设置：设备端暂不支持该操作（$error）。'
        '请手动进入「设置 → 应用 → 所有文件访问权限」开启。',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final ThemeData theme = Theme.of(context);
    final String current = _path ?? state.store.directory.path;
    final bool underSdcard = current.startsWith('/sdcard');
    final bool showPermissionHint = underSdcard && !_storageReadable;

    final List<_QuickJump> jumps = <_QuickJump>[
      _QuickJump('应用目录', state.store.directory.path, Icons.apps_outlined),
      _QuickJump('服务器根目录', state.effectiveLocalRoot, Icons.dns_outlined),
      const _QuickJump('下载', '/sdcard/Download', Icons.download_outlined),
      const _QuickJump('文档', '/sdcard/Documents', Icons.description_outlined),
      const _QuickJump('内部共享存储', '/sdcard', Icons.sd_storage_outlined),
    ];
    final Set<String> seenPaths = <String>{};
    final List<_QuickJump> uniqueJumps = <_QuickJump>[
      for (final _QuickJump jump in jumps)
        if (seenPaths.add(jump.path)) jump,
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pickDirectory ? '选择目录' : '本地文件'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: () => _load(current),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTheme.contentMaxWidth),
          child: Column(
            children: <Widget>[
              // 当前路径
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                color: theme.colorScheme.surfaceContainerLow,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.folder_open, size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: PatternText(current, fontSize: 12.5)),
                  ],
                ),
              ),
              // 快捷跳转
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final _QuickJump jump in uniqueJumps)
                      ActionChip(
                        avatar: Icon(jump.icon, size: 17),
                        label: Text(jump.label),
                        onPressed: () {
                          if (Directory(jump.path).existsSync()) {
                            _openDirectory(jump.path);
                          } else {
                            showAppSnackBar(context, '目录不存在或不可访问：${jump.path}');
                          }
                        },
                      ),
                  ],
                ),
              ),
              if (showPermissionHint)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                  child: Card(
                    color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Icon(Icons.warning_amber_rounded,
                                  size: 18, color: theme.colorScheme.error),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text('无法读取 /sdcard', style: theme.textTheme.titleSmall),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Android 11 及以上限制了共享存储访问，本应用需要「所有文件访问权限」'
                            '才能浏览 /sdcard 下的文件。请到系统设置中开启，或改用应用私有目录。',
                          ),
                          const SizedBox(height: 10),
                          FilledButton.icon(
                            onPressed: _openStorageSettings,
                            icon: const Icon(Icons.settings_outlined),
                            label: const Text('打开系统权限设置'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const Divider(height: 1),
              Expanded(child: _buildBody(theme, current)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, String current) {
    // 上级目录入口始终可见：即使目录为空或不可读，也能返回上一层。
    final bool canGoUp = current != '/' && current.contains('/');
    final Widget content = _buildListing(theme, current);

    if (!canGoUp) return content;

    return Column(
      children: <Widget>[
        ListTile(
          leading: const Icon(Icons.arrow_upward),
          title: const Text('上级目录'),
          subtitle: Text(_parentOf(current), style: monoStyle(context, fontSize: 12)),
          onTap: _goUp,
        ),
        const Divider(height: 1),
        Expanded(child: content),
      ],
    );
  }

  Widget _buildListing(ThemeData theme, String current) {
    if (_error != null) {
      return EmptyState(
        icon: Icons.folder_off_outlined,
        title: '无法打开该目录',
        message: '${_error!}\n\n如果这是 /sdcard 下的目录，通常是没有获得“所有文件访问权限”。',
        action: underSdcardPath(current)
            ? FilledButton.icon(
                onPressed: _openStorageSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('打开系统权限设置'),
              )
            : null,
      );
    }

    if (_entries.isEmpty) {
      return const EmptyState(
        icon: Icons.folder_open_outlined,
        title: '这个目录是空的',
        message: '可以把本地网页（.html）放到这里，然后点击文件返回它的 file:// 网址。',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _directories.length + _files.length + (_truncated ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        var cursor = index;
        if (cursor < _directories.length) {
          final FileSystemEntity dir = _directories[cursor];
          return ListTile(
            leading: Icon(Icons.folder, color: Theme.of(context).colorScheme.primary),
            title: Text(_basename(dir.path)),
            subtitle: const Text('文件夹'),
            trailing: widget.pickDirectory
                ? TextButton(
                    onPressed: () => Navigator.of(context).pop(fileUrlOf(dir.path)),
                    child: const Text('选择'),
                  )
                : const Icon(Icons.chevron_right),
            onTap: () => _handleTap(dir),
          );
        }
        cursor -= _directories.length;
        if (cursor < _files.length) {
          final FileSystemEntity file = _files[cursor];
          final String name = _basename(file.path);
          final bool isHtml = name.toLowerCase().endsWith('.html') ||
              name.toLowerCase().endsWith('.htm');
          return ListTile(
            leading: Icon(
              isHtml ? Icons.html : _iconFor(name),
              color: isHtml ? Theme.of(context).colorScheme.primary : null,
            ),
            title: Text(name, style: monoStyle(context, fontSize: 13.5)),
            subtitle: Text(
              '${_describe(file)}${isHtml ? ' · 网页文件，点击返回 file:// 网址' : ' · 点击返回 file:// 网址'}',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            onTap: () => _handleTap(file),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '目录条目过多，仅显示前 $_maxEntries 项。',
            style: theme.textTheme.bodySmall,
          ),
        );
      },
    );
  }

  static bool underSdcardPath(String path) => path.startsWith('/sdcard');

  static String _parentOf(String path) {
    final int index = path.lastIndexOf('/');
    if (index <= 0) return '/';
    return path.substring(0, index);
  }

  static IconData _iconFor(String name) {
    final String lower = name.toLowerCase();
    if (lower.endsWith('.css')) return Icons.css_outlined;
    if (lower.endsWith('.js') || lower.endsWith('.mjs')) return Icons.javascript_outlined;
    if (lower.endsWith('.json')) return Icons.data_object_outlined;
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif')) {
      return Icons.image_outlined;
    }
    if (lower.endsWith('.mp4') || lower.endsWith('.webm')) return Icons.movie_outlined;
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (lower.endsWith('.md') || lower.endsWith('.txt')) return Icons.article_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static String _describe(FileSystemEntity entity) {
    try {
      final FileStat stat = entity.statSync();
      final String size = stat.type == FileSystemEntityType.directory
          ? ''
          : '${_formatSize(stat.size)} · ';
      final DateTime time = stat.modified;
      String two(int value) => value.toString().padLeft(2, '0');
      return '$size${time.year}-${two(time.month)}-${two(time.day)} '
          '${two(time.hour)}:${two(time.minute)}';
    } catch (_) {
      return '无法读取文件信息';
    }
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class _QuickJump {
  const _QuickJump(this.label, this.path, this.icon);

  final String label;
  final String path;
  final IconData icon;
}
