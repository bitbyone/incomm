package dev.incomm.ui

import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.editor.markup.GutterIconRenderer
import com.intellij.openapi.project.Project
import dev.incomm.editor.IncommEditorTracker
import javax.swing.Icon

/**
 * The transient "+" gutter icon shown on the hovered / caret line. Clicking it
 * opens the inline composer to start a new thread on that line (or the current
 * selection's range).
 */
class AddPlusGutterIconRenderer(
    private val project: Project,
    private val editor: Editor,
    private val line: Int, // 1-based
) : GutterIconRenderer() {

    override fun getIcon(): Icon = IncommIcons.ADD_COMMENT

    override fun getTooltipText(): String = "Start new incomm thread"

    override fun isNavigateAction(): Boolean = true

    override fun getAlignment(): Alignment = Alignment.LEFT

    override fun getClickAction(): AnAction = object : AnAction() {
        override fun actionPerformed(e: AnActionEvent) {
            val (start, end) = targetRange()
            IncommEditorTracker.getInstance(project).startInlineAdd(editor, start, end)
        }
    }

    /**
     * The line range the new comment should span. If there is a multi-line
     * selection and the clicked "+" line falls inside it, comment the whole
     * selection (anchored to its first line); otherwise just the clicked line.
     */
    private fun targetRange(): Pair<Int, Int> {
        val sel = editor.selectionModel
        if (!sel.hasSelection()) return line to line
        val doc = editor.document
        val startLine = doc.getLineNumber(sel.selectionStart) + 1
        var endLine = doc.getLineNumber(sel.selectionEnd) + 1
        // A selection ending exactly at a line start doesn't include that line.
        if (endLine > startLine && sel.selectionEnd == doc.getLineStartOffset(endLine - 1)) endLine--
        return if (line in startLine..endLine) startLine to endLine else line to line
    }

    override fun equals(other: Any?): Boolean =
        other is AddPlusGutterIconRenderer && other.line == line && other.editor === editor

    override fun hashCode(): Int = line
}
