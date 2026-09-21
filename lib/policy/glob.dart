/// Glob pattern language, matching, and **language containment**.
///
/// This file is the mathematical core of the filter: it answers two questions.
///
///  1. Does a pattern match a URL?                       -> [GlobPattern.matches]
///  2. Is the language of one set of patterns a subset
///     of the language of another set of patterns?       -> [GlobContainment.isSubset]
///
/// Question 2 is what makes the "more specific rule wins" requirement decidable
/// rather than guesswork. It is answered exactly: a pattern is compiled to an
/// NFA, the superset side is determinised on the fly by subset construction,
/// and the product automaton is searched for a reachable state that accepts on
/// the subset side while rejecting on the superset side. Such a state exists
/// iff `L(sub) \ L(sup)` is non-empty, i.e. iff the subset relation fails.
///
/// The alphabet is infinite (all code units), but only finitely many code units
/// can ever matter: the literal characters occurring in the patterns under
/// comparison. Every other character is behaviourally identical, so the search
/// runs over a finite alphabet of (distinct literals + one "other" class).
library;

import 'dart:collection';

/// Pattern syntax:
///
///  * `*`   zero or more characters
///  * `?`   exactly one character
///  * `\x`  literal `x` (escape)
///
/// Every other character matches itself.
///
/// When [GlobPattern.implicitTrailingStar] is true the pattern is a **prefix**
/// pattern: `https://example.com/news` also matches
/// `https://example.com/news/2026/01`. Internally that is simply a trailing
/// `*` appended at compile time, so matching stays a plain whole-string match
/// and containment stays a plain language-containment question. This is the
/// setting that implements the requirement "以名单为前缀的网址都被认为成功匹配".
enum _AtomKind { literal, anyChar, star }

class _Atom {
  final _AtomKind kind;
  final int? unit;
  const _Atom._(this.kind, [this.unit]);
  const _Atom.literal(int u) : this._(_AtomKind.literal, u);
  const _Atom.anyChar() : this._(_AtomKind.anyChar);
  const _Atom.star() : this._(_AtomKind.star);
}

/// A single compiled glob pattern.
class GlobPattern {
  /// The pattern text as authored (after normalisation done by the caller).
  final String source;

  /// Whether a trailing `*` is implied (prefix semantics).
  final bool implicitTrailingStar;

  final List<_Atom> _atoms;

  late final Set<int> _literalUnits = _collectLiteralUnits();

  /// The state index that accepts. The NFA always has `_atoms.length + 1`
  /// states, numbered `0 .. _atoms.length`.
  int get _accept => _atoms.length;

  GlobPattern._(this.source, this.implicitTrailingStar, this._atoms);

  /// Compiles [pattern]. A trailing `*` is appended unless one is already
  /// present, when [implicitTrailingStar] is true.
  factory GlobPattern.compile(String pattern, {bool implicitTrailingStar = true}) {
    final atoms = <_Atom>[];
    var escaped = false;
    for (final unit in pattern.codeUnits) {
      if (escaped) {
        atoms.add(_Atom.literal(unit));
        escaped = false;
        continue;
      }
      switch (unit) {
        case 0x5C: // backslash
          escaped = true;
        case 0x2A: // *
          atoms.add(const _Atom.star());
        case 0x3F: // ?
          atoms.add(const _Atom.anyChar());
        default:
          atoms.add(_Atom.literal(unit));
      }
    }
    if (escaped) {
      // Dangling escape: treat the backslash itself as a literal.
      atoms.add(const _Atom.literal(0x5C));
    }
    if (implicitTrailingStar && (atoms.isEmpty || atoms.last.kind != _AtomKind.star)) {
      atoms.add(const _Atom.star());
    }
    return GlobPattern._(pattern, implicitTrailingStar, List.unmodifiable(atoms));
  }

  Set<int> _collectLiteralUnits() => {
        for (final atom in _atoms)
          if (atom.kind == _AtomKind.literal) atom.unit!,
      };

  /// Every code unit that appears literally in this pattern. Used to build the
  /// finite alphabet for [GlobContainment].
  Set<int> get literalUnits => _literalUnits;

  /// True when the pattern is the match-everything pattern, which can never be
  /// the more specific side of a containment relation.
  bool get matchesEverything => _atoms.every((a) => a.kind == _AtomKind.star);

  /// Whole-string match against [input].
  bool matches(String input) {
    var states = _startStates();
    for (final unit in input.codeUnits) {
      states = _step(states, unit);
      if (states.isEmpty) return false;
    }
    return _accepts(states);
  }

  // ---------------------------------------------------------------------
  // NFA primitives. A state has exactly one outgoing transition kind, so the
  // automaton needs no general transition table.
  // ---------------------------------------------------------------------

  Set<int> _startStates() => _epsilonClosure({0});

  bool _accepts(Set<int> states) => states.contains(_accept);

  /// Epsilon steps are only possible out of `*` states, which may chain.
  Set<int> _epsilonClosure(Set<int> seed) {
    final closure = <int>{};
    final stack = <int>[...seed];
    while (stack.isNotEmpty) {
      final state = stack.removeLast();
      if (!closure.add(state)) continue;
      if (state < _atoms.length && _atoms[state].kind == _AtomKind.star) {
        stack.add(state + 1);
      }
    }
    return closure;
  }

  /// Consumes one character. [unit] is the consumed code unit, or `null` for
  /// the "any character not listed literally in either pattern" class, which
  /// may only be consumed by `*` and `?`.
  Set<int> _step(Set<int> states, int? unit) {
    final moved = <int>{};
    for (final state in states) {
      if (state >= _atoms.length) continue; // accept state, no outgoing edges
      final atom = _atoms[state];
      switch (atom.kind) {
        case _AtomKind.star:
          moved.add(state); // consume and stay: `*` is unbounded
        case _AtomKind.anyChar:
          moved.add(state + 1);
        case _AtomKind.literal:
          if (unit != null && atom.unit == unit) moved.add(state + 1);
      }
    }
    return _epsilonClosure(moved);
  }
}

/// Thrown when the containment search exceeds its state budget. Callers should
/// treat this as "unknown", not as "false".
class ContainmentBudgetExceeded implements Exception {
  final int budget;
  final String detail;
  ContainmentBudgetExceeded(this.budget, this.detail);
  @override
  String toString() => 'ContainmentBudgetExceeded($budget): $detail';
}

/// Exact language containment over sets of glob patterns (the union of each
/// set is the language of that set).
abstract final class GlobContainment {
  /// Upper bound on visited product states. Patterns authored by a human are
  /// tiny and never come close; the cap exists so a pathological pattern
  /// degrades into "unknown" instead of hanging the UI.
  static const int defaultBudget = 200000;

  /// Encodes `(patternIndex, state)` into one int for union states.
  static const int _unionStride = 1 << 20;

  /// True iff every string matched by some pattern in [sub] is also matched by
  /// some pattern in [sup]. Empty [sub] is vacuously a subset; empty [sup]
  /// matches nothing, so only an empty [sub] is contained in it.
  static bool isSubset(
    List<GlobPattern> sub,
    List<GlobPattern> sup, {
    int budget = defaultBudget,
  }) {
    if (sub.isEmpty) return true;
    if (sup.isEmpty) return false;

    final classes = <int?>[];
    final seen = <int>{};
    for (final pattern in sub) {
      for (final unit in pattern.literalUnits) {
        if (seen.add(unit)) classes.add(unit);
      }
    }
    for (final pattern in sup) {
      for (final unit in pattern.literalUnits) {
        if (seen.add(unit)) classes.add(unit);
      }
    }
    classes.add(null); // the "everything else" class

    for (final pattern in sub) {
      if (!_singleIsSubsetOfUnion(pattern, sup, classes, budget)) return false;
    }
    return true;
  }

  /// True iff the language of one NFA is a subset of the union of [others].
  static bool _singleIsSubsetOfUnion(
    GlobPattern sub,
    List<GlobPattern> others,
    List<int?> classes,
    int budget,
  ) {
    final start = _Pair(_StateSet.of(sub._startStates()), _unionStart(others));
    final visited = <_PairKey>{_PairKey.of(start)};
    final queue = Queue<_Pair>()..add(start);

    while (queue.isNotEmpty) {
      final current = queue.removeFirst();

      // A string reaching this pair is accepted by `sub` but by none of
      // `others`: a witness that containment fails.
      if (sub._accepts(current.sub.states) && !_unionAccepts(others, current.sup)) {
        return false;
      }

      for (final unit in classes) {
        final next = _Pair(
          _StateSet.of(sub._step(current.sub.states, unit)),
          _unionStep(others, current.sup, unit),
        );
        if (visited.add(_PairKey.of(next))) {
          if (visited.length > budget) {
            throw ContainmentBudgetExceeded(
              budget,
              'pattern "${sub.source}" vs ${others.length} pattern(s)',
            );
          }
          queue.add(next);
        }
      }
    }
    return true;
  }

  static _StateSet _unionStart(List<GlobPattern> patterns) {
    final encoded = <int>{};
    for (var i = 0; i < patterns.length; i++) {
      for (final state in patterns[i]._startStates()) {
        encoded.add(i * _unionStride + state);
      }
    }
    return _StateSet.of(encoded);
  }

  static bool _unionAccepts(List<GlobPattern> patterns, _StateSet states) {
    for (var i = 0; i < patterns.length; i++) {
      final accept = i * _unionStride + patterns[i]._accept;
      if (states.states.contains(accept)) return true;
    }
    return false;
  }

  static _StateSet _unionStep(
    List<GlobPattern> patterns,
    _StateSet states,
    int? unit,
  ) {
    if (states.states.isEmpty) return _StateSet.empty;
    final moved = <int>{};
    for (final encoded in states.sorted) {
      final index = encoded ~/ _unionStride;
      final state = encoded % _unionStride;
      final stepped = patterns[index]._step({state}, unit);
      for (final next in stepped) {
        moved.add(index * _unionStride + next);
      }
    }
    return _StateSet.of(moved);
  }
}

/// An immutable set of NFA state numbers with value equality, so it can be used
/// as a deterministic-automaton state and as a hash key.
class _StateSet {
  /// The states themselves, for membership tests and transitions.
  final Set<int> states;

  /// The same states sorted, for stable hashing and equality.
  final List<int> sorted;

  _StateSet._(this.states, this.sorted);

  static final _StateSet empty = _StateSet._(const <int>{}, const <int>[]);

  factory _StateSet.of(Iterable<int> values) {
    if (values.isEmpty) return empty;
    final set = values.toSet();
    final list = set.toList()..sort();
    return _StateSet._(set, List.unmodifiable(list));
  }

  @override
  int get hashCode => Object.hashAll(sorted);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _StateSet) return false;
    if (other.sorted.length != sorted.length) return false;
    for (var i = 0; i < sorted.length; i++) {
      if (sorted[i] != other.sorted[i]) return false;
    }
    return true;
  }
}

class _Pair {
  final _StateSet sub;
  final _StateSet sup;
  const _Pair(this.sub, this.sup);
}

class _PairKey {
  final _StateSet sub;
  final _StateSet sup;
  final int _hash;
  _PairKey.of(_Pair pair)
      : sub = pair.sub,
        sup = pair.sup,
        _hash = Object.hash(pair.sub, pair.sup);

  @override
  int get hashCode => _hash;

  @override
  bool operator ==(Object other) =>
      other is _PairKey && other.sub == sub && other.sup == sup;
}
