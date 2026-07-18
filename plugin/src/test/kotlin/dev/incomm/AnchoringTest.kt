package dev.incomm

import com.google.gson.Gson
import dev.incomm.anchor.Anchoring
import dev.incomm.model.Anchor
import dev.incomm.model.Note
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Runs the SAME re-anchoring cases as the Go suite (fixtures/anchor) to keep the
 * two implementations in lockstep.
 */
class AnchoringTest {

    private data class AnchorCase(
        val name: String = "",
        val startLine: Int = 0,
        val endLine: Int = 0,
        val anchor: Anchor = Anchor(),
        val expectStartLine: Int = 0,
        val expectEndLine: Int = 0,
        val expectOrphaned: Boolean = false,
    )

    private data class AnchorCases(val file: String = "", val cases: List<AnchorCase> = emptyList())

    @Test
    fun reanchorSharedFixtures() {
        val dir = fixturesDir("anchor")
        val cases = Gson().fromJson(File(dir, "cases.json").readText(), AnchorCases::class.java)
        val lines = Anchoring.splitLines(File(dir, cases.file).readText())

        for (c in cases.cases) {
            val note = Note(startLine = c.startLine, endLine = c.endLine, anchor = c.anchor)
            Anchoring.reanchor(note, lines)
            assertEquals("[${c.name}] startLine", c.expectStartLine, note.startLine)
            assertEquals("[${c.name}] endLine", c.expectEndLine, note.endLine)
            assertEquals("[${c.name}] orphaned", c.expectOrphaned, note.orphaned)
        }
    }

    @Test
    fun freshAnchorHitsFastPath() {
        val lines = listOf("package main", "", "func main() {", "\tprintln(\"hi\")", "}")
        val note = Note(startLine = 3, endLine = 3, anchor = Anchoring.compute(lines, 3, 3))
        assertFalse("freshly computed anchor should be unchanged", Anchoring.reanchor(note, lines))
        assertEquals(3, note.startLine)
        assertFalse(note.orphaned)
    }

    @Test
    fun checksumMatchesGoFormat() {
        val lines = listOf("alpha", "beta", "gamma")
        val sum = Anchoring.checksum(lines, 1, 1)
        assertTrue(sum.startsWith("sha1:"))
        assertEquals(45, sum.length) // "sha1:" + 40 hex chars
    }

    @Test
    fun trimmedPrefixTrimsAndLimits() {
        assertEquals("hello", Anchoring.trimmedPrefix("\t  hello world  ", 5))
        assertEquals("", Anchoring.trimmedPrefix("   ", 10))
    }

    companion object {
        fun fixturesDir(sub: String): File {
            var dir: File? = File(System.getProperty("user.dir"))
            repeat(8) {
                val probe = File(dir, "fixtures/$sub")
                if (probe.isDirectory) return probe
                dir = dir?.parentFile
            }
            error("fixtures/$sub not found from ${System.getProperty("user.dir")}")
        }
    }
}
