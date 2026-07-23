package dev.incomm.store

import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.AsyncFileListener
import com.intellij.openapi.vfs.newvfs.events.VFileContentChangeEvent
import com.intellij.openapi.vfs.newvfs.events.VFileEvent
import com.intellij.util.concurrency.AppExecutorUtil

/**
 * Watches project source files (everything except notes.json) for on-disk
 * content changes made outside the IDE — typically an agent editing code via
 * the CLI. When a changed file has comments and is *not* open in an editor
 * (open editors are reindexed live by [dev.incomm.editor.IncommEditorTracker]),
 * its notes are reanchored from disk so positions stay correct.
 */
class IncommSourceFileWatcher(
    private val project: Project,
    private val isFileOpen: (String) -> Boolean,
) : AsyncFileListener {

    override fun prepareChange(events: List<VFileEvent>): AsyncFileListener.ChangeApplier? {
        if (project.isDisposed) return null
        val service = NotesService.getInstance(project)
        val notesPath = service.notesPath()?.toString()?.replace('\\', '/')

        val rels = HashSet<String>()
        for (event in events) {
            if (event !is VFileContentChangeEvent) continue
            if (event.path.replace('\\', '/') == notesPath) continue
            val rel = IncommPaths.relPath(project, event.file) ?: continue
            if (!service.hasNotesForFile(rel)) continue
            if (isFileOpen(rel)) continue // reindexed live by the editor tracker
            rels.add(rel)
        }
        if (rels.isEmpty()) return null

        return object : AsyncFileListener.ChangeApplier {
            override fun afterVfsChange() {
                if (project.isDisposed) return
                AppExecutorUtil.getAppExecutorService().execute {
                    if (!project.isDisposed) {
                        NotesService.getInstance(project).reanchorFilesFromDisk(rels)
                    }
                }
            }
        }
    }
}
