package one.bitby.incomm.ui

import com.intellij.icons.AllIcons
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonShortcuts
import com.intellij.openapi.actionSystem.CustomShortcutSet
import com.intellij.openapi.fileTypes.FileTypes
import com.intellij.openapi.project.DumbAwareAction
import com.intellij.openapi.project.Project
import com.intellij.openapi.wm.IdeFocusManager
import com.intellij.ui.EditorTextField
import com.intellij.util.ui.JBUI
import one.bitby.incomm.model.AUTHOR_USER
import one.bitby.incomm.model.AUTHOR_AGENT
import one.bitby.incomm.model.Note
import one.bitby.incomm.settings.IncommSettings
import one.bitby.incomm.store.NotesService
import java.awt.BorderLayout
import java.awt.Component
import java.awt.Container
import java.awt.FlowLayout
import java.awt.Graphics
import java.awt.Graphics2D
import java.awt.GridBagConstraints
import java.awt.GridBagLayout
import java.awt.RenderingHints
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import java.awt.event.MouseListener
import javax.swing.BoxLayout
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.SwingUtilities

/**
 * The interactive inline card for a single note, embedded directly in the editor
 * (replaces the old thread dialog). Shows every message as a colour-coded bubble;
 * whole-thread actions (resolve/reopen, reply, delete) sit top-right, and each
 * message reveals edit/delete icons on hover together with a lighter background.
 * Editing happens in place through a real embedded editor.
 */
class NoteCardComponent(
    private val project: Project,
    private val noteId: String,
    private val onReply: () -> Unit,
    private val onResolve: (Boolean) -> Unit,
    private val onDelete: () -> Unit = {},
    private val onDeleteReply: (String) -> Unit = {},
    private val onEdit: (String, String?) -> Unit = { _, _ -> },
    private val onHover: (Boolean) -> Unit,
    private val withViewportPreserved: ((() -> Unit) -> Unit) = { it() },
    private val onContentResized: () -> Unit = {},
) : JPanel(BorderLayout()) {

    private val titleLabel = com.intellij.ui.components.JBLabel()
    private val toolbar = JPanel(FlowLayout(FlowLayout.RIGHT, 2, 0)).apply { isOpaque = false }
    private val body = JPanel(GridBagLayout()).apply { isOpaque = false }

    /** KEY_ORIGINAL or reply:<id> currently being edited, or null. */
    private var editingKey: String? = null
    private var focusAfterBuild: JComponent? = null

    /** Reports hover over the whole card so the gutter range band can light up. */
    private val cardHoverAdapter = object : MouseAdapter() {
        override fun mouseEntered(e: MouseEvent) = onHover(true)
        override fun mouseExited(e: MouseEvent) {
            if (!pointerStillInside(this@NoteCardComponent, e)) onHover(false)
        }
    }

    init {
        isOpaque = false
        border = JBUI.Borders.empty(1, 8, 5, 10)
        val header = JPanel(BorderLayout()).apply {
            isOpaque = false
            border = JBUI.Borders.emptyBottom(4)
            add(titleLabel, BorderLayout.CENTER)
            add(toolbar, BorderLayout.EAST)
        }
        add(header, BorderLayout.NORTH)
        add(body, BorderLayout.CENTER)
        addRecursively(this, cardHoverAdapter)
        rebuild()
    }

    fun rebuild() {
        val note = NotesService.getInstance(project).find(noteId) ?: return
        withViewportPreserved {
            rebuildFor(note)
            onContentResized()
        }
    }

    /** Start editing the original comment in place (used by the Edit action). */
    fun beginEditOriginal() {
        editingKey = KEY_ORIGINAL
        rebuild()
    }

    /**
     * Refresh only the location header (e.g. `L70` → `L72`) in place, without
     * rebuilding the card — used when live re-anchoring moves the note as the
     * user edits above it, so the header keeps up without disturbing the viewport.
     */
    fun refreshLocation() {
        val note = NotesService.getInstance(project).find(noteId) ?: return
        titleLabel.text = titleHtml(note)
    }

    private fun rebuildFor(note: Note) {
        focusAfterBuild = null

        titleLabel.text = titleHtml(note)
        buildToolbar(note)

        body.removeAll()
        val gap = JBUI.scale(2)
        val indent = JBUI.scale(16)
        val gbc = GridBagConstraints().apply {
            gridx = 0; gridy = 0; weightx = 1.0
            fill = GridBagConstraints.HORIZONTAL
            anchor = GridBagConstraints.NORTHWEST
            insets = JBUI.insetsBottom(gap)
        }
        body.add(bubbleFor(note, KEY_ORIGINAL, note.author, note.authorTitle, note.createdAt, note.content, null), gbc)
        for (reply in note.replies) {
            gbc.gridy++
            // Replies are lightly nested under the original comment.
            gbc.insets = JBUI.insets(0, indent, gap, 0)
            body.add(bubbleFor(note, keyReply(reply.id), reply.author, reply.authorTitle, reply.createdAt, reply.content, reply.id), gbc)
        }

        revalidate()
        repaint()
        SwingUtilities.invokeLater {
            focusAfterBuild?.let { focus(it) }
        }
    }

    private fun titleHtml(note: Note): String {
        val range = if (note.endLine != note.startLine) "${note.startLine}\u2013${note.endLine}" else "${note.startLine}"
        val (stateText, stateColor) = when {
            note.orphaned -> "<b>orphaned</b>" to IncommColors.stateOrphaned
            note.resolved -> "<b>resolved</b>" to IncommColors.stateResolved
            else -> "open" to IncommColors.muted
        }
        return "<html><b>L$range</b>&nbsp;&nbsp;<font color='${ThreadUi.hex(stateColor)}'>$stateText</font></html>"
    }

    private fun buildToolbar(note: Note) {
        toolbar.removeAll()
        if (note.resolved) {
            toolbar.add(ThreadUi.iconButton(AllIcons.Actions.Rollback, "Reopen thread") { onResolve(false) })
        } else {
            toolbar.add(ThreadUi.iconButton(AllIcons.Actions.Commit, "Resolve thread") { onResolve(true) })
        }
        toolbar.add(ThreadUi.iconButton(IncommIcons.REPLY, "Reply") { onReply() })
        toolbar.add(ThreadUi.iconButton(IncommIcons.DELETE_COMMENT, "Delete thread") {
            onDelete()
        })
        toolbar.revalidate()
        toolbar.repaint()
    }

    // ---- bubbles -----------------------------------------------------------

    private fun bubbleFor(
        note: Note,
        key: String,
        author: String,
        authorTitle: String?,
        createdAt: String,
        text: String,
        replyId: String?,
    ): JComponent {
        val editing = editingKey == key
        val bubble = Bubble(author)
        val headerRow = JPanel(BorderLayout()).apply { isOpaque = false }
        headerRow.add(ThreadUi.authorLabel(author, ThreadUi.prettyTime(createdAt), authorTitle), BorderLayout.CENTER)

        val icons = JPanel(FlowLayout(FlowLayout.RIGHT, 2, 0)).apply { isOpaque = false }
        if (editing) {
            val field = editorField(text)
            icons.add(ThreadUi.iconButton(IncommIcons.CHECK, "Save") { saveEdit(key, replyId, field.text) })
            icons.add(ThreadUi.iconButton(IncommIcons.CANCEL, "Cancel") { editingKey = null; rebuild() })
            registerEditShortcuts(field, { saveEdit(key, replyId, field.text) }, { editingKey = null; rebuild() })
            headerRow.add(icons, BorderLayout.EAST)
            bubble.add(headerRow)
            bubble.add(field)
            focusAfterBuild = field
        } else {
            if (author == AUTHOR_USER) {
                icons.add(ThreadUi.iconButton(IncommIcons.EDIT_COMMENT, "Edit") { editingKey = key; rebuild() })
            }
            icons.add(ThreadUi.iconButton(IncommIcons.DELETE_COMMENT, "Delete") { deleteMessage(key, replyId) })
            icons.isVisible = false // revealed on hover
            headerRow.add(icons, BorderLayout.EAST)
            bubble.add(headerRow)
            val settings = IncommSettings.getInstance().data
            val useMarkdown = if (author == AUTHOR_USER) settings.enableUserMarkdown else settings.enableAgentMarkdown
            val display = if (useMarkdown) ThreadUi.markdownDisplay(text) else ThreadUi.flatEditor(text.trim(), rows = 0, editable = false).apply { isFocusable = false }
            bubble.add(display)
            installBubbleHover(bubble, icons)
        }
        addRecursively(bubble, cardHoverAdapter)
        return bubble
    }

    private fun registerEditShortcuts(field: JComponent, save: () -> Unit, cancel: () -> Unit) {
        object : DumbAwareAction() {
            override fun actionPerformed(e: AnActionEvent) = save()
        }.registerCustomShortcutSet(CustomShortcutSet.fromString("control ENTER", "meta ENTER"), field)
        object : DumbAwareAction() {
            override fun actionPerformed(e: AnActionEvent) = cancel()
        }.registerCustomShortcutSet(CommonShortcuts.ESCAPE, field)
    }

    private fun editorField(text: String): EditorTextField {
        // A plain EditorTextField reports a one-line preferred height even in
        // multi-line mode, so it never grows. Size it to its actual line count.
        val field = object : EditorTextField(text, project, FileTypes.PLAIN_TEXT) {
            override fun getPreferredSize(): java.awt.Dimension {
                val base = super.getPreferredSize()
                val ed = getEditor() ?: return base
                val lines = ed.document.lineCount.coerceAtLeast(1)
                val h = ed.lineHeight * lines + insets.top + insets.bottom + JBUI.scale(6)
                return java.awt.Dimension(base.width, maxOf(base.height, h))
            }
        }
        field.setOneLineMode(false)
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
                isVirtualSpace = true
            }
            e.setBorder(JBUI.Borders.empty())
            e.backgroundColor = ThreadUi.USER_BG
        }
        // Let the enclosing block inlay grow as the user adds lines while editing,
        // so the editor isn't clipped to one line.
        field.addDocumentListener(object : com.intellij.openapi.editor.event.DocumentListener {
            override fun documentChanged(event: com.intellij.openapi.editor.event.DocumentEvent) {
                withViewportPreserved {
                    field.revalidate()
                    onContentResized()
                }
            }
        })
        return field
    }

    private fun saveEdit(key: String, replyId: String?, text: String) {
        val trimmed = text.trim()
        if (trimmed.isNotEmpty()) {
            editingKey = null
            onEdit(trimmed, replyId)
        } else {
            editingKey = null
            rebuild()
        }
    }

    private fun deleteMessage(key: String, replyId: String?) {
        if (key == KEY_ORIGINAL) onDelete()
        else if (replyId != null) onDeleteReply(replyId)
    }

    // ---- hover -------------------------------------------------------------

    private fun installBubbleHover(bubble: Bubble, icons: JComponent) {
        val adapter = object : MouseAdapter() {
            override fun mouseEntered(e: MouseEvent) = set(true)
            override fun mouseExited(e: MouseEvent) {
                if (!pointerStillInside(bubble, e)) set(false)
            }
            private fun set(on: Boolean) {
                if (bubble.hovered == on) return
                bubble.hovered = on
                icons.isVisible = on
                bubble.revalidate()
                bubble.repaint()
            }
        }
        addRecursively(bubble, adapter)
    }

    /**
     * Whether the pointer that triggered [e] is still within [target]'s bounds.
     * Converts the event point into [target] coordinates and does an explicit
     * bounds check — reliable on every edge (unlike `getMousePosition`, which
     * was unreliable at the bottom of an embedded inlay, leaving hover stuck on).
     */
    private fun pointerStillInside(target: JComponent, e: MouseEvent): Boolean {
        val p = SwingUtilities.convertPoint(e.component, e.point, target)
        return p.x >= 0 && p.y >= 0 && p.x < target.width && p.y < target.height
    }

    private fun focus(c: JComponent) {
        IdeFocusManager.getInstance(project).requestFocus(c, true)
    }

    // ---- bubble panel ------------------------------------------------------

    private inner class Bubble(private val author: String) : JPanel() {
        var hovered = false

        init {
            isOpaque = false
            layout = BoxLayout(this, BoxLayout.Y_AXIS)
            border = JBUI.Borders.empty(5, 12, 6, 8)
            alignmentX = LEFT_ALIGNMENT
        }

        override fun getPreferredSize(): java.awt.Dimension {
            val parentWidth = parent?.width ?: 0
            if (parentWidth > 0 && width <= 0) {
                // We are inside GridBagLayout, which measures before setting bounds.
                // We can compute our future width based on our GridBagConstraints!
                val layout = parent.layout as? GridBagLayout
                val gbc = layout?.getConstraints(this)
                val indent = (gbc?.insets?.left ?: 0) + (gbc?.insets?.right ?: 0)
                val targetWidth = parentWidth - indent
                
                // Temporarily set our bounds to targetWidth so children can read it!
                val oldSize = size
                setSize(targetWidth, 10000)
                doLayout() // Lay out children (this assigns width to markdownDisplay / flatEditor)
                val pref = super.getPreferredSize()
                size = oldSize
                return java.awt.Dimension(targetWidth, pref.height)
            }
            return super.getPreferredSize()
        }

        override fun paintComponent(g: Graphics) {
            val g2 = g.create() as Graphics2D
            try {
                g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON)
                g2.color = if (hovered) ThreadUi.bgHoverFor(author) else ThreadUi.bgFor(author)
                g2.fillRoundRect(0, 0, width - 1, height - 1, JBUI.scale(12), JBUI.scale(12))
            } finally {
                g2.dispose()
            }
            super.paintComponent(g)
        }
    }

    private companion object {
        private const val KEY_ORIGINAL = "orig"
        private fun keyReply(id: String) = "reply:$id"

        private fun addRecursively(c: Component, l: MouseListener) {
            c.addMouseListener(l)
            if (c is Container) for (child in c.components) addRecursively(child, l)
        }
    }
}
