import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/parental/parental_gate.dart';
import 'package:tablet_browser/parental/parental_password.dart';
import 'package:tablet_browser/rules/rules_screen.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// The default challenge: a parent password. The arithmetic variant is covered
/// in parental_gate_test.dart.
void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tb_pw_gate');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  /// Settings with a password already configured, derived here so the test does
  /// not depend on any file I/O.
  AppSettings withPassword(String password, {
    bool protectRules = true,
    bool gateEnabled = true,
  }) {
    final salt = ParentalPassword.newSalt();
    return AppSettings(
      localServerEnabled: false,
      parentalGateEnabled: gateEnabled,
      parentalGateProtectRules: protectRules,
      parentalPasswordSalt: salt,
      parentalPasswordHash: ParentalPassword.derive(password, salt),
    );
  }

  AppState buildState(AppSettings settings) =>
      AppState(store: ConfigStore(directory), settings: settings);

  Future<void> pump(WidgetTester tester, AppState state, Widget home) async {
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
          home: home,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> enterPassword(WidgetTester tester, String password) async {
    await tester.enterText(find.byKey(passwordInputKey), password);
    await tester.pump();
  }

  group('first run', () {
    testWidgets('the gate asks the parent to set a password', (tester) async {
      final state = buildState(const AppSettings(localServerEnabled: false));
      await pump(tester, state, const ParentalGate(child: Text('机密内容')));

      expect(find.text('机密内容'), findsNothing);
      expect(find.byKey(passwordInputKey), findsOneWidget);
      expect(find.byKey(passwordConfirmKey), findsOneWidget);
      expect(find.textContaining('首次使用'), findsOneWidget);
      // No arithmetic question is shown in password mode.
      expect(find.byKey(challengePromptKey), findsNothing);
    });

    testWidgets('setting a password unlocks the content', (tester) async {
      final state = buildState(const AppSettings(localServerEnabled: false));
      await pump(tester, state, const ParentalGate(child: Text('机密内容')));

      await enterPassword(tester, '1234');
      await tester.enterText(find.byKey(passwordConfirmKey), '1234');
      await tester.tap(find.text('设置并进入'));
      await tester.pump();

      expect(find.text('机密内容'), findsOneWidget);
      expect(state.settings.hasParentalPassword, isTrue);
      expect(state.verifyParentalPassword('1234'), isTrue);
    });

    testWidgets('a short password is refused with an explanation', (tester) async {
      final state = buildState(const AppSettings(localServerEnabled: false));
      await pump(tester, state, const ParentalGate(child: Text('机密内容')));

      await enterPassword(tester, '12');
      await tester.enterText(find.byKey(passwordConfirmKey), '12');
      await tester.tap(find.text('设置并进入'));
      await tester.pump();

      expect(find.text('密码至少 4 位'), findsOneWidget);
      expect(find.text('机密内容'), findsNothing);
      expect(state.settings.hasParentalPassword, isFalse);
    });

    testWidgets('a mismatched confirmation is refused', (tester) async {
      final state = buildState(const AppSettings(localServerEnabled: false));
      await pump(tester, state, const ParentalGate(child: Text('机密内容')));

      await enterPassword(tester, '1234');
      await tester.enterText(find.byKey(passwordConfirmKey), '4321');
      await tester.tap(find.text('设置并进入'));
      await tester.pump();

      expect(find.text('两次输入的密码不一致'), findsOneWidget);
      expect(find.text('机密内容'), findsNothing);
      expect(state.settings.hasParentalPassword, isFalse);
    });
  });

  group('verification', () {
    testWidgets('the right password unlocks, a wrong one does not', (tester) async {
      final state = buildState(withPassword('家长密码1234'));
      await pump(tester, state, const ParentalGate(child: Text('机密内容')));

      expect(find.textContaining('首次使用'), findsNothing);
      expect(find.byKey(passwordConfirmKey), findsNothing);

      await enterPassword(tester, '猜错了');
      await tester.tap(find.text('确定'));
      await tester.pump();
      expect(find.text('机密内容'), findsNothing);
      expect(find.text('密码不正确'), findsOneWidget);
      expect(find.textContaining('还可以尝试 4 次'), findsOneWidget);

      await enterPassword(tester, '家长密码1234');
      await tester.tap(find.text('确定'));
      await tester.pump();
      expect(find.text('机密内容'), findsOneWidget);
    });

    testWidgets('five wrong attempts lock the gate and disable the field',
        (tester) async {
      final state = buildState(withPassword('1234'));
      await pump(tester, state, const ParentalGate(child: Text('机密内容')));

      for (var attempt = 0; attempt < 5; attempt++) {
        await enterPassword(tester, 'wrong$attempt');
        await tester.tap(find.text('确定'));
        await tester.pump();
      }

      expect(find.textContaining('请等待'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(passwordInputKey)).enabled, isFalse);
      expect(find.text('机密内容'), findsNothing);

      // Even the correct password is refused while locked out.
      await enterPassword(tester, '1234');
      await tester.pump();
      expect(find.text('机密内容'), findsNothing);

      // Drain the countdown timer so the test can finish cleanly.
      await tester.pump(const Duration(seconds: 31));
    });

    testWidgets('an empty password is simply wrong', (tester) async {
      final state = buildState(withPassword('1234'));
      await pump(tester, state, const ParentalGate(child: Text('机密内容')));

      await tester.tap(find.text('确定'));
      await tester.pump();
      expect(find.text('机密内容'), findsNothing);
      expect(find.text('密码不正确'), findsOneWidget);
    });
  });

  group('protection defaults', () {
    testWidgets('the rules screen is behind the password by default',
        (tester) async {
      // parentalGateProtectRules defaults to true, and the gate to password.
      final state = buildState(withPassword('1234'));
      expect(state.settings.parentalGateProtectRules, isTrue);
      await pump(tester, state, const RulesScreen());

      expect(find.byKey(passwordInputKey), findsOneWidget);
      expect(find.text('添加白名单规则'), findsNothing);
      expect(find.text('策略测试器'), findsNothing);

      await enterPassword(tester, '1234');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(find.byKey(passwordInputKey), findsNothing);
      expect(find.text('添加白名单规则'), findsWidgets);
    });

    testWidgets('the password prompt is worded for a password, not a question',
        (tester) async {
      // Regression: the rules screen used to say "请先答对下面的题目" in password
      // mode, which reads as a bug because there is no question to answer.
      final state = buildState(withPassword('1234'));
      await pump(tester, state, const RulesScreen());

      final prompt = find.byKey(passwordInputKey);
      expect(prompt, findsOneWidget);
      expect(find.textContaining('请输入家长密码'), findsOneWidget);
      expect(find.textContaining('答对下面的题目'), findsNothing);
      expect(find.byKey(challengePromptKey), findsNothing);
    });

    testWidgets('the arithmetic mode keeps its own wording', (tester) async {
      final state = buildState(AppSettings(
        localServerEnabled: false,
        parentalGateMode: ParentalGateMode.arithmetic,
        parentalGateProtectRules: true,
      ));
      await pump(tester, state, const RulesScreen());

      expect(find.byKey(challengePromptKey), findsOneWidget);
      expect(find.textContaining('请先答对下面的题目'), findsOneWidget);
      expect(find.textContaining('请输入家长密码'), findsNothing);
    });

    testWidgets('turning the protection off leaves the rules screen open',
        (tester) async {
      final state = buildState(withPassword('1234', protectRules: false));
      await pump(tester, state, const RulesScreen());

      expect(find.byKey(passwordInputKey), findsNothing);
      expect(find.text('添加白名单规则'), findsWidgets);
    });

    testWidgets('the master switch still disables everything', (tester) async {
      final state = buildState(withPassword('1234', gateEnabled: false));
      await pump(tester, state, const ParentalGate(child: Text('机密内容')));
      expect(find.text('机密内容'), findsOneWidget);
    });
  });
}
