package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import dev.incomm.editor.IncommEditorTracker
import dev.incomm.model.AUTHOR_USER

/**
 * "Incomm: Edit" — edits the thread's comment on the caret line in place (inside
 * its inline card). From the context menu this targets the original comment, so
 * it is offered only when the thread has **no replies** (with replies it's
 * ambiguous which message to edit — the card's per-message edit icons are used
 * for that). Enabled only when the caret is inside a thread whose original
 * comment is user-authored (agent comments aren't edited by the user).
 */
class EditCommentAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

    override fun update(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR)
        val project = e.project
        val note = if (project != null && editor != null) CaretNote.of(project, editor) else null
        e.presentation.isEnabledAndVisible =
            note != null && note.author == AUTHOR_USER && note.replies.isEmpty()
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val note = CaretNote.of(project, editor) ?: return
        IncommEditorTracker.getInstance(project).startInlineEdit(editor, note.id)
    }
}
