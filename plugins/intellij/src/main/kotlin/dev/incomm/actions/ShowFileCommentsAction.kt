package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import com.intellij.openapi.ui.Messages
import dev.incomm.store.IncommPaths
import dev.incomm.store.NotesService
import dev.incomm.ui.NotesExplorerPopup

/**
 * "Incomm: Thread Explorer in File" — opens the fuzzy-finder explorer over threads
 * in the currently opened and focused file only.
 */
class ShowFileCommentsAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun update(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR)
        val vf = e.getData(CommonDataKeys.VIRTUAL_FILE)
        e.presentation.isEnabled = e.project != null && editor != null && vf != null
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val vf = e.getData(CommonDataKeys.VIRTUAL_FILE) ?: return
        val rel = IncommPaths.relPath(project, vf)
        if (rel == null) {
            Messages.showInfoMessage(project, "This file is outside the project root.", "Incomm")
            return
        }
        NotesService.getInstance(project).reload()
        NotesExplorerPopup.show(project, fileFilter = rel)
    }
}
