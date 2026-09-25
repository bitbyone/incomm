package one.bitby.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import one.bitby.incomm.model.Audience
import one.bitby.incomm.store.NotesService

/**
 * "Incomm: Cycle Thread Audience" - steps the audience of the thread on the caret
 * line (its first comment) through agent, agent + external, external and private.
 * A reply's audience is changed from its own bubble. Enabled only when the caret
 * is inside a thread and the notes file can be written.
 */
class CycleThreadAudienceAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

    override fun update(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR)
        val project = e.project
        val note = if (project != null && editor != null) CaretNote.of(project, editor) else null
        val writable = project != null && !NotesService.getInstance(project).isBlocked()
        e.presentation.isEnabledAndVisible = note != null && writable
        if (note != null) {
            e.presentation.text = "Incomm: Set Thread Audience to " + Audience.label(Audience.next(note.audience))
        }
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val note = CaretNote.of(project, editor) ?: return
        NotesService.getInstance(project).setAudience(note.id, null, Audience.next(note.audience))
    }
}
