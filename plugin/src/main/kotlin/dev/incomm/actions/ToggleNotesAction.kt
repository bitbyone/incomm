package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import dev.incomm.editor.IncommEditorTracker

/**
 * "Incomm: Hide/Show Notes" — toggles the inline comment cards in the editor.
 * Gutter icons (and the "+") stay so threads remain reachable.
 */
class ToggleNotesAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

    override fun update(e: AnActionEvent) {
        val project = e.project
        e.presentation.isEnabled = project != null
        val visible = project?.let { IncommEditorTracker.getInstance(it).inlaysVisible } ?: true
        e.presentation.text = if (visible) "Incomm: Hide Notes" else "Incomm: Show Notes"
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        IncommEditorTracker.getInstance(project).start() // ensure tracking is running
        IncommEditorTracker.getInstance(project).toggleInlaysVisible()
    }
}
