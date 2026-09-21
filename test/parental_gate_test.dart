import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/parental/parental_challenge.dart';
import 'package:tablet_browser/parental/parental_password.dart';
import 'package:tablet_browser/parental/parental_gate.dart';
import 'package:tablet_browser/rules/rules_screen.dart';
import 'package:tablet_browser/settings/settings_screen.dart';
import 'package:tablet_browser/state/app_scope.dart';
import 'package:tablet_browser/state/app_state.dart';
import 'package:tablet_browser/ui/theme.dart';

/// The settings screen must be unreachable until the arithmetic question is
/// answered, from every entry point.
void main() {
  late Directory directory;
  late AppState state;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tablet_browser_gate');
    state = AppState(
      store: ConfigStore(directory),
      settings: const AppSettings(localServerEnabled: false, parentalGateMode: ParentalGateMode.arithmetic),
    );
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1400, 1000);
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

  /// Reads the question off the screen and works out the answer, exactly as a
  /// human would.
  String promptText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(challengePromptKey)).data!;

  int solve(String prompt) {
    final expression = prompt.replaceAll('=', '').replaceAll('?', '').trim();
    if (expression.contains('×')) {
      final parts = expression.split('×');
      return int.parse(parts[0].trim()) * int.parse(parts[1].trim());
    }
    final parts = expression.split('+');
    return int.parse(parts[0].trim()) + int.parse(parts[1].trim());
  }

  Future<void> answer(WidgetTester tester, int value) async {
    await tester.enterText(find.byKey(challengeAnswerKey), '$value');
    await tester.tap(find.text('确定'));
    await tester.pump();
  }

  testWidgets('the protected content is not built until the answer is right',
      (tester) async {
    await pump(tester, const ParentalGate(child: Text('机密内容')));

    expect(find.text('机密内容'), findsNothing);
    expect(find.text('家长验证'), findsOneWidget);
    expect(find.byKey(challengePromptKey), findsOneWidget);
    expect(promptText(tester), contains('='));
  });

  testWidgets('a wrong answer reports the mistake and asks a new question',
      (tester) async {
    await pump(tester, const ParentalGate(child: Text('机密内容')));

    final first = promptText(tester);
    await answer(tester, solve(first) + 1);

    expect(find.text('机密内容'), findsNothing);
    expect(find.textContaining('答案不对'), findsOneWidget);
    expect(promptText(tester), isNot(first));
  });

  testWidgets('the correct answer reveals the content', (tester) async {
    await pump(tester, const ParentalGate(child: Text('机密内容')));

    await answer(tester, solve(promptText(tester)));

    expect(find.byKey(challengePromptKey), findsNothing);
    expect(find.text('机密内容'), findsOneWidget);
  });

  testWidgets('every question of a multi-question challenge must be answered',
      (tester) async {
    state = AppState(
      store: ConfigStore(directory),
      settings: const AppSettings(
        localServerEnabled: false,
        parentalGateMode: ParentalGateMode.arithmetic,
        parentalGateQuestionCount: 3,
      ),
    );
    await pump(tester, const ParentalGate(child: Text('机密内容')));

    for (var step = 1; step <= 3; step++) {
      expect(find.textContaining('第 $step / 3 题'), findsOneWidget);
      await answer(tester, solve(promptText(tester)));
      if (step < 3) {
        expect(find.text('机密内容'), findsNothing, reason: 'still locked at step $step');
      }
    }

    expect(find.text('机密内容'), findsOneWidget);
  });

  testWidgets('disabling the gate lets the content through immediately',
      (tester) async {
    state = AppState(
      store: ConfigStore(directory),
      settings: const AppSettings(
        localServerEnabled: false,
        parentalGateMode: ParentalGateMode.arithmetic,
        parentalGateEnabled: false,
      ),
    );
    await pump(tester, const ParentalGate(child: Text('机密内容')));

    expect(find.text('机密内容'), findsOneWidget);
    expect(find.byKey(challengePromptKey), findsNothing);
  });

  testWidgets('repeated failures lock the gate for a while', (tester) async {
    await pump(tester, const ParentalGate(child: Text('机密内容')));

    for (var attempt = 0; attempt < 5; attempt++) {
      await answer(tester, solve(promptText(tester)) + 1);
    }

    expect(find.textContaining('请等待'), findsOneWidget);
    expect(find.text('机密内容'), findsNothing);
    // The input is disabled while locked out.
    final field = tester.widget<TextField>(find.byKey(challengeAnswerKey));
    expect(field.enabled, isFalse);

    // The countdown timer keeps running; drain it so the test can finish.
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('the settings screen itself is behind the gate', (tester) async {
    await pump(tester, const SettingsScreen());

    // Nothing from the settings content is reachable...
    expect(find.byKey(challengePromptKey), findsOneWidget);
    expect(find.textContaining('JavaScript'), findsNothing);

    // ...until the question is answered.
    await answer(tester, solve(promptText(tester)));
    expect(find.byKey(challengePromptKey), findsNothing);
    expect(find.textContaining('JavaScript'), findsWidgets);
  });

  testWidgets('changing the challenge settings does not re-lock an unlocked gate',
      (tester) async {
    await pump(tester, const SettingsScreen());
    await answer(tester, solve(promptText(tester)));
    expect(find.textContaining('JavaScript'), findsWidgets);

    // 题型 / 题目数量 are edited from inside this very screen. Committing one
    // must not throw the user back behind a fresh challenge.
    await tester.runAsync(() => state.updateSettings(
          state.settings.copyWith(
            parentalGateOperation: ParentalOperation.addition,
            parentalGateQuestionCount: 4,
          ),
        ));
    await tester.pump();

    expect(find.byKey(challengePromptKey), findsNothing);
    expect(find.textContaining('JavaScript'), findsWidgets);
  });

  testWidgets('the rules screen hides its actions until the challenge is solved',
      (tester) async {
    state = AppState(
      store: ConfigStore(directory),
      settings: const AppSettings(
        localServerEnabled: false,
        parentalGateMode: ParentalGateMode.arithmetic,
        parentalGateProtectRules: true,
      ),
    );
    await pump(tester, const RulesScreen());

    // The whole screen is gated, not just its body: the AppBar actions and the
    // add-rule button must not be reachable either.
    expect(find.byKey(challengePromptKey), findsOneWidget);
    expect(find.text('添加白名单规则'), findsNothing);
    expect(find.text('策略测试器'), findsNothing);

    await answer(tester, solve(promptText(tester)));

    expect(find.byKey(challengePromptKey), findsNothing);
    // The FAB label and the list's own add button both carry this text.
    expect(find.text('添加白名单规则'), findsWidgets);
  });

  testWidgets('the rules screen is open when protection is off', (tester) async {
    state = AppState(
      store: ConfigStore(directory),
      settings: const AppSettings(
        localServerEnabled: false,
        parentalGateMode: ParentalGateMode.arithmetic,
        parentalGateProtectRules: false,
      ),
    );
    await pump(tester, const RulesScreen());
    expect(find.byKey(challengePromptKey), findsNothing);
    expect(find.text('添加白名单规则'), findsWidgets);
  });

  test('question kinds offered by the settings are the supported ones', () {
    expect(ParentalOperation.values.map((o) => o.wire),
        containsAll(['multiplication', 'addition', 'mixed']));
    expect(ParentalOperation.fromWire('nonsense'), ParentalOperation.multiplication);
  });
}
