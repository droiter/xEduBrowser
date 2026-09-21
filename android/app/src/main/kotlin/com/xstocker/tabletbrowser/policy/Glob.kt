package com.xstocker.tabletbrowser.policy

import java.util.ArrayDeque

/**
 * Glob pattern language, matching, and **language containment**.
 *
 * This is a faithful Kotlin port of `lib/policy/glob.dart`. It is pure JVM code
 * (no Android APIs) so it can be unit tested with plain JUnit.
 *
 *  1. Does a pattern match a URL?                       -> [GlobPattern.matches]
 *  2. Is the language of one set of patterns a subset
 *     of the language of another set of patterns?       -> [GlobContainment.isSubset]
 *
 * Question 2 is answered exactly: a pattern is compiled to an NFA, the superset
 * side is determinised on the fly by subset construction, and the product
 * automaton is searched for a reachable state that accepts on the subset side
 * while rejecting on the superset side. Such a state exists iff
 * `L(sub) \ L(sup)` is non-empty, i.e. iff the subset relation fails.
 *
 * The alphabet is infinite (all code units), but only finitely many code units
 * can ever matter: the literal characters occurring in the patterns under
 * comparison. Every other character is behaviourally identical, so the search
 * runs over a finite alphabet of (distinct literals + one "other" class).
 *
 * Pattern syntax:
 *
 *  * `*`   zero or more characters
 *  * `?`   exactly one character
 *  * `\x`  literal `x` (escape)
 *
 * Every other character matches itself. When [GlobPattern.compile] is called
 * with `implicitTrailingStar = true` the pattern is a **prefix** pattern:
 * `https://example.com/news` also matches `https://example.com/news/2026/01`.
 */
internal enum class AtomKind { LITERAL, ANY_CHAR, STAR }

internal class Atom private constructor(val kind: AtomKind, val unit: Int) {
    companion object {
        fun literal(unit: Int) = Atom(AtomKind.LITERAL, unit)
        val ANY_CHAR = Atom(AtomKind.ANY_CHAR, -1)
        val STAR = Atom(AtomKind.STAR, -1)
    }
}

/** A single compiled glob pattern. */
class GlobPattern private constructor(
    /** The pattern text as authored (after normalisation done by the caller). */
    val source: String,
    /** Whether a trailing `*` is implied (prefix semantics). */
    val implicitTrailingStar: Boolean,
    private val atoms: List<Atom>,
) {
    /** Every code unit that appears literally in this pattern. */
    val literalUnits: Set<Int> = buildSet {
        for (atom in atoms) if (atom.kind == AtomKind.LITERAL) add(atom.unit)
    }

    /** The state index that accepts; the NFA has `atoms.size + 1` states. */
    val accept: Int get() = atoms.size

    /** True for the match-everything pattern, which is never the more specific side. */
    val matchesEverything: Boolean get() = atoms.all { it.kind == AtomKind.STAR }

    /** Whole-string match against [input]. */
    fun matches(input: String): Boolean {
        var states = startStates()
        for (index in 0 until input.length) {
            states = step(states, input[index].code)
            if (states.isEmpty()) return false
        }
        return accepts(states)
    }

    // ---------------------------------------------------------------------
    // NFA primitives. A state has exactly one outgoing transition kind, so the
    // automaton needs no general transition table.
    // ---------------------------------------------------------------------

    fun startStates(): Set<Int> = epsilonClosure(mutableSetOf(0))

    fun accepts(states: Set<Int>): Boolean = states.contains(accept)

    /** Epsilon steps are only possible out of `*` states, which may chain. */
    private fun epsilonClosure(seed: MutableSet<Int>): Set<Int> {
        val closure = HashSet<Int>()
        val stack = ArrayList<Int>(seed)
        while (stack.isNotEmpty()) {
            val state = stack.removeAt(stack.size - 1)
            if (!closure.add(state)) continue
            if (state < atoms.size && atoms[state].kind == AtomKind.STAR) {
                stack.add(state + 1)
            }
        }
        return closure
    }

    /**
     * Consumes one character. [unit] is the consumed code unit, or `null` for
     * the "any character not listed literally in either pattern" class, which
     * may only be consumed by `*` and `?`.
     */
    fun step(states: Set<Int>, unit: Int?): Set<Int> {
        val moved = HashSet<Int>()
        for (state in states) {
            if (state >= atoms.size) continue // accept state, no outgoing edges
            when (atoms[state].kind) {
                AtomKind.STAR -> moved.add(state) // consume and stay: `*` is unbounded
                AtomKind.ANY_CHAR -> moved.add(state + 1)
                AtomKind.LITERAL -> if (unit != null && atoms[state].unit == unit) moved.add(state + 1)
            }
        }
        return epsilonClosure(moved)
    }

    override fun toString(): String = if (implicitTrailingStar) "$source*" else source

    companion object {
        /**
         * Compiles [pattern]. A trailing `*` is appended unless one is already
         * present, when [implicitTrailingStar] is true.
         */
        @JvmStatic
        @JvmOverloads
        fun compile(pattern: String, implicitTrailingStar: Boolean = true): GlobPattern {
            val atoms = ArrayList<Atom>()
            var escaped = false
            for (index in 0 until pattern.length) {
                val unit = pattern[index].code
                if (escaped) {
                    atoms.add(Atom.literal(unit))
                    escaped = false
                    continue
                }
                when (unit) {
                    0x5C -> escaped = true // backslash
                    0x2A -> atoms.add(Atom.STAR) // *
                    0x3F -> atoms.add(Atom.ANY_CHAR) // ?
                    else -> atoms.add(Atom.literal(unit))
                }
            }
            if (escaped) {
                // Dangling escape: treat the backslash itself as a literal.
                atoms.add(Atom.literal(0x5C))
            }
            if (implicitTrailingStar && (atoms.isEmpty() || atoms.last().kind != AtomKind.STAR)) {
                atoms.add(Atom.STAR)
            }
            return GlobPattern(pattern, implicitTrailingStar, atoms)
        }
    }
}

/** Thrown when the containment search exceeds its state budget. */
class ContainmentBudgetExceeded(val budget: Int, val detail: String) :
    Exception("ContainmentBudgetExceeded($budget): $detail")

/**
 * An immutable, sorted set of NFA state numbers with value equality, so it can
 * be used as a deterministic-automaton state and as a hash key.
 */
private class StateSet private constructor(val units: IntArray) {
    override fun equals(other: Any?): Boolean =
        this === other || (other is StateSet && units.contentEquals(other.units))

    override fun hashCode(): Int = units.contentHashCode()

    companion object {
        val EMPTY = StateSet(IntArray(0))

        fun of(values: Collection<Int>): StateSet {
            if (values.isEmpty()) return EMPTY
            val sorted = values.toSortedSet().toIntArray()
            return StateSet(sorted)
        }
    }
}

/** Exact language containment over sets of glob patterns (union semantics). */
object GlobContainment {
    /**
     * Upper bound on visited product states. Patterns authored by a human are
     * tiny and never come close; the cap exists so a pathological pattern
     * degrades into "unknown" instead of hanging the UI.
     */
    const val DEFAULT_BUDGET: Int = 200000

    /** Encodes `(patternIndex, state)` into one int for union states. */
    private const val UNION_STRIDE: Int = 1 shl 20

    /**
     * True iff every string matched by some pattern in [sub] is also matched by
     * some pattern in [sup]. Empty [sub] is vacuously a subset; empty [sup]
     * matches nothing, so only an empty [sub] is contained in it.
     */
    @JvmStatic
    @JvmOverloads
    fun isSubset(
        sub: List<GlobPattern>,
        sup: List<GlobPattern>,
        budget: Int = DEFAULT_BUDGET,
    ): Boolean {
        if (sub.isEmpty()) return true
        if (sup.isEmpty()) return false

        val classes = ArrayList<Int?>()
        val seen = HashSet<Int>()
        for (pattern in sub) {
            for (unit in pattern.literalUnits) if (seen.add(unit)) classes.add(unit)
        }
        for (pattern in sup) {
            for (unit in pattern.literalUnits) if (seen.add(unit)) classes.add(unit)
        }
        classes.add(null) // the "everything else" class

        for (pattern in sub) {
            if (!singleIsSubsetOfUnion(pattern, sup, classes, budget)) return false
        }
        return true
    }

    /** True iff the language of one NFA is a subset of the union of [others]. */
    private fun singleIsSubsetOfUnion(
        sub: GlobPattern,
        others: List<GlobPattern>,
        classes: List<Int?>,
        budget: Int,
    ): Boolean {
        val start = StatePair(sub.startStates(), unionStart(others))
        val visited = HashSet<PairKey>()
        visited.add(PairKey(start))
        val queue = ArrayDeque<StatePair>()
        queue.addLast(start)

        while (queue.isNotEmpty()) {
            val current = queue.removeFirst()

            // A string reaching this pair is accepted by `sub` but by none of
            // `others`: a witness that containment fails.
            if (sub.accepts(current.sub) && !unionAccepts(others, current.sup)) {
                return false
            }

            for (unit in classes) {
                val next = StatePair(
                    sub.step(current.sub, unit),
                    unionStep(others, current.sup, unit),
                )
                if (visited.add(PairKey(next))) {
                    if (visited.size > budget) {
                        throw ContainmentBudgetExceeded(
                            budget,
                            "pattern \"${sub.source}\" vs ${others.size} pattern(s)",
                        )
                    }
                    queue.addLast(next)
                }
            }
        }
        return true
    }

    private fun unionStart(patterns: List<GlobPattern>): StateSet {
        val encoded = HashSet<Int>()
        for (index in patterns.indices) {
            for (state in patterns[index].startStates()) {
                encoded.add(index * UNION_STRIDE + state)
            }
        }
        return StateSet.of(encoded)
    }

    private fun unionAccepts(patterns: List<GlobPattern>, states: StateSet): Boolean {
        for (index in patterns.indices) {
            val acceptState = index * UNION_STRIDE + patterns[index].accept
            if (states.units.contains(acceptState)) return true
        }
        return false
    }

    private fun unionStep(
        patterns: List<GlobPattern>,
        states: StateSet,
        unit: Int?,
    ): StateSet {
        if (states.units.isEmpty()) return StateSet.EMPTY
        val moved = HashSet<Int>()
        for (encoded in states.units) {
            val index = encoded / UNION_STRIDE
            val state = encoded % UNION_STRIDE
            val stepped = patterns[index].step(java.util.Collections.singleton(state), unit)
            for (next in stepped) moved.add(index * UNION_STRIDE + next)
        }
        return StateSet.of(moved)
    }
}

private class StatePair(val sub: Set<Int>, val sup: StateSet)

private class PairKey(private val pair: StatePair) {
    private val sub: Set<Int> = pair.sub
    private val sup: StateSet = pair.sup
    // `Set` equality/hashCode are value based (HashSet), matching Dart's _StateSet.
    override fun hashCode(): Int = 31 * sub.hashCode() + sup.hashCode()

    override fun equals(other: Any?): Boolean =
        other is PairKey && other.sub == sub && other.sup == sup
}
