package one.bitby.incomm.ui

import com.intellij.openapi.ui.popup.IconButton
import com.intellij.ui.InplaceButton
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBTextArea
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import one.bitby.incomm.model.AUTHOR_AGENT
import one.bitby.incomm.model.AUTHOR_USER
import one.bitby.incomm.settings.IncommSettings
import java.awt.Color
import java.awt.Cursor
import java.awt.Graphics
import java.awt.Graphics2D
import java.awt.RenderingHints
import java.awt.event.ActionListener
import javax.swing.BoxLayout
import javax.swing.Icon
import javax.swing.JPanel

import com.intellij.util.ui.HTMLEditorKitBuilder
import javax.swing.JEditorPane

/**
 * Shared visual language for the incomm comment UIs so the thread bubbles
 * (gutter popup + explorer) and the add/reply composer look identical: rounded,
 * colour-coded cards with flat, borderless text areas and small icon buttons.
 */
object ThreadUi {

    fun markdownDisplay(text: String): JEditorPane {
        val html = MarkdownRenderer.render(text.trim())
        val pane = object : JEditorPane("text/html", "<html><body>$html</body></html>") {
            override fun getPreferredSize(): java.awt.Dimension {
                var w = width
                if (w <= 0 && parent != null && parent.width > 0) {
                    w = parent.width
                }
                if (w > 0) {
                    val view = (ui as? javax.swing.plaf.basic.BasicTextUI)?.getRootView(this)
                    if (view != null) {
                        view.setSize((w - insets.left - insets.right).toFloat(), Float.MAX_VALUE)
                        return java.awt.Dimension(w, view.getPreferredSpan(javax.swing.text.View.Y_AXIS).toInt() + insets.top + insets.bottom)
                    }
                }
                return super.getPreferredSize()
            }
        }
        pane.isEditable = false
        pane.isOpaque = false
        pane.caret.isSelectionVisible = true
        pane.border = JBUI.Borders.emptyTop(4)
        pane.putClientProperty(JEditorPane.HONOR_DISPLAY_PROPERTIES, true)
        pane.font = UIUtil.getLabelFont()
        pane.foreground = IncommColors.commentFg
        pane.editorKit = HTMLEditorKitBuilder().withWordWrapViewFactory().build().apply {
            styleSheet.addRule("body { font-family: ${pane.font.family}; font-size: ${pane.font.size}pt; color: ${hex(IncommColors.commentFg)}; margin: 0; padding: 0; }")
            styleSheet.addRule("p { margin-top: 0; margin-bottom: 6px; }")
            styleSheet.addRule("pre, code { font-family: monospace; }")
        }
        
        UIUtil.doNotScrollToCaret(pane)
        pane.text = "<html><body>$html</body></html>"
        pane.caretPosition = 0
        return pane
    }

    /** Kept for the composer input backgrounds; sourced from the active theme. */
    val USER_BG: Color get() = IncommColors.bubbleBg(AUTHOR_USER)

    fun bgFor(author: String): Color = IncommColors.bubbleBg(author)
    fun bgHoverFor(author: String): Color = IncommColors.bubbleBgHover(author)

    /** A rounded, author-coloured card laid out top-to-bottom. */
    fun roundedCard(author: String): JPanel {
        return RoundedPanel(IncommColors.bubbleBg(author)).apply {
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
            foreground = IncommColors.commentFg
            emptyText.text = placeholder
        }
        area.caretPosition = area.text.length
        return area
    }

    /** Coloured author name plus a muted subtitle (timestamp / location). */
    fun authorLabel(author: String, subtitle: String, authorTitle: String? = null): JBLabel =
        JBLabel(
            "<html><b><font color='${hex(accent(author))}'>${escape(label(author, authorTitle))}</font></b>" +
                "&nbsp;&nbsp;<font color='${hex(IncommColors.muted)}'>${escape(subtitle)}</font></html>"
        )

    fun iconButton(icon: Icon, tooltip: String, onClick: () -> Unit): InplaceButton {
        val button = InplaceButton(IconButton(tooltip, icon, icon), ActionListener { onClick() })
        button.cursor = Cursor.getPredefinedCursor(Cursor.HAND_CURSOR)
        return button
    }

    fun accent(author: String): Color = IncommColors.bubbleAccent(author)

    /**
     * Display name for an author.
     * - User: [authorTitle] if present (e.g. "Jan Tobola"), else "you"
     * - Agent: "Agent" if no title, "Agent (Opus 4.6)" if title present
     */
    fun label(author: String, authorTitle: String? = null) = when (author) {
        AUTHOR_USER -> if (!authorTitle.isNullOrBlank()) authorTitle else "you"
        AUTHOR_AGENT -> if (!authorTitle.isNullOrBlank()) "Agent ($authorTitle)" else "Agent"
        else -> author
    }

    fun prettyTime(s: String) = IncommSettings.getInstance().formatTimestamp(s)
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
