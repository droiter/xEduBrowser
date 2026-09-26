import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bookmarks/bookmark_manager.dart';
import '../browser/browser_bridge.dart';
import '../files/local_files_screen.dart';
import '../parental/parental_challenge.dart';
import '../parental/parental_gate.dart';
import '../parental/parental_password.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';

/// 与原生 WebView 通信的通道名（由浏览器外壳实现，这里只负责调用）。
const MethodChannel _commands = MethodChannel('tablet_browser/commands');

/// 家长验证题目数量的可选范围。
const int _minQuestionCount = 1;
const int _maxQuestionCount = 5;

/// 测试钩子：稳定的 Key，便于 widget 测试驱动新控件而不依赖布局与样式。
const Key parentalModeSelectorKey = ValueKey<String>('parental-mode-selector');
const Key setParentalPasswordButtonKey = ValueKey<String>('parental-set-password');
const Key clearParentalPasswordButtonKey = ValueKey<String>('parental-clear-password');
const Key newParentalPasswordFieldKey = ValueKey<String>('parental-new-password');
const Key newParentalPasswordConfirmFieldKey =
    ValueKey<String>('parental-new-password-confirm');
const Key arithmeticOptionsKey = ValueKey<String>('parental-arithmetic-options');

/// 测试钩子：「关于」卡片里显示版本号的那一行。
const Key aboutVersionKey = ValueKey<String>('about-version');

/// WebView 与应用设置：引擎开关、文字缩放、起始页、本地服务器、
/// 家长验证、书签默认行为与危险操作。
///
/// 整页内容都挂在 [ParentalGate] 后面：AppBar 照常显示，但设置项在通过验证
/// 之前不会被构建，从任意入口（工具栏、深链接）打开都会先看到挑战。验证方式
/// 由“家长验证”一节的“验证方式”决定：默认是家长密码（未设置时首次进入会
/// 要求设置），也可以改成每次随机出题的算术题。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// 拖动中的缩放值（未提交时优先显示它，避免滑块跳动）。
  double? _draggingZoom;

  /// 拖动中的题目数量（同上，松手时才写入设置）。
  int? _draggingQuestionCount;

  /// 本机安装的版本，供「关于」卡片显示。null 表示还没读到（或读不到）。
  AppVersion? _appVersion;
  bool _appVersionRead = false;

  @override
  void initState() {
    super.initState();
    // 版本号只有原生知道（它读的是真正装上的那个 APK），所以异步取一次。
    unawaited(_loadAppVersion());
  }

  Future<void> _loadAppVersion() async {
    final AppVersion? version = await BrowserBridge.appVersion();
    if (!mounted) return;
    setState(() {
      _appVersion = version;
      _appVersionRead = true;
    });
  }

  /// 保存设置。始终以**当前**设置为基准改写，避免用界面上捕获的旧快照
  /// 覆盖掉刚刚改过的其它设置。
  Future<void> _apply(AppSettings Function(AppSettings current) mutate) async {
    final state = AppScope.read(context);
    try {
      await state.updateSettings(mutate(state.settings));
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, '保存设置失败：$error', isError: true);
    }
  }

  Future<void> _pickLocalServerRoot() async {
    final state = AppScope.read(context);
    final String? url = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => LocalFilesScreen(
          pickDirectory: true,
          startPath: state.effectiveLocalRoot,
        ),
      ),
    );
    if (url == null || !mounted) return;
    final String path = Uri.parse(url).toFilePath();
    await _apply((AppSettings current) => current.copyWith(localServerRoot: path));
    if (!mounted) return;
    showAppSnackBar(context, '本地服务器根目录已设为 $path');
  }

  Future<void> _pickHomePage() async {
    final String? url = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const LocalFilesScreen()),
    );
    if (url == null || !mounted) return;
    await _apply((AppSettings current) => current.copyWith(homeUrl: url));
    if (!mounted) return;
    showAppSnackBar(context, '起始页已设为 $url');
  }

  /// 危险操作：先确认，再调用原生实现；原生未实现时只提示，不崩溃。
  Future<void> _runNativeCommand({
    required String title,
    required String message,
    required String method,
    required String doneLabel,
  }) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(doneLabel),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _commands.invokeMethod<Object?>(method);
      if (!mounted) return;
      showAppSnackBar(context, '$doneLabel完成');
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        '$doneLabel失败：设备端暂不支持该操作（$error）',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final AppSettings settings = state.settings;
    final bool wide = AppTheme.isWide(context);

    final List<Widget> left = <Widget>[
      // Bookmarks are added here, not on the home page: the home page is the
      // wall of tiles and nothing else.
      const BookmarkManagerCard(),
      const SizedBox(height: 16),
      _webViewCard(settings),
      const SizedBox(height: 16),
      _zoomCard(settings),
      const SizedBox(height: 16),
      _homeCard(settings),
      const SizedBox(height: 16),
      _bookmarkCard(settings),
    ];
    final List<Widget> right = <Widget>[
      _localServerCard(state, settings),
      const SizedBox(height: 16),
      _parentalCard(settings),
      const SizedBox(height: 16),
      _dangerCard(),
      const SizedBox(height: 16),
      _aboutCard(),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      // 全部设置项都在验证之后：ParentalGate 在解锁前不构建 child，
      // 因此这里的卡片不会出现在界面上，也无法用返回手势以外的办法绕过。
      body: ParentalGate(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppTheme.contentMaxWidth),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: <Widget>[
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(child: Column(children: left)),
                      const SizedBox(width: 16),
                      Expanded(child: Column(children: right)),
                    ],
                  )
                else ...<Widget>[
                  ...left,
                  ...right,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 网页引擎

  Widget _webViewCard(AppSettings settings) {
    return SectionCard(
      title: '网页引擎',
      subtitle: '这些开关会立即推送给 WebView，重新加载页面后完全生效。',
      icon: Icons.language,
      children: <Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: settings.javaScript,
          onChanged: (bool value) => _apply((AppSettings current) => current.copyWith(javaScript: value)),
          title: const Text('启用 JavaScript'),
          subtitle: const Text('关闭后动态网页无法运行，只能显示静态内容。'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: settings.domStorage,
          onChanged: (bool value) => _apply((AppSettings current) => current.copyWith(domStorage: value)),
          title: const Text('DOM 存储'),
          subtitle: const Text('允许网页使用 localStorage / sessionStorage / IndexedDB。'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: settings.fileAccess,
          onChanged: (bool value) => _apply((AppSettings current) => current.copyWith(fileAccess: value)),
          title: const Text('允许 file:// 访问'),
          subtitle: const Text('允许网页读取本机文件，本地静态页面需要它。'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: settings.allowFileUrlCrossAccess,
          onChanged: (bool value) =>
              _apply((AppSettings current) => current.copyWith(allowFileUrlCrossAccess: value)),
          title: const Text('允许 file:// 跨域访问'),
          subtitle: const Text('允许本地文件互相读取（含 fetch / XHR 跨文件请求）。'),
        ),
        const HintText(
          '注意：开启“允许 file:// 跨域访问”会放宽本地页面的同源限制，'
          '本机任意 HTML 之间可以互读内容。仅在完全信任本地文件时开启。',
          tone: ChipTone.warning,
          icon: Icons.warning_amber_rounded,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: settings.mediaAutoplay,
          onChanged: (bool value) => _apply((AppSettings current) => current.copyWith(mediaAutoplay: value)),
          title: const Text('媒体自动播放'),
          subtitle: const Text('允许音视频在无用户操作时自动播放（可能发出声音）。'),
        ),
        const SizedBox(height: 8),
        _CommitTextField(
          label: '自定义 User-Agent',
          value: settings.userAgent ?? '',
          hint: '留空则使用系统默认 UA',
          monospace: true,
          maxLines: 2,
          onCommit: (String text) {
            final String trimmed = text.trim();
            _apply((AppSettings current) => trimmed.isEmpty
                ? current.copyWith(clearUserAgent: true)
                : current.copyWith(userAgent: trimmed));
          },
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 文字缩放

  Widget _zoomCard(AppSettings settings) {
    final double zoom = _draggingZoom ?? settings.textZoom.toDouble();
    return SectionCard(
      title: '文字缩放',
      subtitle: '只影响网页内文字大小，不影响本应用界面。',
      icon: Icons.format_size,
      trailing: Text(
        '${zoom.round()}%',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      children: <Widget>[
        Row(
          children: <Widget>[
            const Text('50%', style: TextStyle(fontSize: 12)),
            Expanded(
              child: Slider(
                value: zoom.clamp(50, 200),
                min: 50,
                max: 200,
                divisions: 150,
                label: '${zoom.round()}%',
                onChanged: (double value) => setState(() => _draggingZoom = value),
                onChangeEnd: (double value) {
                  setState(() => _draggingZoom = null);
                  _apply((AppSettings current) => current.copyWith(textZoom: value.round()));
                },
              ),
            ),
            const Text('200%', style: TextStyle(fontSize: 12)),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: zoom.round() == 100
                ? null
                : () {
                    setState(() => _draggingZoom = null);
                    _apply((AppSettings current) => current.copyWith(textZoom: 100));
                  },
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('恢复 100%'),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 起始页

  Widget _homeCard(AppSettings settings) {
    return SectionCard(
      title: '起始页',
      subtitle: '新建标签页时打开的地址；about:home 表示应用内置的本地起始页。',
      icon: Icons.home_outlined,
      children: <Widget>[
        _CommitTextField(
          label: '起始页 URL',
          value: settings.homeUrl,
          hint: 'about:home 或 https://example.com',
          monospace: true,
          onCommit: (String text) {
            final String trimmed = text.trim();
            _apply((AppSettings current) =>
                current.copyWith(homeUrl: trimmed.isEmpty ? 'about:home' : trimmed));
          },
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: _pickHomePage,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('选择本地文件'),
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: settings.homeUrl == 'about:home'
                  ? null
                  : () => _apply((AppSettings current) => current.copyWith(homeUrl: 'about:home')),
              child: const Text('恢复内置起始页'),
            ),
          ],
        ),
      ],
    );
  }

  // -------------------------------------------------------------- 书签

  Widget _bookmarkCard(AppSettings settings) {
    return SectionCard(
      title: '书签默认行为',
      subtitle: '收藏常用地址时的默认行为。',
      icon: Icons.bookmark_outline,
      children: <Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: settings.bookmarkWhitelistByDefault,
          onChanged: (bool value) =>
              _apply((AppSettings current) => current.copyWith(bookmarkWhitelistByDefault: value)),
          title: const Text('添加书签时默认加入白名单'),
          subtitle: const Text('添加书签时，同时把它的地址和它所在的网站（本地网页是所在目录）'
              '加进白名单，过滤规则默认放行。'),
        ),
        const HintText(
          '关闭后书签只保存地址，不再改动白名单；已有的白名单规则不会因此被删除。',
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 家长验证

  Widget _parentalCard(AppSettings settings) {
    final ThemeData theme = Theme.of(context);
    final bool passwordMode = settings.parentalGateMode == ParentalGateMode.password;

    return SectionCard(
      title: '家长验证',
      subtitle: passwordMode
          ? '打开设置前先输入家长密码，避免孩子自行改动上面的选项。'
          : '打开设置前先做几道一位数算术题，避免孩子自行改动上面的选项。',
      icon: Icons.lock_outline,
      trailing: RuleChip(
        settings.parentalGateEnabled ? '已启用' : '已关闭',
        tone: settings.parentalGateEnabled ? ChipTone.allow : ChipTone.warning,
        icon: settings.parentalGateEnabled ? Icons.lock_outline : Icons.lock_open_outlined,
      ),
      children: <Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: settings.parentalGateEnabled,
          onChanged: (bool value) =>
              _apply((AppSettings current) => current.copyWith(parentalGateEnabled: value)),
          title: const Text('启用家长验证'),
          subtitle: const Text('打开设置页时先通过下面的验证方式，通过之后才能看到并修改这里的设置。'),
        ),
        if (!settings.parentalGateEnabled)
          const HintText(
            '家长验证已关闭：任何人都可以直接打开设置页。',
            tone: ChipTone.warning,
            icon: Icons.lock_open_outlined,
          ),
        const SizedBox(height: 12),

        // 验证方式
        Text('验证方式', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<ParentalGateMode>(
          key: parentalModeSelectorKey,
          segments: <ButtonSegment<ParentalGateMode>>[
            for (final ParentalGateMode mode in ParentalGateMode.values)
              ButtonSegment<ParentalGateMode>(
                value: mode,
                label: Text(mode.labelZh),
              ),
          ],
          selected: <ParentalGateMode>{settings.parentalGateMode},
          onSelectionChanged: (Set<ParentalGateMode> selection) => _apply(
            (AppSettings current) => current.copyWith(parentalGateMode: selection.first),
          ),
        ),
        const HintText(
          '家长密码 — 孩子无法靠算术猜出，首次进入时会要求设置；'
          '算术题 — 每次随机出题，无需记密码。',
        ),
        const SizedBox(height: 16),

        if (passwordMode) ..._passwordControls(settings) else ..._arithmeticControls(settings),

        // 黑白名单页保护
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: settings.parentalGateProtectRules,
          onChanged: (bool value) =>
              _apply((AppSettings current) => current.copyWith(parentalGateProtectRules: value)),
          title: const Text('同时保护黑白名单页'),
          subtitle: const Text(
            '默认已开启。关闭后任何人都能从黑白名单页直接增删改规则，不必通过上面的验证。',
          ),
        ),
        HintText(
          passwordMode
              ? '家长验证只用来挡住孩子：密码只保存加盐哈希，不会保存明文，也无法找回，'
                  '请记牢；输错次数过多会暂时锁定，稍等片刻即可重试。'
              : '家长验证只用来挡住孩子：答案不需要记住，题目每次打开都会重新生成，'
                  '答错也不会把应用锁死，稍等片刻即可重试。',
        ),
      ],
    );
  }

  // -------------------------------------------------- 家长验证：密码模式

  /// 密码模式的控件：尚未设置时是“设置家长密码”，已设置时是“修改 / 清除”。
  ///
  /// 这里只显示是否已设置，从不显示哈希与盐，也不把密码写进任何 [Text]。
  List<Widget> _passwordControls(AppSettings settings) {
    final ThemeData theme = Theme.of(context);
    final bool hasPassword = settings.hasParentalPassword;

    return <Widget>[
      Row(
        children: <Widget>[
          Text('家长密码', style: theme.textTheme.titleSmall),
          const Spacer(),
          RuleChip(
            hasPassword ? '已设置' : '未设置',
            tone: hasPassword ? ChipTone.allow : ChipTone.warning,
            icon: hasPassword ? Icons.lock_outline : Icons.lock_open_outlined,
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        hasPassword
            ? '进入设置页与受保护页面时需要输入这个密码。'
            : '还没有设置家长密码：首次进入受保护页面时会要求你设置一个。',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 10),
      if (!hasPassword)
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: setParentalPasswordButtonKey,
            onPressed: _openSetPasswordDialog,
            icon: const Icon(Icons.password_outlined),
            label: const Text('设置家长密码'),
          ),
        )
      else
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            OutlinedButton.icon(
              key: setParentalPasswordButtonKey,
              onPressed: _openSetPasswordDialog,
              icon: const Icon(Icons.password_outlined),
              label: const Text('修改家长密码'),
            ),
            OutlinedButton.icon(
              key: clearParentalPasswordButtonKey,
              onPressed: _confirmClearPassword,
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              icon: const Icon(Icons.lock_open_outlined),
              label: const Text('清除家长密码'),
            ),
          ],
        ),
      HintText(
        hasPassword
            ? '密码至少 ${ParentalPassword.minLength} 位，只保存加盐哈希。清除后下一次进入受保护页面会要求重新设置。'
            : '密码至少 ${ParentalPassword.minLength} 位，无法找回，请记牢；设置后每次进入受保护页面都要输入它。',
      ),
      const SizedBox(height: 16),
    ];
  }

  Future<void> _openSetPasswordDialog() async {
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => const _ParentalPasswordDialog(),
    );
    if (saved != true || !mounted) return;
    showAppSnackBar(context, '家长密码已保存，下次进入受保护页面时需要输入它。');
  }

  Future<void> _confirmClearPassword() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('清除家长密码'),
        content: const Text(
          '确定清除家长密码吗？清除后进入受保护页面会要求重新设置一个新密码，'
          '旧的密码立即失效。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await AppScope.read(context).clearParentalPassword();
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, '清除家长密码失败：$error', isError: true);
      return;
    }
    if (!mounted) return;
    showAppSnackBar(context, '家长密码已清除，下次进入受保护页面会要求重新设置。');
  }

  // ------------------------------------------------ 家长验证：算术题模式

  /// 算术题模式的控件。未选中算术题时整体变淡且不可点击，避免误以为它对
  /// 家长密码也生效。
  List<Widget> _arithmeticControls(AppSettings settings) {
    final ThemeData theme = Theme.of(context);
    final bool arithmetic = settings.parentalGateMode == ParentalGateMode.arithmetic;
    final int count = (_draggingQuestionCount ?? settings.parentalGateQuestionCount)
        .clamp(_minQuestionCount, _maxQuestionCount)
        .toInt();

    return <Widget>[
      if (!arithmetic)
        const HintText(
          '下面的题型与题目数量只对“算术题”生效；要调整它们请先把验证方式切换为算术题。',
          icon: Icons.info_outline,
        ),
      Opacity(
        opacity: arithmetic ? 1 : 0.45,
        child: IgnorePointer(
          ignoring: !arithmetic,
          child: Column(
            key: arithmeticOptionsKey,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 题型
              Text('题型', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<ParentalOperation>(
                segments: <ButtonSegment<ParentalOperation>>[
                  for (final ParentalOperation operation in ParentalOperation.values)
                    ButtonSegment<ParentalOperation>(
                      value: operation,
                      label: Text(operation.labelZh),
                    ),
                ],
                selected: <ParentalOperation>{settings.parentalGateOperation},
                onSelectionChanged: (Set<ParentalOperation> selection) => _apply(
                  (AppSettings current) => current.copyWith(parentalGateOperation: selection.first),
                ),
              ),
              const HintText('题目由 2–9 的一位数字随机组成，每次打开设置页都会重新出题。'),
              const SizedBox(height: 16),

              // 题目数量
              Row(
                children: <Widget>[
                  Text('题目数量', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  Text(
                    '$count 题',
                    style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
                  ),
                ],
              ),
              Row(
                children: <Widget>[
                  const Text('$_minQuestionCount 题', style: TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: count.toDouble(),
                      min: _minQuestionCount.toDouble(),
                      max: _maxQuestionCount.toDouble(),
                      divisions: _maxQuestionCount - _minQuestionCount,
                      label: '$count 题',
                      onChanged: (double value) =>
                          setState(() => _draggingQuestionCount = value.round()),
                      onChangeEnd: (double value) {
                        setState(() => _draggingQuestionCount = null);
                        _apply((AppSettings current) =>
                            current.copyWith(parentalGateQuestionCount: value.round()));
                      },
                    ),
                  ),
                  const Text('$_maxQuestionCount 题', style: TextStyle(fontSize: 12)),
                ],
              ),
              const HintText('连续答对上面这么多道题才能进入设置；答错会换一道新题，答对进度保留。'),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
    ];
  }

  // ------------------------------------------------------------ 本地服务器

  Widget _localServerCard(AppState state, AppSettings settings) {
    final bool running = state.localServerRunning;
    final String? baseUrl = state.localServer?.baseUrl;
    final String effectiveRoot = state.effectiveLocalRoot;
    final ThemeData theme = Theme.of(context);
    final bool failed = settings.localServerEnabled && !running;

    return SectionCard(
      title: '本地服务器',
      subtitle: '把本地目录以 http://127.0.0.1 提供，让本地动态网页（ES 模块、fetch）正常工作。',
      icon: Icons.dns_outlined,
      trailing: RuleChip(
        running ? '运行中' : '未运行',
        tone: running ? ChipTone.allow : ChipTone.warning,
        icon: running ? Icons.play_circle_outline : Icons.pause_circle_outline,
      ),
      children: <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    running ? Icons.check_circle_outline : Icons.info_outline,
                    size: 16,
                    color: running ? theme.colorScheme.primary : theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      running
                          ? '访问地址：${baseUrl ?? 'http://127.0.0.1:${settings.localServerPort}'}'
                          : (settings.localServerEnabled
                              ? '服务器已启用但未启动，可能是端口被占用，可点击“重新启动”重试。'
                              : '服务器未启用，本地页面只能用 file:// 打开。'),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const SizedBox(width: 22, child: Text('根目录', style: TextStyle(fontSize: 12.5))),
                  Expanded(child: PatternText(effectiveRoot, fontSize: 12.5)),
                ],
              ),
              if (running && baseUrl != null) ...<Widget>[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: baseUrl));
                      if (!mounted) return;
                      showAppSnackBar(context, '已复制访问地址：$baseUrl');
                    },
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                    label: const Text('复制访问地址'),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: settings.localServerEnabled,
          onChanged: (bool value) => _apply((AppSettings current) => current.copyWith(localServerEnabled: value)),
          title: const Text('启用本地服务器'),
          subtitle: const Text('关闭后停止监听，已打开的本地页面会失效。'),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: _CommitTextField(
                label: '端口',
                value: '${settings.localServerPort}',
                hint: '8787',
                helper: '默认 8787，可选范围 1024–65535',
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                validator: (String value) {
                  final int? port = int.tryParse(value.trim());
                  if (port == null) return '请输入数字端口';
                  if (port < 1024 || port > 65535) return '端口范围 1024–65535';
                  return null;
                },
                onCommit: (String value) {
                  final int? port = int.tryParse(value.trim());
                  if (port == null) return;
                  _apply((AppSettings current) => current.copyWith(localServerPort: port));
                },
              ),
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton.icon(
                onPressed: failed
                    ? () async {
                        final int? port = await AppScope.read(context).startLocalServer();
                        if (!mounted) return;
                        showAppSnackBar(
                          context,
                          port == null ? '启动失败：端口可能被占用' : '已启动：http://127.0.0.1:$port',
                          isError: port == null,
                        );
                      }
                    : null,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新启动'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _CommitTextField(
          label: '根目录',
          value: settings.localServerRoot,
          hint: '留空则使用应用文档目录：${state.store.directory.path}',
          monospace: true,
          onCommit: (String text) => _apply(
            (AppSettings current) => current.copyWith(localServerRoot: text.trim()),
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _pickLocalServerRoot,
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('选择目录'),
          ),
        ),
        const HintText('修改端口或根目录后会自动重启服务器；本地页面同样受白名单 / 黑名单约束。'),
      ],
    );
  }

  // ------------------------------------------------------------ 关于

  /// 「关于」：应用名、**本机真正安装的**版本号与包名。
  ///
  /// 版本号来自原生层（packageManager），所以升级后这里显示的就是升级后的
  /// 版本；读不到时如实显示「未知」，不拿一个编译期常量冒充。
  Widget _aboutCard() {
    final String version = _appVersion?.label ??
        (_appVersionRead ? '未知（无法读取）' : '读取中…');
    return SectionCard(
      title: '关于',
      subtitle: '本机安装的应用信息，报问题时请连同这个版本号一起说明。',
      icon: Icons.info_outline,
      trailing: RuleChip(version, icon: Icons.new_releases_outlined),
      children: <Widget>[
        _aboutRow(Icons.apps_outlined, '应用', '平板浏览器'),
        const SizedBox(height: 8),
        _aboutRow(Icons.tag_outlined, '版本', version, key: aboutVersionKey),
        const SizedBox(height: 8),
        _aboutRow(Icons.android_outlined, '包名', 'com.xstocker.tabletbrowser'),
      ],
    );
  }

  Widget _aboutRow(IconData icon, String label, String value, {Key? key}) {
    final ThemeData theme = Theme.of(context);
    return Row(
      key: key,
      children: <Widget>[
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 10),
        SizedBox(
          width: 64,
          child: Text(label, style: theme.textTheme.bodyMedium),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 危险操作

  Widget _dangerCard() {
    final ThemeData theme = Theme.of(context);
    return SectionCard(
      title: '危险操作',
      subtitle: '执行后无法撤销，操作前会再次确认。',
      icon: Icons.warning_amber_rounded,
      children: <Widget>[
        _DangerTile(
          icon: Icons.cleaning_services_outlined,
          title: '清除缓存',
          subtitle: '删除网页缓存文件，下次打开会重新下载资源。',
          buttonLabel: '清除',
          onPressed: () => _runNativeCommand(
            title: '清除缓存',
            message: '确定清除全部网页缓存吗？已保存的登录状态可能一并失效。',
            method: 'clearCache',
            doneLabel: '清除缓存',
          ),
        ),
        const Divider(height: 24),
        _DangerTile(
          icon: Icons.cookie_outlined,
          title: '清除 Cookie',
          subtitle: '删除所有网站的 Cookie 与本地站点数据，需要重新登录。',
          buttonLabel: '清除',
          onPressed: () => _runNativeCommand(
            title: '清除 Cookie',
            message: '确定清除全部 Cookie 与站点数据吗？所有网站都需要重新登录。',
            method: 'clearCookies',
            doneLabel: '清除 Cookie',
          ),
        ),
        const Divider(height: 24),
        _DangerTile(
          icon: Icons.history_toggle_off,
          title: '数据清除',
          subtitle: '清除浏览历史记录（应用内的请求日志请在“请求日志”页清空）。',
          buttonLabel: '清除',
          onPressed: () => _runNativeCommand(
            title: '清除浏览数据',
            message: '确定清除浏览历史记录吗？该操作不可撤销。',
            method: 'clearHistory',
            doneLabel: '清除浏览数据',
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '以上操作通过原生接口执行；若设备端尚未实现，这里只会给出提示，不会影响应用运行。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 危险操作的一行：图标 + 标题 + 说明 + 危险按钮。
class _DangerTile extends StatelessWidget {
  const _DangerTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String buttonLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Icon(icon, color: theme.colorScheme.error),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
          child: Text(buttonLabel),
        ),
      ],
    );
  }
}

/// 失焦或回车时提交的文本框：输入过程中不会被外部状态刷新覆盖。
class _CommitTextField extends StatefulWidget {
  const _CommitTextField({
    required this.label,
    required this.value,
    required this.onCommit,
    this.hint,
    this.helper,
    this.monospace = false,
    this.keyboardType,
    this.inputFormatters,
    this.validator,
    this.maxLines = 1,
  });

  final String label;
  final String value;
  final ValueChanged<String> onCommit;
  final String? hint;
  final String? helper;
  final bool monospace;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String value)? validator;
  final int maxLines;

  @override
  State<_CommitTextField> createState() => _CommitTextFieldState();
}

class _CommitTextFieldState extends State<_CommitTextField> {
  late final TextEditingController _controller;
  late final FocusNode _focus;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _focus = FocusNode()
      ..addListener(() {
        if (!_focus.hasFocus) _commit();
      });
  }

  @override
  void didUpdateWidget(covariant _CommitTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final String raw = _controller.text;
    final String? error = widget.validator?.call(raw);
    if (error != null) {
      if (mounted) setState(() => _error = error);
      return;
    }
    if (mounted) setState(() => _error = null);
    if (raw != widget.value) widget.onCommit(raw);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      maxLines: widget.maxLines,
      textInputAction:
          widget.maxLines > 1 ? TextInputAction.newline : TextInputAction.done,
      style: widget.monospace ? monoStyle(context, fontSize: 13.5) : null,
      onSubmitted: (_) => _commit(),
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        helperText: widget.helper,
        helperMaxLines: 3,
        errorText: _error,
      ),
    );
  }
}

/// 设置 / 修改家长密码的对话框。
///
/// 两个遮蔽输入框（新密码 / 再次输入），校验交给 [ParentalPassword.validate]
/// 与一致性检查，确认后调用 [AppState.setParentalPassword]——它只把新生成的
/// 盐与派生哈希写进设置，明文密码既不落盘也不出现在界面上。
///
/// 成功时以 `true` 关闭对话框，由设置页显示 SnackBar；失败信息留在对话框里，
/// 不会泄露密码本身。
class _ParentalPasswordDialog extends StatefulWidget {
  const _ParentalPasswordDialog();

  @override
  State<_ParentalPasswordDialog> createState() => _ParentalPasswordDialogState();
}

class _ParentalPasswordDialogState extends State<_ParentalPasswordDialog> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final FocusNode _confirmFocus = FocusNode();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;

    final String password = _password.text;
    final String? problem = ParentalPassword.validate(password) ??
        (password == _confirm.text ? null : '两次输入的密码不一致');
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // 只保存盐与哈希；明文既不写日志也不写设置。
      await AppScope.read(context).setParentalPassword(password);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败：$error';
      });
      return;
    }
    if (!mounted) return;
    // 尽早丢弃明文。
    _password.clear();
    _confirm.clear();
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: const Text('设置家长密码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '设置后进入设置页与受保护页面都需要输入这个密码。',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            key: newParentalPasswordFieldKey,
            controller: _password,
            autofocus: true,
            obscureText: true,
            enabled: !_saving,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _confirmFocus.requestFocus(),
            decoration: InputDecoration(
              labelText: '新密码',
              hintText: '至少 ${ParentalPassword.minLength} 位',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: newParentalPasswordConfirmFieldKey,
            controller: _confirm,
            focusNode: _confirmFocus,
            obscureText: true,
            enabled: !_saving,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: '再次输入',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.warning_amber_rounded, size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '密码无法找回：只保存加盐哈希，忘记后只能清除应用数据重来，请记牢。',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: const Icon(Icons.check),
          label: const Text('保存'),
        ),
      ],
    );
  }
}
