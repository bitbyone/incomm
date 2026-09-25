package one.bitby.incomm.model

const val AUDIENCE_PRIVATE = "private"
const val AUDIENCE_AGENT = "agent"
const val AUDIENCE_EXTERNAL = "external"
const val AUDIENCE_BOTH = "agent+external"

/**
 * Who may see a comment, as the editor shows and changes it. Pure logic, so it is
 * unit-testable without an IDE; mirrors `model.EffectiveAudience` in the CLI.
 *
 * A comment stores `null` for the default (`agent`). A value this build does not
 * know is treated as `private`, so a newer audience is never shown as shared.
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

    /** What the toggle changes [current] to. */
    fun next(current: String?): String = CYCLE[(CYCLE.indexOf(normalize(current)) + 1) % CYCLE.size]

    /** What to store for [audience]: the default is left out of the file. */
    fun stored(audience: String): String? = normalize(audience).takeIf { it != AUDIENCE_AGENT }

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

    /** How an audience reads in the UI. */
    fun label(audience: String?): String = when (normalize(audience)) {
        AUDIENCE_BOTH -> "agent + external"
        else -> normalize(audience)
    }

    /**
     * The compact text shown in a bubble's header, or null for a plain `agent`
     * comment. Anything that includes `external` also says whether it has been
     * published, which is whether it has a [source].
     */
    fun badge(source: Source?, effective: String): String? {
        val audience = normalize(effective)
        if (audience == AUDIENCE_AGENT) return null
        if (!includesExternal(audience)) return label(audience)
        return label(audience) + " · " + publication(source)
    }

    /** `published` once a comment has a source on the forge, `not published` until then. */
    fun publication(source: Source?): String = if (source != null) "published" else "not published"

    /** Tooltip of the toggle: what it is now and what a click changes it to. */
    fun tooltip(stored: String?, effective: String): String {
        val inherited = normalize(effective) == AUDIENCE_PRIVATE && normalize(stored) != AUDIENCE_PRIVATE
        return "Audience: " + label(effective) + (if (inherited) " (its thread is private)" else "") +
            " - click to change to " + label(next(stored))
    }
}
