package one.bitby.incomm.store

import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.openapi.vfs.VirtualFile

/** Maps between IDE [VirtualFile]s and the project-root-relative POSIX paths
 *  stored in notes.json. */
object IncommPaths {

    /** Project-root-relative POSIX path for [file], or null if outside the project. */
    fun relPath(project: Project, file: VirtualFile): String? {
        val base = project.basePath ?: return null
        val basePath = base.replace('\\', '/')
        val filePath = file.path
        if (filePath == basePath) return null
        if (filePath.startsWith("$basePath/")) {
            return filePath.substring(basePath.length + 1)
        }
        return null
    }

    /** Resolve a note's rel path back to a [VirtualFile], if it exists on disk. */
    fun findVirtualFile(project: Project, rel: String): VirtualFile? {
        val base = project.basePath ?: return null
        val fullPath = "${base.replace('\\', '/')}/$rel"
        return LocalFileSystem.getInstance().findFileByPath(fullPath)
    }
}
