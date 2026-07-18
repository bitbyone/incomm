package dev.incomm.ui

import com.intellij.openapi.ui.popup.IconButton
import com.intellij.ui.InplaceButton
import com.intellij.ui.JBColor
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBTextArea
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import dev.incomm.model.AUTHOR_AGENT
import dev.incomm.model.AUTHOR_USER
import java.awt.Color
import java.awt.Cursor
import java.awt.Graphics
import java.awt.Graphics2D
import java.awt.RenderingHints
import java.awt.event.ActionListener
import javax.swing.BoxLayout
import javax.swing.Icon
import javax.swing.JPanel

/**
 * Shared visual language for the incomm comment UIs so the thread bubbles
 * (gutter popup + explorer) and the add/reply composer look identical: rounded,
 * colour-coded cards with flat, borderless text areas and small icon buttons.
 */
object ThreadUi {

    val USER_BG = JBColor(0xEAF1FB, 0x2C3038)
    val AGENT_BG = JBColor(0xEAF5EC, 0x28322C)
    val USER_BG_HOVER = JBColor(0xF3F7FE, 0x363C47)
    val AGENT_BG_HOVER = JBColor(0xF2FAF3, 0x303B34)
    val USER_ACCENT = JBColor(0x2A6EBB, 0x77A6E0)
    val AGENT_ACCENT = JBColor(0x3B7D3B, 0x6FB86F)

    fun bgFor(author: String): JBColor = if (author == AUTHOR_AGENT) AGENT_BG else USER_BG
    fun bgHoverFor(author: String): JBColor = if (author == AUTHOR_AGENT) AGENT_BG_HOVER else USER_BG_HOVER

    /** A rounded, author-coloured card laid out top-to-bottom. */
    fun roundedCard(author: String): JPanel {
        val bg = if (author == AUTHOR_AGENT) AGENT_BG else USER_BG
        return RoundedPanel(bg).apply {
            layout = BoxLayout(this, BoxLayout.Y_AXIS)
            border = JBUI.Borders.empty(8, 12, 10, 8)
        }
    }

    /**
     * A flat, borderless text area matching the in-place editors used inside
     * thread bubbles — no framed box, label font, transparent background.
     */
    fun flatEditor(
        text: String,
        placeholder: String = "",
        rows: Int = 2,
        editable: Boolean = true,
    ): JBTextArea {
        val area = JBTextArea(text).apply {
            lineWrap = true
            wrapStyleWord = true
            this.rows = rows
            isEditable = editable
            isOpaque = false
            border = if (editable) JBUI.Borders.empty(4) else JBUI.Borders.emptyTop(4)
            font = UIUtil.getLabelFont()
            emptyText.text = placeholder
        }
        area.caretPosition = area.text.length
        return area
    }

    /** Coloured author name plus a muted subtitle (timestamp / location). */
    fun authorLabel(author: String, subtitle: String): JBLabel =
        JBLabel(
            "<html><b><font color='${hex(accent(author))}'>${escape(label(author))}</font></b>" +
                "&nbsp;&nbsp;<font color='#8A8A8A'>${escape(subtitle)}</font></html>"
        )

    fun iconButton(icon: Icon, tooltip: String, onClick: () -> Unit): InplaceButton {
        val button = InplaceButton(IconButton(tooltip, icon, icon), ActionListener { onClick() })
        button.cursor = Cursor.getPredefinedCursor(Cursor.HAND_CURSOR)
        return button
    }

    fun accent(author: String): JBColor = if (author == AUTHOR_AGENT) AGENT_ACCENT else USER_ACCENT

    fun label(author: String) = when (author) {
        AUTHOR_AGENT -> "agent"
        AUTHOR_USER -> "you"
        else -> author
    }

    fun prettyTime(s: String) = s.replace('T', ' ').removeSuffix("Z")
    fun hex(c: Color) = "#%02x%02x%02x".format(c.red, c.green, c.blue)
    fun escape(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    class RoundedPanel(private val fill: Color) : JPanel() {
        init {
            isOpaque = false
            alignmentX = LEFT_ALIGNMENT
        }

        override fun paintComponent(g: Graphics) {
            val g2 = g.create() as Graphics2D
            try {
                g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON)
                g2.color = fill
                g2.fillRoundRect(0, 0, width - 1, height - 1, JBUI.scale(12), JBUI.scale(12))
            } finally {
                g2.dispose()
            }
            super.paintComponent(g)
        }
    }
}
