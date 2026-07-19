package dev.incomm.ui

import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CustomShortcutSet
import com.intellij.openapi.project.DumbAwareAction
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.popup.JBPopup
import com.intellij.openapi.ui.popup.JBPopupFactory
import com.intellij.openapi.util.SystemInfo
import com.intellij.psi.codeStyle.NameUtil
import com.intellij.ui.JBColor
import com.intellij.ui.JBSplitter
import com.intellij.ui.SearchTextField
import com.intellij.ui.components.JBCheckBox
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBList
import com.intellij.ui.components.JBScrollPane
import com.intellij.util.ui.JBUI
import dev.incomm.model.Note
import dev.incomm.store.NotesService
import java.awt.BorderLayout
import java.awt.Dimension
import java.awt.FlowLayout
import java.awt.event.KeyAdapter
import java.awt.event.KeyEvent
import javax.swing.DefaultListModel
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.ListSelectionModel
import javax.swing.event.DocumentEvent
import javax.swing.event.DocumentListener

/**
 * A double-pane fuzzy explorer. Left: two-line rows (comment text; reply count +
 * location). Right: the interactive [NoteThreadComponent] for the selected
 * comment — identical to the gutter-icon popup.
 */
object NotesExplorerPopup {

    fun show(project: Project) {
        val service = NotesService.getInstance(project)
        if (service.isEmpty()) {
            JBPopupFactory.getInstance().createMessage("No incomm threads yet.")
                .showCenteredInCurrentWindow(project)
            return
        }

        val model = DefaultListModel<Note>()
        val list = JBList(model).apply {
            selectionMode = ListSelectionModel.SINGLE_SELECTION
            cellRenderer = NoteListCellRenderer()
        }
        val search = SearchTextField(false)
        val orphanedFilter = JBCheckBox("Include orphaned", true).apply {
            isOpaque = false
            toolTipText = "Show orphaned threads (${if (SystemInfo.isMac) "\u2318O" else "Ctrl+O"})"
            border = JBUI.Borders.emptyLeft(8)
        }
        val resolvedFilter = JBCheckBox("Include resolved", false).apply {
            isOpaque = false
            toolTipText = "Show resolved threads too (${if (SystemInfo.isMac) "\u2318R" else "Ctrl+R"})"
            border = JBUI.Borders.emptyLeft(8)
        }
        val rightHost = JPanel(BorderLayout())

        lateinit var popup: JBPopup
        var shownId: String? = null

        fun selected(): Note? = list.selectedValue

        fun placeholder(): JComponent =
            JBLabel("<html><center>Select a thread</center></html>").apply {
                horizontalAlignment = JBLabel.CENTER
            }

        fun reload(preserveId: String?) {
            val query = search.text.trim()
            val matcher = if (query.isEmpty()) null else NameUtil.buildMatcher("*$query").build()
            val includeResolved = resolvedFilter.isSelected
            val includeOrphaned = orphanedFilter.isSelected
            val items = service.allNotes()
                .filter { includeResolved || !it.resolved }
                .filter { includeOrphaned || !it.orphaned }
                .filter { matcher == null || matcher.matches(searchableText(it)) }
                .sortedWith(compareBy({ it.file }, { it.startLine }))
            model.clear()
            items.forEach { model.addElement(it) }
            val newIndex = when {
                model.isEmpty -> -1
                preserveId != null -> items.indexOfFirst { it.id == preserveId }.let { if (it >= 0) it else 0 }
                else -> 0
            }
            if (newIndex >= 0) list.selectedIndex = newIndex
        }

        fun showDetail() {
            val note = selected()
            if (note?.id == shownId && note != null) return // already shown; component manages itself
            shownId = note?.id
            rightHost.removeAll()
            if (note == null) {
                rightHost.add(placeholder(), BorderLayout.CENTER)
            } else {
                val component = NoteThreadComponent(
                    project,
                    note.id,
                    onChanged = { reload(note.id) },
                    onNoteDeleted = {
                        shownId = null
                        if (service.isEmpty()) popup.cancel() else reload(null)
                    },
                )
                rightHost.add(component, BorderLayout.CENTER)
            }
            rightHost.revalidate()
            rightHost.repaint()
        }

        val leftPanel = JPanel(BorderLayout()).apply {
            add(JBScrollPane(list), BorderLayout.CENTER)
            add(hintBar(), BorderLayout.SOUTH)
        }

        val splitter = JBSplitter(false, 0.42f).apply {
            firstComponent = leftPanel
            secondComponent = rightHost
            preferredSize = Dimension(960, 560)
        }

        // Search-Everywhere-style header: the search field with the orphaned and
        // resolved filters on the right.
        val filters = JPanel(FlowLayout(FlowLayout.RIGHT, 0, 0)).apply {
            isOpaque = false
            add(orphanedFilter)
            add(resolvedFilter)
        }
        val header = JPanel(BorderLayout()).apply {
            add(search, BorderLayout.CENTER)
            add(filters, BorderLayout.EAST)
            border = JBUI.Borders.compound(
                JBUI.Borders.customLine(JBColor.border(), 0, 0, 1, 0),
                JBUI.Borders.empty(2, 4, 2, 6),
            )
        }
        val root = JPanel(BorderLayout()).apply {
            add(header, BorderLayout.NORTH)
            add(splitter, BorderLayout.CENTER)
        }

        popup = JBPopupFactory.getInstance()
            .createComponentPopupBuilder(root, search)
            .setRequestFocus(true)
            .setFocusable(true)
            .setResizable(true)
            .setMovable(true)
            .setCancelOnClickOutside(true)
            .setDimensionServiceKey(project, "incomm.explorer", true)
            .createPopup()

        fun openSelected() {
            val note = selected() ?: return
            popup.cancel()
            IncommNavigator.open(project, note)
        }

        // Return focus to the search field, caret at the end.
        fun focusSearch() {
            search.textEditor.requestFocusInWindow()
            search.textEditor.caretPosition = search.text.length
        }

        list.addListSelectionListener { showDetail() }
        resolvedFilter.addActionListener { reload(selected()?.id) }
        orphanedFilter.addActionListener { reload(selected()?.id) }
        // Cmd+R (Ctrl+R off macOS) toggles the resolved filter from anywhere in the popup.
        object : DumbAwareAction() {
            override fun actionPerformed(e: AnActionEvent) = resolvedFilter.doClick()
        }.registerCustomShortcutSet(
            CustomShortcutSet.fromString(if (SystemInfo.isMac) "meta R" else "control R"),
            root,
        )
        // Cmd+O (Ctrl+O off macOS) toggles the orphaned filter from anywhere in the popup.
        object : DumbAwareAction() {
            override fun actionPerformed(e: AnActionEvent) = orphanedFilter.doClick()
        }.registerCustomShortcutSet(
            CustomShortcutSet.fromString(if (SystemInfo.isMac) "meta O" else "control O"),
            root,
        )
        search.addDocumentListener(object : DocumentListener {
            override fun insertUpdate(e: DocumentEvent) = reload(selected()?.id)
            override fun removeUpdate(e: DocumentEvent) = reload(selected()?.id)
            override fun changedUpdate(e: DocumentEvent) = reload(selected()?.id)
        })
        search.textEditor.addKeyListener(object : KeyAdapter() {
            override fun keyPressed(e: KeyEvent) {
                when (e.keyCode) {
                    KeyEvent.VK_DOWN, KeyEvent.VK_UP -> {
                        list.requestFocusInWindow()
                        if (list.selectedIndex < 0 && !model.isEmpty) list.selectedIndex = 0
                    }
                    KeyEvent.VK_ENTER -> openSelected()
                }
            }
        })
        list.addKeyListener(object : KeyAdapter() {
            override fun keyPressed(e: KeyEvent) {
                when (e.keyCode) {
                    KeyEvent.VK_ENTER -> openSelected()
                    // Backspace anywhere in the list edits the query and jumps back to search.
                    KeyEvent.VK_BACK_SPACE -> {
                        if (search.text.isNotEmpty()) search.text = search.text.dropLast(1)
                        focusSearch()
                        e.consume()
                    }
                }
            }

            // Typing a character anywhere in the list refocuses the search bar and
            // starts filtering — exactly like the IntelliJ Settings search.
            override fun keyTyped(e: KeyEvent) {
                if (e.isControlDown || e.isMetaDown || e.isAltDown) return
                val c = e.keyChar
                if (c == KeyEvent.CHAR_UNDEFINED || Character.isISOControl(c)) return
                search.text += c
                focusSearch()
                e.consume()
            }
        })

        reload(null)
        showDetail()
        popup.showCenteredInCurrentWindow(project)
    }

    private fun hintBar(): JComponent =
        JBLabel("<html><small>&nbsp;\u2191\u2193 navigate &nbsp;\u00B7&nbsp; \u23CE open &nbsp;\u00B7&nbsp; type to filter &nbsp;\u00B7&nbsp; \u2318O/Ctrl+O orphaned &nbsp;\u00B7&nbsp; \u2318R/Ctrl+R resolved</small></html>")
            .apply { border = JBUI.Borders.empty(3, 6) }

    private fun searchableText(note: Note): String =
        "${note.file}:${note.startLine} ${note.content} ${note.replies.joinToString(" ") { it.content }}"
}
