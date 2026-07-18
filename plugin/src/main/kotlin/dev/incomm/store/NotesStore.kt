package dev.incomm.store

import com.google.gson.GsonBuilder
import dev.incomm.anchor.Anchoring
import dev.incomm.model.NotesFile
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import kotlin.io.path.exists
import kotlin.io.path.readText
import kotlin.io.path.writeText

/**
 * Pure filesystem access to `<root>/.incomm/notes.json`. No IntelliJ
 * dependencies, so it is unit-testable and mirrors the Go `internal/store`.
 */
class NotesStore(val root: Path) {

    val dir: Path get() = root.resolve(DIR_NAME)
    val notesPath: Path get() = dir.resolve(FILE_NAME)

    /** Load notes.json; a missing file yields an empty, normalized [NotesFile]. */
    fun load(): NotesFile {
        if (!notesPath.exists()) return NotesFile().normalize()
        val text = notesPath.readText()
        if (text.isBlank()) return NotesFile().normalize()
        val parsed = GSON.fromJson(text, NotesFile::class.java) ?: NotesFile()
        return parsed.normalize()
    }

    /** Write notes.json atomically (temp file + rename) with 2-space indent. */
    fun save(file: NotesFile) {
        file.normalize()
        Files.createDirectories(dir)
        val json = GSON.toJson(file) + "\n"
        val tmp = Files.createTempFile(dir, ".notes-", ".json.tmp")
        try {
            tmp.writeText(json)
            try {
                Files.move(tmp, notesPath, StandardCopyOption.ATOMIC_MOVE)
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(tmp, notesPath, StandardCopyOption.REPLACE_EXISTING)
            }
        } catch (e: Throwable) {
            Files.deleteIfExists(tmp)
            throw e
        }
    }

    /** Delete notes.json (and the .incomm dir if it becomes empty). */
    fun clear(): Boolean {
        val existed = Files.deleteIfExists(notesPath)
        if (dir.exists()) {
            Files.newDirectoryStream(dir).use { stream ->
                if (!stream.iterator().hasNext()) Files.deleteIfExists(dir)
            }
        }
        return existed
    }

    /** Convert an absolute path to a project-root-relative POSIX path. */
    fun relFile(path: Path): String {
        val abs = path.toAbsolutePath().normalize()
        val rel = root.toAbsolutePath().normalize().relativize(abs)
        return rel.joinToString("/")
    }

    /** Resolve a note's rel path to an absolute filesystem path. */
    fun absFile(rel: String): Path = root.resolve(rel.replace('/', java.io.File.separatorChar))

    /** Read a project file's lines (editor-line semantics), or null if missing. */
    fun readLines(rel: String): List<String>? {
        val p = absFile(rel)
        if (!p.exists()) return null
        return Anchoring.splitLines(p.readText())
    }

    companion object {
        const val DIR_NAME = ".incomm"
        const val FILE_NAME = "notes.json"

        // HTML escaping disabled for readable output; field order follows the
        // data-class declaration, matching the Go struct order in SCHEMA.md.
        private val GSON = GsonBuilder()
            .setPrettyPrinting()
            .disableHtmlEscaping()
            .create()
    }
}
