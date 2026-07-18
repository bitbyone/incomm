package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import com.intellij.openapi.ui.Messages
import dev.incomm.store.IncommPaths
import dev.incomm.store.NotesService

/**
 * "Incomm: Clear Comments in File" — deletes every comment for the current file
 * only (after confirmation). Other files' comments are untouched.
 */
class ClearFileAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun update(e: AnActionEvent) {
        e.presentation.isEnabled =
            e.project != null && e.getData(CommonDataKeys.VIRTUAL_FILE) != null
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val vf = e.getData(CommonDataKeys.VIRTUAL_FILE) ?: return
        val rel = IncommPaths.relPath(project, vf)
        if (rel == null) {
            Messages.showInfoMessage(project, "This file is outside the project root.", "Incomm")
            return
        }
        val service = NotesService.getInstance(project)
        val count = service.notesForFile(rel).size
        if (count == 0) {
            Messages.showInfoMessage(project, "There are no incomm comments in ${vf.name}.", "Incomm")
            return
        }
        val answer = Messages.showYesNoDialog(
            project,
            "Delete all $count incomm comment(s) in ${vf.name}? This cannot be undone.",
            "Incomm: Clear Comments in File",
            Messages.getWarningIcon(),
        )
        if (answer == Messages.YES) {
            service.removeNotesForFile(rel)
        }
    }
}
