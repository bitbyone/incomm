package dev.incomm.actions

import com.intellij.openapi.editor.Editor
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.project.Project
import dev.incomm.model.Note
import dev.incomm.store.IncommPaths
import dev.incomm.store.NotesService

/** Shared lookup: the incomm note (if any) covering the caret line. */
internal object CaretNote {
    fun of(project: Project, editor: Editor): Note? {
        val vf = FileDocumentManager.getInstance().getFile(editor.document) ?: return null
        val rel = IncommPaths.relPath(project, vf) ?: return null
        val line = editor.caretModel.logicalPosition.line + 1
        return NotesService.getInstance(project)
            .notesForFile(rel)
            .firstOrNull { line in it.startLine..it.endLine }
    }
}
