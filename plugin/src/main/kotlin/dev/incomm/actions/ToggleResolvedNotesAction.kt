package dev.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import dev.incomm.editor.IncommEditorTracker

/**
 * "Incomm: Show/Hide Resolved Threads" — collapses or reveals the inline cards
 * of the *resolved* threads only (open threads are untouched). Gutter icons stay
 * so threads remain reachable.
 */
class ToggleResolvedNotesAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

    override fun update(e: AnActionEvent) {
        val project = e.project
        val tracker = project?.let { IncommEditorTracker.getInstance(it) }
        e.presentation.isEnabledAndVisible = tracker?.hasResolvedNotes() == true
        val anyVisible = tracker?.anyResolvedVisible() == true
        e.presentation.text = if (anyVisible) "Incomm: Hide Resolved Threads" else "Incomm: Show Resolved Threads"
    }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val tracker = IncommEditorTracker.getInstance(project)
        tracker.start() // ensure tracking is running
        // If any resolved card is showing, hide them all; otherwise reveal them.
        tracker.setResolvedHidden(tracker.anyResolvedVisible())
    }
}
