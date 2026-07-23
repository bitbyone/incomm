package dev.incomm.startup

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.diagnostic.thisLogger
import com.intellij.openapi.project.Project
import com.intellij.openapi.startup.ProjectActivity
import dev.incomm.editor.IncommEditorTracker
import dev.incomm.store.NotesService

/**
 * On project open: load the notes model, start gutter/inlay tracking (on the
 * EDT, as early as possible), then re-anchor persisted notes against the
 * current on-disk file contents.
 */
class IncommStartupActivity : ProjectActivity {
    override suspend fun execute(project: Project) {
        // Touch the service so notes are loaded before the UI attaches.
        runCatching { NotesService.getInstance(project) }
            .onFailure { thisLogger().warn("incomm: failed to initialize NotesService", it) }

        // Start the editor tracking on the EDT so gutter icons, the "+" and
        // inline comments attach to already-open editors right away.
        ApplicationManager.getApplication().invokeLater(
            {
                if (project.isDisposed) return@invokeLater
                try {
                    IncommEditorTracker.getInstance(project).start()
                } catch (t: Throwable) {
                    thisLogger().error("incomm: failed to start editor tracker", t)
                }
                // Re-anchor in the background; publishes a refresh when done.
                ApplicationManager.getApplication().executeOnPooledThread {
                    if (project.isDisposed) return@executeOnPooledThread
                    runCatching { NotesService.getInstance(project).reanchorAllFromDisk() }
                        .onFailure { thisLogger().warn("incomm: reanchor on startup failed", it) }
                }
            },
            project.disposed,
        )
    }
}
