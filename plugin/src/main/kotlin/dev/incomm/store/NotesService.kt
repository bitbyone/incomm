package dev.incomm.store

import com.intellij.openapi.Disposable
import com.intellij.openapi.components.Service
import com.intellij.openapi.diagnostic.thisLogger
import com.intellij.openapi.project.Project
import com.intellij.util.concurrency.AppExecutorUtil
import dev.incomm.anchor.Anchoring
import dev.incomm.model.Note
import dev.incomm.model.NotesFile
import dev.incomm.model.Reply
import dev.incomm.model.newId
import dev.incomm.model.nowUtc
import java.nio.file.Path
import java.nio.file.Paths
import java.util.concurrent.TimeUnit

/**
 * Project-level owner of the in-memory notes model and its `.incomm/notes.json`
 * persistence. All reads/mutations go through here. Mutations update memory
 * synchronously, notify listeners, and persist to disk on a single background
 * thread (serialized, atomic).
 */
@Service(Service.Level.PROJECT)
class NotesService(private val project: Project) : Disposable {

    private val lock = Any()
    private var model: NotesFile = NotesFile()

    private val writeExecutor =
        AppExecutorUtil.createBoundedApplicationPoolExecutor("incomm-notes-writer", 1)

    init {
        reloadInternal(publish = false)
    }

    private fun storeOrNull(): NotesStore? {
        val base = project.basePath ?: return null
        return NotesStore(Paths.get(base))
    }

    /** Absolute path to notes.json, or null if the project has no base path. */
    fun notesPath(): Path? = storeOrNull()?.notesPath

    // ---- reads -------------------------------------------------------------

    fun allNotes(): List<Note> = synchronized(lock) { model.notes.map { it.deepCopy() } }

    fun notesForFile(rel: String): List<Note> =
        synchronized(lock) { model.notes.filter { it.file == rel }.map { it.deepCopy() } }

    fun find(id: String): Note? = synchronized(lock) { model.find(id)?.deepCopy() }

    fun isEmpty(): Boolean = synchronized(lock) { model.notes.isEmpty() }

    /** Cheap check (no copying) used on the hot mouse-move path. */
    fun hasNoteOnLine(rel: String, line: Int): Boolean = synchronized(lock) {
        model.notes.any { it.file == rel && line in it.startLine..it.endLine }
    }

    // ---- lifecycle ---------------------------------------------------------

    /** Reload from disk and notify listeners. */
    fun reload() = reloadInternal(publish = true)

    private fun reloadInternal(publish: Boolean) {
        val store = storeOrNull() ?: return
        val loaded = try {
            store.load()
        } catch (e: Exception) {
            thisLogger().warn("incomm: failed to load ${store.notesPath}", e)
            NotesFile()
        }
        synchronized(lock) { model = loaded }
        if (publish) publishChanged()
    }

    // ---- mutations ---------------------------------------------------------

    /** Create a note for [file] (rel path) spanning [startLine]..[endLine]. */
    fun addNote(
        file: String,
        startLine: Int,
        endLine: Int,
        content: String,
        author: String,
        fileLines: List<String>,
    ): Note {
        val now = nowUtc()
        val note = Note(
            id = newId(),
            file = file,
            startLine = startLine,
            endLine = endLine,
            anchor = Anchoring.compute(fileLines, startLine, endLine),
            content = content,
            resolved = false,
            orphaned = false,
            author = author,
            createdAt = now,
            updatedAt = now,
            replies = mutableListOf(),
        )
        synchronized(lock) { model.notes.add(note) }
        persistAndNotify()
        return note.deepCopy()
    }

    fun updateContent(id: String, content: String) = mutate(id) {
        it.content = content
        it.updatedAt = nowUtc()
    }

    fun addReply(id: String, content: String, author: String) = mutate(id) {
        it.replies.add(Reply(newId(), author, content, nowUtc()))
        it.updatedAt = nowUtc()
    }

    /** Edit an existing reply's text. */
    fun updateReply(noteId: String, replyId: String, content: String) = mutate(noteId) { note ->
        note.replies.firstOrNull { it.id == replyId }?.let {
            it.content = content
            note.updatedAt = nowUtc()
        }
    }

    /** Remove a single reply from a note. */
    fun removeReply(noteId: String, replyId: String) = mutate(noteId) { note ->
        note.replies.removeAll { it.id == replyId }
        note.updatedAt = nowUtc()
    }

    fun setResolved(id: String, resolved: Boolean) = mutate(id) {
        it.resolved = resolved
        it.updatedAt = nowUtc()
    }

    /** Persist a new position (used by live tracking on document save). */
    fun updatePosition(id: String, startLine: Int, endLine: Int, fileLines: List<String>) = mutate(id) {
        it.startLine = startLine
        it.endLine = endLine
        it.anchor = Anchoring.compute(fileLines, startLine, endLine)
        it.orphaned = false
    }

    /**
     * Persist positions for all notes of one file after a save. [positions] maps
     * note id -> (startLine,endLine) for notes whose live range marker survived;
     * notes not present are re-anchored by text (or marked orphaned).
     */
    fun applySavedPositions(rel: String, fileLines: List<String>, positions: Map<String, Pair<Int, Int>>) {
        var changed = false
        synchronized(lock) {
            for (note in model.notes) {
                if (note.file != rel) continue
                val pos = positions[note.id]
                if (pos != null) {
                    if (note.startLine != pos.first || note.endLine != pos.second || note.orphaned) {
                        note.startLine = pos.first
                        note.endLine = pos.second
                        note.anchor = Anchoring.compute(fileLines, pos.first, pos.second)
                        note.orphaned = false
                        changed = true
                    }
                } else if (Anchoring.reanchor(note, fileLines)) {
                    changed = true
                }
            }
        }
        if (changed) persistAndNotify()
    }

    fun removeNote(id: String): Boolean {
        val removed = synchronized(lock) { model.remove(id) }
        if (removed) persistAndNotify()
        return removed
    }

    /** Delete every note for one file (rel path). Returns how many were removed. */
    fun removeNotesForFile(rel: String): Int {
        val removed = synchronized(lock) {
            val before = model.notes.size
            model.notes.removeAll { it.file == rel }
            before - model.notes.size
        }
        if (removed > 0) persistAndNotify()
        return removed
    }

    /** Delete every note by removing notes.json. */
    fun clearAll() {
        synchronized(lock) { model = NotesFile() }
        publishChanged()
        val store = storeOrNull() ?: return
        writeExecutor.execute {
            try {
                store.clear()
            } catch (e: Exception) {
                thisLogger().warn("incomm: clear failed", e)
            }
        }
    }

    /**
     * Reanchor every note against its file's on-disk contents. Files that are
     * missing mark their notes orphaned. Returns whether anything changed.
     */
    fun reanchorAllFromDisk(): Boolean {
        val store = storeOrNull() ?: return false
        var changed = false
        synchronized(lock) {
            val cache = HashMap<String, List<String>?>()
            for (note in model.notes) {
                val lines = cache.getOrPut(note.file) { store.readLines(note.file) }
                if (lines == null) {
                    if (!note.orphaned) {
                        note.orphaned = true
                        changed = true
                    }
                    continue
                }
                if (Anchoring.reanchor(note, lines)) changed = true
            }
        }
        if (changed) persistAndNotify()
        return changed
    }

    private inline fun mutate(id: String, block: (Note) -> Unit): Boolean {
        val hit = synchronized(lock) {
            val note = model.find(id) ?: return false
            block(note)
            true
        }
        if (hit) persistAndNotify()
        return hit
    }

    // ---- persistence -------------------------------------------------------

    private fun persistAndNotify() {
        val snapshot = synchronized(lock) { model.deepCopy() }
        publishChanged()
        val store = storeOrNull() ?: return
        writeExecutor.execute {
            try {
                store.save(snapshot)
            } catch (e: Exception) {
                thisLogger().warn("incomm: save failed", e)
            }
        }
    }

    /** Test hook: block until all queued disk writes have completed. */
    @org.jetbrains.annotations.TestOnly
    fun flushWrites() {
        writeExecutor.submit { }.get(5, TimeUnit.SECONDS)
    }

    private fun publishChanged() {
        if (project.isDisposed) return
        project.messageBus.syncPublisher(IncommNotesListener.TOPIC).notesChanged()
    }

    override fun dispose() {
        writeExecutor.shutdown()
        try {
            writeExecutor.awaitTermination(2, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    companion object {
        fun getInstance(project: Project): NotesService =
            project.getService(NotesService::class.java)
    }
}
