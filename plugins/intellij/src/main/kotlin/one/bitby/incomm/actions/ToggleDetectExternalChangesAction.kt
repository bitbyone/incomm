package one.bitby.incomm.actions

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.ToggleAction
import com.intellij.openapi.project.DumbAware
import one.bitby.incomm.editor.IncommEditorTracker
import one.bitby.incomm.settings.IncommSettings

class ToggleDetectExternalChangesAction : ToggleAction(), DumbAware {
    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun isSelected(e: AnActionEvent): Boolean {
        return IncommSettings.getInstance().data.detectExternalChanges
    }

    override fun setSelected(e: AnActionEvent, state: Boolean) {
        IncommSettings.getInstance().data.detectExternalChanges = state
        val project = e.project ?: return
        IncommEditorTracker.getInstance(project).updateWatchers()
    }
}
