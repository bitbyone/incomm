package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import dev.incomm.store.NotesService

/**
 * "Incomm: Delete Thread" — deletes the whole thread (its original comment and
 * all replies) on the caret line directly, without opening it and without
 * confirmation. Discoverable in Find Action and the editor/gutter context menus;
 * bindable to a shortcut.
 */
class DeleteThreadAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

    override fun update(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR)
        val project = e.project
        e.presentation.isEnabledAndVisible =
            project != null && editor != null && CaretNote.of(project, editor) != null
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val note = CaretNote.of(project, editor) ?: return
        NotesService.getInstance(project).removeNote(note.id)
    }
}
