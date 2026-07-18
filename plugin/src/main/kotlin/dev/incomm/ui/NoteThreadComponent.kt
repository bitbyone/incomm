package dev.incomm.ui

import com.intellij.icons.AllIcons
import com.intellij.openapi.editor.EditorFactory
import com.intellij.openapi.editor.colors.EditorColors
import com.intellij.openapi.editor.ex.EditorEx
import com.intellij.openapi.editor.markup.HighlighterLayer
import com.intellij.openapi.editor.markup.TextAttributes
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.TextRange
import com.intellij.ui.EditorTextField
import com.intellij.ui.InplaceButton
import com.intellij.ui.JBColor
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.components.JBTextArea
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import dev.incomm.model.AUTHOR_USER
import dev.incomm.model.Note
import dev.incomm.store.IncommPaths
import dev.incomm.store.NotesService
import java.awt.BorderLayout
import java.awt.FlowLayout
import java.awt.GridBagConstraints
import java.awt.GridBagLayout
import javax.swing.Icon
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.ScrollPaneConstants
import javax.swing.SwingUtilities

/**
 * Interactive, chat-like thread for a single note: the original comment and each
 * reply as a rounded, colour-coded bubble. Each user-authored message has hover
 * edit/delete icons (in-place editing with check/cancel); global actions (go to,
 * resolve/reopen, reply, delete) sit as icons in the top-right. Used by both the
 * gutter-icon popup and the explorer's right pane so they look identical.
 */
class NoteThreadComponent(
    private val project: Project,
    private val noteId: String,
    private val onChanged: () -> Unit,
    private val onNoteDeleted: () -> Unit,
) : JPanel(BorderLayout()) {

    private val headerLabel = JBLabel()
    private val toolbar = JPanel(FlowLayout(FlowLayout.RIGHT, 2, 0)).apply { isOpaque = false }
    private val previewHost = JPanel(BorderLayout()).apply { isOpaque = false }
    private val threadHost = JPanel(GridBagLayout()).apply {
        isOpaque = false
        border = JBUI.Borders.empty(10, 12)
    }
    private val scroll = JBScrollPane(
        threadHost,
        ScrollPaneConstants.VERTICAL_SCROLLBAR_AS_NEEDED,
        ScrollPaneConstants.HORIZONTAL_SCROLLBAR_NEVER,
    ).apply { border = JBUI.Borders.empty() }

    private var editingKey: String? = null
    private var addingReply = false
    private var focusAfterBuild: JComponent? = null

    init {
        isOpaque = true
        background = UIUtil.getPanelBackground()
        val header = JPanel(BorderLayout()).apply {
            border = JBUI.Borders.empty(6, 10, 6, 6)
            add(headerLabel, BorderLayout.CENTER)
            add(toolbar, BorderLayout.EAST)
        }
        val top = JPanel(BorderLayout()).apply {
            isOpaque = false
            add(header, BorderLayout.NORTH)
            add(previewHost, BorderLayout.SOUTH)
        }
        add(top, BorderLayout.NORTH)
        add(scroll, BorderLayout.CENTER)
        rebuild()
    }

    fun rebuild() {
        val note = NotesService.getInstance(project).find(noteId)
        if (note == null) {
            onNoteDeleted()
            return
        }
        focusAfterBuild = null

        val state = when {
            note.orphaned -> "unanchored"
            note.resolved -> "resolved"
            else -> "open"
        }
        headerLabel.text = "<html><b>${escape(note.location())}</b> &nbsp; <i>$state</i></html>"
        buildToolbar(note)

        previewHost.removeAll()
        codePreview(note)?.let { previewHost.add(it, BorderLayout.CENTER) }
        previewHost.revalidate()
        previewHost.repaint()

        threadHost.removeAll()
        val gbc = GridBagConstraints().apply {
            gridx = 0; gridy = 0; weightx = 1.0
            fill = GridBagConstraints.HORIZONTAL
            anchor = GridBagConstraints.NORTHWEST
            insets = JBUI.insetsBottom(8)
        }

        threadHost.add(bubbleFor(note, KEY_ORIGINAL, note.author, note.createdAt, note.content, null, 0), gbc)
        gbc.gridy++
        for (reply in note.replies) {
            threadHost.add(bubbleFor(note, keyReply(reply.id), reply.author, reply.createdAt, reply.content, reply.id, JBUI.scale(18)), gbc)
            gbc.gridy++
        }
        if (addingReply) {
            threadHost.add(newReplyBubble(note), gbc)
            gbc.gridy++
        }

        gbc.weighty = 1.0
        gbc.fill = GridBagConstraints.BOTH
        threadHost.add(JPanel().apply { isOpaque = false }, gbc)

        threadHost.revalidate()
        threadHost.repaint()
        SwingUtilities.invokeLater {
            focusAfterBuild?.requestFocusInWindow()
            if (addingReply || editingKey != null) scroll.verticalScrollBar.value = scroll.verticalScrollBar.maximum
        }
    }

    /**
     * A read-only, syntax-highlighted preview of the note's lines. For a
     * single-line comment it shows the line plus one above and one below (3
     * lines). For a multi-line range it shows the range itself, capped at
     * [MAX_RANGE_LINES] lines. The comment's own line(s) are highlighted.
     * Returns null if the file/document can't be resolved.
     */
    private fun codePreview(note: Note): JComponent? {
        val vf = IncommPaths.findVirtualFile(project, note.file) ?: return null
        val doc = FileDocumentManager.getInstance().getDocument(vf) ?: return null
        val lineCount = doc.lineCount
        if (lineCount == 0) return null

        val start0 = (note.startLine - 1).coerceIn(0, lineCount - 1)
        val end0 = (note.endLine - 1).coerceIn(start0, lineCount - 1)

        val from: Int
        val to: Int
        val hlFrom: Int
        val hlTo: Int
        if (end0 == start0) {
            // Single line: show one line above and one below, highlight the line.
            from = (start0 - 1).coerceAtLeast(0)
            to = (start0 + 1).coerceAtMost(lineCount - 1)
            hlFrom = start0
            hlTo = start0
        } else {
            // Multi-line: show the range itself (no extra context), capped at 7.
            from = start0
            to = (start0 + MAX_RANGE_LINES - 1).coerceAtMost(end0)
            hlFrom = from
            hlTo = to
        }

        val text = doc.getText(TextRange(doc.getLineStartOffset(from), doc.getLineEndOffset(to)))
        val snippet = EditorFactory.getInstance().createDocument(text)
        val field = EditorTextField(snippet, project, vf.fileType, /* viewer = */ true, /* oneLineMode = */ false)
        field.setFontInheritedFromLAF(false)
        field.addSettingsProvider { editor ->
            editor.setVerticalScrollbarVisible(false)
            editor.setHorizontalScrollbarVisible(false)
            editor.setBorder(JBUI.Borders.empty())
            editor.settings.apply {
                isLineNumbersShown = false
                isLineMarkerAreaShown = false
                isFoldingOutlineShown = false
                isRightMarginShown = false
                isCaretRowShown = false
                additionalLinesCount = 0
                additionalColumnsCount = 0
                isUseSoftWraps = false
            }
            for (line in (hlFrom - from)..(hlTo - from)) highlightSnippetLine(editor, line)
        }

        return JPanel(BorderLayout()).apply {
            isOpaque = false
            border = JBUI.Borders.empty(0, 10, 6, 10)
            add(field, BorderLayout.CENTER)
        }
    }

    private fun highlightSnippetLine(editor: EditorEx, line: Int) {
        if (line < 0 || line >= editor.document.lineCount) return
        val bg = editor.colorsScheme.getColor(EditorColors.CARET_ROW_COLOR)
            ?: JBColor(0xEDF3FE, 0x2E3A47)
        val attrs = TextAttributes().apply { backgroundColor = bg }
        editor.markupModel.addLineHighlighter(line, HighlighterLayer.CARET_ROW, attrs)
    }

    private fun buildToolbar(note: Note) {
        toolbar.removeAll()
        if (note.resolved) {
            toolbar.add(iconButton(AllIcons.Actions.Rollback, "Reopen") { toggleResolve(note) })
        } else {
            toolbar.add(iconButton(AllIcons.Actions.Commit, "Resolve") { toggleResolve(note) })
        }
        toolbar.add(iconButton(IncommIcons.REPLY, "Reply") {
            addingReply = true
            editingKey = null
            rebuild()
        })
        toolbar.add(iconButton(IncommIcons.DELETE_COMMENT, "Delete comment") {
            NotesService.getInstance(project).removeNote(noteId)
            onNoteDeleted()
        })
        toolbar.revalidate()
        toolbar.repaint()
    }

    private fun toggleResolve(note: Note) {
        NotesService.getInstance(project).setResolved(noteId, !note.resolved)
        onChanged()
        rebuild()
    }

    /** A display or (if being edited) in-place editor bubble for one message. */
    private fun bubbleFor(
        note: Note,
        key: String,
        author: String,
        createdAt: String,
        text: String,
        replyId: String?,
        indent: Int,
    ): JComponent {
        val editing = editingKey == key
        val card = roundedCard(author)

        val headerRow = JPanel(BorderLayout()).apply { isOpaque = false }
        headerRow.add(authorLabel(author, createdAt), BorderLayout.CENTER)

        val icons = JPanel(FlowLayout(FlowLayout.RIGHT, 2, 0)).apply { isOpaque = false }
        if (editing) {
            val editor = editorArea(text)
            icons.add(iconButton(IncommIcons.CHECK, "Save") { saveEdit(key, replyId, editor.text) })
            icons.add(iconButton(IncommIcons.CANCEL, "Cancel") { editingKey = null; rebuild() })
            headerRow.add(icons, BorderLayout.EAST)
            card.add(headerRow)
            card.add(editor)
            focusAfterBuild = editor
        } else {
            if (author == AUTHOR_USER) {
                icons.add(iconButton(IncommIcons.EDIT_COMMENT, "Edit") { editingKey = key; addingReply = false; rebuild() })
            }
            icons.add(iconButton(IncommIcons.DELETE_COMMENT, "Delete") { deleteMessage(key, replyId) })
            headerRow.add(icons, BorderLayout.EAST)
            card.add(headerRow)
            card.add(displayArea(text))
        }

        return indented(card, indent)
    }

    private fun newReplyBubble(note: Note): JComponent {
        val card = roundedCard(AUTHOR_USER)
        val headerRow = JPanel(BorderLayout()).apply { isOpaque = false }
        headerRow.add(authorLabel(AUTHOR_USER, "new reply"), BorderLayout.CENTER)
        val editor = editorArea("")
        val icons = JPanel(FlowLayout(FlowLayout.RIGHT, 2, 0)).apply { isOpaque = false }
        icons.add(iconButton(IncommIcons.CHECK, "Send") {
            val t = editor.text.trim()
            if (t.isNotEmpty()) {
                NotesService.getInstance(project).addReply(noteId, t, AUTHOR_USER)
                onChanged()
            }
            addingReply = false
            rebuild()
        })
        icons.add(iconButton(IncommIcons.CANCEL, "Cancel") { addingReply = false; rebuild() })
        headerRow.add(icons, BorderLayout.EAST)
        card.add(headerRow)
        card.add(editor)
        focusAfterBuild = editor
        return indented(card, JBUI.scale(18))
    }

    private fun saveEdit(key: String, replyId: String?, text: String) {
        val trimmed = text.trim()
        if (trimmed.isNotEmpty()) {
            val service = NotesService.getInstance(project)
            if (key == KEY_ORIGINAL) service.updateContent(noteId, trimmed)
            else if (replyId != null) service.updateReply(noteId, replyId, trimmed)
            onChanged()
        }
        editingKey = null
        rebuild()
    }

    private fun deleteMessage(key: String, replyId: String?) {
        val service = NotesService.getInstance(project)
        if (key == KEY_ORIGINAL) {
            service.removeNote(noteId)
            onNoteDeleted()
        } else if (replyId != null) {
            service.removeReply(noteId, replyId)
            onChanged()
            rebuild()
        }
    }

    // ---- small builders -----------------------------------------------------

    private fun authorLabel(author: String, createdAt: String): JBLabel =
        ThreadUi.authorLabel(author, ThreadUi.prettyTime(createdAt))

    private fun displayArea(text: String): JBTextArea =
        ThreadUi.flatEditor(text.trim(), rows = 0, editable = false)

    private fun editorArea(text: String): JBTextArea =
        ThreadUi.flatEditor(text, rows = 2)

    private fun iconButton(icon: Icon, tooltip: String, onClick: () -> Unit): InplaceButton =
        ThreadUi.iconButton(icon, tooltip, onClick)

    private fun roundedCard(author: String): JPanel = ThreadUi.roundedCard(author)

    private fun indented(card: JComponent, indent: Int): JComponent =
        JPanel(BorderLayout()).apply {
            isOpaque = false
            border = JBUI.Borders.emptyLeft(indent)
            add(card, BorderLayout.CENTER)
        }

    companion object {
        private const val KEY_ORIGINAL = "orig"
        private const val MAX_RANGE_LINES = 7
        private fun keyReply(id: String) = "reply:$id"

        private fun escape(s: String) = ThreadUi.escape(s)
    }
}
