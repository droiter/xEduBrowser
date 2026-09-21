import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// How the parental gate challenges an adult.
enum ParentalGateMode {
  /// A password the parent set. The default: unlike arithmetic, a child cannot
  /// simply work it out.
  password('password', '家长密码'),

  /// A single-digit arithmetic question, kept as an option for anyone who would
  /// rather not manage a password.
  arithmetic('arithmetic', '算术题');

  const ParentalGateMode(this.wire, this.labelZh);
  final String wire;
  final String labelZh;

  static ParentalGateMode fromWire(String? value) => ParentalGateMode.values.firstWhere(
        (m) => m.wire == value,
        orElse: () => ParentalGateMode.password,
      );
}

/// Salted, iterated SHA-256 hashing for the parental password.
///
/// The threat model is a child with the tablet, not a forensic attacker, but a
/// password should still never be written down in clear text: only the salt and
/// the derived hash ever reach `settings.json`.
///
/// `crypto` gives a plain SHA-256, so the derivation is stretched by hashing
/// repeatedly. That is not PBKDF2/Argon2, but it turns an instant guess into a
/// measurable cost, which is the useful property against someone tapping at the
/// screen.
abstract final class ParentalPassword {
  /// Minimum accepted length. Short enough not to be annoying on a tablet,
  /// long enough that a child cannot stumble onto it.
  static const int minLength = 4;

  /// Iterations of SHA-256. Roughly 10-40 ms on a tablet: imperceptible when
  /// unlocking, expensive when guessing thousands of times.
  static const int iterations = 10000;

  static const int saltBytes = 16;

  /// A fresh random salt, base64 encoded for storage.
  static String newSalt([Random? random]) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(saltBytes, (_) => rng.nextInt(256));
    return base64Encode(bytes);
  }

  /// Derives the stored hash for [password] and [salt].
  static String derive(String password, String salt) {
    var digest = sha256.convert(utf8.encode('$salt:$password')).bytes;
    for (var i = 1; i < iterations; i++) {
      digest = sha256.convert(digest).bytes;
    }
    return base64Encode(digest);
  }

  /// Constant-time comparison, so a wrong guess cannot be narrowed down by
  /// measuring how long the check took.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }

  /// True when [password] matches the stored [hash] for [salt].
  ///
  /// An empty [hash] (nothing configured yet) never matches.
  static bool verify({
    required String password,
    required String hash,
    required String salt,
  }) {
    if (hash.isEmpty || salt.isEmpty || password.isEmpty) return false;
    return _constantTimeEquals(derive(password, salt), hash);
  }

  /// Why a candidate password is unacceptable, or null when it is fine.
  static String? validate(String password) {
    if (password.trim().length < minLength) {
      return '密码至少 $minLength 位';
    }
    if (password.trim() != password) {
      return '密码首尾不要有空格';
    }
    return null;
  }
}

/// Bounds how often a wrong password can be tried.
///
/// Deliberately independent of real time so the whole flow — including the
/// lockout window — is unit testable with an injected clock.
class AttemptLimiter {
  AttemptLimiter({
    this.maxAttempts = 5,
    this.lockoutDuration = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int maxAttempts;
  final Duration lockoutDuration;
  final DateTime Function() _now;

  int _consecutiveFailures = 0;
  int _totalFailures = 0;
  DateTime? _lockedUntil;

  int get consecutiveFailures => _consecutiveFailures;

  int get totalFailures => _totalFailures;

  int get attemptsLeft => (maxAttempts - _consecutiveFailures).clamp(0, maxAttempts);

  Duration get lockoutRemaining {
    final until = _lockedUntil;
    if (until == null) return Duration.zero;
    final remaining = until.difference(_now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool get isLockedOut => lockoutRemaining > Duration.zero;

  /// Records an attempt. Returns true when it succeeded (which also clears the
  /// failure streak).
  bool record({required bool success}) {
    if (isLockedOut) return false;
    if (success) {
      _consecutiveFailures = 0;
      _lockedUntil = null;
      return true;
    }
    _consecutiveFailures++;
    _totalFailures++;
    if (_consecutiveFailures >= maxAttempts) {
      _lockedUntil = _now().add(lockoutDuration);
      _consecutiveFailures = 0;
    }
    return false;
  }

  void reset() {
    _consecutiveFailures = 0;
    _lockedUntil = null;
  }
}
