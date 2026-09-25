package one.bitby.incomm.model

import java.security.SecureRandom
import java.time.Instant
import java.time.temporal.ChronoUnit

/**
 * The newest notes.json format this build understands, and the version every save
 * stamps. Any change to the JSON shape bumps it (AGENTS.md §11.7); a build refuses
 * to read or write a file whose version is greater than its own.
 */
const val SCHEMA_VERSION = 2

/** What a file with no version field is taken to be. */
const val LEGACY_VERSION = 1

const val AUTHOR_USER = "user"
const val AUTHOR_AGENT = "agent"

/**
 * Root object of `.incomm/notes[_<branch>].json`.
 *
 * Fields are `var` with defaults because Gson populates them by reflection and
 * may leave absent fields null; [normalize] repairs such values after parsing.
 */
data class NotesFile(
    var version: Int = SCHEMA_VERSION,
    var branch: String? = null,
    var notes: MutableList<Note> = mutableListOf(),
) {
    fun normalize(): NotesFile {
        @Suppress("SENSELESS_COMPARISON")
        if (notes == null) notes = mutableListOf()
        if (version == 0) version = LEGACY_VERSION
        notes.forEach { it.normalize() }
        return this
    }

    fun find(id: String): Note? = notes.firstOrNull { it.id == id }

    fun remove(id: String): Boolean = notes.removeAll { it.id == id }

    /** Deep, independent copy safe to hand to a background writer. */
    fun deepCopy(): NotesFile =
        NotesFile(version, branch, notes.map { it.deepCopy() }.toMutableList())
}

/** A single line-anchored comment thread. */
data class Note(
    var id: String = "",
    var file: String = "",
    var startLine: Int = 1,
    var endLine: Int = 1,
    var anchor: Anchor = Anchor(),
    var content: String = "",
    var resolved: Boolean = false,
    var orphaned: Boolean = false,
    var author: String = AUTHOR_USER,
    var authorTitle: String? = null,
    var audience: String? = AUDIENCE_AGENT,
    var source: Source? = null,
    var createdAt: String = "",
    var updatedAt: String = "",
    var replies: MutableList<Reply> = mutableListOf(),
) {
    @Suppress("SENSELESS_COMPARISON")
    fun normalize() {
        if (anchor == null) anchor = Anchor()
        if (replies == null) replies = mutableListOf()
        if (author == null) author = AUTHOR_USER
        if (content == null) content = ""
        if (file == null) file = ""
        if (id == null) id = ""
        if (audience.isNullOrBlank()) audience = AUDIENCE_AGENT
        replies.forEach { it.normalize() }
    }

    /** Human-readable `file:line` (or `file:start-end`) location. */
    fun location(): String =
        if (endLine != startLine) "$file:$startLine-$endLine" else "$file:$startLine"

    /**
     * Whether this note should be drawn in the editor gutter / inline at all.
     * An orphaned note that is also resolved is fully hidden from the editor.
     */
    fun isHiddenInEditor(): Boolean = orphaned && resolved

    /**
     * The 1-based line the note anchors to for editor rendering. Orphaned notes
     * have lost their real location, so they float to the file's first line.
     */
    fun displayStartLine(): Int = if (orphaned) 1 else startLine

    fun displayEndLine(): Int = if (orphaned) 1 else endLine

    /** Deep, independent copy (anchor + replies not shared). */
    fun deepCopy(): Note =
        copy(anchor = anchor.copy(), source = source?.copy(), replies = replies.map { it.deepCopy() }.toMutableList())
}

/**
 * Best-effort textual anchor used to re-find a note's line after edits.
 * All fields are plain strings so the struct stays value-comparable.
 */
data class Anchor(
    var startPrefix: String = "",
    var endPrefix: String = "",
    var contextBefore: String = "",
    var contextAfter: String = "",
    var checksum: String = "",
)

/**
 * Where a comment came from or was published to. Metadata for integrations: an
 * `external` comment with no source is still waiting to be published.
 */
data class Source(
    var url: String? = null,
    var id: Long? = null,
    var thread: String? = null,
)

/** A single response in a note's thread. */
data class Reply(
    var id: String = "",
    var author: String = AUTHOR_AGENT,
    var authorTitle: String? = null,
    var audience: String? = AUDIENCE_AGENT,
    var source: Source? = null,
    var content: String = "",
    var createdAt: String = "",
) {
    fun normalize() {
        if (audience.isNullOrBlank()) audience = AUDIENCE_AGENT
    }

    fun deepCopy(): Reply = copy(source = source?.copy())
}

/** Current UTC time as an RFC3339 instant, e.g. `2026-07-17T15:12:49Z`. */
fun nowUtc(): String = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString()

/** A short, unique-enough 8-char hex id (matches the Go CLI's format). */
fun newId(): String {
    val b = ByteArray(4)
    SecureRandom().nextBytes(b)
    return b.joinToString("") { "%02x".format(it) }
}
