package com.xstocker.tabletbrowser.policy

import java.util.concurrent.ConcurrentHashMap

/**
 * Configuration model for the whitelist / blacklist filter, plus the rule text
 * normaliser, the rule expansion and the decision procedure.
 *
 * Faithful Kotlin port of `lib/policy/policy_config.dart` and
 * `lib/policy/policy_engine.dart`. Pure JVM: no Android APIs, thread safe.
 */

/** Which list a rule belongs to. */
enum class PolicyListKind(val wire: String) {
    WHITELIST("whitelist"),
    BLACKLIST("blacklist");

    val labelZh: String get() = if (this == WHITELIST) "白名单" else "黑名单"

    companion object {
        @JvmStatic
        fun fromWire(value: String?): PolicyListKind =
            entries.firstOrNull { it.wire == value } ?: BLACKLIST
    }
}

/**
 * How to resolve a conflict when a URL matches a whitelist entry and a
 * blacklist entry and **neither is a subset of the other**.
 */
enum class ConflictResolution(val wire: String, val labelZh: String) {
    BLACKLIST_WINS("blacklistWins", "黑名单优先（默认）"),
    WHITELIST_WINS("whitelistWins", "白名单优先");

    companion object {
        @JvmStatic
        fun fromWire(value: String?): ConflictResolution =
            entries.firstOrNull { it.wire == value } ?: BLACKLIST_WINS
    }
}

/** What to do with a URL that matches **no** rule at all. */
enum class UnmatchedAction(val wire: String, val labelZh: String) {
    AUTO("auto", "自动（白名单非空则拒绝，否则放行）"),
    ALLOW("allow", "一律放行"),
    DENY("deny", "一律拒绝");

    companion object {
        @JvmStatic
        fun fromWire(value: String?): UnmatchedAction =
            entries.firstOrNull { it.wire == value } ?: AUTO
    }
}

/** One configured entry, e.g. `https://example.com/news`. */
data class PolicyRule(
    val pattern: String,
    val kind: PolicyListKind,
    val enabled: Boolean = true,
    val note: String = "",
) {
    /** Stable identity: normalised pattern plus list kind. */
    val id: String get() = "${kind.wire}:${PatternNormalizer.normalizeRulePattern(pattern)}"

    fun toJson(): Map<String, Any?> = buildMap {
        put("pattern", pattern)
        put("kind", kind.wire)
        put("enabled", enabled)
        if (note.isNotEmpty()) put("note", note)
    }

    companion object {
        @JvmStatic
        fun fromJson(json: Map<*, *>?): PolicyRule = PolicyRule(
            pattern = (json?.get("pattern") as? String ?: "").trim(),
            kind = PolicyListKind.fromWire(json?.get("kind") as? String),
            enabled = json?.get("enabled") as? Boolean ?: true,
            note = json?.get("note") as? String ?: "",
        )
    }
}

/**
 * The loopback -> local file mapping described in CONTRACT.md section 2: a URL
 * served by the app-local HTTP server (`127.0.0.1` / `localhost` on
 * `localServer.port`) is evaluated as `file://<rootPath><path[?query]>` so that
 * one set of file-path rules governs both `file://` browsing and locally served
 * pages.
 */
data class LocalServerConfig(val port: Int, val rootPath: String) {
    fun toJson(): Map<String, Any?> = mapOf("port" to port, "rootPath" to rootPath)

    companion object {
        @JvmStatic
        fun fromJson(json: Map<*, *>?): LocalServerConfig? {
            if (json == null) return null
            val port = (json["port"] as? Number)?.toInt() ?: return null
            val rootPath = (json["rootPath"] as? String)?.trim().orEmpty()
            if (rootPath.isEmpty()) return null
            return LocalServerConfig(port, rootPath)
        }
    }
}

/** The complete filter configuration. */
data class PolicyConfig(
    val enabled: Boolean = true,
    val rules: List<PolicyRule> = emptyList(),
    val conflictResolution: ConflictResolution = ConflictResolution.BLACKLIST_WINS,
    val unmatchedAction: UnmatchedAction = UnmatchedAction.AUTO,
    val strictDomainBoundary: Boolean = false,
    val localServer: LocalServerConfig? = null,
) {
    fun rulesOf(kind: PolicyListKind): List<PolicyRule> = rules.filter { it.kind == kind }

    /** Whether a non-empty, enabled whitelist exists. Drives [UnmatchedAction.AUTO]. */
    val hasActiveWhitelist: Boolean
        get() = rules.any {
            it.enabled && it.kind == PolicyListKind.WHITELIST && it.pattern.trim().isNotEmpty()
        }

    fun toJson(): Map<String, Any?> = buildMap {
        put("version", SCHEMA_VERSION)
        put("enabled", enabled)
        put("conflictResolution", conflictResolution.wire)
        put("unmatchedAction", unmatchedAction.wire)
        put("strictDomainBoundary", strictDomainBoundary)
        put("rules", rules.map { it.toJson() })
        localServer?.let { put("localServer", it.toJson()) }
    }

    /**
     * Applies the local-server mapping, if configured, returning either the
     * original URL or the equivalent `file://` URL for policy evaluation.
     */
    fun mapUrlToLocalFile(rawUrl: String): String {
        val server = localServer ?: return rawUrl
        if (server.port <= 0) return rawUrl
        var candidate = rawUrl.trim()
        if (!candidate.contains("://") &&
            (candidate.startsWith("localhost") || candidate.startsWith("127.0.0.1"))
        ) {
            candidate = "http://$candidate"
        }
        val parsed = parseUrl(candidate) ?: return rawUrl
        val scheme = parsed.scheme.lowercase()
        if (scheme != "http" && scheme != "https") return rawUrl
        val host = parsed.host.lowercase()
        val isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1" ||
            host == "0:0:0:0:0:0:0:1" || host == "[::1]"
        if (!isLoopback) return rawUrl
        val port = parsed.port ?: if (scheme == "https") 443 else 80
        if (port != server.port) return rawUrl
        val root = server.rootPath.trimEnd('/')
        val path = if (parsed.path.isEmpty()) "/" else parsed.path
        val query = parsed.query?.let { "?$it" } ?: ""
        val prefix = if (root.startsWith("/")) "file://$root" else "file:///$root"
        return prefix + path + query
    }

    companion object {
        const val SCHEMA_VERSION = 1
        val EMPTY = PolicyConfig()

        @JvmStatic
        fun fromJson(json: Map<*, *>?): PolicyConfig {
            if (json == null) return EMPTY
            val rawRules = json["rules"] as? List<*>
            return PolicyConfig(
                enabled = json["enabled"] as? Boolean ?: true,
                rules = rawRules.orEmpty().mapNotNull { raw ->
                    (raw as? Map<*, *>)?.let { PolicyRule.fromJson(it) }
                },
                conflictResolution = ConflictResolution.fromWire(json["conflictResolution"] as? String),
                unmatchedAction = UnmatchedAction.fromWire(json["unmatchedAction"] as? String),
                strictDomainBoundary = json["strictDomainBoundary"] as? Boolean ?: false,
                localServer = LocalServerConfig.fromJson(json["localServer"] as? Map<*, *>),
            )
        }
    }
}

/** A concrete glob produced from a rule. */
data class GlobSpec(val glob: String, val prefix: Boolean = true) {
    fun compile(): GlobPattern = GlobPattern.compile(glob, implicitTrailingStar = prefix)

    override fun toString(): String = if (prefix) "$glob*" else glob
}

/** Turns authored rule text into patterns the engine can reason about. */
object PatternNormalizer {
    /**
     * Canonicalises a rule's text: trims whitespace; adds a `*://` scheme
     * wildcard when no scheme was given; lowercases the scheme and authority
     * only, keeping the path case sensitive; drops a default port.
     */
    @JvmStatic
    fun normalizeRulePattern(raw: String): String {
        var text = raw.trim()
        if (text.isEmpty()) return ""
        if (!text.contains("://") && !text.startsWith("*:")) {
            text = "*://$text"
        }
        val schemeEnd = text.indexOf("://")
        if (schemeEnd < 0) return text
        val scheme = text.substring(0, schemeEnd).lowercase()
        val rest = text.substring(schemeEnd + 3)
        val authorityEnd = rest.indexOf('/')
        var authority = (if (authorityEnd < 0) rest else rest.substring(0, authorityEnd)).lowercase()
        val tail = if (authorityEnd < 0) "" else rest.substring(authorityEnd)
        // Drop a default port so that `https://host:443/x` and `https://host/x`
        // are the same rule, mirroring URL normalisation. A `*` scheme wildcard
        // must drop both, because URLs are normalised per concrete scheme and so
        // never carry `:80` or `:443` after normalisation.
        val stripsHttpDefault = scheme == "http" || scheme == "*"
        val stripsHttpsDefault = scheme == "https" || scheme == "*"
        if (stripsHttpDefault && authority.endsWith(":80")) {
            authority = authority.substring(0, authority.length - 3)
        } else if (stripsHttpsDefault && authority.endsWith(":443")) {
            authority = authority.substring(0, authority.length - 4)
        }
        return "$scheme://$authority$tail"
    }

    /**
     * Normalises an absolute URL for matching: scheme and authority lowercased,
     * default port removed, empty fragment dropped. A URL without a scheme is
     * treated as `https://`; a bare path is treated as `file://`.
     */
    @JvmStatic
    fun normalizeUrl(raw: String): String {
        var text = raw.trim()
        if (text.isEmpty()) return text
        if (!text.contains("://")) {
            text = when {
                text.startsWith("//") -> "https:$text"
                text.startsWith("/") -> "file://$text"
                else -> "https://$text"
            }
        }
        val schemeEnd = text.indexOf("://")
        val scheme = text.substring(0, schemeEnd).lowercase()
        val rest = text.substring(schemeEnd + 3)
        val authorityEnd = rest.indexOf('/')
        var authority = if (authorityEnd < 0) rest else rest.substring(0, authorityEnd)
        var tail = if (authorityEnd < 0) "" else rest.substring(authorityEnd)

        authority = authority.lowercase()
        if (scheme == "http" && authority.endsWith(":80")) {
            authority = authority.substring(0, authority.length - 3)
        } else if (scheme == "https" && authority.endsWith(":443")) {
            authority = authority.substring(0, authority.length - 4)
        }
        if (tail.isEmpty() && scheme != "file") tail = "/"
        val fragment = tail.indexOf('#')
        if (fragment >= 0) tail = tail.substring(0, fragment)
        return "$scheme://$authority$tail"
    }

    /** Expands a normalised rule into one or more concrete glob specs. */
    @JvmStatic
    @JvmOverloads
    fun expandRule(normalized: String, strictDomainBoundary: Boolean = false): List<GlobSpec> {
        if (normalized.isEmpty()) return emptyList()
        val specs = mutableListOf(GlobSpec(normalized))
        if (!strictDomainBoundary) return specs

        val schemeEnd = normalized.indexOf("://")
        if (schemeEnd < 0) return specs
        val rest = normalized.substring(schemeEnd + 3)
        // Only host-only rules can be boundary-anchored; a rule that already
        // mentions a path, query or fragment is left as a prefix rule.
        if (rest.contains('/') || rest.contains('?') || rest.contains('#')) return specs

        return listOf(
            GlobSpec(normalized, prefix = false), // the bare host, exactly
            GlobSpec("$normalized/"),
            GlobSpec("$normalized:"),
            // `?` and `#` are glob metacharacters, so the boundary characters
            // themselves must be escaped — otherwise `host?` would match `host.`
            // followed by any single character, which is exactly the
            // `example.com.evil.test` hole this option exists to close.
            GlobSpec("$normalized\\?"),
            GlobSpec("$normalized\\#"),
        )
    }

    /** Human-readable list of what a rule expands to, for the UI. */
    @JvmStatic
    @JvmOverloads
    fun describeExpansion(raw: String, strictDomainBoundary: Boolean = false): String {
        val normalized = normalizeRulePattern(raw)
        val specs = expandRule(normalized, strictDomainBoundary)
        if (specs.isEmpty()) return "（空规则，无效）"
        return specs.joinToString("  或  ")
    }
}

/** Why a request was allowed or denied. Wire names are shared with Dart. */
enum class DecisionReason(val wire: String, val labelZh: String) {
    POLICY_DISABLED("policyDisabled", "策略总开关已关闭"),
    UNMATCHED_ALLOW("unmatchedAllow", "未匹配任何名单，且默认动作是放行"),
    UNMATCHED_DENY("unmatchedDeny", "未匹配任何名单，且默认动作是拒绝"),
    WHITELIST_ONLY("whitelistOnly", "仅命中白名单"),
    BLACKLIST_ONLY("blacklistOnly", "仅命中黑名单"),
    WHITELIST_MORE_SPECIFIC("whitelistMoreSpecific", "同时命中黑白名单，白名单更具体（是其子集）"),
    BLACKLIST_MORE_SPECIFIC("blacklistMoreSpecific", "同时命中黑白名单，黑名单更具体（是其子集）"),
    CONFLICT_BLACKLIST_WINS("conflictBlacklistWins", "黑白名单互不包含，冲突解决方式为黑名单优先"),
    CONFLICT_WHITELIST_WINS("conflictWhitelistWins", "黑白名单互不包含，冲突解决方式为白名单优先"),
    CONTAINMENT_BUDGET_EXCEEDED("containmentBudgetExceeded", "包含关系判定超出预算，按互不包含处理"),
}

/** A rule together with the URL-normalised form it was matched against. */
class RuleMatch(val rule: PolicyRule, val normalizedPattern: String) {
    val kind: PolicyListKind get() = rule.kind

    override fun toString(): String = "${rule.kind.labelZh}: ${rule.pattern}"
}

/** The outcome of evaluating one URL. */
class PolicyDecision(
    val allowed: Boolean,
    val reason: DecisionReason,
    /** The URL as normalised for matching (after the local-server mapping). */
    val normalizedUrl: String,
    /** The URL as handed to [PolicyEngine.decide]. */
    val originalUrl: String,
    val whitelistMatches: List<RuleMatch> = emptyList(),
    val blacklistMatches: List<RuleMatch> = emptyList(),
    /** The most specific matching entries (minimal elements of the subset order). */
    val decisiveRules: List<RuleMatch> = emptyList(),
    /** True when the outcome came from the conflict setting rather than specificity. */
    val conflictResolved: Boolean = false,
) {
    /** A short, user-facing explanation, e.g. for the block page. */
    val explanation: String
        get() = buildString {
            append(reason.labelZh)
            if (decisiveRules.isNotEmpty()) {
                append('：')
                append(decisiveRules.joinToString("、") { it.rule.pattern })
            }
        }

    fun toJson(): Map<String, Any?> = mapOf(
        "allowed" to allowed,
        "reason" to reason.wire,
        "reasonLabel" to reason.labelZh,
        "url" to normalizedUrl,
        "whitelistMatches" to whitelistMatches.map { it.rule.pattern },
        "blacklistMatches" to blacklistMatches.map { it.rule.pattern },
        "decisive" to decisiveRules.map { it.rule.pattern },
        "conflictResolved" to conflictResolved,
    )
}

/** How two rules' languages relate. */
enum class RuleRelation(val labelZh: String) {
    SUBSUMES("前者包含后者（后者更具体）"),
    SUBSUMED_BY("前者被后者包含（前者更具体）"),
    EQUIVALENT("两者等价"),
    INCOMPARABLE("互不包含"),
}

/** Detail used by the in-app policy tester. */
class PolicyTrace(
    val decision: PolicyDecision,
    val relations: List<RuleRelation> = emptyList(),
    val budgetWarnings: List<String> = emptyList(),
)

/** A rule compiled into matchable glob patterns. */
class CompiledRule private constructor(
    val rule: PolicyRule,
    val normalized: String,
    val patterns: List<GlobPattern>,
    val valid: Boolean,
) {
    val isWhitelist: Boolean get() = rule.kind == PolicyListKind.WHITELIST
    val isBlacklist: Boolean get() = rule.kind == PolicyListKind.BLACKLIST

    fun matchesNormalized(normalizedUrl: String): Boolean =
        patterns.any { it.matches(normalizedUrl) }

    override fun toString(): String = "${rule.kind.wire}:$normalized"

    companion object {
        @JvmStatic
        fun compile(rule: PolicyRule, strictDomainBoundary: Boolean): CompiledRule {
            val normalized = PatternNormalizer.normalizeRulePattern(rule.pattern)
            if (normalized.isEmpty()) {
                return CompiledRule(rule, normalized, emptyList(), false)
            }
            val specs = PatternNormalizer.expandRule(normalized, strictDomainBoundary)
            return CompiledRule(rule, normalized, specs.map { it.compile() }, true)
        }
    }
}

/**
 * The filter engine. Immutable configuration; the only mutable state is a
 * concurrent memo table for containment queries, so one engine instance may be
 * shared across the WebView platform thread and `shouldInterceptRequest`
 * background threads.
 */
class PolicyEngine(val config: PolicyConfig = PolicyConfig.EMPTY) {
    val compiledRules: List<CompiledRule> =
        config.rules.map { CompiledRule.compile(it, config.strictDomainBoundary) }

    /** Rules that are enabled and syntactically usable. */
    val activeRules: List<CompiledRule> =
        config.rules
            .filter {
                it.enabled && PatternNormalizer.normalizeRulePattern(it.pattern).isNotEmpty()
            }
            .map { CompiledRule.compile(it, config.strictDomainBoundary) }

    private val subsetCache = ConcurrentHashMap<String, Boolean>()

    fun isAllowed(url: String): Boolean = decide(url).allowed

    /** Evaluates [url] and returns the full decision. */
    fun decide(url: String): PolicyDecision {
        val mappedUrl = config.mapUrlToLocalFile(url)
        val normalizedUrl = PatternNormalizer.normalizeUrl(mappedUrl)

        if (!config.enabled) {
            return PolicyDecision(
                allowed = true,
                reason = DecisionReason.POLICY_DISABLED,
                normalizedUrl = normalizedUrl,
                originalUrl = url,
            )
        }

        val whitelistMatches = ArrayList<RuleMatch>()
        val blacklistMatches = ArrayList<RuleMatch>()
        for (candidate in activeRules) {
            if (!candidate.matchesNormalized(normalizedUrl)) continue
            val match = RuleMatch(candidate.rule, candidate.normalized)
            if (candidate.isWhitelist) whitelistMatches.add(match) else blacklistMatches.add(match)
        }

        // (4) nothing matched
        if (whitelistMatches.isEmpty() && blacklistMatches.isEmpty()) {
            val allowed: Boolean
            val reason: DecisionReason
            when (config.unmatchedAction) {
                UnmatchedAction.ALLOW -> {
                    allowed = true
                    reason = DecisionReason.UNMATCHED_ALLOW
                }
                UnmatchedAction.DENY -> {
                    allowed = false
                    reason = DecisionReason.UNMATCHED_DENY
                }
                UnmatchedAction.AUTO -> if (config.hasActiveWhitelist) {
                    allowed = false
                    reason = DecisionReason.UNMATCHED_DENY
                } else {
                    allowed = true
                    reason = DecisionReason.UNMATCHED_ALLOW
                }
            }
            return PolicyDecision(
                allowed = allowed,
                reason = reason,
                normalizedUrl = normalizedUrl,
                originalUrl = url,
                whitelistMatches = whitelistMatches,
                blacklistMatches = blacklistMatches,
            )
        }

        // (3) only one list matched
        if (blacklistMatches.isEmpty()) {
            return PolicyDecision(
                allowed = true,
                reason = DecisionReason.WHITELIST_ONLY,
                normalizedUrl = normalizedUrl,
                originalUrl = url,
                whitelistMatches = whitelistMatches,
                blacklistMatches = blacklistMatches,
                decisiveRules = whitelistMatches,
            )
        }
        if (whitelistMatches.isEmpty()) {
            return PolicyDecision(
                allowed = false,
                reason = DecisionReason.BLACKLIST_ONLY,
                normalizedUrl = normalizedUrl,
                originalUrl = url,
                whitelistMatches = whitelistMatches,
                blacklistMatches = blacklistMatches,
                decisiveRules = blacklistMatches,
            )
        }

        // (2) both lists matched: reduce to the most specific entries.
        val allMatches = whitelistMatches + blacklistMatches
        val byPattern = HashMap<String, CompiledRule>()
        for (rule in activeRules) {
            if (rule.valid) byPattern[ruleKey(rule.rule)] = rule
        }

        var budgetExceeded = false
        fun isStrictlyMoreSpecific(candidate: RuleMatch, other: RuleMatch): Boolean {
            val a = byPattern[ruleKey(candidate.rule)] ?: return false
            val b = byPattern[ruleKey(other.rule)] ?: return false
            return try {
                val aSubsetB = isSubset(a, b)
                if (!aSubsetB) return false
                val bSubsetA = isSubset(b, a)
                !bSubsetA // strict
            } catch (e: ContainmentBudgetExceeded) {
                budgetExceeded = true
                false
            }
        }

        val minimal = ArrayList<RuleMatch>()
        for (candidate in allMatches) {
            var shadowed = false
            for (other in allMatches) {
                if (other === candidate) continue
                if (isStrictlyMoreSpecific(other, candidate)) {
                    shadowed = true
                    break
                }
            }
            if (!shadowed) minimal.add(candidate)
        }

        val anyWhitelist = minimal.any { it.kind == PolicyListKind.WHITELIST }
        val anyBlacklist = minimal.any { it.kind == PolicyListKind.BLACKLIST }

        if (minimal.isNotEmpty() && !(anyWhitelist && anyBlacklist)) {
            // Every most-specific entry sits in the same list: specificity decides.
            val whitelistDecides = anyWhitelist
            return PolicyDecision(
                allowed = whitelistDecides,
                reason = if (whitelistDecides) DecisionReason.WHITELIST_MORE_SPECIFIC
                else DecisionReason.BLACKLIST_MORE_SPECIFIC,
                normalizedUrl = normalizedUrl,
                originalUrl = url,
                whitelistMatches = whitelistMatches,
                blacklistMatches = blacklistMatches,
                decisiveRules = minimal,
            )
        }

        // Mixed most-specific entries: equal patterns or genuinely incomparable
        // ones. The configured conflict resolution decides.
        val blacklistWins = config.conflictResolution == ConflictResolution.BLACKLIST_WINS
        return PolicyDecision(
            allowed = !blacklistWins,
            reason = when {
                budgetExceeded -> DecisionReason.CONTAINMENT_BUDGET_EXCEEDED
                blacklistWins -> DecisionReason.CONFLICT_BLACKLIST_WINS
                else -> DecisionReason.CONFLICT_WHITELIST_WINS
            },
            normalizedUrl = normalizedUrl,
            originalUrl = url,
            whitelistMatches = whitelistMatches,
            blacklistMatches = blacklistMatches,
            decisiveRules = minimal,
            conflictResolved = true,
        )
    }

    /**
     * Evaluates [url] and additionally reports the pairwise relation between
     * every matching whitelist and blacklist entry. Backs the in-app tester.
     */
    fun trace(url: String): PolicyTrace {
        val decision = decide(url)
        val relations = ArrayList<RuleRelation>()
        val warnings = ArrayList<String>()
        val byPattern = HashMap<String, CompiledRule>()
        for (rule in activeRules) {
            if (rule.valid) byPattern[ruleKey(rule.rule)] = rule
        }

        for (w in decision.whitelistMatches) {
            for (b in decision.blacklistMatches) {
                val a = byPattern[ruleKey(w.rule)] ?: continue
                val c = byPattern[ruleKey(b.rule)] ?: continue
                try {
                    val aSubsetC = isSubset(a, c)
                    val cSubsetA = isSubset(c, a)
                    relations.add(
                        when {
                            aSubsetC && cSubsetA -> RuleRelation.EQUIVALENT
                            aSubsetC -> RuleRelation.SUBSUMED_BY
                            cSubsetA -> RuleRelation.SUBSUMES
                            else -> RuleRelation.INCOMPARABLE
                        }
                    )
                } catch (e: ContainmentBudgetExceeded) {
                    warnings.add(e.toString())
                    relations.add(RuleRelation.INCOMPARABLE)
                }
            }
        }
        return PolicyTrace(decision, relations, warnings)
    }

    /** True iff every URL matched by [a] is also matched by [b]. */
    fun isSubset(a: CompiledRule, b: CompiledRule): Boolean {
        val key = "${ruleKey(a.rule)}\u0000${ruleKey(b.rule)}"
        subsetCache[key]?.let { return it }
        // A budget overflow propagates as ContainmentBudgetExceeded and is
        // deliberately not cached: callers treat it as "unknown" (incomparable).
        val result = GlobContainment.isSubset(a.patterns, b.patterns)
        subsetCache[key] = result
        return result
    }

    /** Convenience for the UI: relation between two configured rules. */
    fun relationBetween(a: PolicyRule, b: PolicyRule): RuleRelation {
        val ca = CompiledRule.compile(a, config.strictDomainBoundary)
        val cb = CompiledRule.compile(b, config.strictDomainBoundary)
        if (!ca.valid || !cb.valid) return RuleRelation.INCOMPARABLE
        return try {
            val aSubsetB = isSubset(ca, cb)
            val bSubsetA = isSubset(cb, ca)
            when {
                aSubsetB && bSubsetA -> RuleRelation.EQUIVALENT
                aSubsetB -> RuleRelation.SUBSUMED_BY
                bSubsetA -> RuleRelation.SUBSUMES
                else -> RuleRelation.INCOMPARABLE
            }
        } catch (e: ContainmentBudgetExceeded) {
            RuleRelation.INCOMPARABLE
        }
    }

    /** Rules that could never fire because a broader rule already covers them. */
    fun shadowedRules(kind: PolicyListKind): List<PolicyRule> {
        val list = activeRules.filter { it.rule.kind == kind && it.valid }
        val shadowed = ArrayList<PolicyRule>()
        outer@ for (candidate in list) {
            for (other in list) {
                if (other === candidate) continue
                try {
                    if (isSubset(other, candidate) && !isSubset(candidate, other)) {
                        shadowed.add(candidate.rule)
                        continue@outer
                    }
                } catch (e: ContainmentBudgetExceeded) {
                    continue@outer
                }
            }
        }
        return shadowed
    }

    companion object {
        internal fun ruleKey(rule: PolicyRule): String = "${rule.kind.wire}\u0000${rule.pattern.trim()}"
    }
}

/** Minimal, dependency-free absolute-URL splitter used by the loopback mapping. */
internal class ParsedUrl(
    val scheme: String,
    val authority: String,
    val host: String,
    val port: Int?,
    val path: String,
    val query: String?,
    val fragment: String?,
)

internal fun parseUrl(raw: String): ParsedUrl? {
    val text = raw.trim()
    val schemeEnd = text.indexOf("://")
    if (schemeEnd <= 0) return null
    val scheme = text.substring(0, schemeEnd)
    val rest = text.substring(schemeEnd + 3)
    var authorityEnd = rest.length
    for (i in rest.indices) {
        val c = rest[i]
        if (c == '/' || c == '?' || c == '#') {
            authorityEnd = i
            break
        }
    }
    val authority = rest.substring(0, authorityEnd)
    var remainder = rest.substring(authorityEnd)

    var fragment: String? = null
    val hash = remainder.indexOf('#')
    if (hash >= 0) {
        fragment = remainder.substring(hash + 1)
        remainder = remainder.substring(0, hash)
    }
    var query: String? = null
    val q = remainder.indexOf('?')
    if (q >= 0) {
        query = remainder.substring(q + 1)
        remainder = remainder.substring(0, q)
    }

    var hostPart = authority
    val at = hostPart.lastIndexOf('@')
    if (at >= 0) hostPart = hostPart.substring(at + 1)
    var host = hostPart
    var port: Int? = null
    if (hostPart.startsWith("[")) {
        val close = hostPart.indexOf(']')
        if (close >= 0) {
            host = hostPart.substring(0, close + 1)
            val after = hostPart.substring(close + 1)
            if (after.startsWith(":") && after.length > 1) port = after.substring(1).toIntOrNull()
        }
    } else {
        val colon = hostPart.lastIndexOf(':')
        if (colon >= 0) {
            host = hostPart.substring(0, colon)
            port = hostPart.substring(colon + 1).toIntOrNull()
        }
    }
    return ParsedUrl(scheme, authority, host, port, remainder, query, fragment)
}
