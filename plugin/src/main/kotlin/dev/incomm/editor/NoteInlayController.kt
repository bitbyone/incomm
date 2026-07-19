package dev.incomm.editor

import com.intellij.openapi.Disposable
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.application.ModalityState
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonShortcuts
import com.intellij.openapi.actionSystem.CustomShortcutSet
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.editor.Inlay
import com.intellij.openapi.editor.event.DocumentEvent
import com.intellij.openapi.editor.event.DocumentListener
import com.intellij.openapi.editor.ex.EditorEx
import com.intellij.openapi.editor.impl.EditorEmbeddedComponentManager
import com.intellij.openapi.fileTypes.FileTypes
import com.intellij.openapi.project.DumbAwareAction
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Disposer
import com.intellij.openapi.wm.IdeFocusManager
import com.intellij.ui.EditorTextField
import com.intellij.util.ui.JBUI
import dev.incomm.anchor.Anchoring
import dev.incomm.model.AUTHOR_USER
import dev.incomm.model.Note
import dev.incomm.settings.IncommSettings
import dev.incomm.store.NotesService
import dev.incomm.ui.IncommIcons
import dev.incomm.ui.NoteCardComponent
import dev.incomm.ui.ThreadUi
import java.awt.BorderLayout
import java.awt.Dimension
import java.awt.FlowLayout
import java.awt.Rectangle
import java.awt.event.ComponentAdapter
import java.awt.event.ComponentEvent
import java.awt.event.HierarchyEvent
import java.awt.event.HierarchyListener
import javax.swing.JPanel

/**
 * Per-editor manager of the display-only inline comment cards (block inlays).
 * Each note gets a card rendered above its first line. The card is read-only;
 * new comments and replies are composed in place: [startAdd] / [startReply]
 * embed an editable editor — the same rounded, colour-coded input used by the
 * thread view — with check/cancel icons (Esc/cancel discards it, and does not
 * save). Cards can be hidden via the tracker's visibility toggle while the
 * gutter icons remain.
 */
class NoteInlayController(
    private val project: Project,
    private val editor: Editor,
    private val rel: String,
    parent: Disposable,
) : Disposable {

    private class CardEntry(val inlay: Inlay<*>, val card: NoteCardComponent)

    private val cards = LinkedHashMap<String, CardEntry>()
    private var composeInlay: Inlay<*>? = null

    private val resizeListener = object : ComponentAdapter() {
        override fun componentResized(e: ComponentEvent) {
            for (entry in cards.values) if (entry.inlay.isValid) entry.inlay.update()
        }
    }

    init {
        Disposer.register(parent, this)
        editor.contentComponent.addComponentListener(resizeListener)
        rebuild()
    }

    fun refresh() = rebuild()

    /**
     * Update just the location header of every card in place (no inlay rebuild),
     * after live re-anchoring moved notes. Cheap and viewport-safe.
     */
    fun refreshLocations() {
        for (entry in cards.values) {
            if (entry.inlay.isValid) entry.card.refreshLocation()
        }
    }

    private fun rebuild() = keepScroll { rebuildInlays() }

    /**
     * Keep the editor's viewport exactly where it is while inlays are added or
     * removed. We simply preserve the raw pixel scroll offset — the editor is
     * already at the right position before the change, so we just don't let it
     * move. (An `EditorScrollingPositionKeeper` anchors to a logical line/caret,
     * which during compose is the *compose* editor's caret, not the note line —
     * that mis-anchoring is what made the page jump, worse the deeper you were.)
     */
    private fun keepScroll(block: () -> Unit) {
        if (editor.isDisposed) {
            block()
            return
        }
        val sm = editor.scrollingModel
        val saved = sm.verticalScrollOffset
        block()
        fun restore() {
            if (editor.isDisposed || sm.verticalScrollOffset == saved) return
            sm.disableAnimation()
            try {
                sm.scrollVertically(saved)
            } finally {
                sm.enableAnimation()
            }
        }
        restore()
        // Re-assert after the async layout settle (and after the notes-changed
        // refresh runs), so nothing nudges the viewport away.
        ApplicationManager.getApplication().invokeLater({ restore() }, ModalityState.any())
    }

    /**
     * Host panel for an embedded card/composer that never asks the code editor
     * to scroll it into view (so focusing an inner field doesn't move the page).
     */
    private fun noScrollHost(): JPanel = object : JPanel(BorderLayout()) {
        override fun scrollRectToVisible(aRect: Rectangle) { /* no-op */ }
    }

    private fun rebuildInlays() {
        disposeCompose()
        val tracker = IncommEditorTracker.getInstance(project)
        // Visibility is driven purely by hiddenNotes; "hide all" adds every id to
        // it, so a per-thread gutter toggle can still reveal one thread afterwards.
        val desired = NotesService.getInstance(project).notesForFile(rel)
            .filterNot { it.isHiddenInEditor() }
            .filterNot { tracker.isNoteHidden(it.id) }
        val desiredIds = desired.mapTo(HashSet()) { it.id }

        // Drop cards that are gone/hidden; keep the rest so the page doesn't churn.
        cards.keys.toList().forEach { id ->
            if (id !in desiredIds) cards.remove(id)?.let { if (it.inlay.isValid) Disposer.dispose(it.inlay) }
        }
        // Refresh existing cards in place; add the genuinely new ones. If a note
        // moved to a different line without an in-editor edit (e.g. its anchor was
        // changed via the CLI), the block inlay's offset is stale, so re-add it at
        // the new line instead of merely refreshing its contents.
        val doc = editor.document
        val lineCount = doc.lineCount
        for (note in desired) {
            val entry = cards[note.id]
            if (entry != null && entry.inlay.isValid && inlayAtNoteLine(entry.inlay, note, lineCount)) {
                entry.card.rebuild()
            } else {
                cards.remove(note.id)?.let { if (it.inlay.isValid) Disposer.dispose(it.inlay) }
                addCard(note)
            }
        }
    }

    /** Whether [inlay] still sits on the note's current (display) start line. */
    private fun inlayAtNoteLine(inlay: Inlay<*>, note: Note, lineCount: Int): Boolean {
        if (lineCount == 0) return true
        val target = (note.displayStartLine() - 1).coerceIn(0, lineCount - 1)
        val current = editor.document.getLineNumber(inlay.offset.coerceIn(0, editor.document.textLength))
        return current == target
    }

    /**
     * Show/hide just one thread's card, keeping the viewport fixed — used by the
     * gutter icon toggle so the whole page doesn't churn.
     */
    fun refreshCard(noteId: String) = keepScroll {
        cards.remove(noteId)?.let { if (it.inlay.isValid) Disposer.dispose(it.inlay) }
        val tracker = IncommEditorTracker.getInstance(project)
        if (tracker.isNoteHidden(noteId)) return@keepScroll
        val note = NotesService.getInstance(project).find(noteId) ?: return@keepScroll
        if (note.isHiddenInEditor()) return@keepScroll
        if (note.file == rel) addCard(note)
    }

    private fun addCard(note: Note) {
        val ex = editor as? EditorEx ?: return
        val doc = editor.document
        val lineCount = doc.lineCount
        if (lineCount == 0) return
        val startLine0 = (note.displayStartLine() - 1).coerceIn(0, lineCount - 1)
        // Always render the interactive card above the first line.
        val offset = doc.getLineStartOffset(startLine0)
        val card = NoteCardComponent(
            project,
            editor,
            note.id,
            onReply = { startReply(note.id) },
            onResolve = { resolved -> resolveNote(note.id, resolved) },
            onHover = { hovered ->
                IncommEditorTracker.getInstance(project)
                    .setHoveredNote(editor, if (hovered) note.id else null)
            },
            onContentResized = { onCardResized(note.id) },
        )

        // Compute indent: align with the first non-whitespace char of the line.
        val indentPx = computeIndentPx(startLine0)
        // Size the card to its capped width with a *measured* height, so the
        // block inlay gets the correct height immediately (no late growth/jump).
        sizeCard(card, indentPx)

        val host = noScrollHost().apply {
            isOpaque = true
            background = editor.colorsScheme.defaultBackground
            layout = javax.swing.BoxLayout(this, javax.swing.BoxLayout.Y_AXIS)
            border = JBUI.Borders.emptyLeft(indentPx)
            card.alignmentX = java.awt.Component.LEFT_ALIGNMENT
            add(card)
        }
        val props = EditorEmbeddedComponentManager.Properties(
            EditorEmbeddedComponentManager.ResizePolicy.none(),
            null,
            /* relatesToPrecedingText = */ false,
            /* showAbove = */ true,
            /* showWhenFolded = */ false,
            /* fullWidth = */ true,
            CARD_PRIORITY,
            offset,
        )
        EditorEmbeddedComponentManager.getInstance().addComponent(ex, host, props)
            ?.let { cards[note.id] = CardEntry(it, card) }
    }

    /**
     * Pixel indent from the content area's left edge to the first non-whitespace
     * character on [line0]. Handles tabs and variable-width (unlikely in monospace
     * editors, but safe).
     */
    private fun computeIndentPx(line0: Int): Int {
        val doc = editor.document
        if (line0 >= doc.lineCount) return 0
        val lineStart = doc.getLineStartOffset(line0)
        val lineEnd = doc.getLineEndOffset(line0)
        val text = doc.charsSequence
        var i = lineStart
        while (i < lineEnd && text[i].isWhitespace()) i++
        if (i == lineEnd) return 0 // blank line — no indent
        val firstNonWsX = editor.offsetToXY(i).x.toInt()
        val lineStartX = editor.offsetToXY(lineStart).x.toInt()
        return (firstNonWsX - lineStartX).coerceAtLeast(0)
    }

    /**
     * Size [card] to its capped render width with a **measured** height. The card
     * wraps its text at the capped width, so its real height is only known after a
     * layout at that width — we force one here and pin the card's preferred/maximum
     * size to the result. This gives the block inlay its correct height at creation
     * time, so it never grows on a later layout pass (which was causing the
     * viewport to jump after saving a comment).
     */
    private fun sizeCard(card: javax.swing.JComponent, indentPx: Int) {
        val cardWidth = cappedCardWidth(indentPx)
        // Reset any previous fixed size so the measurement reflects current content.
        card.preferredSize = null
        card.maximumSize = null
        card.setSize(cardWidth, 100_000)
        layoutDeep(card)
        val h = card.preferredSize.height.coerceAtLeast(1)
        val fixed = Dimension(cardWidth, h)
        card.preferredSize = fixed
        card.maximumSize = fixed
    }

    /** The pixel width a card renders at: min(maxWidthSetting, editorWidth - indent). */
    private fun cappedCardWidth(indentPx: Int): Int {
        val ex = editor as? EditorEx
        val maxChars = IncommSettings.getInstance().data.maxCardWidthChars
        val avail = editor.contentComponent.width
        val maxPx = if (maxChars > 0 && ex != null) {
            val font = ex.colorsScheme.getFont(com.intellij.openapi.editor.colors.EditorFontType.PLAIN)
            maxChars * editor.contentComponent.getFontMetrics(font).charWidth('m')
        } else {
            Int.MAX_VALUE
        }
        val width = when {
            avail <= 0 && maxPx == Int.MAX_VALUE -> 900 // fallback before first layout
            avail <= 0 -> maxPx
            maxPx == Int.MAX_VALUE -> avail - indentPx
            else -> minOf(maxPx, avail - indentPx)
        }
        return width.coerceAtLeast(120)
    }

    /** Recursively lay out a container so nested wrapping text reports true height. */
    private fun layoutDeep(c: java.awt.Container) {
        c.doLayout()
        for (child in c.components) {
            if (child is java.awt.Container) layoutDeep(child)
        }
    }

    /** Re-measure a card after its content changed (edit/reply), then update the inlay. */
    private fun onCardResized(noteId: String) {
        val entry = cards[noteId] ?: return
        val note = NotesService.getInstance(project).find(noteId) ?: return
        val doc = editor.document
        if (doc.lineCount == 0) return
        val startLine0 = (note.displayStartLine() - 1).coerceIn(0, doc.lineCount - 1)
        sizeCard(entry.card, computeIndentPx(startLine0))
        if (entry.inlay.isValid) resizeInlay(entry.inlay)
    }

    /** Resolve/reopen a thread; resolving also collapses (hides) its card. */
    private fun resolveNote(noteId: String, resolved: Boolean) {
        IncommEditorTracker.getInstance(project).setNoteResolved(noteId, resolved)
    }

    /** Begin editing a note's original comment in place, revealing its card first. */
    fun startEdit(noteId: String) {
        val tracker = IncommEditorTracker.getInstance(project)
        if (tracker.isNoteHidden(noteId)) {
            tracker.setNoteHidden(noteId, false)
            refreshCard(noteId)
        }
        cards[noteId]?.card?.beginEditOriginal()
    }

    /**
     * Embed an editable reply entry for [noteId] directly beneath its card, in
     * edit mode with the caret ready. Check saves the reply; cancel / Escape
     * discards it and the entry simply disappears.
     */
    fun startReply(noteId: String) {
        val note = NotesService.getInstance(project).find(noteId) ?: return
        startCompose(note.startLine, "new reply") { text ->
            NotesService.getInstance(project).addReply(noteId, text, AUTHOR_USER)
            null
        }
    }

    /**
     * Embed a composer for a brand-new comment on [startLine]..[endLine], inline
     * above the first line — identical to the reply editor. Check saves the
     * comment; cancel / Escape discards it.
     */
    fun startAdd(startLine: Int, endLine: Int) {
        startCompose(startLine, "new comment") { text ->
            val lines = Anchoring.splitLines(editor.document.text)
            NotesService.getInstance(project).addNote(rel, startLine, endLine, text, AUTHOR_USER, lines)
        }
    }

    /**
     * Shared inline composer used by both add and reply. [onSave] performs the
     * model mutation and returns the newly created [Note] (for a brand-new
     * comment) or null (for a reply); the returned note's card is added in the
     * same scroll-kept pass that removes the composer, so a new comment never
     * makes the editor jump.
     */
    private fun startCompose(anchorLine: Int, subtitle: String, onSave: (String) -> Note?) {
        val ex = editor as? EditorEx ?: return
        disposeCompose()

        val doc = editor.document
        if (doc.lineCount == 0) return
        val anchor0 = (anchorLine - 1).coerceIn(0, doc.lineCount - 1)
        val offset = doc.getLineStartOffset(anchor0)

        val field = composeField()
        val icons = JPanel(FlowLayout(FlowLayout.RIGHT, 2, 0)).apply { isOpaque = false }
        val header = JPanel(BorderLayout()).apply {
            isOpaque = false
            add(ThreadUi.authorLabel(AUTHOR_USER, subtitle), BorderLayout.CENTER)
            add(icons, BorderLayout.EAST)
        }
        val card = ThreadUi.RoundedPanel(ThreadUi.USER_BG).apply {
            layout = BorderLayout(0, 6)
            border = JBUI.Borders.empty(5, 12, 6, 8)
        }
        card.add(header, BorderLayout.NORTH)
        card.add(field, BorderLayout.CENTER)

        // Align with the code's first non-whitespace char, and cap width — same
        // proven BoxLayout approach as the display cards (addCard).
        val indentPx = computeIndentPx(anchor0)
        val maxChars = IncommSettings.getInstance().data.maxCardWidthChars
        val font = ex.colorsScheme.getFont(com.intellij.openapi.editor.colors.EditorFontType.PLAIN)
        val charWidth = editor.contentComponent.getFontMetrics(font).charWidth('m')
        val maxPx = if (maxChars > 0) maxChars * charWidth else Int.MAX_VALUE

        val host = noScrollHost().apply {
            isOpaque = true
            background = editor.colorsScheme.defaultBackground
            layout = javax.swing.BoxLayout(this, javax.swing.BoxLayout.Y_AXIS)
            border = JBUI.Borders.empty(1, 8 + indentPx, 5, 10)
            card.alignmentX = java.awt.Component.LEFT_ALIGNMENT
            card.maximumSize = Dimension(maxPx, Int.MAX_VALUE)
            add(card)
        }

        fun save() {
            val text = field.text.trim()
            if (text.isEmpty()) {
                closeCompose()
                return
            }
            // Swap the composer for the resulting card in a single scroll-kept
            // pass so the viewport doesn't jump; the async notes-changed refresh
            // then just refreshes that card in place.
            keepScroll {
                disposeCompose()
                val created = onSave(text)
                if (created != null && created.file == rel) addCard(created)
            }
        }

        icons.add(ThreadUi.iconButton(IncommIcons.CHECK, "Save") { save() })
        icons.add(ThreadUi.iconButton(IncommIcons.CANCEL, "Cancel") { closeCompose() })
        registerComposeShortcuts(field, ::save) { closeCompose() }

        val props = EditorEmbeddedComponentManager.Properties(
            EditorEmbeddedComponentManager.ResizePolicy.none(),
            null,
            /* relatesToPrecedingText = */ true,
            /* showAbove = */ true,
            /* showWhenFolded = */ false,
            /* fullWidth = */ true,
            REPLY_PRIORITY,
            offset,
        )
        keepScroll {
            composeInlay = EditorEmbeddedComponentManager.getInstance().addComponent(ex, host, props)
        }
        composeInlay?.let { inlay ->
            field.setDisposedWith(inlay)
            // Grow the block inlay as the user adds lines, so the editor isn't
            // clipped to one line and earlier lines don't scroll out of view.
            field.addDocumentListener(object : DocumentListener {
                override fun documentChanged(event: DocumentEvent) {
                    field.revalidate()
                    resizeInlay(inlay)
                }
            })
        }
        focusWhenShown(field)
    }

    /** Re-measure a block inlay immediately after its embedded editor changed height. */
    private fun resizeInlay(inlay: Inlay<*>) {
        if (inlay.isValid) inlay.update()
    }

    /**
     * A real, embedded editor for the input — not a plain Swing text area — so
     * every editing key (selection, word/line motion, backspace, undo, …) acts
     * on *this* input instead of leaking to the code editor underneath. Styled
     * flat to blend into the card.
     */
    private fun composeField(): EditorTextField {
        // A plain EditorTextField reports a one-line preferred height even in
        // multi-line mode, so it never grows. Size it to its actual line count.
        val field = object : EditorTextField("", project, FileTypes.PLAIN_TEXT) {
            override fun getPreferredSize(): java.awt.Dimension {
                val base = super.getPreferredSize()
                val ed = getEditor() ?: return base
                val lines = ed.document.lineCount.coerceAtLeast(1)
                val h = ed.lineHeight * lines + insets.top + insets.bottom + JBUI.scale(6)
                return java.awt.Dimension(base.width, maxOf(base.height, h))
            }
        }
        field.setOneLineMode(false)
        field.setPlaceholder("Write a comment\u2026")
        field.background = ThreadUi.USER_BG
        field.border = JBUI.Borders.empty(2)
        field.addSettingsProvider { e ->
            e.settings.apply {
                isLineNumbersShown = false
                isLineMarkerAreaShown = false
                isFoldingOutlineShown = false
                isRightMarginShown = false
                additionalColumnsCount = 0
                additionalLinesCount = 0
                isUseSoftWraps = true
                isCaretRowShown = false
            }
            e.setBorder(JBUI.Borders.empty())
            e.backgroundColor = ThreadUi.USER_BG
        }
        return field
    }

    private fun closeCompose() = keepScroll { disposeCompose() }

    private fun disposeCompose() {
        composeInlay?.let { if (it.isValid) Disposer.dispose(it) }
        composeInlay = null
    }

    /**
     * Register the composer's confirm/cancel keys as component-local IDE actions
     * so they win over the editor underneath: Cmd/Ctrl+Enter saves, Escape
     * discards. Plain Enter, motion, selection and deletion are handled natively
     * by the embedded editor.
     */
    private fun registerComposeShortcuts(field: EditorTextField, save: () -> Unit, cancel: () -> Unit) {
        object : DumbAwareAction() {
            override fun actionPerformed(e: AnActionEvent) = save()
        }.registerCustomShortcutSet(CustomShortcutSet.fromString("control ENTER", "meta ENTER"), field)
        object : DumbAwareAction() {
            override fun actionPerformed(e: AnActionEvent) = cancel()
        }.registerCustomShortcutSet(CommonShortcuts.ESCAPE, field)
    }

    /** Move keyboard focus into the composer once it is actually on screen. */
    private fun focusWhenShown(field: EditorTextField) {
        if (field.isShowing) {
            requestComposeFocus(field)
            return
        }
        field.addHierarchyListener(object : HierarchyListener {
            override fun hierarchyChanged(e: HierarchyEvent) {
                if (e.changeFlags and HierarchyEvent.SHOWING_CHANGED.toLong() != 0L && field.isShowing) {
                    field.removeHierarchyListener(this)
                    requestComposeFocus(field)
                }
            }
        })
    }

    private fun requestComposeFocus(field: EditorTextField) {
        IdeFocusManager.getInstance(project).requestFocus(field.focusTarget ?: field, true)
    }

    private fun disposeInlays() {
        for (entry in cards.values) {
            if (entry.inlay.isValid) Disposer.dispose(entry.inlay)
        }
        cards.clear()
    }

    override fun dispose() {
        editor.contentComponent.removeComponentListener(resizeListener)
        disposeCompose()
        disposeInlays()
    }

    private companion object {
        private const val CARD_PRIORITY = 0
        // Larger priority ⇒ closer to the line of text, so the composer sits
        // directly beneath the note's card (between the comments and the code).
        private const val REPLY_PRIORITY = 100
    }
}
