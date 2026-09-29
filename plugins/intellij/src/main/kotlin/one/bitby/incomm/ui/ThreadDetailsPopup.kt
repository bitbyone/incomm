package one.bitby.incomm.ui

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.popup.JBPopup
import com.intellij.openapi.ui.popup.JBPopupFactory
import com.intellij.ui.SimpleColoredComponent
import com.intellij.ui.SimpleTextAttributes
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBList
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import one.bitby.incomm.model.AUDIENCE_PRIVATE
import one.bitby.incomm.model.Audience
import one.bitby.incomm.model.AudienceRow
import one.bitby.incomm.editor.IncommEditorTracker
import one.bitby.incomm.store.IncommNotesListener
import one.bitby.incomm.store.NotesService
import java.awt.BorderLayout
import java.awt.Color
import java.awt.Component
import java.awt.Dimension
import java.awt.event.KeyAdapter
import java.awt.event.KeyEvent
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import javax.swing.DefaultListModel
import javax.swing.JList
import javax.swing.JPanel
import javax.swing.ListCellRenderer
import javax.swing.ListSelectionModel
import javax.swing.SwingConstants

/**
 * "Incomm: Thread Details" - a small popup listing every comment of one thread:
 * its text on the left, its audience on the right between two arrows, and three
 * things to do to the selected one without the mouse. ↑/↓ or j/k pick a comment;
 * ←/→ or h/l step its audience back and forth through agent → agent + external →
 * external → private, saved at once; `e` edits it in place (in the card, or in the
 * explorer's pane); `d` deletes it (the original takes the thread). Esc (or Enter)
 * closes it. Clicking an arrow steps the audience too.
 *
 * What is on the merge request (a comment with a `source`) only flips between
 * agent + external and external, and is neither edited nor deleted here.
 *
 * The Neovim plugin's `:Incomm list` is the same dialog.
 */
object ThreadDetailsPopup {

    private const val LEFT_ARROW = "◀"
    private const val RIGHT_ARROW = "▶"

    /** The popup on screen, if any (tests). */
    @Volatile
    var current: Handle? = null
        private set

    /** What a test needs to drive the popup without a keyboard. */
    class Handle internal constructor(
        val popup: JBPopup,
        val list: JBList<AudienceRow>,
        internal val step: (Boolean) -> Unit,
        internal val edit: () -> Unit,
        internal val delete: () -> Unit,
        /** What the hint line says: the key list, or why the last key did nothing. */
        val hint: JBLabel,
    ) {
        fun rows(): List<AudienceRow> = (0 until list.model.size).map { list.model.getElementAt(it) }
        fun select(index: Int) { list.selectedIndex = index }
        fun next() = step(true)
        fun previous() = step(false)
        fun edit() = edit.invoke()
        fun delete() = delete.invoke()
    }

    /**
     * Show it for [noteId]. `e` hands the comment to [onEdit] (the original when its
     * argument is null); without one it is edited in [editor]'s card, and without
     * either `e` is not offered.
     */
    fun show(
        project: Project,
        noteId: String,
        editor: Editor? = null,
        onEdit: ((replyId: String?) -> Unit)? = null,
    ): Handle? {
        val service = NotesService.getInstance(project)
        if (service.isBlocked()) return null
        val note = service.find(noteId) ?: return null

        val model = DefaultListModel<AudienceRow>()
        val list = JBList(model).apply {
            selectionMode = ListSelectionModel.SINGLE_SELECTION
            cellRenderer = Renderer()
            // Fixed, so a long comment is clipped instead of stretching the popup.
            fixedCellWidth = JBUI.scale(600)
            border = JBUI.Borders.empty(4, 0)
        }

        lateinit var popup: JBPopup

        fun reload() {
            val fresh = service.find(noteId)
            if (fresh == null) {
                popup.cancel()
                return
            }
            val keep = list.selectedIndex.coerceAtLeast(0)
            val rows = Audience.rows(fresh)
            model.clear()
            rows.forEach { model.addElement(it) }
            list.selectedIndex = keep.coerceAtMost(rows.size - 1)
            list.visibleRowCount = rows.size.coerceAtMost(12)
        }

        fun step(forward: Boolean) {
            val row = list.selectedValue ?: return
            // Only through what this comment may be: a published one flips between
            // agent + external and external.
            val target = if (forward) Audience.next(row.audience, row.cycle) else Audience.previous(row.audience, row.cycle)
            service.setAudience(noteId, row.replyId, target)
            reload()
        }

        val editHandler: ((String?) -> Unit)? = onEdit ?: editor?.let { ed ->
            { replyId -> IncommEditorTracker.getInstance(project).startInlineEdit(ed, noteId, replyId) }
        }
        val keys = "↑↓ j/k comment &nbsp;·&nbsp; ←→ h/l audience" +
            (if (editHandler != null) " &nbsp;·&nbsp; e edit" else "") +
            " &nbsp;·&nbsp; d delete &nbsp;·&nbsp; Esc close"
        val hint = JBLabel().apply { border = JBUI.Borders.empty(3, 8) }
        fun showKeys() {
            hint.text = "<html><small>$keys</small></html>"
            hint.foreground = IncommColors.muted
        }
        // Why a key did nothing, in place of the key list until the next key.
        fun refuse(why: String) {
            hint.text = "<html><small>${ThreadUi.escape(why)}</small></html>"
            hint.foreground = IncommColors.notPublishedBadge
        }
        showKeys()

        fun edit() {
            val row = list.selectedValue ?: return
            val handler = editHandler ?: return
            if (!row.editable) {
                refuse(
                    if (row.author != one.bitby.incomm.model.AUTHOR_USER) "Only your own comments are editable"
                    else "It is on the merge request: edit it there",
                )
                return
            }
            popup.closeOk(null)
            // After the popup has gone, so the editor gets the focus back first.
            ApplicationManager.getApplication().invokeLater { handler(row.replyId) }
        }

        fun delete() {
            val row = list.selectedValue ?: return
            if (!row.deletable) {
                refuse(
                    if (row.published) "It is on the merge request: delete it there"
                    else "A reply of it is on the merge request",
                )
                return
            }
            if (row.replyId != null) service.removeReply(noteId, row.replyId)
            else service.removeNote(noteId) // the original takes the thread, and reload() closes the popup
            reload()
        }

        list.addKeyListener(object : KeyAdapter() {
            override fun keyPressed(e: KeyEvent) {
                if (e.isControlDown || e.isMetaDown || e.isAltDown) return
                showKeys()
                when (e.keyCode) {
                    KeyEvent.VK_J -> move(list, 1)
                    KeyEvent.VK_K -> move(list, -1)
                    KeyEvent.VK_L, KeyEvent.VK_RIGHT, KeyEvent.VK_SPACE -> step(true)
                    KeyEvent.VK_H, KeyEvent.VK_LEFT -> step(false)
                    KeyEvent.VK_E -> if (editHandler != null) edit() else return
                    KeyEvent.VK_D, KeyEvent.VK_DELETE -> delete()
                    KeyEvent.VK_ENTER -> popup.closeOk(null)
                    else -> return
                }
                e.consume()
            }

            // JList's type-ahead would otherwise jump to a row starting with the letter.
            override fun keyTyped(e: KeyEvent) {
                if (e.keyChar in "hjkled ") e.consume()
            }
        })
        // A click on the audience column steps it: the left arrow's half back, the rest on.
        list.addMouseListener(object : MouseAdapter() {
            override fun mouseClicked(e: MouseEvent) {
                val index = list.locationToIndex(e.point)
                val bounds = list.getCellBounds(index, index) ?: return
                if (!bounds.contains(e.point)) return
                val column = Renderer.audienceWidth(list)
                val columnStart = bounds.x + bounds.width - JBUI.scale(8) - column
                if (e.x < columnStart) return
                list.selectedIndex = index
                step(forward = e.x >= columnStart + column / 2)
            }
        })

        val root = JPanel(BorderLayout()).apply {
            add(list, BorderLayout.CENTER)
            add(hint, BorderLayout.SOUTH)
        }

        val location = if (note.startLine != note.endLine) "L${note.startLine}-${note.endLine}" else "L${note.startLine}"
        popup = JBPopupFactory.getInstance()
            .createComponentPopupBuilder(root, list)
            .setTitle("Thread Details · ${note.file.substringAfterLast('/')}:$location")
            .setRequestFocus(true)
            .setFocusable(true)
            .setMovable(true)
            .setCancelOnClickOutside(true)
            .setCancelKeyEnabled(true)
            .createPopup()

        reload()
        list.selectedIndex = 0

        // The agent answering while it is open adds a row; a deleted thread closes it.
        project.messageBus.connect(popup).subscribe(
            IncommNotesListener.TOPIC,
            IncommNotesListener {
                ApplicationManager.getApplication().invokeLater {
                    if (!popup.isDisposed) reload()
                }
            },
        )

        val handle = Handle(popup, list, ::step, ::edit, ::delete, hint)
        current = handle
        popup.addListener(object : com.intellij.openapi.ui.popup.JBPopupListener {
            override fun onClosed(event: com.intellij.openapi.ui.popup.LightweightWindowEvent) {
                if (current === handle) current = null
            }
        })

        if (editor != null && editor.component.isShowing) popup.showInBestPositionFor(editor)
        else popup.showCenteredInCurrentWindow(project)
        return handle
    }

    private fun move(list: JList<AudienceRow>, delta: Int) {
        val size = list.model.size
        if (size == 0) return
        list.selectedIndex = (list.selectedIndex + delta).coerceIn(0, size - 1)
        list.ensureIndexIsVisible(list.selectedIndex)
    }

    /** One row: author and a one-line preview on the left, `◀ audience ▶` on the right. */
    private class Renderer : ListCellRenderer<AudienceRow> {
        private val text = SimpleColoredComponent().apply { isOpaque = false }
        private val left = JBLabel(LEFT_ARROW)
        private val label = JBLabel().apply { horizontalAlignment = SwingConstants.CENTER }
        private val right = JBLabel(RIGHT_ARROW)
        private val audience = JPanel(BorderLayout()).apply {
            isOpaque = false
            add(left, BorderLayout.WEST)
            add(label, BorderLayout.CENTER)
            add(right, BorderLayout.EAST)
        }
        private val panel = JPanel(BorderLayout(JBUI.scale(16), 0)).apply {
            border = JBUI.Borders.empty(3, 8)
            add(text, BorderLayout.CENTER)
            add(audience, BorderLayout.EAST)
        }

        override fun getListCellRendererComponent(
            list: JList<out AudienceRow>,
            row: AudienceRow,
            index: Int,
            isSelected: Boolean,
            cellHasFocus: Boolean,
        ): Component {
            panel.background = if (isSelected) UIUtil.getListSelectionBackground(list.hasFocus()) else list.background
            text.clear()
            if (row.replyId != null) text.ipad = JBUI.insetsLeft(16) else text.ipad = JBUI.insetsLeft(0)
            text.append(
                ThreadUi.label(row.author, row.authorTitle),
                SimpleTextAttributes(SimpleTextAttributes.STYLE_BOLD, ThreadUi.accent(row.author)),
            )
            // What is on the merge request says so: it cannot be edited or deleted here.
            if (row.published) {
                text.append("  \u00B7 on the MR", SimpleTextAttributes(SimpleTextAttributes.STYLE_PLAIN, IncommColors.publishedBadge))
            }
            text.append("   " + preview(row.content), SimpleTextAttributes(SimpleTextAttributes.STYLE_PLAIN, IncommColors.muted))

            label.text = Audience.label(row.audience)
            label.foreground = colorOf(row)
            left.foreground = IncommColors.muted
            right.foreground = IncommColors.muted
            audience.preferredSize = Dimension(audienceWidth(list), audience.preferredSize.height)
            return panel
        }

        private fun colorOf(row: AudienceRow): Color = when {
            row.inherited -> IncommColors.muted
            row.audience == AUDIENCE_PRIVATE -> IncommColors.audienceBadge(AUDIENCE_PRIVATE)
            Audience.includesExternal(row.audience) ->
                if (row.published) IncommColors.publishedBadge else IncommColors.notPublishedBadge
            else -> UIUtil.getLabelForeground()
        }

        companion object {
            /** The audience column fits the widest label, so the arrows never move. */
            fun audienceWidth(list: JList<*>): Int {
                val metrics = list.getFontMetrics(list.font)
                val widest = Audience.CYCLE.maxOf { metrics.stringWidth(Audience.label(it)) }
                return widest + metrics.stringWidth("$LEFT_ARROW$RIGHT_ARROW") + JBUI.scale(24)
            }

            fun preview(content: String): String {
                val flat = content.trim().replace(Regex("\\s+"), " ")
                return if (flat.length > 80) flat.take(79) + "…" else flat
            }
        }
    }
}
