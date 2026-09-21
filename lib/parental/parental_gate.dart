import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'parental_challenge.dart';
import 'parental_password.dart';

/// Test hooks: stable keys so widget tests can drive the gate without depending
/// on layout or styling.
const Key challengePromptKey = ValueKey<String>('parental-question');
const Key challengeAnswerKey = ValueKey<String>('parental-answer');
const Key passwordInputKey = ValueKey<String>('parental-password');
const Key passwordConfirmKey = ValueKey<String>('parental-password-confirm');

/// Gates [child] behind the parental check.
///
/// It wraps the protected content instead of being shown before navigation, so
/// no entry point can slip past it: opening the settings screen from the
/// toolbar, from the rules screen, or from anywhere else all land on the
/// challenge first, and the protected screen is not built at all until the
/// check passes.
///
/// Presentation is a modal dialog over a dimmed background, but it lives inside
/// the route, so the system back gesture keeps working and simply leaves the
/// screen.
class ParentalGate extends StatefulWidget {
  const ParentalGate({
    super.key,
    required this.child,
    this.title = '家长验证',
    this.reason,
  });

  final Widget child;
  final String title;

  /// Overrides the explanation. Left null by default so the wording can match
  /// the active challenge: telling someone to "answer the question below" when
  /// the gate is asking for a password reads as a bug.
  final String? reason;

  @override
  State<ParentalGate> createState() => _ParentalGateState();
}

class _ParentalGateState extends State<ParentalGate> {
  bool _unlocked = false;

  /// The explanation shown, worded for whichever challenge is active.
  String _reasonFor(AppSettings settings) {
    if (widget.reason != null) return widget.reason!;
    return settings.parentalGateMode == ParentalGateMode.password
        ? '这部分内容受家长验证保护，请输入家长密码。'
        : '这部分内容受家长验证保护，请先答对下面的题目。';
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    if (!settings.parentalGateEnabled || _unlocked) return widget.child;
    final reason = _reasonFor(settings);

    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Dialog(
            insetPadding: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 26, 28, 18),
              child: settings.parentalGateMode == ParentalGateMode.password
                  ? _PasswordGate(
                      title: widget.title,
                      reason: reason,
                      onUnlocked: () => setState(() => _unlocked = true),
                    )
                  : _ArithmeticGate(
                      title: widget.title,
                      reason: reason,
                      operation: settings.parentalGateOperation,
                      questionCount: settings.parentalGateQuestionCount,
                      onUnlocked: () => setState(() => _unlocked = true),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared dialog chrome: icon, title, explanation, form fields, then buttons.
class _GateFrame extends StatelessWidget {
  const _GateFrame({
    required this.icon,
    required this.title,
    required this.reason,
    required this.fields,
    required this.actions,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String reason;

  /// The form fields, between the explanation and the buttons.
  final List<Widget> fields;

  final List<Widget> actions;

  /// Optional small label at the top right, e.g. a question counter.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
            ?trailing,
          ],
        ),
        const SizedBox(height: 10),
        Text(reason, style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor)),
        const SizedBox(height: 20),
        ...fields,
        const SizedBox(height: 18),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
      ],
    );
  }
}

/// The default challenge: the password the parent set.
class _PasswordGate extends StatefulWidget {
  const _PasswordGate({
    required this.title,
    required this.reason,
    required this.onUnlocked,
  });

  final String title;
  final String reason;
  final VoidCallback onUnlocked;

  @override
  State<_PasswordGate> createState() => _PasswordGateState();
}

class _PasswordGateState extends State<_PasswordGate> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final AttemptLimiter _limiter = AttemptLimiter();
  String? _error;
  Timer? _countdown;

  /// With no password configured the gate asks the parent to set one, rather
  /// than shipping a default a child could guess.
  bool get _setupMode => !AppScope.read(context).settings.hasParentalPassword;

  @override
  void dispose() {
    _countdown?.cancel();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _countdown ??= Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_limiter.isLockedOut) {
        timer.cancel();
        _countdown = null;
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _submit() async {
    if (_limiter.isLockedOut) return;
    final state = AppScope.read(context);

    if (_setupMode) {
      final password = _password.text;
      final problem = ParentalPassword.validate(password) ??
          (password == _confirm.text ? null : '两次输入的密码不一致');
      if (problem != null) {
        setState(() => _error = problem);
        return;
      }
      // The parent just set it, so they are through. The hash is already in
      // memory after this call, so unlocking must not wait on the disk write.
      unawaited(state.setParentalPassword(password));
      _password.clear();
      _confirm.clear();
      widget.onUnlocked();
      return;
    }

    final entered = _password.text;
    _password.clear();
    final ok = _limiter.record(success: state.verifyParentalPassword(entered));
    if (ok) {
      widget.onUnlocked();
      return;
    }
    setState(() => _error = _limiter.isLockedOut ? null : '密码不正确');
    if (_limiter.isLockedOut) _startCountdown();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lockedOut = _limiter.isLockedOut;
    final seconds = _limiter.lockoutRemaining.inSeconds + 1;

    if (_setupMode) {
      return _GateFrame(
        icon: Icons.lock_reset,
        title: widget.title,
        reason: '首次使用：请设置家长密码。之后进入受保护页面都需要输入它。',
        fields: [
          TextField(
            key: passwordInputKey,
            controller: _password,
            autofocus: true,
            obscureText: true,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: '设置家长密码',
              hintText: '至少 ${ParentalPassword.minLength} 位',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: passwordConfirmKey,
            controller: _confirm,
            obscureText: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: '再次输入',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '密码无法找回：忘记后需要清除应用数据（规则与书签也会一起清空），请记牢。',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        ],
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _submit,
            icon: const Icon(Icons.check),
            label: const Text('设置并进入'),
          ),
        ],
      );
    }

    return _GateFrame(
      icon: Icons.lock_outline,
      title: widget.title,
      reason: widget.reason,
      fields: [
        TextField(
          key: passwordInputKey,
          controller: _password,
          autofocus: true,
          obscureText: true,
          enabled: !lockedOut,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: '家长密码',
            errorText: _error,
            border: const OutlineInputBorder(),
          ),
        ),
        if (lockedOut) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.timer_outlined, size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '连续输错次数过多，请等待 $seconds 秒后再试。',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        ] else if (_limiter.consecutiveFailures > 0) ...[
          const SizedBox(height: 8),
          Text(
            '还可以尝试 ${_limiter.attemptsLeft} 次',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ],
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('取消'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: lockedOut ? null : _submit,
          icon: const Icon(Icons.check),
          label: const Text('确定'),
        ),
      ],
    );
  }
}

/// The optional arithmetic challenge, for anyone who would rather not manage a
/// password.
class _ArithmeticGate extends StatefulWidget {
  const _ArithmeticGate({
    required this.title,
    required this.reason,
    required this.operation,
    required this.questionCount,
    required this.onUnlocked,
  });

  final String title;
  final String reason;
  final ParentalOperation operation;
  final int questionCount;
  final VoidCallback onUnlocked;

  @override
  State<_ArithmeticGate> createState() => _ArithmeticGateState();
}

class _ArithmeticGateState extends State<_ArithmeticGate> {
  late final ParentalChallenge _challenge = ParentalChallenge(
    operation: widget.operation,
    questionCount: widget.questionCount,
  );
  final TextEditingController _answer = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _wrong = false;
  Timer? _countdown;

  @override
  void dispose() {
    _countdown?.cancel();
    _answer.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _countdown ??= Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_challenge.isLockedOut) {
        timer.cancel();
        _countdown = null;
      }
      if (mounted) setState(() {});
    });
  }

  void _submit() {
    if (_challenge.isLockedOut) return;
    final value = int.tryParse(_answer.text.trim());
    if (value == null) {
      setState(() => _wrong = true);
      return;
    }
    final correct = _challenge.submit(value);
    _answer.clear();
    if (correct) {
      if (_challenge.isSolved) {
        widget.onUnlocked();
        return;
      }
      setState(() => _wrong = false);
      _focus.requestFocus();
      return;
    }
    setState(() => _wrong = true);
    if (_challenge.isLockedOut) _startCountdown();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lockedOut = _challenge.isLockedOut;
    final seconds = _challenge.lockoutRemaining.inSeconds + 1;

    return _GateFrame(
      icon: Icons.lock_outline,
      title: widget.title,
      reason: widget.reason,
      trailing: _challenge.questionCount > 1
          ? Text(
              '第 ${_challenge.currentIndex} / ${_challenge.questionCount} 题',
              style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor),
            )
          : null,
      fields: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 18),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text(
              _challenge.current.prompt,
              key: challengePromptKey,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: challengeAnswerKey,
          controller: _answer,
          focusNode: _focus,
          autofocus: true,
          enabled: !lockedOut,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(4),
          ],
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            hintText: '输入答案',
            errorText: _wrong && !lockedOut ? '答案不对，请再算一次' : null,
            border: const OutlineInputBorder(),
          ),
        ),
        if (lockedOut) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.timer_outlined, size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '连续答错次数过多，请等待 $seconds 秒后再试。',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        ],
      ],
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('取消'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: lockedOut ? null : _submit,
          icon: const Icon(Icons.check),
          label: const Text('确定'),
        ),
      ],
    );
  }
}
