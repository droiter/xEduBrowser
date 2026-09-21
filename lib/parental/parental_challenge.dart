import 'dart:math';

/// What kind of arithmetic the parental gate asks.
enum ParentalOperation {
  multiplication('multiplication', '一位数乘法'),
  addition('addition', '一位数加法'),
  mixed('mixed', '乘法/加法混合');

  const ParentalOperation(this.wire, this.labelZh);
  final String wire;
  final String labelZh;

  static ParentalOperation fromWire(String? value) => ParentalOperation.values.firstWhere(
        (o) => o.wire == value,
        orElse: () => ParentalOperation.multiplication,
      );
}

/// The two supported single-digit operations.
enum ParentalQuestionKind { multiply, add }

/// One question, e.g. `7 × 8 = ?`.
class ParentalQuestion {
  final int left;
  final int right;
  final ParentalQuestionKind kind;

  const ParentalQuestion._(this.left, this.right, this.kind);

  int get answer => kind == ParentalQuestionKind.multiply ? left * right : left + right;

  String get prompt => '$left${kind == ParentalQuestionKind.multiply ? ' × ' : ' + '}$right = ?';

  String get operatorLabel => kind == ParentalQuestionKind.multiply ? '×' : '+';

  /// Both operands are single digits (2..9), as specified.
  static const int minOperand = 2;
  static const int maxOperand = 9;

  bool get isValid => left >= minOperand && left <= maxOperand &&
      right >= minOperand && right <= maxOperand;

  @override
  String toString() => prompt;
}

/// The state machine behind the parental challenge.
///
/// Pure logic with an injectable clock and RNG so the whole flow — including the
/// lockout after repeated failures — is unit testable without real time.
class ParentalChallenge {
  ParentalChallenge({
    required this.operation,
    required this.questionCount,
    Random? random,
    DateTime Function()? now,
    this.maxAttempts = 5,
    this.lockoutDuration = const Duration(seconds: 30),
  })  : _random = random ?? Random(),
        _now = now ?? DateTime.now,
        assert(questionCount >= 1);

  final ParentalOperation operation;
  final int questionCount;

  /// Wrong answers allowed before a lockout kicks in.
  final int maxAttempts;

  /// How long the gate refuses input after [maxAttempts] failures.
  final Duration lockoutDuration;

  final Random _random;
  final DateTime Function() _now;

  late ParentalQuestion _current = _generate();

  /// Prompt of the question handed out last, so the next one differs.
  String? _lastPrompt;

  int _solved = 0;
  int _wrong = 0;
  int _totalWrong = 0;
  DateTime? _lockoutUntil;

  /// The question the user must answer now.
  ParentalQuestion get current => _current;

  /// How many questions have been answered correctly so far.
  int get solvedCount => _solved;

  /// 1-based index of the current question, for "第 n / N 题".
  ///
  /// Clamped once solved, so a progress label can never read "第 4 / 3 题".
  int get currentIndex => isSolved ? questionCount : _solved + 1;

  /// Wrong answers since the last correct one.
  int get wrongAttempts => _wrong;

  /// Total wrong answers, useful for logging.
  int get totalWrongAttempts => _totalWrong;

  bool get isSolved => _solved >= questionCount;

  bool get isLockedOut => lockoutRemaining > Duration.zero;

  Duration get lockoutRemaining {
    final until = _lockoutUntil;
    if (until == null) return Duration.zero;
    final remaining = until.difference(_now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Submits [answer]. Returns true when it was correct.
  ///
  /// A wrong answer replaces the question (so the same problem cannot be brute
  /// forced) and, after [maxAttempts] wrong answers in a row, starts a lockout.
  bool submit(int answer) {
    if (isLockedOut) return false;
    if (answer == _current.answer) {
      _solved++;
      _wrong = 0;
      _lockoutUntil = null;
      if (!isSolved) _current = _generate();
      return true;
    }

    _wrong++;
    _totalWrong++;
    if (_wrong >= maxAttempts && !isSolved) {
      _lockoutUntil = _now().add(lockoutDuration);
      _wrong = 0;
    }
    _current = _generate();
    return false;
  }

  /// Restarts the whole challenge with fresh questions.
  void reset() {
    _solved = 0;
    _wrong = 0;
    _lockoutUntil = null;
    _current = _generate();
  }

  ParentalQuestion _generate() {
    final kind = switch (operation) {
      ParentalOperation.multiplication => ParentalQuestionKind.multiply,
      ParentalOperation.addition => ParentalQuestionKind.add,
      ParentalOperation.mixed =>
        _random.nextBool() ? ParentalQuestionKind.multiply : ParentalQuestionKind.add,
    };

    // Reroll a few times so the same problem is not asked twice in a row.
    for (var attempt = 0; attempt < 8; attempt++) {
      final left = ParentalQuestion.minOperand +
          _random.nextInt(ParentalQuestion.maxOperand - ParentalQuestion.minOperand + 1);
      final right = ParentalQuestion.minOperand +
          _random.nextInt(ParentalQuestion.maxOperand - ParentalQuestion.minOperand + 1);
      final candidate = ParentalQuestion._(left, right, kind);
      if (candidate.prompt != _lastPrompt) {
        _lastPrompt = candidate.prompt;
        return candidate;
      }
    }
    final fallback =
        ParentalQuestion._(ParentalQuestion.maxOperand, ParentalQuestion.maxOperand, kind);
    _lastPrompt = fallback.prompt;
    return fallback;
  }
}
