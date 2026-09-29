package one.bitby.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import one.bitby.incomm.editor.IncommEditorTracker
import one.bitby.incomm.model.AUDIENCE_BOTH
import one.bitby.incomm.model.AUDIENCE_EXTERNAL
import one.bitby.incomm.model.AUDIENCE_PRIVATE

/**
 * "Incomm: Reply" — adds a new reply entry directly inside the thread's inline
 * card, in edit mode with the caret ready (check saves, Esc / cancel discards
 * it). No separate dialog. It is seen by whoever sees the comment it answers;
 * the variants below answer for another [audience], each with a shortcut of its own.
 */
open class ReplyAction(private val audience: String? = null) : AnAction() {

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
        IncommEditorTracker.getInstance(project).startInlineReply(editor, note.id, audience)
    }
}

/** "Incomm: Private Reply" — an answer only you see. */
class PrivateReplyAction : ReplyAction(AUDIENCE_PRIVATE)

/** "Incomm: External Reply" — for the merge request, hidden from the agent. */
class ExternalReplyAction : ReplyAction(AUDIENCE_EXTERNAL)

/** "Incomm: Agent + External Reply" — for the agent and the merge request. */
class AgentExternalReplyAction : ReplyAction(AUDIENCE_BOTH)
