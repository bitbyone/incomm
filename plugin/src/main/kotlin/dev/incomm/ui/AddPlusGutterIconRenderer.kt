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
 * opens the inline composer for that single line.
 */
class AddPlusGutterIconRenderer(
    private val project: Project,
    private val editor: Editor,
    private val line: Int, // 1-based
) : GutterIconRenderer() {

    override fun getIcon(): Icon = IncommIcons.ADD_COMMENT

    override fun getTooltipText(): String = "Add incomm comment"

    override fun isNavigateAction(): Boolean = true

    override fun getAlignment(): Alignment = Alignment.LEFT

    override fun getClickAction(): AnAction = object : AnAction() {
        override fun actionPerformed(e: AnActionEvent) {
            IncommEditorTracker.getInstance(project).startInlineAdd(editor, line, line)
        }
    }

    override fun equals(other: Any?): Boolean =
        other is AddPlusGutterIconRenderer && other.line == line && other.editor === editor

    override fun hashCode(): Int = line
}
