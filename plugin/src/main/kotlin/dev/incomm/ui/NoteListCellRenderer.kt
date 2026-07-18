package dev.incomm.ui

import com.intellij.ui.SimpleColoredComponent
import com.intellij.ui.SimpleTextAttributes
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import dev.incomm.model.Note
import java.awt.BorderLayout
import java.awt.Component
import javax.swing.BoxLayout
import javax.swing.JList
import javax.swing.JPanel
import javax.swing.ListCellRenderer

/**
 * Two-line list row: the comment text on top, and the reply count + file:line
 * location underneath.
 */
class NoteListCellRenderer : ListCellRenderer<Note> {

    private val top = SimpleColoredComponent().apply { isOpaque = false }
    private val bottom = SimpleColoredComponent().apply { isOpaque = false }
    private val panel = JPanel(BorderLayout())

    init {
        val box = JPanel().apply {
            layout = BoxLayout(this, BoxLayout.Y_AXIS)
            isOpaque = false
            border = JBUI.Borders.empty(4, 6)
            add(top)
            add(bottom)
        }
        panel.add(box, BorderLayout.CENTER)
    }

    override fun getListCellRendererComponent(
        list: JList<out Note>,
        note: Note,
        index: Int,
        selected: Boolean,
        focused: Boolean,
    ): Component {
        top.clear()
        bottom.clear()

        panel.isOpaque = true
        panel.background = if (selected) UIUtil.getListSelectionBackground(focused) else UIUtil.getListBackground()

        val mainAttr = if (selected) {
            SimpleTextAttributes(SimpleTextAttributes.STYLE_PLAIN, UIUtil.getListSelectionForeground(focused))
        } else {
            SimpleTextAttributes.REGULAR_ATTRIBUTES
        }
        val subAttr = if (selected) {
            SimpleTextAttributes(SimpleTextAttributes.STYLE_PLAIN, UIUtil.getListSelectionForeground(focused))
        } else {
            SimpleTextAttributes.GRAYED_ATTRIBUTES
        }

        top.icon = NoteGutterIconRenderer.iconFor(note)
        top.append(oneLine(note.content), mainAttr)
        when {
            note.orphaned -> top.append("  unanchored", if (selected) subAttr else SimpleTextAttributes.ERROR_ATTRIBUTES)
            note.resolved -> top.append("  \u2713 resolved", subAttr)
        }

        val replies = when (val n = note.replies.size) {
            0 -> ""
            1 -> "1 reply   "
            else -> "$n replies   "
        }
        bottom.append("$replies${note.location()}", subAttr)

        return panel
    }

    private fun oneLine(text: String): String {
        val flat = text.replace("\n", " ").trim()
        return if (flat.length > 80) flat.take(77) + "\u2026" else flat
    }
}
