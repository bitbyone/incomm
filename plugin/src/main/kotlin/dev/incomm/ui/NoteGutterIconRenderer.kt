package dev.incomm.ui

import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.editor.markup.GutterIconRenderer
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.NlsContexts
import dev.incomm.editor.IncommEditorTracker
import dev.incomm.model.AUTHOR_AGENT
import dev.incomm.model.Note
import javax.swing.Icon

/**
 * Gutter icon shown next to a commented line. Its icon reflects the note state
 * (open / resolved / orphaned); clicking hides/shows that thread's inline card.
 */
class NoteGutterIconRenderer(
    private val project: Project,
    private val noteId: String,
    private val icon: Icon,
    private val tooltip: String,
) : GutterIconRenderer() {

    override fun getIcon(): Icon = icon

    @Suppress("DialogTitleCapitalization")
    override fun getTooltipText(): @NlsContexts.Tooltip String = tooltip

    override fun isNavigateAction(): Boolean = true

    override fun getAlignment(): Alignment = Alignment.LEFT

    override fun getClickAction(): AnAction = object : AnAction() {
        override fun actionPerformed(e: AnActionEvent) {
            IncommEditorTracker.getInstance(project).toggleNoteHidden(noteId)
        }
    }

    // Identity is (noteId, icon) so the platform only repaints on real changes.
    override fun equals(other: Any?): Boolean =
        other is NoteGutterIconRenderer && other.noteId == noteId && other.icon === icon

    override fun hashCode(): Int = 31 * noteId.hashCode() + icon.hashCode()

    companion object {
        fun iconFor(note: Note): Icon = when {
            note.orphaned -> IncommIcons.COMMENT_ORPHANED
            note.resolved -> IncommIcons.COMMENT_RESOLVED
            else -> IncommIcons.COMMENT
        }

        fun tooltipFor(note: Note): String {
            val snippet = note.content.replace("\n", " ").let {
                if (it.length > 80) it.take(77) + "\u2026" else it
            }
            val who = when {
                note.author == AUTHOR_AGENT && !note.authorTitle.isNullOrBlank() ->
                    "<b>Agent (${escapeHtml(note.authorTitle!!)}):</b> "
                note.author == AUTHOR_AGENT -> "<b>Agent:</b> "
                !note.authorTitle.isNullOrBlank() -> "<b>${escapeHtml(note.authorTitle!!)}:</b> "
                else -> ""
            }
            val meta = buildList {
                if (note.orphaned) add("orphaned") else if (note.resolved) add("resolved")
                if (note.replies.isNotEmpty()) add("${note.replies.size} repl.")
            }
            val metaLine = if (meta.isEmpty()) "" else "<br/><small>${meta.joinToString(" \u00B7 ")}</small>"
            return "<html>$who${escapeHtml(snippet)}$metaLine</html>"
        }

        private fun escapeHtml(s: String): String =
            s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    }
}
