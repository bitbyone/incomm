package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import dev.incomm.editor.IncommEditorTracker
import dev.incomm.model.AUTHOR_USER

/**
 * "Incomm: Edit Comment" — edits the comment on the caret line in place (inside
 * its inline card). Enabled only when the caret is inside a comment's line range
 * and the comment is user-authored (agent comments aren't edited by the user).
 */
class EditCommentAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

    override fun update(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR)
        val project = e.project
        val note = if (project != null && editor != null) CaretNote.of(project, editor) else null
        e.presentation.isEnabledAndVisible = note != null && note.author == AUTHOR_USER
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val note = CaretNote.of(project, editor) ?: return
        IncommEditorTracker.getInstance(project).startInlineEdit(editor, note.id)
    }
}
