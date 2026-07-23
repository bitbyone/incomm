package dev.incomm.editor

import com.intellij.openapi.Disposable
import com.intellij.openapi.application.ApplicationActivationListener
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.application.ModalityState
import com.intellij.openapi.components.Service
import com.intellij.openapi.editor.Document
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.editor.EditorFactory
import com.intellij.openapi.editor.event.DocumentEvent
import com.intellij.openapi.editor.event.DocumentListener
import com.intellij.openapi.editor.event.EditorFactoryEvent
import com.intellij.openapi.editor.event.EditorFactoryListener
import com.intellij.openapi.editor.impl.DocumentMarkupModel
import com.intellij.openapi.editor.markup.HighlighterLayer
import com.intellij.openapi.editor.markup.HighlighterTargetArea
import com.intellij.openapi.editor.markup.RangeHighlighter
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.fileEditor.FileDocumentManagerListener
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Disposer
import com.intellij.openapi.vfs.VirtualFileManager
import com.intellij.util.Alarm
import dev.incomm.anchor.Anchoring
import dev.incomm.store.IncommNotesListener
import dev.incomm.store.IncommPaths
import dev.incomm.store.IncommSourceFileWatcher
import dev.incomm.store.NotesFileWatcher
import dev.incomm.store.NotesService
import dev.incomm.ui.NoteGutterIconRenderer
import java.util.concurrent.ConcurrentHashMap

/**
 * Project-level owner of per-document gutter icons for notes. Icons live in the
 * shared [DocumentMarkupModel] so they appear in every editor of a file and
 * track edits automatically (range-marker semantics). On document save the
 * tracked positions are written back to notes.json.
 */
@Service(Service.Level.PROJECT)
class IncommEditorTracker(private val project: Project) : Disposable {

    private class DocEntry(var rel: String) {
        val highlighters = mutableListOf<RangeHighlighter>()
        val noteIdByHighlighter = HashMap<RangeHighlighter, String>()
        var refCount = 0
    }

    /** Keyed by Document; only touched on the EDT. */
    private val entries = HashMap<Document, DocEntry>()

    /** Per-editor "+" affordance controllers. */
    private val editorControllers = HashMap<Editor, AddGutterController>()

    /** Per-editor inline reply inlay controllers. */
    private val inlayControllers = HashMap<Editor, NoteInlayController>()

    /** Per-editor gutter range-band controllers (hover/caret). */
    private val rangeControllers = HashMap<Editor, NoteRangeHighlighter>()
    private var started = false

    /**
     * Rel paths of files currently open in an editor. Maintained on the EDT but
     * read from the (background) source-file watcher, so it is a concurrent set.
     */
    private val openRels = ConcurrentHashMap.newKeySet<String>()

    /** Debounces live re-anchoring while the user is typing. */
    private val reanchorAlarm = Alarm(Alarm.ThreadToUse.SWING_THREAD, this)
    private val pendingDocs = HashSet<Document>()

    /** Whether the inline comment cards are shown (gutter icons stay regardless). */
    var inlaysVisible = true
        private set

    /** Individually collapsed threads (their card is hidden; gutter icon stays). */
    private val hiddenNotes = HashSet<String>()

    /**
     * Hide or show *all* inline cards. Implemented via [hiddenNotes] (the single
     * source of truth for "card hidden") so an individual gutter-icon toggle can
     * still reveal one thread afterwards. Gutter icons stay regardless.
     */
    fun toggleInlaysVisible() {
        inlaysVisible = !inlaysVisible
        if (inlaysVisible) {
            hiddenNotes.clear()
        } else {
            NotesService.getInstance(project).allNotes().forEach { hiddenNotes.add(it.id) }
        }
        for (controller in inlayControllers.values) controller.refresh()
    }

    /** Hide/show one thread's card (from its gutter icon). Gutter icon stays. */
    fun toggleNoteHidden(noteId: String) {
        if (!hiddenNotes.remove(noteId)) hiddenNotes.add(noteId)
        for (controller in inlayControllers.values) controller.refreshCard(noteId)
    }

    fun isNoteHidden(noteId: String): Boolean = noteId in hiddenNotes

    /** Set one thread's hidden state; the caller triggers the rebuild that applies it. */
    fun setNoteHidden(noteId: String, hidden: Boolean) {
        if (hidden) hiddenNotes.add(noteId) else hiddenNotes.remove(noteId)
    }

    /** Resolve/reopen a thread; resolving also collapses (hides) its card. */
    fun setNoteResolved(noteId: String, resolved: Boolean) {
        setNoteHidden(noteId, resolved)
        NotesService.getInstance(project).setResolved(noteId, resolved)
    }

    /** Whether any resolved note has at least one comment. */
    fun hasResolvedNotes(): Boolean =
        NotesService.getInstance(project).allNotes().any { it.resolved }

    /** Whether at least one resolved note's card is currently shown. */
    fun anyResolvedVisible(): Boolean =
        NotesService.getInstance(project).allNotes().any { it.resolved && it.id !in hiddenNotes }

    /** Hide or show every resolved note's card in bulk. */
    fun setResolvedHidden(hidden: Boolean) {
        val resolved = NotesService.getInstance(project).allNotes().filter { it.resolved }
        if (resolved.isEmpty()) return
        for (note in resolved) {
            if (hidden) hiddenNotes.add(note.id) else hiddenNotes.remove(note.id)
        }
        for (controller in inlayControllers.values) controller.refresh()
    }

    /** Begin composing a reply for [noteId] inline, in [editor]'s comment card. */
    fun startInlineReply(editor: Editor, noteId: String) {
        inlayControllers[editor]?.startReply(noteId)
    }

    /** Begin composing a new comment for [startLine]..[endLine] inline in [editor]. */
    fun startInlineAdd(editor: Editor, startLine: Int, endLine: Int) {
        inlayControllers[editor]?.startAdd(startLine, endLine)
    }

    /** Begin editing [noteId]'s original comment in place, in [editor]'s card. */
    fun startInlineEdit(editor: Editor, noteId: String) {
        inlayControllers[editor]?.startEdit(noteId)
    }

    /** Light the gutter band for [noteId] (or clear it) as its card is hovered. */
    fun setHoveredNote(editor: Editor, noteId: String?) {
        rangeControllers[editor]?.setHoverNote(noteId)
    }

    fun start() {
        if (started) return
        started = true

        val factory = EditorFactory.getInstance()
        factory.addEditorFactoryListener(object : EditorFactoryListener {
            override fun editorCreated(event: EditorFactoryEvent) = onEditorCreated(event.editor)
            override fun editorReleased(event: EditorFactoryEvent) = onEditorReleased(event.editor)
        }, this)

        // Live re-anchoring: while a tracked document is edited, recompute and
        // persist note positions (debounced) so notes.json — and every rendered
        // block — tracks added/removed lines and anchor-text edits as they happen.
        factory.eventMulticaster.addDocumentListener(object : DocumentListener {
            override fun documentChanged(event: DocumentEvent) {
                val doc = event.document
                if (!entries.containsKey(doc)) return
                pendingDocs.add(doc)
                reanchorAlarm.cancelAllRequests()
                reanchorAlarm.addRequest({ flushPendingReanchors() }, REANCHOR_DELAY_MS)
            }
        }, this)

        project.messageBus.connect(this).subscribe(
            IncommNotesListener.TOPIC,
            IncommNotesListener {
                ApplicationManager.getApplication().invokeLater(
                    { if (!project.isDisposed) refreshAll() },
                    project.disposed,
                )
            },
        )

        ApplicationManager.getApplication().messageBus.connect(this).subscribe(
            FileDocumentManagerListener.TOPIC,
            object : FileDocumentManagerListener {
                override fun beforeDocumentSaving(document: Document) = persistPositions(document)
            },
        )

        // React to external edits of notes.json (agent/CLI writes).
        VirtualFileManager.getInstance().addAsyncFileListener(NotesFileWatcher(project), this)

        // React to external edits of source files (agent/CLI code edits) that are
        // not open in an editor, reanchoring their notes from disk.
        VirtualFileManager.getInstance()
            .addAsyncFileListener(IncommSourceFileWatcher(project) { rel -> rel in openRels }, this)

        // Ensure the native file watcher actually watches `.incomm/` so external
        // CLI writes fire VFS events (the dir is often gitignored / outside a
        // content root, so it isn't watched by default).
        registerIncommWatchRoot()

        // When the IDE regains focus, re-sync `.incomm/` from disk and reload.
        // This is the reliable moment to pick up external changes the VFS may
        // have missed — e.g. `incomm clear` deletes the dir and `incomm add`
        // recreates it, which leaves the VFS view stale until a refresh.
        ApplicationManager.getApplication().messageBus.connect(this).subscribe(
            ApplicationActivationListener.TOPIC,
            object : ApplicationActivationListener {
                override fun applicationActivated(ideFrame: com.intellij.openapi.wm.IdeFrame) {
                    syncIncommFromDisk()
                }
            },
        )

        // Rebuild inlays when the IDE theme or editor colour scheme changes, so
        // card/bubble colours (and the cached inlay-host backgrounds) update.
        val appConnection = ApplicationManager.getApplication().messageBus.connect(this)
        appConnection.subscribe(
            com.intellij.ide.ui.LafManagerListener.TOPIC,
            com.intellij.ide.ui.LafManagerListener { onThemeChanged() },
        )
        appConnection.subscribe(
            com.intellij.openapi.editor.colors.EditorColorsManager.TOPIC,
            com.intellij.openapi.editor.colors.EditorColorsListener { onThemeChanged() },
        )

        // Attach to editors that are already open (e.g. restored on project load).
        for (editor in factory.allEditors) {
            if (editor.project == project) onEditorCreated(editor)
        }
    }

    /** Full rebuild after a theme/scheme change (recreates inlays for new colours). */
    private fun onThemeChanged() {
        if (!started) return
        ApplicationManager.getApplication().invokeLater({
            if (project.isDisposed) return@invokeLater
            for ((document, entry) in entries) rebuild(document, entry)
            for (controller in inlayControllers.values) controller.hardRefresh()
            for (controller in editorControllers.values) controller.refresh()
            for (controller in rangeControllers.values) controller.refresh()
        }, project.disposed)
    }

    /** Register `.incomm/` (and its parent) with the native watcher. */
    private fun registerIncommWatchRoot() {
        val incommDir = NotesService.getInstance(project).notesPath()?.parent ?: return
        // Watch recursively; the request is disposed with the tracker. Watching a
        // not-yet-existing path is fine — it takes effect once the dir appears.
        com.intellij.openapi.vfs.LocalFileSystem.getInstance()
            .addRootToWatch(incommDir.toString().replace('\\', '/'), true)
    }

    /**
     * Force a VFS refresh of `.incomm/` from disk and reload the model. Handles
     * the case where the directory was deleted and recreated externally (which
     * leaves the VFS view stale), so external `incomm clear`/`add` show up.
     */
    private fun syncIncommFromDisk() {
        if (project.isDisposed) return
        ApplicationManager.getApplication().executeOnPooledThread {
            if (project.isDisposed) return@executeOnPooledThread
            val notesPath = NotesService.getInstance(project).notesPath() ?: return@executeOnPooledThread
            val lfs = com.intellij.openapi.vfs.LocalFileSystem.getInstance()
            // Refresh the parent (project base) so a recreated `.incomm/` dir is
            // discovered, then the dir and the notes file themselves.
            notesPath.parent?.parent?.let { lfs.refreshAndFindFileByNioFile(it) }
            notesPath.parent?.let { lfs.refreshAndFindFileByNioFile(it) }
            lfs.refreshAndFindFileByNioFile(notesPath)
            if (!project.isDisposed) NotesService.getInstance(project).reload()
        }
    }

    private fun onEditorCreated(editor: Editor) {
        if (editor.project != project) return
        val document = editor.document
        val vf = FileDocumentManager.getInstance().getFile(document) ?: return
        val rel = IncommPaths.relPath(project, vf) ?: return
        val entry = entries.getOrPut(document) { DocEntry(rel) }
        entry.rel = rel
        entry.refCount++
        if (entry.refCount == 1) rebuild(document, entry)

        editorControllers[editor] = AddGutterController(project, editor, rel, this)
        inlayControllers[editor] = NoteInlayController(project, editor, rel, this)
        rangeControllers[editor] = NoteRangeHighlighter(project, editor, rel, this)
        refreshOpenRels()
    }

    private fun onEditorReleased(editor: Editor) {
        editorControllers.remove(editor)?.let { Disposer.dispose(it) }
        inlayControllers.remove(editor)?.let { Disposer.dispose(it) }
        rangeControllers.remove(editor)?.let { Disposer.dispose(it) }
        val document = editor.document
        val entry = entries[document] ?: return
        entry.refCount--
        if (entry.refCount <= 0) {
            clear(entry)
            entries.remove(document)
        }
        refreshOpenRels()
    }

    /** Refresh the concurrent set of open rel paths from the current entries (EDT). */
    private fun refreshOpenRels() {
        openRels.clear()
        entries.values.mapTo(openRels) { it.rel }
    }

    /** Persist recomputed positions for every document that changed since the last flush. */
    private fun flushPendingReanchors() {
        if (project.isDisposed) return
        val docs = pendingDocs.toList()
        pendingDocs.clear()
        for (doc in docs) {
            if (!entries.containsKey(doc)) continue
            persistPositions(doc)
            // Update each card's line-number header in place. Position-only moves
            // persist quietly (no rebuild), so the header would otherwise go stale.
            for ((editor, controller) in inlayControllers) {
                if (editor.document === doc) controller.refreshLocations()
            }
        }
    }

    /** Rebuild every editor's incomm UI (e.g. after the settings colours changed). */
    fun refreshUi() {
        if (started) refreshAll()
    }

    private fun refreshAll() {
        val editors = EditorFactory.getInstance().allEditors
            .filter { it.project == project && !it.isDisposed }
            
        val saved = editors.associateWith { editor ->
            val visibleArea = editor.scrollingModel.visibleArea
            val logicalPos = editor.xyToLogicalPosition(visibleArea.location)
            val yOffsetWithinLine = visibleArea.y - editor.logicalPositionToXY(logicalPos).y
            Pair(logicalPos, yOffsetWithinLine)
        }

        for ((document, entry) in entries) rebuild(document, entry)
        for (controller in editorControllers.values) controller.refresh()
        for (controller in inlayControllers.values) controller.refresh()
        for (controller in rangeControllers.values) controller.refresh()

        fun restore() {
            for ((editor, state) in saved) {
                if (editor.isDisposed) continue
                val (logicalPos, yOffsetWithinLine) = state
                val targetY = editor.logicalPositionToXY(logicalPos).y + yOffsetWithinLine
                
                val sm = editor.scrollingModel
                if (sm.verticalScrollOffset == targetY) continue
                sm.disableAnimation()
                try {
                    sm.scrollVertically(targetY)
                } finally {
                    sm.enableAnimation()
                }
            }
        }
        
        restore()
        ApplicationManager.getApplication().invokeLater({
            if (!project.isDisposed) restore()
        }, ModalityState.any())
    }

    private fun rebuild(document: Document, entry: DocEntry) {
        clear(entry)
        val notes = NotesService.getInstance(project).notesForFile(entry.rel)
        if (notes.isEmpty()) return
        val lineCount = document.lineCount
        if (lineCount == 0) return

        val markup = DocumentMarkupModel.forDocument(document, project, true)
        for (note in notes) {
            // Orphaned+resolved notes are fully hidden; orphaned+unresolved float
            // to the first line rather than staying on their stale range.
            if (note.isHiddenInEditor()) continue
            val startLine0 = (note.displayStartLine() - 1).coerceIn(0, lineCount - 1)
            val endLine0 = (note.displayEndLine() - 1).coerceIn(startLine0, lineCount - 1)
            val startOffset = document.getLineStartOffset(startLine0)
            val endOffset = document.getLineEndOffset(endLine0)
            val hl = markup.addRangeHighlighter(
                startOffset,
                endOffset,
                LAYER,
                null,
                HighlighterTargetArea.EXACT_RANGE,
            )
            hl.gutterIconRenderer = NoteGutterIconRenderer(
                project,
                note.id,
                NoteGutterIconRenderer.iconFor(note),
                NoteGutterIconRenderer.tooltipFor(note),
            )
            entry.highlighters.add(hl)
            entry.noteIdByHighlighter[hl] = note.id
        }
    }

    private fun clear(entry: DocEntry) {
        for (hl in entry.highlighters) {
            if (hl.isValid) hl.dispose()
        }
        entry.highlighters.clear()
        entry.noteIdByHighlighter.clear()
    }

    /** On save, read each note's current line from its (moved) range marker and persist. */
    private fun persistPositions(document: Document) {
        val entry = entries[document] ?: return
        val service = NotesService.getInstance(project)
        val positions = HashMap<String, Pair<Int, Int>>()
        for (hl in entry.highlighters) {
            val id = entry.noteIdByHighlighter[hl] ?: continue
            // Orphaned notes are floated to line 1 for display only; never persist
            // that synthetic position — let the service re-anchor them by text.
            if (service.find(id)?.orphaned == true) continue
            if (hl.isValid && hl.endOffset >= hl.startOffset) {
                val s = document.getLineNumber(hl.startOffset) + 1
                val e = document.getLineNumber(hl.endOffset) + 1
                positions[id] = s to maxOf(s, e)
            }
            // Invalid markers are omitted so the service re-anchors them by text.
        }
        val lines = Anchoring.splitLines(document.text)
        NotesService.getInstance(project).applySavedPositions(entry.rel, lines, positions)
    }

    override fun dispose() {
        reanchorAlarm.cancelAllRequests()
        pendingDocs.clear()
        openRels.clear()
        for (entry in entries.values) clear(entry)
        entries.clear()
        editorControllers.clear()
        inlayControllers.clear()
        rangeControllers.clear()
    }

    companion object {
        private const val LAYER = HighlighterLayer.ADDITIONAL_SYNTAX

        /** Idle delay after the last keystroke before live positions are persisted. */
        private const val REANCHOR_DELAY_MS = 400

        fun getInstance(project: Project): IncommEditorTracker =
            project.getService(IncommEditorTracker::class.java)
    }
}
