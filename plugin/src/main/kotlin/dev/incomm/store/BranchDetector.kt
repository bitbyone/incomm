package dev.incomm.store

import com.intellij.openapi.Disposable
import com.intellij.openapi.components.Service
import com.intellij.openapi.diagnostic.thisLogger
import com.intellij.openapi.project.Project
import com.intellij.openapi.vcs.BranchChangeListener
import java.io.File
import java.nio.file.Path
import java.nio.file.Paths

/**
 * Detects the current git branch for the project and notifies when it changes.
 *
 * Primary method: IntelliJ's [BranchChangeListener] API (fires for any VCS
 * branch change, including terminal-driven checkouts).
 *
 * Initial state: reads `.git/HEAD` directly from the filesystem — no git
 * binary required, no VCS plugin dependency. This handles the startup race
 * where IntelliJ's VCS subsystem may not have scanned repositories yet.
 *
 * Worktrees are supported: `.git` may be a file containing `gitdir: <path>`.
 *
 * The [branch] property is always the **raw** branch name (e.g. `feature/thing`),
 * never sanitized. Use [sanitize] / [notesFileName] when constructing filenames.
 */
@Service(Service.Level.PROJECT)
class BranchDetector(private val project: Project) : Disposable {

    /** Listeners called with the raw branch name (or empty string). */
    private val listeners = mutableListOf<(String) -> Unit>()

    /** Current raw branch name. Empty string = no branch / no git / detached. */
    @Volatile
    var branch: String = ""
        private set

    init {
        branch = detectRawFromGitHead()

        project.messageBus.connect(this).subscribe(
            BranchChangeListener.VCS_BRANCH_CHANGED,
            object : BranchChangeListener {
                override fun branchWillChange(branchName: String) {}
                override fun branchHasChanged(branchName: String) {
                    // Git4Idea fires branchHasChanged("HEAD") during initial VCS
                    // scan when getCurrentBranch() is null. In that case re-read
                    // .git/HEAD for the real branch instead of using the literal
                    // "HEAD" as a branch name.
                    val resolved = if (branchName == "HEAD") {
                        detectRawFromGitHead()
                    } else {
                        branchName
                    }
                    if (resolved != branch) {
                        branch = resolved
                        thisLogger().info("incomm: branch changed to '$resolved'")
                        listeners.forEach { it(resolved) }
                    }
                }
            },
        )
    }

    /** Register a callback invoked when the branch changes. */
    fun addListener(listener: (String) -> Unit) {
        listeners.add(listener)
    }

    override fun dispose() {
        listeners.clear()
    }

    /**
     * Read `.git/HEAD` from the project root (walking up if needed) and extract
     * the raw branch name. Returns the raw (unsanitized) branch name or empty string.
     */
    private fun detectRawFromGitHead(): String {
        val basePath = project.basePath ?: return ""
        val gitDir = findGitDir(Paths.get(basePath)) ?: return ""
        val head = gitDir.resolve("HEAD").toFile()
        if (!head.isFile) return ""
        return try {
            parseBranch(head.readText().trim())
        } catch (e: Exception) {
            thisLogger().debug("incomm: could not read .git/HEAD", e)
            ""
        }
    }

    companion object {
        fun getInstance(project: Project): BranchDetector =
            project.getService(BranchDetector::class.java)

        /** Sanitize a branch name for use in filenames (slashes → underscores). */
        fun sanitize(branch: String): String = branch.replace('/', '_')

        /**
         * Compute the notes filename for a raw branch.
         * Empty branch → legacy [NotesStore.FILE_NAME].
         */
        fun notesFileName(rawBranch: String): String =
            if (rawBranch.isEmpty()) NotesStore.FILE_NAME
            else "notes_${sanitize(rawBranch)}.json"

        /**
         * Extract branch name from `.git/HEAD` content.
         * `"ref: refs/heads/main"` → `"main"`;
         * `"abc123..."` (detached) → `""`.
         */
        internal fun parseBranch(head: String): String {
            val prefix = "ref: refs/heads/"
            return if (head.startsWith(prefix)) head.removePrefix(prefix) else ""
        }

        /**
         * Walk up from [start] looking for `.git` (directory or worktree file).
         * Returns the resolved git directory [Path], or null.
         */
        internal fun findGitDir(start: Path): Path? {
            var dir = start.toAbsolutePath().normalize()
            while (true) {
                val candidate = dir.resolve(".git")
                val file = candidate.toFile()
                if (file.exists()) {
                    if (file.isDirectory) return candidate
                    // Worktree: .git is a file containing "gitdir: <path>"
                    val gitdir = readGitdirFile(file, dir)
                    if (gitdir != null) return gitdir
                }
                val parent = dir.parent ?: return null
                if (parent == dir) return null
                dir = parent
            }
        }

        /**
         * Read a worktree `.git` file (`gitdir: <path>\n`) and resolve the path.
         */
        private fun readGitdirFile(gitFile: File, base: Path): Path? {
            val line = try {
                gitFile.readText().trim()
            } catch (_: Exception) {
                return null
            }
            val prefix = "gitdir: "
            if (!line.startsWith(prefix)) return null
            val raw = line.removePrefix(prefix)
            val resolved = if (File(raw).isAbsolute) Paths.get(raw) else base.resolve(raw)
            val normalized = resolved.normalize()
            return if (normalized.toFile().isDirectory) normalized else null
        }

        /**
         * Read `user.name` from the local `.git/config` (if present) or the
         * global `~/.gitconfig`. Returns null if neither is set.
         */
        fun detectUserName(projectBasePath: String): String? {
            val gitDir = findGitDir(Paths.get(projectBasePath))
            if (gitDir != null) {
                readGitConfigUserName(gitDir.resolve("config").toFile())?.let { return it }
            }
            val home = System.getProperty("user.home") ?: return null
            return readGitConfigUserName(File(home, ".gitconfig"))
        }

        /**
         * Parse a git config file for `[user] name = VALUE`.
         */
        private fun readGitConfigUserName(configFile: File): String? {
            if (!configFile.isFile) return null
            var inUserSection = false
            try {
                for (raw in configFile.readLines()) {
                    val line = raw.trim()
                    if (line.isEmpty() || line.startsWith('#') || line.startsWith(';')) continue
                    if (line.startsWith('[')) {
                        inUserSection = line.equals("[user]", ignoreCase = true)
                        continue
                    }
                    if (inUserSection) {
                        val eq = line.indexOf('=')
                        if (eq > 0 && line.substring(0, eq).trim().equals("name", ignoreCase = true)) {
                            return line.substring(eq + 1).trim().ifEmpty { null }
                        }
                    }
                }
            } catch (_: Exception) { /* best effort */ }
            return null
        }
    }
}
