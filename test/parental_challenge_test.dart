import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/parental/parental_challenge.dart';

/// The gate's state machine: single-digit questions, retry behaviour, and the
/// lockout that stops a child from brute-forcing the answer.
void main() {
  ParentalChallenge build({
    ParentalOperation operation = ParentalOperation.multiplication,
    int questionCount = 1,
    int maxAttempts = 5,
    Duration lockout = const Duration(seconds: 30),
    DateTime Function()? now,
    int seed = 7,
  }) =>
      ParentalChallenge(
        operation: operation,
        questionCount: questionCount,
        maxAttempts: maxAttempts,
        lockoutDuration: lockout,
        random: Random(seed),
        now: now,
      );

  group('question generation', () {
    test('multiplication questions use single digits and the product is right', () {
      final challenge = build();
      for (var i = 0; i < 200; i++) {
        final question = challenge.current;
        expect(question.kind, ParentalQuestionKind.multiply);
        expect(question.left, inInclusiveRange(2, 9));
        expect(question.right, inInclusiveRange(2, 9));
        expect(question.answer, question.left * question.right);
        expect(question.prompt, contains('×'));
        challenge.submit(question.answer);
      }
    });

    test('addition mode only adds', () {
      final challenge = build(operation: ParentalOperation.addition, questionCount: 50);
      for (var i = 0; i < 50; i++) {
        expect(challenge.current.kind, ParentalQuestionKind.add);
        expect(challenge.current.answer,
            challenge.current.left + challenge.current.right);
        challenge.submit(challenge.current.answer);
      }
      expect(challenge.isSolved, isTrue);
    });

    test('mixed mode only ever produces the two supported operations', () {
      final challenge = build(operation: ParentalOperation.mixed, questionCount: 100);
      for (var i = 0; i < 100; i++) {
        final question = challenge.current;
        expect(question.isValid, isTrue);
        expect(question.answer, greaterThanOrEqualTo(4));
        challenge.submit(question.answer);
      }
      expect(challenge.isSolved, isTrue);
    });

    test('consecutive questions differ', () {
      final challenge = build(questionCount: 60);
      var previous = challenge.current.prompt;
      for (var i = 0; i < 59; i++) {
        challenge.submit(challenge.current.answer);
        expect(challenge.current.prompt, isNot(previous));
        previous = challenge.current.prompt;
      }
    });
  });

  group('answering', () {
    test('a correct answer solves a single-question challenge', () {
      final challenge = build();
      expect(challenge.isSolved, isFalse);
      expect(challenge.currentIndex, 1);
      expect(challenge.submit(challenge.current.answer), isTrue);
      expect(challenge.isSolved, isTrue);
    });

    test('every question must be answered', () {
      final challenge = build(questionCount: 3);
      for (var solved = 1; solved <= 3; solved++) {
        expect(challenge.solvedCount, solved - 1);
        expect(challenge.currentIndex, solved);
        expect(challenge.submit(challenge.current.answer), isTrue);
      }
      expect(challenge.isSolved, isTrue);
      expect(challenge.currentIndex, 3);
    });

    test('a wrong answer keeps the gate closed and asks a new question', () {
      final challenge = build(questionCount: 2);
      final first = challenge.current.prompt;
      expect(challenge.submit(challenge.current.answer + 1), isFalse);
      expect(challenge.isSolved, isFalse);
      expect(challenge.wrongAttempts, 1);
      expect(challenge.totalWrongAttempts, 1);
      expect(challenge.current.prompt, isNot(first));

      // The challenge can still be completed normally afterwards.
      expect(challenge.submit(challenge.current.answer), isTrue);
      expect(challenge.submit(challenge.current.answer), isTrue);
      expect(challenge.isSolved, isTrue);
    });

    test('a correct answer clears the wrong-answer streak', () {
      final challenge = build(questionCount: 4, maxAttempts: 3);
      challenge.submit(challenge.current.answer + 1);
      expect(challenge.wrongAttempts, 1);
      challenge.submit(challenge.current.answer);
      expect(challenge.wrongAttempts, 0);
      expect(challenge.isLockedOut, isFalse);
    });

    test('zero and negative answers are simply wrong, never accepted', () {
      final challenge = build();
      expect(challenge.submit(0), isFalse);
      expect(challenge.submit(-1), isFalse);
      expect(challenge.isSolved, isFalse);
    });
  });

  group('lockout', () {
    test('repeated failures lock the gate for the configured duration', () {
      var now = DateTime(2026, 1, 1, 12);
      final challenge = build(
        maxAttempts: 3,
        lockout: const Duration(seconds: 30),
        now: () => now,
      );

      for (var attempt = 0; attempt < 3; attempt++) {
        expect(challenge.submit(challenge.current.answer + 1), isFalse);
      }

      expect(challenge.isLockedOut, isTrue);
      expect(challenge.lockoutRemaining.inSeconds, 30);

      // Even the right answer is refused while locked out.
      final lockedQuestion = challenge.current.prompt;
      expect(challenge.submit(challenge.current.answer), isFalse);
      expect(challenge.current.prompt, lockedQuestion);
      expect(challenge.isSolved, isFalse);

      // Time passing releases it.
      now = now.add(const Duration(seconds: 29));
      expect(challenge.isLockedOut, isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(challenge.isLockedOut, isFalse);
      expect(challenge.lockoutRemaining, Duration.zero);
      expect(challenge.submit(challenge.current.answer), isTrue);
    });

    test('never locks out once solved', () {
      final challenge = build(questionCount: 1, maxAttempts: 2);
      expect(challenge.submit(challenge.current.answer), isTrue);
      expect(challenge.isSolved, isTrue);
      // Post-solve submissions are irrelevant but must not lock the gate.
      challenge.submit(-99);
      expect(challenge.isLockedOut, isFalse);
    });
  });

  group('reset', () {
    test('restarts the whole challenge', () {
      final challenge = build(questionCount: 2);
      challenge.submit(challenge.current.answer);
      expect(challenge.solvedCount, 1);

      challenge.reset();
      expect(challenge.solvedCount, 0);
      expect(challenge.currentIndex, 1);
      expect(challenge.isSolved, isFalse);
      expect(challenge.wrongAttempts, 0);
      expect(challenge.isLockedOut, isFalse);
    });
  });
}
