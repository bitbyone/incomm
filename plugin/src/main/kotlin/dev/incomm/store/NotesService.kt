package dev.incomm.store

import com.intellij.openapi.Disposable
import com.intellij.openapi.application.ApplicationManager
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

    /**
     * Ids of notes deleted locally but whose deletion may not have hit disk yet.
     * The merge-on-write step consults this so a note the user just deleted is
     * not resurrected from the still-current on-disk copy. Guarded by [lock].
     */
    private val locallyDeleted = HashSet<String>()

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

    /** Whether any note anchors to [rel] (cheap; no copying). */
    fun hasNotesForFile(rel: String): Boolean =
        synchronized(lock) { model.notes.any { it.file == rel } }

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
        // Skip the notification (and the UI rebuild it drives) when the file on
        // disk already matches memory — e.g. the reload triggered by our own
        // atomic write. This avoids redundant, viewport-disturbing refreshes.
        val changed = synchronized(lock) {
            // Don't resurrect notes we've deleted locally but not yet flushed.
            if (locallyDeleted.isNotEmpty()) loaded.notes.removeAll { it.id in locallyDeleted }
            if (model == loaded) false else { model = loaded; true }
        }
        if (publish && changed) publishChanged()
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
     * Persist positions for all notes of one file after an edit. [positions] maps
     * note id -> (startLine,endLine) for notes whose live range marker survived;
     * notes not present are re-anchored by text (or marked orphaned).
     *
     * Position-only updates persist **quietly** (no [publishChanged]): the editor's
     * range markers and block inlays already track document edits natively, so
     * rebuilding them would only disturb the viewport. A rebuild is published only
     * when something visual actually changes — a note un-orphans, or a note whose
     * marker died had to be re-anchored by text (its gutter marker must be rebuilt).
     */
    fun applySavedPositions(rel: String, fileLines: List<String>, positions: Map<String, Pair<Int, Int>>) {
        var changed = false
        var needsRebuild = false
        synchronized(lock) {
            for (note in model.notes) {
                if (note.file != rel) continue
                val pos = positions[note.id]
                if (pos != null) {
                    // Recompute the anchor too so editing the anchored line's text
                    // (not just adding/removing lines) refreshes it live.
                    val newAnchor = Anchoring.compute(fileLines, pos.first, pos.second)
                    if (note.startLine != pos.first || note.endLine != pos.second ||
                        note.orphaned || note.anchor != newAnchor
                    ) {
                        if (note.orphaned) needsRebuild = true // un-orphaning changes the gutter icon
                        note.startLine = pos.first
                        note.endLine = pos.second
                        note.anchor = newAnchor
                        note.orphaned = false
                        changed = true
                    }
                } else {
                    // No surviving marker: the gutter highlighter is gone, so a
                    // successful text re-anchor requires rebuilding it.
                    if (Anchoring.reanchor(note, fileLines)) {
                        changed = true
                        needsRebuild = true
                    }
                }
            }
        }
        if (changed) {
            if (needsRebuild) persistAndNotify() else persistQuietly()
        }
    }

    fun removeNote(id: String): Boolean {
        val removed = synchronized(lock) {
            if (model.remove(id)) { locallyDeleted.add(id); true } else false
        }
        if (removed) persistAndNotify()
        return removed
    }

    /** Delete every note for one file (rel path). Returns how many were removed. */
    fun removeNotesForFile(rel: String): Int {
        val removed = synchronized(lock) {
            val gone = model.notes.filter { it.file == rel }.map { it.id }
            model.notes.removeAll { it.file == rel }
            locallyDeleted.addAll(gone)
            gone.size
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

    /**
     * Reanchor only the notes belonging to [rels] against their on-disk
     * contents (used when a source file changes outside any open editor).
     * Missing files mark their notes orphaned. Returns whether anything changed.
     */
    fun reanchorFilesFromDisk(rels: Set<String>): Boolean {
        if (rels.isEmpty()) return false
        val store = storeOrNull() ?: return false
        var changed = false
        synchronized(lock) {
            val cache = HashMap<String, List<String>?>()
            for (note in model.notes) {
                if (note.file !in rels) continue
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

    private fun persistAndNotify() = persist(notify = true)

    /**
     * Persist without an immediate notification (no UI rebuild). Used for live
     * position tracking, where the editor already renders correctly and a rebuild
     * would only disturb the viewport. The CLI still sees the update. If the
     * merge below discovers notes added externally, a refresh is published anyway.
     */
    private fun persistQuietly() = persist(notify = false)

    /**
     * Merge-on-write persistence. On the writer thread we first load the **current**
     * `notes.json` and fold in any notes it contains that our in-memory model does
     * not yet know about — i.e. comments the agent/CLI added concurrently — before
     * saving. This guarantees a plugin write never clobbers the agent's notes
     * (the previous "serialize the whole model over the file" behaviour deleted
     * them). Newly discovered external notes also trigger a refresh so they appear.
     */
    private fun persist(notify: Boolean) {
        if (notify) publishChanged() // immediate UI for the local change
        val store = storeOrNull() ?: return
        writeExecutor.execute {
            val disk = try {
                store.load()
            } catch (e: Exception) {
                thisLogger().warn("incomm: load-for-merge failed", e)
                null
            }
            var externalAppeared = false
            val handledDeletes: Set<String>
            val merged = synchronized(lock) {
                if (disk != null) {
                    val known = model.notes.mapTo(HashSet()) { it.id }
                    // Fold in notes another writer (the agent) added, but never a
                    // note we deleted locally that just hasn't been flushed yet.
                    val extras = disk.notes.filter { it.id !in known && it.id !in locallyDeleted }
                    if (extras.isNotEmpty()) {
                        model.notes.addAll(extras.map { it.deepCopy() })
                        externalAppeared = true
                    }
                }
                handledDeletes = HashSet(locallyDeleted)
                model.deepCopy()
            }
            try {
                store.save(merged)
            } catch (e: Exception) {
                thisLogger().warn("incomm: save failed", e)
            }
            // Those deletions are now on disk (merged omits them); stop guarding them.
            synchronized(lock) { locallyDeleted.removeAll(handledDeletes) }
            if (externalAppeared && !notify) {
                ApplicationManager.getApplication().invokeLater(
                    { if (!project.isDisposed) publishChanged() },
                    project.disposed,
                )
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
