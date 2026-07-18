package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import dev.incomm.editor.IncommEditorTracker

/**
 * "Incomm: Hide/Show Comment" — collapses or reveals the inline card of the
 * comment on the caret line (its gutter icon stays). Enabled only when the caret
 * is inside a comment's line range.
 */
class ToggleThreadAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

    override fun update(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR)
        val project = e.project
        val note = if (project != null && editor != null) CaretNote.of(project, editor) else null
        e.presentation.isEnabledAndVisible = note != null
        if (note != null && project != null) {
            val hidden = IncommEditorTracker.getInstance(project).isNoteHidden(note.id)
            e.presentation.text = if (hidden) "Incomm: Show Comment" else "Incomm: Hide Comment"
        }
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val note = CaretNote.of(project, editor) ?: return
        IncommEditorTracker.getInstance(project).toggleNoteHidden(note.id)
    }
}
