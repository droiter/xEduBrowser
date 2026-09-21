import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/parental/parental_password.dart';
import 'package:tablet_browser/state/app_state.dart';

/// The parental password: derivation, verification, storage hygiene and the
/// attempt limiter.
void main() {
  group('derivation', () {
    test('the same password and salt always derive the same hash', () {
      const salt = 'c2FsdHNhbHRzYWx0c2ExMg==';
      final first = ParentalPassword.derive('hunter2', salt);
      final second = ParentalPassword.derive('hunter2', salt);
      expect(first, second);
      expect(first, isNotEmpty);
    });

    test('a different salt gives a different hash for the same password', () {
      final saltA = ParentalPassword.newSalt(Random(1));
      final saltB = ParentalPassword.newSalt(Random(2));
      expect(saltA, isNot(saltB));
      expect(
        ParentalPassword.derive('hunter2', saltA),
        isNot(ParentalPassword.derive('hunter2', saltB)),
      );
    });

    test('the password itself never appears in the stored values', () {
      final salt = ParentalPassword.newSalt();
      final hash = ParentalPassword.derive('correct horse battery', salt);
      expect(hash, isNot(contains('correct')));
      expect(salt, isNot(contains('correct')));
    });

    test('salts are random and long enough', () {
      final salts = {for (var i = 0; i < 50; i++) ParentalPassword.newSalt()};
      expect(salts.length, 50);
      expect(ParentalPassword.newSalt().length, greaterThanOrEqualTo(20));
    });
  });

  group('verification', () {
    late String salt;
    late String hash;

    setUp(() {
      salt = ParentalPassword.newSalt();
      hash = ParentalPassword.derive('家长密码1234', salt);
    });

    test('accepts the right password', () {
      expect(
        ParentalPassword.verify(password: '家长密码1234', hash: hash, salt: salt),
        isTrue,
      );
    });

    test('rejects a wrong password, an empty one, and near misses', () {
      for (final attempt in ['家长密码123', '家长密码12345', '家长密码1235', '', 'x']) {
        expect(
          ParentalPassword.verify(password: attempt, hash: hash, salt: salt),
          isFalse,
          reason: 'must reject "$attempt"',
        );
      }
    });

    test('rejects everything when nothing is configured yet', () {
      expect(
        ParentalPassword.verify(password: 'anything', hash: '', salt: ''),
        isFalse,
      );
      expect(
        ParentalPassword.verify(password: 'anything', hash: hash, salt: ''),
        isFalse,
      );
    });

    test('a hash from another salt does not verify', () {
      final otherSalt = ParentalPassword.newSalt();
      expect(
        ParentalPassword.verify(password: '家长密码1234', hash: hash, salt: otherSalt),
        isFalse,
      );
    });
  });

  group('validation', () {
    test('rejects short, empty and whitespace-padded passwords', () {
      expect(ParentalPassword.validate(''), isNotNull);
      expect(ParentalPassword.validate('123'), isNotNull);
      expect(ParentalPassword.validate(' 1234 '), isNotNull);
      expect(ParentalPassword.validate('1234'), isNull);
      expect(ParentalPassword.validate('家长密码'), isNull);
    });
  });

  group('attempt limiter', () {
    test('a success clears the failure streak', () {
      final limiter = AttemptLimiter();
      limiter.record(success: false);
      limiter.record(success: false);
      expect(limiter.consecutiveFailures, 2);
      expect(limiter.attemptsLeft, 3);
      limiter.record(success: true);
      expect(limiter.consecutiveFailures, 0);
      expect(limiter.isLockedOut, isFalse);
    });

    test('too many failures lock out, and time releases it', () {
      var now = DateTime(2026, 3, 1, 9);
      final limiter = AttemptLimiter(
        maxAttempts: 3,
        lockoutDuration: const Duration(seconds: 30),
        now: () => now,
      );

      for (var i = 0; i < 3; i++) {
        expect(limiter.record(success: false), isFalse);
      }
      expect(limiter.isLockedOut, isTrue);
      expect(limiter.lockoutRemaining.inSeconds, 30);

      // Even a correct password is refused while locked out.
      expect(limiter.record(success: true), isFalse);
      expect(limiter.isLockedOut, isTrue);

      now = now.add(const Duration(seconds: 31));
      expect(limiter.isLockedOut, isFalse);
      expect(limiter.record(success: true), isTrue);
    });
  });

  group('AppSettings integration', () {
    test('starts with no password and the expected defaults', () {
      const settings = AppSettings();
      expect(settings.hasParentalPassword, isFalse);
      expect(settings.parentalGateEnabled, isTrue);
      expect(settings.parentalGateMode, ParentalGateMode.password);
      // Both protections are on out of the box.
      expect(settings.parentalGateProtectRules, isTrue);
    });

    test('setting a password stores only a salt and a hash', () async {
      final state = AppState(
        store: ConfigStore(Directory.systemTemp.createTempSync('tb_pw')),
        settings: const AppSettings(localServerEnabled: false),
      );

      await state.setParentalPassword('家长密码1234');

      expect(state.settings.hasParentalPassword, isTrue);
      expect(state.settings.parentalPasswordHash, isNotEmpty);
      expect(state.settings.parentalPasswordSalt, isNotEmpty);
      expect(state.settings.parentalPasswordHash, isNot(contains('家长密码')));
      expect(state.verifyParentalPassword('家长密码1234'), isTrue);
      expect(state.verifyParentalPassword('错密码'), isFalse);
    });

    test('changing the password invalidates the old one', () async {
      final state = AppState(
        store: ConfigStore(Directory.systemTemp.createTempSync('tb_pw2')),
        settings: const AppSettings(localServerEnabled: false),
      );

      await state.setParentalPassword('first1234');
      await state.setParentalPassword('second1234');

      expect(state.verifyParentalPassword('first1234'), isFalse);
      expect(state.verifyParentalPassword('second1234'), isTrue);
    });

    test('clearing the password puts the gate back into setup mode', () async {
      final state = AppState(
        store: ConfigStore(Directory.systemTemp.createTempSync('tb_pw3')),
        settings: const AppSettings(localServerEnabled: false),
      );

      await state.setParentalPassword('1234');
      expect(state.settings.hasParentalPassword, isTrue);

      await state.clearParentalPassword();
      expect(state.settings.hasParentalPassword, isFalse);
      expect(state.verifyParentalPassword('1234'), isFalse);
    });

    test('the password never reaches the native WebView settings payload', () async {
      final state = AppState(
        store: ConfigStore(Directory.systemTemp.createTempSync('tb_pw4')),
        settings: const AppSettings(localServerEnabled: false),
      );
      await state.setParentalPassword('secret1234');

      final payload = state.settings.toNativeSettings();
      expect(payload.values.whereType<String>(), isNot(contains('secret1234')));
      expect(payload.containsKey('parentalPasswordHash'), isFalse);
      expect(payload.containsKey('parentalPasswordSalt'), isFalse);
    });

    test('settings survive a JSON round trip and carry the password fields', () {
      const settings = AppSettings(
        parentalGateMode: ParentalGateMode.arithmetic,
        parentalPasswordHash: 'hash',
        parentalPasswordSalt: 'salt',
        parentalGateProtectRules: false,
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.parentalGateMode, ParentalGateMode.arithmetic);
      expect(restored.parentalPasswordHash, 'hash');
      expect(restored.parentalPasswordSalt, 'salt');
      expect(restored.parentalGateProtectRules, isFalse);
      expect(restored.hasParentalPassword, isTrue);
    });

    test('an old settings file without the new fields defaults to password mode', () {
      final restored = AppSettings.fromJson(const {
        'javaScript': true,
        'localServerEnabled': false,
      });
      expect(restored.parentalGateMode, ParentalGateMode.password);
      expect(restored.hasParentalPassword, isFalse);
      expect(restored.parentalGateProtectRules, isTrue);
    });
  });
}
