package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import dev.incomm.store.NotesService
import dev.incomm.ui.NotesExplorerPopup

/**
 * "Incomm: Thread Explorer" — opens the fuzzy-finder explorer over all threads.
 */
class ShowCommentsAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun update(e: AnActionEvent) {
        e.presentation.isEnabled = e.project != null
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        // Reload from disk first so the explorer always reflects the current
        // on-disk state, even if a VFS event for an external change (e.g. an
        // `incomm clear`/`add` from the CLI) hasn't been delivered yet. reload()
        // reads the file directly via NIO, so it doesn't depend on VFS.
        NotesService.getInstance(project).reload()
        NotesExplorerPopup.show(project)
    }
}
