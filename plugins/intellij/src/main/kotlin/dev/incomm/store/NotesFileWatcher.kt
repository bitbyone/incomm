package dev.incomm.store

import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.AsyncFileListener
import com.intellij.openapi.vfs.newvfs.events.VFileDeleteEvent
import com.intellij.openapi.vfs.newvfs.events.VFileEvent
import com.intellij.util.concurrency.AppExecutorUtil

/**
 * Watches the project's `.incomm/notes[_<branch>].json` for external changes
 * (e.g. the agent writing via the CLI) and reloads the model so the IDE
 * reflects them live. Also detects deletion of the `.incomm/` directory itself
 * (e.g. `rm -rf .incomm`) — an event that only touches the parent, not the
 * notes file directly.
 */
class NotesFileWatcher(private val project: Project) : AsyncFileListener {

    override fun prepareChange(events: List<VFileEvent>): AsyncFileListener.ChangeApplier? {
        if (project.isDisposed) return null
        val target = NotesService.getInstance(project).notesPath()?.toString()?.replace('\\', '/')
            ?: return null

        // Also consider the .incomm/ directory path: if it's deleted the notes
        // file is gone too, even though no event mentions the file directly.
        val dirPath = target.substringBeforeLast('/')

        val touched = events.any { event ->
            val path = normalize(event.path)
            path == target || (event is VFileDeleteEvent && (path == dirPath || target.startsWith("$path/")))
        }
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
