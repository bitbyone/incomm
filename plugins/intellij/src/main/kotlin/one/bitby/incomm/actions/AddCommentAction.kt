package one.bitby.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import com.intellij.openapi.editor.Editor
import one.bitby.incomm.editor.IncommEditorTracker
import one.bitby.incomm.model.AUDIENCE_AGENT
import one.bitby.incomm.model.AUDIENCE_BOTH
import one.bitby.incomm.model.AUDIENCE_EXTERNAL
import one.bitby.incomm.model.AUDIENCE_PRIVATE
import one.bitby.incomm.store.NotesService

/**
 * "Incomm: Start New Thread" — opens the inline composer for the current
 * selection (a line range) or, with no selection, the caret line. Discoverable
 * in Find Action and bindable to a shortcut. The variants below start a thread
 * with another [audience], so each one can have a shortcut of its own.
 */
open class AddCommentAction(private val audience: String = AUDIENCE_AGENT) : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun update(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR)
        val project = e.project
        e.presentation.isEnabledAndVisible =
            project != null && editor != null && e.getData(CommonDataKeys.VIRTUAL_FILE) != null &&
                !NotesService.getInstance(project).isBlocked()
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val (start, end) = selectedLineRange(editor)
        IncommEditorTracker.getInstance(project).startInlineAdd(editor, start, end, audience)
    }

    /** 1-based inclusive line range of the selection, or the caret line. */
    private fun selectedLineRange(editor: Editor): Pair<Int, Int> {
        val doc = editor.document
        val sel = editor.selectionModel
        if (sel.hasSelection()) {
            val startLine = doc.getLineNumber(sel.selectionStart)
            var endLine = doc.getLineNumber(sel.selectionEnd)
            // A selection ending exactly at a line start shouldn't include that line.
            if (endLine > startLine && sel.selectionEnd == doc.getLineStartOffset(endLine)) {
                endLine--
            }
            return (startLine + 1) to (endLine + 1)
        }
        val line = editor.caretModel.logicalPosition.line + 1
        return line to line
    }
}

/** "Incomm: Start New Private Thread" — a thread only you see. */
class AddPrivateCommentAction : AddCommentAction(AUDIENCE_PRIVATE)

/** "Incomm: Start New External Thread" — meant for the merge request, hidden from the agent. */
class AddExternalCommentAction : AddCommentAction(AUDIENCE_EXTERNAL)

/** "Incomm: Start New Agent + External Thread" — for the agent and the merge request. */
class AddAgentExternalCommentAction : AddCommentAction(AUDIENCE_BOTH)
