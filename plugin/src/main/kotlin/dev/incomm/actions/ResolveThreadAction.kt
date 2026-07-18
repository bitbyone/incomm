package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import dev.incomm.editor.IncommEditorTracker

/**
 * "Incomm: Resolve/Reopen Comment" — resolves (or reopens) the comment on the
 * caret line. Resolving also collapses its inline card. Enabled only when the
 * caret is inside a comment's line range.
 */
class ResolveThreadAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

    override fun update(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR)
        val project = e.project
        val note = if (project != null && editor != null) CaretNote.of(project, editor) else null
        e.presentation.isEnabledAndVisible = note != null
        if (note != null) {
            e.presentation.text = if (note.resolved) "Incomm: Reopen Comment" else "Incomm: Resolve Comment"
        }
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val note = CaretNote.of(project, editor) ?: return
        IncommEditorTracker.getInstance(project).setNoteResolved(note.id, !note.resolved)
    }
}
