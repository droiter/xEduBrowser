import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';

import 'browser/browser_bridge.dart';
import 'browser/browser_screen.dart';
import 'state/app_scope.dart';
import 'state/app_state.dart';
import 'ui/app_shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Directory directory;
  try {
    directory = await getApplicationDocumentsDirectory();
  } catch (_) {
    // Should not happen on Android, but never leave the user without a
    // working configuration store.
    directory = Directory.systemTemp;
  }

  final state = AppState(store: ConfigStore(directory));
  await state.load();

  // 固定桌面：锁定任务不跨重启保留，所以启动时按设置再申请一次。系统是否答应由它
  // 决定（可能弹一次确认框），失败只写日志——顶栏的图标随后会显示真实状态。
  unawaited(
    BrowserBridge.syncDesktopPin(wanted: state.settings.lockTaskEnabled)
        .then((String result) {
      if (state.settings.lockTaskEnabled && result == 'none') {
        debugPrint('固定桌面：系统未允许锁定任务（Home 键仍可用）');
      }
    }),
  );

  runApp(TabletBrowserApp(state: state));
}

class TabletBrowserApp extends StatelessWidget {
  const TabletBrowserApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: '平板浏览器',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        // The shell hosts the off-screen capture view the background thumbnail
        // pass needs; see thumbnail_backfill.dart.
        builder: (BuildContext context, Widget? child) =>
            AppShell(child: child ?? const SizedBox.shrink()),
        home: const BrowserScreen(),
      ),
    );
  }
}
