package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import dev.incomm.editor.IncommEditorTracker

/**
 * "Incomm: Reply to Comment" — adds a new reply entry directly inside the
 * comment's inline card, in edit mode with the caret ready (check saves, Esc /
 * cancel discards it). No separate dialog.
 */
class ReplyAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

    override fun update(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR)
        val project = e.project
        e.presentation.isEnabledAndVisible =
            project != null && editor != null && CaretNote.of(project, editor) != null
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val note = CaretNote.of(project, editor) ?: return
        IncommEditorTracker.getInstance(project).startInlineReply(editor, note.id)
    }
}
