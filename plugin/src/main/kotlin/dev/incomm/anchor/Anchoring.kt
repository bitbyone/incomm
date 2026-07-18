package dev.incomm.anchor

import dev.incomm.model.Anchor
import dev.incomm.model.Note
import java.security.MessageDigest
import kotlin.math.abs

/**
 * Shared, deterministic line-anchoring algorithm (see SCHEMA.md). This is a
 * pure port of the Go `internal/anchor` package — keep the two in lockstep;
 * both test suites run against `/fixtures/anchor`.
 */
object Anchoring {
    const val PREFIX_LEN = 64
    const val CONTEXT_PREFIX_LEN = 48
    const val SEARCH_RADIUS = 400
    const val MIN_PREFIX_MATCH = 4

    private val WS = charArrayOf(' ', '\t', '\n', '\r', '\u000C', '\u000B')

    /** Strip leading/trailing ASCII whitespace and keep at most [maxLen] code points. */
    fun trimmedPrefix(line: String, maxLen: Int): String {
        val t = line.trim { it in WS }
        if (t.isEmpty()) return t
        val cpCount = t.codePointCount(0, t.length)
        if (cpCount <= maxLen) return t
        return t.substring(0, t.offsetByCodePoints(0, maxLen))
    }

    private fun nonWsCount(s: String): Int = s.count { it !in WS }

    /** "sha1:<hex>" of the 1-based inclusive block [start,end] joined by '\n'. */
    fun checksum(lines: List<String>, start: Int, end: Int): String {
        if (lines.isEmpty()) return ""
        val s = clamp(start, 1, lines.size)
        val e = maxOf(clamp(end, 1, lines.size), s)
        val block = lines.subList(s - 1, e).joinToString("\n")
        val digest = MessageDigest.getInstance("SHA-1").digest(block.toByteArray(Charsets.UTF_8))
        return "sha1:" + digest.joinToString("") { "%02x".format(it) }
    }

    /** Build an [Anchor] for a note at 1-based inclusive lines [startLine,endLine]. */
    fun compute(lines: List<String>, startLine: Int, endLine: Int): Anchor {
        val n = lines.size
        val s = clamp(startLine, 1, maxOf(n, 1))
        val e = clamp(endLine, s, maxOf(n, 1))
        var startPrefix = ""
        var endPrefix = ""
        var before = ""
        var after = ""
        if (n > 0) {
            startPrefix = trimmedPrefix(lines[s - 1], PREFIX_LEN)
            endPrefix = trimmedPrefix(lines[e - 1], PREFIX_LEN)
            if (s - 2 >= 0) before = trimmedPrefix(lines[s - 2], CONTEXT_PREFIX_LEN)
            if (e < n) after = trimmedPrefix(lines[e], CONTEXT_PREFIX_LEN)
        }
        return Anchor(startPrefix, endPrefix, before, after, checksum(lines, s, e))
    }

    /**
     * Recompute [note].startLine/endLine against [lines], updating its anchor and
     * `orphaned` flag. Returns true if anything changed.
     */
    fun reanchor(note: Note, lines: List<String>): Boolean {
        val oldStart = note.startLine
        val oldEnd = note.endLine
        val oldOrphaned = note.orphaned
        val oldAnchor = note.anchor
        apply(note, lines)
        return note.startLine != oldStart ||
            note.endLine != oldEnd ||
            note.orphaned != oldOrphaned ||
            note.anchor != oldAnchor
    }

    private fun apply(note: Note, lines: List<String>) {
        val total = lines.size
        val lineSpan = (note.endLine - note.startLine).coerceAtLeast(0)
        val a = note.anchor

        // 1. Fast path — prefixes AND any stored context still match.
        if (note.startLine in 1..total && note.endLine in 1..total &&
            trimmedPrefix(lines[note.startLine - 1], PREFIX_LEN) == a.startPrefix &&
            trimmedPrefix(lines[note.endLine - 1], PREFIX_LEN) == a.endPrefix &&
            contextMatches(lines, note.startLine - 1, note.endLine - 1, a)
        ) {
            note.orphaned = false
            return
        }

        // 2. Too weak to anchor.
        if (nonWsCount(a.startPrefix) < MIN_PREFIX_MATCH) {
            note.orphaned = true
            return
        }

        // 3. Search + score.
        val oldIdx = note.startLine - 1
        var bestIdx = -1
        var bestScore = 0
        var bestDist = 0
        for (i in 0 until total) {
            val dist = abs(i - oldIdx)
            if (dist > SEARCH_RADIUS) continue
            val cand = trimmedPrefix(lines[i], PREFIX_LEN)
            if (!cand.startsWith(a.startPrefix)) continue
            var score = 100
            if (cand == a.startPrefix) score += 60
            if (a.contextBefore.isNotEmpty() && i - 1 >= 0 &&
                trimmedPrefix(lines[i - 1], CONTEXT_PREFIX_LEN) == a.contextBefore
            ) score += 40
            if (a.contextAfter.isNotEmpty() && i + lineSpan + 1 < total &&
                trimmedPrefix(lines[i + lineSpan + 1], CONTEXT_PREFIX_LEN) == a.contextAfter
            ) score += 40
            if (a.checksum.isNotEmpty() && checksum(lines, i + 1, i + 1 + lineSpan) == a.checksum) score += 80
            score -= dist
            if (bestIdx == -1 || score > bestScore || (score == bestScore && dist < bestDist)) {
                bestIdx = i
                bestScore = score
                bestDist = dist
            }
        }

        // 4. Accept or give up.
        if (bestIdx == -1 || bestScore < 100) {
            note.orphaned = true
            return
        }
        val newStart = bestIdx + 1
        val newEnd = clamp(newStart + lineSpan, newStart, total)
        note.startLine = newStart
        note.endLine = newEnd
        note.anchor = compute(lines, newStart, newEnd)
        note.orphaned = false
    }

    private fun contextMatches(lines: List<String>, startIdx: Int, endIdx: Int, a: Anchor): Boolean {
        if (a.contextBefore.isNotEmpty()) {
            if (startIdx - 1 < 0 ||
                trimmedPrefix(lines[startIdx - 1], CONTEXT_PREFIX_LEN) != a.contextBefore
            ) return false
        }
        if (a.contextAfter.isNotEmpty()) {
            if (endIdx + 1 >= lines.size ||
                trimmedPrefix(lines[endIdx + 1], CONTEXT_PREFIX_LEN) != a.contextAfter
            ) return false
        }
        return true
    }

    private fun clamp(v: Int, lo: Int, hi: Int): Int = when {
        v < lo -> lo
        v > hi -> hi
        else -> v
    }

    /**
     * Split document text into lines the same way the Go store does: normalize
     * CRLF/CR to LF and drop a single trailing newline so counts match editor
     * line numbers.
     */
    fun splitLines(text: String): List<String> {
        val normalized = text.replace("\r\n", "\n").replace('\r', '\n')
        if (normalized.isEmpty()) return emptyList()
        val trimmed = if (normalized.endsWith("\n")) normalized.dropLast(1) else normalized
        return trimmed.split('\n')
    }
}
