package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.ui.Messages
import dev.incomm.store.NotesService

/**
 * "Incomm: Clear All Comments" — deletes every comment by removing
 * .incomm/notes.json (after confirmation).
 */
class ClearAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun update(e: AnActionEvent) {
        e.presentation.isEnabled = e.project != null
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val service = NotesService.getInstance(project)
        if (service.isEmpty()) {
            Messages.showInfoMessage(project, "There are no incomm comments to clear.", "Incomm")
            return
        }
        val answer = Messages.showYesNoDialog(
            project,
            "Delete ALL incomm comments? This removes .incomm/notes.json and cannot be undone.",
            "Incomm: Clear All Comments",
            Messages.getWarningIcon(),
        )
        if (answer == Messages.YES) {
            service.clearAll()
        }
    }
}
