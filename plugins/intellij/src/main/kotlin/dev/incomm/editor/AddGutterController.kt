package dev.incomm.editor

import com.intellij.openapi.Disposable
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.editor.event.CaretEvent
import com.intellij.openapi.editor.event.CaretListener
import com.intellij.openapi.editor.event.EditorMouseEvent
import com.intellij.openapi.editor.event.EditorMouseEventArea
import com.intellij.openapi.editor.event.EditorMouseListener
import com.intellij.openapi.editor.event.EditorMouseMotionListener
import com.intellij.openapi.editor.markup.HighlighterLayer
import com.intellij.openapi.editor.markup.HighlighterTargetArea
import com.intellij.openapi.editor.markup.RangeHighlighter
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Disposer
import dev.incomm.store.NotesService
import dev.incomm.ui.AddPlusGutterIconRenderer

/**
 * Per-editor controller that renders the "+" add-comment affordance in the
 * gutter: on the line under the mouse (GitHub-style hover) and, as a reliable
 * fallback, on the caret line. Lines that already carry a note show no "+".
 */
class AddGutterController(
    private val project: Project,
    private val editor: Editor,
    private val rel: String,
    parent: Disposable,
) : Disposable {

    private var hoverHighlighter: RangeHighlighter? = null
    private var hoverLine = -1
    private var caretHighlighter: RangeHighlighter? = null
    private var caretLine = -1

    init {
        Disposer.register(parent, this)

        editor.addEditorMouseMotionListener(object : EditorMouseMotionListener {
            override fun mouseMoved(e: EditorMouseEvent) {
                if (e.area in GUTTER_AREAS) {
                    setHover(lineOf(e))
                } else {
                    setHover(-1)
                }
            }
        }, this)

        editor.addEditorMouseListener(object : EditorMouseListener {
            override fun mouseExited(e: EditorMouseEvent) = setHover(-1)
        }, this)

        editor.caretModel.addCaretListener(object : CaretListener {
            override fun caretPositionChanged(e: CaretEvent) = setCaret(e.newPosition.line + 1)
        }, this)

        setCaret(editor.caretModel.logicalPosition.line + 1)
    }

    /** Re-evaluate both markers (e.g. after notes changed). */
    fun refresh() {
        val h = hoverLine
        val c = caretLine
        hoverLine = -1
        caretLine = -1
        setCaret(c)
        setHover(h)
    }

    private fun lineOf(e: EditorMouseEvent): Int {
        val line0 = e.logicalPosition.line
        if (line0 < 0 || line0 >= editor.document.lineCount) return -1
        return line0 + 1
    }

    private fun hasNote(line1: Int): Boolean =
        NotesService.getInstance(project).hasNoteOnLine(rel, line1)

    private fun setHover(line1: Int) {
        if (line1 == hoverLine) return
        hoverLine = line1
        disposeHighlighter(hoverHighlighter)
        hoverHighlighter = null
        // Don't duplicate the caret "+" or clutter a line that has a note.
        if (isPlusCandidate(line1) && line1 != caretLine) {
            hoverHighlighter = addPlus(line1)
        }
    }

    private fun setCaret(line1: Int) {
        if (line1 == caretLine) return
        // If the hover "+" was on this line, drop it; the caret "+" takes over.
        if (hoverLine == line1) {
            disposeHighlighter(hoverHighlighter)
            hoverHighlighter = null
            hoverLine = -1
        }
        caretLine = line1
        disposeHighlighter(caretHighlighter)
        caretHighlighter = null
        if (isPlusCandidate(line1)) {
            caretHighlighter = addPlus(line1)
        }
    }

    private fun isPlusCandidate(line1: Int): Boolean =
        line1 in 1..editor.document.lineCount

    private fun addPlus(line1: Int): RangeHighlighter {
        val doc = editor.document
        val offset = doc.getLineStartOffset((line1 - 1).coerceIn(0, (doc.lineCount - 1).coerceAtLeast(0)))
        val hl = editor.markupModel.addRangeHighlighter(
            offset,
            offset,
            HighlighterLayer.LAST,
            null,
            HighlighterTargetArea.LINES_IN_RANGE,
        )
        hl.gutterIconRenderer = AddPlusGutterIconRenderer(project, editor, line1)
        return hl
    }

    private fun disposeHighlighter(hl: RangeHighlighter?) {
        if (hl != null && hl.isValid) hl.dispose()
    }

    override fun dispose() {
        disposeHighlighter(hoverHighlighter)
        disposeHighlighter(caretHighlighter)
        hoverHighlighter = null
        caretHighlighter = null
    }

    companion object {
        private val GUTTER_AREAS = setOf(
            EditorMouseEventArea.LINE_MARKERS_AREA,
            EditorMouseEventArea.LINE_NUMBERS_AREA,
            EditorMouseEventArea.FOLDING_OUTLINE_AREA,
        )
    }
}
