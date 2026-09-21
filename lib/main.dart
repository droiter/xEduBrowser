import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';

import 'browser/browser_screen.dart';
import 'state/app_scope.dart';
import 'state/app_state.dart';
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
        home: const BrowserScreen(),
      ),
    );
  }
}
