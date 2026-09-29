package one.bitby.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import one.bitby.incomm.store.NotesService
import one.bitby.incomm.ui.ThreadDetailsPopup

/**
 * "Incomm: Thread Details" - opens [ThreadDetailsPopup] for the thread on the caret
 * line: every comment of it, to step its audience (h/l), edit it (e) or delete it
 * (d) from the keyboard. Enabled only when the caret is inside a thread and the
 * notes file can be written.
 */
class ThreadDetailsAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

    override fun update(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR)
        val project = e.project
        val note = if (project != null && editor != null) CaretNote.of(project, editor) else null
        val writable = project != null && !NotesService.getInstance(project).isBlocked()
        e.presentation.isEnabledAndVisible = note != null && writable
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val note = CaretNote.of(project, editor) ?: return
        ThreadDetailsPopup.show(project, note.id, editor)
    }
}
