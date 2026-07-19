package dev.incomm.editor

import com.intellij.openapi.Disposable
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
import com.intellij.openapi.editor.ex.util.EditorScrollingPositionKeeper
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
     * One-shot scroll pin consulted by [refreshAll]: for the given editor, keep
     * this document offset's line at a fixed viewport-Y instead of the default
     * top-line anchor. Set right before a local save so the note's line (which
     * the user is looking at) stays put even as the async rebuild changes card
     * heights above it. Cleared after one refresh.
     */
    @Volatile
    private var scrollPin: Pair<Editor, Int>? = null

    /** Pin the next [refreshAll] for [editor] to keep [offset]'s line steady. */
    fun pinNextRefreshScroll(editor: Editor, offset: Int) {
        scrollPin = editor to offset
    }

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

        // Attach to editors that are already open (e.g. restored on project load).
        for (editor in factory.allEditors) {
            if (editor.project == project) onEditorCreated(editor)
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
        // Keep every visible editor's viewport fixed across the whole rebuild so
        // only the rendered thread blocks move — the code never scrolls. Embedded
        // components settle their height on a later layout pass, hence the second
        // (invokeLater) restore.
        //
        // A one-shot [scrollPin] (set on local save) overrides the default
        // top-line anchor for one editor: it keeps the *note's* line steady
        // instead, so the line the user is looking at doesn't jump when a
        // width-capped (taller) card replaces the composer above it.
        val pin = scrollPin
        scrollPin = null

        val restores = EditorFactory.getInstance().allEditors
            .filter { it.project == project && !it.isDisposed }
            .map { ed -> makeScrollRestore(ed, if (pin != null && pin.first === ed) pin.second else null) }

        for ((document, entry) in entries) rebuild(document, entry)
        for (controller in editorControllers.values) controller.refresh()
        for (controller in inlayControllers.values) controller.refresh()
        for (controller in rangeControllers.values) controller.refresh()

        for (r in restores) r.restore()
        ApplicationManager.getApplication().invokeLater({
            for (r in restores) {
                if (!project.isDisposed) r.restore()
                r.dispose()
            }
        }, ModalityState.any())
    }

    /** A saved scroll anchor with restore + dispose, either offset- or top-line-based. */
    private interface ScrollRestore {
        fun restore()
        fun dispose()
    }

    /**
     * Build a scroll anchor for [editor]. When [pinOffset] is non-null, keep that
     * offset's line at a fixed viewport-Y (used for the just-saved note). Otherwise
     * fall back to the default top-line [EditorScrollingPositionKeeper].
     */
    private fun makeScrollRestore(editor: Editor, pinOffset: Int?): ScrollRestore {
        if (pinOffset != null) {
            val sm = editor.scrollingModel
            val safe = pinOffset.coerceIn(0, editor.document.textLength)
            val relY = editor.offsetToXY(safe).y - sm.verticalScrollOffset
            return object : ScrollRestore {
                override fun restore() {
                    if (editor.isDisposed) return
                    val target = (editor.offsetToXY(safe).y - relY).coerceAtLeast(0)
                    sm.disableAnimation()
                    try {
                        sm.scrollVertically(target)
                    } finally {
                        sm.enableAnimation()
                    }
                }
                override fun dispose() {}
            }
        }
        val keeper = EditorScrollingPositionKeeper(editor)
        keeper.savePosition()
        return object : ScrollRestore {
            override fun restore() {
                if (!editor.isDisposed) keeper.restorePosition(false)
            }
            override fun dispose() = keeper.dispose()
        }
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
