package com.xstocker.tabletbrowser

import com.xstocker.tabletbrowser.policy.CompiledRule
import com.xstocker.tabletbrowser.policy.GlobContainment
import com.xstocker.tabletbrowser.policy.PatternNormalizer
import com.xstocker.tabletbrowser.policy.PolicyConfig
import com.xstocker.tabletbrowser.policy.PolicyEngine
import com.xstocker.tabletbrowser.policy.PolicyListKind
import com.xstocker.tabletbrowser.policy.PolicyRule
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import org.junit.runners.Parameterized.Parameters

/**
 * Cross-checks the Kotlin port against the hand-authored specification vectors
 * in `assets/policy_test_vectors.json` (copied byte-identically to
 * `android/app/src/test/resources/policy_test_vectors.json`).
 *
 * Every vector becomes its own JUnit test case: one case entry from `cases`
 * (asserting both `allowed` and the `reason` wire name) and one relation entry
 * from `relations` (asserting `a ⊆ b` with the containment implementation).
 */
@RunWith(Parameterized::class)
class PolicyVectorsTest(private val vector: Vector) {

    /** One spec vector: either a decision case or a containment relation. */
    class Vector(private val label: String, private val body: () -> Unit) {
        fun check() = body()

        // Test names end up as report file names; keep them ASCII so the HTML
        // report can be written regardless of the JVM default charset.
        override fun toString(): String = label.map { if (it.code in 32..126) it else '-' }.joinToString("")
    }

    @Test
    fun vectorHolds() {
        vector.check()
    }

    companion object {
        private val allVectors: List<Vector> by lazy { buildVectors() }

        @JvmStatic
        @Parameters(name = "{0}")
        fun vectors(): Collection<Vector> = allVectors

        private fun loadSpec(): JSONObject {
            val stream = PolicyVectorsTest::class.java.classLoader
                ?.getResourceAsStream("policy_test_vectors.json")
                ?: throw IllegalStateException(
                    "policy_test_vectors.json is missing from the unit-test classpath " +
                        "(expected at android/app/src/test/resources/policy_test_vectors.json)"
                )
            return stream.use { JSONObject(String(it.readBytes(), Charsets.UTF_8)) }
        }

        private fun numeric(value: Any?): Any? = when (value) {
            is JSONObject -> value.keys().asSequence().associateWith { key -> numeric(value.get(key)) }
            is JSONArray -> (0 until value.length()).map { numeric(value.get(it)) }
            JSONObject.NULL -> null
            else -> value
        }

        private fun buildVectors(): List<Vector> {
            val spec = loadSpec()
            val configs = spec.getJSONObject("configs")
            val vectors = ArrayList<Vector>()

            val cases = spec.getJSONArray("cases")
            for (index in 0 until cases.length()) {
                val case = cases.getJSONObject(index)
                val name = case.getString("name")
                val configName = case.getString("config")
                val url = case.getString("url")
                val allowed = case.getBoolean("allowed")
                val reason = case.getString("reason")
                vectors.add(
                    Vector("case: $name") {
                        val configJson = numeric(configs.getJSONObject(configName)) as Map<*, *>
                        val engine = PolicyEngine(PolicyConfig.fromJson(configJson))
                        val decision = engine.decide(url)
                        assertEquals(
                            "allowed mismatch for [$name] ($configName, $url) reason=${decision.reason.wire}",
                            allowed,
                            decision.allowed,
                        )
                        assertEquals("reason mismatch for [$name] ($configName, $url)", reason, decision.reason.wire)
                    }
                )
            }

            val relations = spec.getJSONArray("relations")
            for (index in 0 until relations.length()) {
                val relation = relations.getJSONObject(index)
                val a = relation.getString("a")
                val b = relation.getString("b")
                val subset = relation.getBoolean("subset")
                val why = relation.optString("why")
                vectors.add(
                    Vector("relation: $a SUBSET-OF $b ($why)") {
                        val left = compileFor(a)
                        val right = compileFor(b)
                        assertEquals(
                            "containment mismatch for [$a] subset-of [$b] ($why)",
                            subset,
                            GlobContainment.isSubset(left.patterns, right.patterns),
                        )
                    }
                )
            }

            assertTrue("no vectors loaded from policy_test_vectors.json", vectors.isNotEmpty())
            return vectors
        }

        private fun compileFor(pattern: String): CompiledRule {
            val normalized = PatternNormalizer.normalizeRulePattern(pattern)
            return CompiledRule.compile(
                PolicyRule(pattern = normalized, kind = PolicyListKind.BLACKLIST),
                strictDomainBoundary = false,
            )
        }
    }
}

/**
 * Extra unit tests for behaviour that is not covered by the shared vectors:
 * the loopback -> local file mapping required by CONTRACT.md section 2.
 */
class LoopbackMappingTest {

    private fun engineWithLocalServer(port: Int = 8787, root: String = "/data/user/0/app/files/site"): PolicyEngine {
        val config = PolicyConfig(
            enabled = true,
            rules = listOf(
                PolicyRule(pattern = "file:///data/user/0/app/files/site/", kind = PolicyListKind.WHITELIST),
                PolicyRule(pattern = "file:///data/user/0/app/files/site/ads/", kind = PolicyListKind.BLACKLIST),
            ),
            strictDomainBoundary = false,
            localServer = com.xstocker.tabletbrowser.policy.LocalServerConfig(port, root),
        )
        return PolicyEngine(config)
    }

    @Test
    fun loopbackRequestOnTheConfiguredPortIsEvaluatedAsAFileUrl() {
        val decision = engineWithLocalServer().decide("http://127.0.0.1:8787/ads/a.html")
        assertEquals("file:///data/user/0/app/files/site/ads/a.html", decision.normalizedUrl)
        assertEquals(false, decision.allowed)
        assertEquals("blacklistMoreSpecific", decision.reason.wire)
    }

    @Test
    fun localhostIsMappedTooAndQueryIsKept() {
        val decision = engineWithLocalServer().decide("http://localhost:8787/index.html?v=2")
        assertEquals("file:///data/user/0/app/files/site/index.html?v=2", decision.normalizedUrl)
        assertEquals(true, decision.allowed)
        assertEquals("whitelistOnly", decision.reason.wire)
    }

    @Test
    fun anotherPortIsNotMapped() {
        val decision = engineWithLocalServer().decide("http://127.0.0.1:9999/ads/a.html")
        assertEquals("http://127.0.0.1:9999/ads/a.html", decision.normalizedUrl)
        assertEquals(false, decision.allowed)
        assertEquals("unmatchedDeny", decision.reason.wire)
    }

    @Test
    fun fragmentIsDroppedByUrlNormalisation() {
        val decision = engineWithLocalServer().decide("http://127.0.0.1:8787/index.html#top")
        assertEquals("file:///data/user/0/app/files/site/index.html", decision.normalizedUrl)
        assertNotNull(decision.normalizedUrl)
    }

    @Test
    fun withoutLocalServerConfigurationNothingIsMapped() {
        val engine = PolicyEngine(
            PolicyConfig(
                enabled = true,
                rules = listOf(PolicyRule(pattern = "file:///site/", kind = PolicyListKind.WHITELIST)),
            )
        )
        val decision = engine.decide("http://127.0.0.1:8787/index.html")
        assertEquals("http://127.0.0.1:8787/index.html", decision.normalizedUrl)
        assertEquals("unmatchedDeny", decision.reason.wire)
    }
}
