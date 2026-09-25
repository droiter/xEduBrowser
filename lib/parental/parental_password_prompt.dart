import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'parental_password.dart';

/// Asks for the parental password in a dialog.
///
/// Returns true when the caller may continue. With no password configured there
/// is nothing to check, so it returns true immediately — the caller says so out
/// loud rather than pretending a password was entered.
///
/// Used by the home page's edit mode: the child-facing wall stays read-only
/// until a parent unlocks it, without leaving the browser for the settings gate.
Future<bool> showParentalPasswordPrompt(
  BuildContext context, {
  required String title,
  required String reason,
  String confirmLabel = '进入编辑模式',
}) async {
  final AppState state = AppScope.read(context);
  if (!state.settings.hasParentalPassword) return true;

  final bool? unlocked = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => _ParentalPasswordDialog(
      title: title,
      reason: reason,
      confirmLabel: confirmLabel,
    ),
  );
  return unlocked == true;
}

/// The dialog body: one password field, a wrong-attempt counter and the same
/// lockout the settings gate uses.
class _ParentalPasswordDialog extends StatefulWidget {
  const _ParentalPasswordDialog({
    required this.title,
    required this.reason,
    required this.confirmLabel,
  });

  final String title;
  final String reason;
  final String confirmLabel;

  @override
  State<_ParentalPasswordDialog> createState() => _ParentalPasswordDialogState();
}

class _ParentalPasswordDialogState extends State<_ParentalPasswordDialog> {
  final TextEditingController _password = TextEditingController();
  final AttemptLimiter _limiter = AttemptLimiter();
  String? _error;
  Timer? _countdown;

  @override
  void dispose() {
    _countdown?.cancel();
    _password.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _countdown ??= Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!_limiter.isLockedOut) {
        timer.cancel();
        _countdown = null;
      }
      if (mounted) setState(() {});
    });
  }

  void _submit() {
    if (_limiter.isLockedOut) return;
    final AppState state = AppScope.read(context);
    final String entered = _password.text;
    _password.clear();
    if (_limiter.record(success: state.verifyParentalPassword(entered))) {
      state.logEvent('home', '家长密码验证通过，进入首页编辑模式');
      Navigator.of(context).pop(true);
      return;
    }
    state.logEvent('home', '家长密码验证失败', level: LogLevel.warn);
    setState(() => _error = _limiter.isLockedOut ? null : '密码不正确');
    if (_limiter.isLockedOut) _startCountdown();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool lockedOut = _limiter.isLockedOut;
    final int seconds = _limiter.lockoutRemaining.inSeconds + 1;

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(widget.reason, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 14),
            TextField(
              controller: _password,
              autofocus: true,
              obscureText: true,
              enabled: !lockedOut,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: '家长密码',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              lockedOut
                  ? '尝试次数过多，请 $seconds 秒后再试。'
                  : '还可以尝试 ${_limiter.attemptsLeft} 次。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: lockedOut ? null : _submit,
          icon: const Icon(Icons.lock_open_outlined, size: 18),
          label: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
