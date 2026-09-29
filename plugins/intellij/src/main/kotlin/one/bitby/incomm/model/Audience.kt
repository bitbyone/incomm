package one.bitby.incomm.model

const val AUDIENCE_PRIVATE = "private"
const val AUDIENCE_AGENT = "agent"
const val AUDIENCE_EXTERNAL = "external"
const val AUDIENCE_BOTH = "agent+external"

/**
 * One comment of a thread as a row of the audience dialog. [audience] is what the
 * comment stores, which is what the dialog steps; [inherited] marks a reply that is
 * private anyway because its thread's root is.
 */
data class AudienceRow(
    val replyId: String?,
    val author: String,
    val authorTitle: String?,
    val content: String,
    val audience: String,
    val published: Boolean,
    val inherited: Boolean,
    /** The audiences it may take, in step order: see [Audience.cycleFor]. */
    val cycle: List<String> = Audience.CYCLE,
    /** Whether thread details may edit / delete it: see [Audience.canEdit], [Audience.canDelete]. */
    val editable: Boolean = false,
    val deletable: Boolean = false,
)

/**
 * Who may see a comment, as the editor shows and changes it. Pure logic, so it is
 * unit-testable without an IDE; mirrors `model.EffectiveAudience` in the CLI.
 *
 * A comment stores its audience explicitly, `agent` included, so a saved file
 * always says who may see each comment; a file that does not say (an older one)
 * is read as `agent`. A value this build does not know is treated as `private`,
 * so a newer audience is never shown as shared.
 */
object Audience {

    /** The order the toggle steps through. */
    val CYCLE: List<String> = listOf(AUDIENCE_AGENT, AUDIENCE_BOTH, AUDIENCE_EXTERNAL, AUDIENCE_PRIVATE)

    /** A stored value as one of [CYCLE]: empty is agent, unknown is private. */
    fun normalize(stored: String?): String = when (stored) {
        null, "", AUDIENCE_AGENT -> AUDIENCE_AGENT
        AUDIENCE_PRIVATE, AUDIENCE_EXTERNAL, AUDIENCE_BOTH -> stored
        else -> AUDIENCE_PRIVATE
    }

    /**
     * What a published comment may be: it is on the forge, so it can be hidden from
     * the agent but never taken off the forge (agent-only or private).
     */
    val PUBLISHED_CYCLE: List<String> = listOf(AUDIENCE_BOTH, AUDIENCE_EXTERNAL)

    /** A thread's own comment while one of its replies is published: private would hide that reply. */
    val SHARED_CYCLE: List<String> = listOf(AUDIENCE_AGENT, AUDIENCE_BOTH, AUDIENCE_EXTERNAL)

    /**
     * The audiences one comment of [note] may take: the root when [replyId] is null,
     * that reply otherwise. A comment with a `source` came from or went to the forge.
     */
    fun cycleFor(note: Note, replyId: String?): List<String> {
        if (replyId != null) {
            val reply = note.replies.firstOrNull { it.id == replyId } ?: return CYCLE
            return if (reply.source != null) PUBLISHED_CYCLE else CYCLE
        }
        return when {
            note.source != null -> PUBLISHED_CYCLE
            note.replies.any { it.source != null } -> SHARED_CYCLE
            else -> CYCLE
        }
    }

    fun allowed(note: Note, replyId: String?, audience: String): Boolean = audience in cycleFor(note, replyId)

    /**
     * Whether a comment may be edited here: your own words (the thread's own when
     * [replyId] is null), and not what is on the forge already - the text there
     * would no longer match.
     */
    fun canEdit(note: Note, replyId: String?): Boolean {
        if (replyId == null) return note.author == AUTHOR_USER && note.source == null
        val reply = note.replies.firstOrNull { it.id == replyId } ?: return false
        return reply.author == AUTHOR_USER && reply.source == null
    }

    /**
     * Whether a comment may be deleted here: not what is on the forge, and not a
     * thread's own comment (which takes the thread with it) while a reply of it is.
     */
    fun canDelete(note: Note, replyId: String?): Boolean {
        if (replyId == null) return note.source == null && note.replies.none { it.source != null }
        val reply = note.replies.firstOrNull { it.id == replyId } ?: return false
        return reply.source == null
    }

    /** What the toggle changes [current] to, within [cycle] (by default the full one). */
    fun next(current: String?, cycle: List<String> = CYCLE): String = step(current, cycle, 1)

    /** One step back: what the dialog's "previous" key changes [current] to. */
    fun previous(current: String?, cycle: List<String> = CYCLE): String = step(current, cycle, -1)

    private fun step(current: String?, cycle: List<String>, delta: Int): String {
        val index = cycle.indexOf(normalize(current))
        // Not a value this comment may have (an older file): the nearest end.
        if (index < 0) return if (delta > 0) cycle.first() else cycle.last()
        return cycle[(index + delta + cycle.size) % cycle.size]
    }

    /** What to store for [audience]: always the value itself, the default included. */
    fun stored(audience: String?): String = normalize(audience)

    /** What a new reply starts with: the audience its root comment stores now. */
    fun inheritedByReply(root: String?): String = stored(root)

    /**
     * The audience a comment really has: everything under a `private` root is
     * private, whatever it stores. Stored values are never rewritten for this, so
     * unlocking the root gives every reply its own audience back.
     */
    fun effective(root: String?, comment: String?): String =
        if (normalize(root) == AUDIENCE_PRIVATE) AUDIENCE_PRIVATE else normalize(comment)

    fun includesExternal(audience: String?): Boolean =
        normalize(audience).let { it == AUDIENCE_EXTERNAL || it == AUDIENCE_BOTH }

    fun includesAgent(audience: String?): Boolean =
        normalize(audience).let { it == AUDIENCE_AGENT || it == AUDIENCE_BOTH }

    /** The comments of [note] as audience-dialog rows, the root first. */
    fun rows(note: Note): List<AudienceRow> {
        val rootPrivate = normalize(note.audience) == AUDIENCE_PRIVATE
        val root = AudienceRow(
            null, note.author, note.authorTitle, note.content,
            normalize(note.audience), note.source != null, inherited = false,
            cycle = cycleFor(note, null),
            editable = canEdit(note, null),
            deletable = canDelete(note, null),
        )
        return listOf(root) + note.replies.map {
            val audience = normalize(it.audience)
            AudienceRow(
                it.id, it.author, it.authorTitle, it.content, audience, it.source != null,
                inherited = rootPrivate && audience != AUDIENCE_PRIVATE,
                cycle = cycleFor(note, it.id),
                editable = canEdit(note, it.id),
                deletable = canDelete(note, it.id),
            )
        }
    }

    /**
     * The colour a bubble is drawn in: the agent's words are always the agent's
     * ([AUTHOR_AGENT]); your own are coloured by who may see them, from the
     * [effective] audience - external (anything meant for the merge request),
     * private, or plain [AUTHOR_USER] (you and the agent).
     */
    fun tone(author: String, effective: String?): String = when {
        author == AUTHOR_AGENT -> AUTHOR_AGENT
        normalize(effective) == AUDIENCE_PRIVATE -> AUDIENCE_PRIVATE
        includesExternal(effective) -> AUDIENCE_EXTERNAL
        else -> AUTHOR_USER
    }

    /** How an audience reads in the UI. */
    fun label(audience: String?): String = when (normalize(audience)) {
        AUDIENCE_BOTH -> "agent + external"
        else -> normalize(audience)
    }

    /**
     * The compact text shown in a bubble's header: every comment says who may
     * see it, plain `agent` included. Anything that includes `external` also says
     * whether it has been published, which is whether it has a [source].
     */
    fun badge(source: Source?, effective: String): String {
        val audience = normalize(effective)
        if (!includesExternal(audience)) return label(audience)
        return label(audience) + " · " + publication(source)
    }

    /** `published` once a comment has a source on the forge, `not published` until then. */
    fun publication(source: Source?): String = if (source != null) "published" else "not published"

    /** Tooltip of the toggle: what it is now and what a click changes it to. */
    fun tooltip(stored: String?, effective: String, cycle: List<String> = CYCLE): String {
        val inherited = normalize(effective) == AUDIENCE_PRIVATE && normalize(stored) != AUDIENCE_PRIVATE
        return "Audience: " + label(effective) + (if (inherited) " (its thread is private)" else "") +
            " - click to change to " + label(next(stored, cycle))
    }
}
