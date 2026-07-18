package dev.incomm.editor

import com.intellij.openapi.Disposable
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.editor.event.CaretEvent
import com.intellij.openapi.editor.event.CaretListener
import com.intellij.openapi.editor.markup.HighlighterLayer
import com.intellij.openapi.editor.markup.HighlighterTargetArea
import com.intellij.openapi.editor.markup.LineMarkerRendererEx
import com.intellij.openapi.editor.markup.RangeHighlighter
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Disposer
import com.intellij.ui.JBColor
import com.intellij.util.ui.JBUI
import dev.incomm.model.Note
import dev.incomm.store.NotesService
import java.awt.Color
import java.awt.Graphics
import java.awt.Graphics2D
import java.awt.Rectangle

/**
 * Per-editor controller that colours the gutter for a note's line range to make
 * a comment's extent obvious. The band appears when the mouse hovers the note's
 * inline card (driven by the card via [setHoverNote]) and, independently, when
 * the caret sits anywhere inside the note's range (even a single line).
 */
class NoteRangeHighlighter(
    private val project: Project,
    private val editor: Editor,
    private val rel: String,
    parent: Disposable,
) : Disposable {

    private var caretHighlighter: RangeHighlighter? = null
    private var caretNoteId: String? = null
    private var hoverHighlighter: RangeHighlighter? = null
    private var hoverNoteId: String? = null

    init {
        Disposer.register(parent, this)

        editor.caretModel.addCaretListener(object : CaretListener {
            override fun caretPositionChanged(e: CaretEvent) = setCaret(e.newPosition.line + 1)
        }, this)

        setCaret(editor.caretModel.logicalPosition.line + 1)
    }

    /** Recompute after notes changed (ranges moved, notes added/removed). */
    fun refresh() {
        caretNoteId = null
        disposeHighlighter(caretHighlighter)
        caretHighlighter = null
        setCaret(editor.caretModel.logicalPosition.line + 1)
        // The hover band re-appears when the card reports hover again; drop stale.
        setHoverNote(null)
    }

    // ---- hover over the inline card (driven by NoteCardComponent) -----------

    fun setHoverNote(noteId: String?) {
        if (noteId == hoverNoteId) return
        hoverNoteId = noteId
        disposeHighlighter(hoverHighlighter)
        hoverHighlighter = null
        // Don't paint twice when the caret already lit the same note.
        if (noteId != null && noteId != caretNoteId) {
            NotesService.getInstance(project).find(noteId)?.let { hoverHighlighter = addBand(it) }
        }
    }

    // ---- caret inside a note's range ---------------------------------------

    private fun setCaret(line1: Int) {
        val note = noteAt(line1)
        if (note?.id == caretNoteId) return
        caretNoteId = note?.id
        disposeHighlighter(caretHighlighter)
        caretHighlighter = null
        if (note != null) caretHighlighter = addBand(note)
        // If the hover band is on the same note, drop the duplicate.
        if (hoverNoteId != null && hoverNoteId == caretNoteId) {
            disposeHighlighter(hoverHighlighter)
            hoverHighlighter = null
        }
    }

    private fun noteAt(line1: Int): Note? {
        if (line1 < 1) return null
        return NotesService.getInstance(project).notesForFile(rel)
            .firstOrNull { line1 in it.startLine..it.endLine }
    }

    // ---- gutter band -------------------------------------------------------

    private fun addBand(note: Note): RangeHighlighter {
        val doc = editor.document
        val last = (doc.lineCount - 1).coerceAtLeast(0)
        val start0 = (note.startLine - 1).coerceIn(0, last)
        val end0 = (note.endLine - 1).coerceIn(start0, last)
        val hl = editor.markupModel.addRangeHighlighter(
            doc.getLineStartOffset(start0),
            doc.getLineEndOffset(end0),
            HighlighterLayer.ADDITIONAL_SYNTAX,
            null,
            HighlighterTargetArea.LINES_IN_RANGE,
        )
        hl.setLineMarkerRenderer(RangeBandRenderer(bandColor(note)))
        return hl
    }

    private fun disposeHighlighter(hl: RangeHighlighter?) {
        if (hl != null && hl.isValid) hl.dispose()
    }

    override fun dispose() {
        disposeHighlighter(caretHighlighter)
        disposeHighlighter(hoverHighlighter)
        caretHighlighter = null
        hoverHighlighter = null
    }

    /** Paints a full-width translucent band across the gutter for the note's lines. */
    private class RangeBandRenderer(private val accent: Color) : LineMarkerRendererEx {
        override fun paint(editor: Editor, g: Graphics, r: Rectangle) {
            val g2 = g.create() as Graphics2D
            try {
                g2.color = Color(accent.red, accent.green, accent.blue, 46)
                g2.fillRect(r.x, r.y, r.width, r.height)
                g2.color = accent
                g2.fillRect(r.x, r.y, JBUI.scale(3), r.height)
            } finally {
                g2.dispose()
            }
        }

        override fun getPosition(): LineMarkerRendererEx.Position = LineMarkerRendererEx.Position.CUSTOM
    }

    private companion object {
        private fun bandColor(note: Note): JBColor = when {
            note.orphaned -> JBColor(0xE5A700, 0xB08400)
            note.resolved -> JBColor(0x59A869, 0x4C8A5A)
            else -> JBColor(0x6C9FF0, 0x3B5680)
        }
    }
}
