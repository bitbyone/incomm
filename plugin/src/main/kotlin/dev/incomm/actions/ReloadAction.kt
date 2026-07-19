package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.application.ApplicationManager
import dev.incomm.editor.IncommEditorTracker
import dev.incomm.store.NotesService

/**
 * "Incomm: Reload State" — forcibly reloads the notes model from disk and
 * rebuilds the UI. Useful as a fallback when the file watcher misses an
 * external change (e.g. the `.incomm/` directory was deleted).
 */
class ReloadAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun update(e: AnActionEvent) {
        e.presentation.isEnabled = e.project != null
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        ApplicationManager.getApplication().executeOnPooledThread {
            if (project.isDisposed) return@executeOnPooledThread
            NotesService.getInstance(project).reload()
            // Belt-and-suspenders: also poke the tracker to rebuild in case the
            // message-bus notification didn't cover a visual edge case.
            ApplicationManager.getApplication().invokeLater({
                if (!project.isDisposed) IncommEditorTracker.getInstance(project).refreshUi()
            }, project.disposed)
        }
    }
}
