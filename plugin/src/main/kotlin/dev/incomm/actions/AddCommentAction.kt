package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import com.intellij.openapi.editor.Editor
import dev.incomm.editor.IncommEditorTracker

/**
 * "Incomm: Add Comment" — opens the inline composer for the current selection
 * (a line range) or, with no selection, the caret line. Discoverable in Find
 * Action and bindable to a shortcut.
 */
class AddCommentAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun update(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR)
        e.presentation.isEnabledAndVisible =
            e.project != null && editor != null && e.getData(CommonDataKeys.VIRTUAL_FILE) != null
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val (start, end) = selectedLineRange(editor)
        IncommEditorTracker.getInstance(project).startInlineAdd(editor, start, end)
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
