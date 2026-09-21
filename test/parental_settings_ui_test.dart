import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/parental/parental_password.dart';
import 'package:tablet_browser/settings/settings_screen.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// The parental controls on the settings screen: choosing the challenge, and
/// setting / changing / clearing the password.
///
/// The gate itself is switched off in these fixtures so the controls can be
/// reached; the gate is exercised in the other parental test files.
void main() {
  late Directory directory;
  late AppState state;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tb_pw_settings');
    state = AppState(
      store: ConfigStore(directory),
      settings: const AppSettings(
        localServerEnabled: false,
        parentalGateEnabled: false,
      ),
    );
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1600);
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
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the settings screen offers the parental controls', (tester) async {
    await pumpSettings(tester);

    // The mode selector and the password controls are present.
    expect(find.text('家长密码'), findsWidgets);
    expect(find.text('算术题'), findsWidgets);
    expect(find.byKey(setParentalPasswordButtonKey), findsOneWidget);
    expect(find.text('设置家长密码'), findsWidgets);
  });

  testWidgets('setting a password from the settings stores it and offers changes',
      (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(setParentalPasswordButtonKey));
    await tester.pumpAndSettle();

    // The dialog asks twice, because a typo would be unrecoverable.
    final dialog = find.byType(AlertDialog);
    final fields = find.descendant(of: dialog, matching: find.byType(TextField));
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), 'abcd1234');
    await tester.enterText(fields.at(1), 'abcd1234');
    await tester.tap(find.descendant(of: dialog, matching: find.text('保存')));
    await tester.pumpAndSettle();

    expect(state.settings.hasParentalPassword, isTrue);
    expect(state.verifyParentalPassword('abcd1234'), isTrue);
    expect(state.verifyParentalPassword('wrong'), isFalse);

    // The button now offers a change instead of an initial setup.
    expect(find.text('修改家长密码'), findsWidgets);
    expect(find.text('清除家长密码'), findsWidgets);
  });

  testWidgets('the password dialog refuses a mismatch', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(setParentalPasswordButtonKey));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    final fields = find.descendant(of: dialog, matching: find.byType(TextField));
    await tester.enterText(fields.at(0), 'abcd1234');
    await tester.enterText(fields.at(1), 'different');
    await tester.tap(find.descendant(of: dialog, matching: find.text('保存')));
    await tester.pumpAndSettle();

    expect(state.settings.hasParentalPassword, isFalse);
    expect(find.textContaining('不一致'), findsWidgets);
  });

  testWidgets('clearing a password asks first and then removes it', (tester) async {
    await tester.runAsync(() => state.setParentalPassword('abcd1234'));
    await pumpSettings(tester);

    await tester.tap(find.text('清除家长密码'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.textContaining('确定清除家长密码吗')),
      findsOneWidget,
    );

    await tester.tap(find.descendant(of: dialog, matching: find.text('清除')));
    await tester.pumpAndSettle();

    expect(state.settings.hasParentalPassword, isFalse);
    expect(find.text('设置家长密码'), findsWidgets);
  });

  testWidgets('switching to the arithmetic challenge is recorded', (tester) async {
    await pumpSettings(tester);
    expect(state.settings.parentalGateMode, ParentalGateMode.password);

    await tester.tap(find.text('算术题').first);
    await tester.pumpAndSettle();

    expect(state.settings.parentalGateMode, ParentalGateMode.arithmetic);
  });

  testWidgets('the whitelist protection switch is on and can be turned off',
      (tester) async {
    await pumpSettings(tester);
    expect(state.settings.parentalGateProtectRules, isTrue);

    final protectionSwitch = find.ancestor(
      of: find.text('同时保护黑白名单页'),
      matching: find.byType(SwitchListTile),
    );
    expect(protectionSwitch, findsOneWidget);

    await tester.tap(find.descendant(of: protectionSwitch, matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    expect(state.settings.parentalGateProtectRules, isFalse);
  });
}
