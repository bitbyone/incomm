package dev.incomm.ui

import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.fileEditor.OpenFileDescriptor
import com.intellij.openapi.project.Project
import dev.incomm.model.Note
import dev.incomm.store.IncommPaths

/** Opens the file for a note and jumps to its start line, at the first non-blank column. */
object IncommNavigator {
    fun open(project: Project, note: Note): Boolean {
        val vf = IncommPaths.findVirtualFile(project, note.file) ?: return false
        val doc = FileDocumentManager.getInstance().getDocument(vf)
        val lastLine = ((doc?.lineCount ?: 0) - 1).coerceAtLeast(0)
        val line = (note.startLine - 1).coerceIn(0, lastLine)
        val column = firstNonBlankColumn(doc, line)
        OpenFileDescriptor(project, vf, line, column).navigate(true)
        return true
    }

    /** Column of the first non-whitespace char on [line], or 0 for a blank line. */
    private fun firstNonBlankColumn(doc: com.intellij.openapi.editor.Document?, line: Int): Int {
        if (doc == null || line >= doc.lineCount) return 0
        val chars = doc.charsSequence
        val start = doc.getLineStartOffset(line)
        val end = doc.getLineEndOffset(line)
        var i = start
        while (i < end && chars[i].isWhitespace()) i++
        return if (i >= end) 0 else i - start
    }
}
