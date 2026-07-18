package dev.incomm.store

import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.newvfs.events.VFileEvent
import com.intellij.util.concurrency.AppExecutorUtil
import com.intellij.openapi.vfs.AsyncFileListener

/**
 * Watches the project's `.incomm/notes.json` for external changes (e.g. the
 * agent writing via the CLI) and reloads the model so the IDE reflects them
 * live. The plugin's own atomic writes also trigger a (harmless) reload.
 */
class NotesFileWatcher(private val project: Project) : AsyncFileListener {

    override fun prepareChange(events: List<VFileEvent>): AsyncFileListener.ChangeApplier? {
        if (project.isDisposed) return null
        val target = NotesService.getInstance(project).notesPath()?.toString()?.replace('\\', '/')
            ?: return null

        val touched = events.any { normalize(it.path) == target }
        if (!touched) return null

        return object : AsyncFileListener.ChangeApplier {
            override fun afterVfsChange() {
                if (project.isDisposed) return
                AppExecutorUtil.getAppExecutorService().execute {
                    if (!project.isDisposed) NotesService.getInstance(project).reload()
                }
            }
        }
    }

    private fun normalize(path: String): String = path.replace('\\', '/')
}
