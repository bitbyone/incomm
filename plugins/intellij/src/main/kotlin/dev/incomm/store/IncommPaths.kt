package dev.incomm.store

import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.openapi.vfs.VirtualFile
import java.io.File
import java.nio.file.Paths

/** Maps between IDE [VirtualFile]s and the project-root-relative POSIX paths
 *  stored in notes.json. */
object IncommPaths {

    /** Project-root-relative POSIX path for [file], or null if outside the project. */
    fun relPath(project: Project, file: VirtualFile): String? {
        val base = project.basePath ?: return null
        val basePath = Paths.get(base).toAbsolutePath().normalize()
        val filePath = Paths.get(file.path).toAbsolutePath().normalize()
        if (filePath == basePath || !filePath.startsWith(basePath)) return null
        return basePath.relativize(filePath).joinToString("/")
    }

    /** Resolve a note's rel path back to a [VirtualFile], if it exists on disk. */
    fun findVirtualFile(project: Project, rel: String): VirtualFile? {
        val base = project.basePath ?: return null
        val path = Paths.get(base).resolve(rel.replace('/', File.separatorChar))
        return LocalFileSystem.getInstance().findFileByNioFile(path)
    }
}
