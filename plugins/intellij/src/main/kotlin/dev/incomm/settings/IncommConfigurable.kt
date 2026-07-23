package dev.incomm.settings

import com.intellij.openapi.options.Configurable
import com.intellij.openapi.project.ProjectManager
import com.intellij.openapi.ui.ComboBox
import com.intellij.ui.ColorPanel
import com.intellij.ui.components.JBLabel
import com.intellij.util.ui.FormBuilder
import dev.incomm.editor.IncommEditorTracker
import dev.incomm.ui.IncommColors
import java.awt.Color
import java.awt.Component
import javax.swing.DefaultListCellRenderer
import javax.swing.JButton
import javax.swing.JComponent
import javax.swing.JList
import javax.swing.JPanel

/**
 * *Settings | Tools | Incomm* — lets the user recolour the comment UI and choose
 * a timestamp format. Colours default to the current IDE theme; a picker left at
 * its theme value is stored as "no override" so it keeps following the theme.
 */
class IncommConfigurable : Configurable {

    private val userBubbleBg = ColorPanel()
    private val userNameFg = ColorPanel()
    private val agentBubbleBg = ColorPanel()
    private val agentNameFg = ColorPanel()
    private val commentFg = ColorPanel()
    private val statusFg = ColorPanel()
    private val dateCombo = ComboBox(DateStyle.entries.toTypedArray())
    private val maxWidthSpinner = javax.swing.JSpinner(
        javax.swing.SpinnerNumberModel(100, 0, 500, 10)
    )

    override fun getDisplayName(): String = "Incomm"

    override fun createComponent(): JComponent {
        dateCombo.renderer = object : DefaultListCellRenderer() {
            override fun getListCellRendererComponent(
                list: JList<*>?, value: Any?, index: Int, selected: Boolean, focus: Boolean,
            ): Component {
                val c = super.getListCellRendererComponent(list, value, index, selected, focus)
                if (value is DateStyle) text = "${labelOf(value)} \u2014 ${IncommSettings.sample(value)}"
                return c
            }
        }
        val restore = JButton("Restore theme defaults").apply { addActionListener { loadDefaults() } }

        val panel = FormBuilder.createFormBuilder()
            .addComponent(JBLabel("<html><b>Bubble colours</b></html>"))
            .addLabeledComponent("Your bubble background:", userBubbleBg)
            .addLabeledComponent("Your name colour:", userNameFg)
            .addLabeledComponent("Agent bubble background:", agentBubbleBg)
            .addLabeledComponent("Agent name colour:", agentNameFg)
            .addSeparator()
            .addComponent(JBLabel("<html><b>Shared colours</b></html>"))
            .addLabeledComponent("Comment text colour:", commentFg)
            .addLabeledComponent("Date / status colour:", statusFg)
            .addSeparator()
            .addLabeledComponent("Timestamp format:", dateCombo)
            .addSeparator()
            .addComponent(JBLabel("<html><b>Layout</b></html>"))
            .addLabeledComponent("Max inline card width (chars, 0 = unlimited):", maxWidthSpinner)
            .addComponent(restore)
            .addComponentFillVertically(JPanel(), 0)
            .panel
        reset()
        return panel
    }

    override fun isModified(): Boolean {
        val s = IncommSettings.getInstance().data
        return overrideOf(userBubbleBg, IncommColors.themeUserBubbleBg()) != s.userBubbleBg ||
            overrideOf(userNameFg, IncommColors.themeUserName()) != s.userNameFg ||
            overrideOf(agentBubbleBg, IncommColors.themeAgentBubbleBg()) != s.agentBubbleBg ||
            overrideOf(agentNameFg, IncommColors.themeAgentName()) != s.agentNameFg ||
            overrideOf(commentFg, IncommColors.themeCommentFg()) != s.commentFg ||
            overrideOf(statusFg, IncommColors.themeStatusFg()) != s.statusFg ||
            (dateCombo.selectedItem as DateStyle) != s.dateStyle ||
            (maxWidthSpinner.value as Int) != s.maxCardWidthChars
    }

    override fun apply() {
        val s = IncommSettings.getInstance().data
        s.userBubbleBg = overrideOf(userBubbleBg, IncommColors.themeUserBubbleBg())
        s.userNameFg = overrideOf(userNameFg, IncommColors.themeUserName())
        s.agentBubbleBg = overrideOf(agentBubbleBg, IncommColors.themeAgentBubbleBg())
        s.agentNameFg = overrideOf(agentNameFg, IncommColors.themeAgentName())
        s.commentFg = overrideOf(commentFg, IncommColors.themeCommentFg())
        s.statusFg = overrideOf(statusFg, IncommColors.themeStatusFg())
        s.dateStyle = dateCombo.selectedItem as DateStyle
        s.maxCardWidthChars = maxWidthSpinner.value as Int
        refreshOpenEditors()
    }

    override fun reset() {
        val s = IncommSettings.getInstance().data
        userBubbleBg.selectedColor = s.userBubbleBg?.let(::Color) ?: IncommColors.themeUserBubbleBg()
        userNameFg.selectedColor = s.userNameFg?.let(::Color) ?: IncommColors.themeUserName()
        agentBubbleBg.selectedColor = s.agentBubbleBg?.let(::Color) ?: IncommColors.themeAgentBubbleBg()
        agentNameFg.selectedColor = s.agentNameFg?.let(::Color) ?: IncommColors.themeAgentName()
        commentFg.selectedColor = s.commentFg?.let(::Color) ?: IncommColors.themeCommentFg()
        statusFg.selectedColor = s.statusFg?.let(::Color) ?: IncommColors.themeStatusFg()
        dateCombo.selectedItem = s.dateStyle
        maxWidthSpinner.value = s.maxCardWidthChars
    }

    private fun loadDefaults() {
        userBubbleBg.selectedColor = IncommColors.themeUserBubbleBg()
        userNameFg.selectedColor = IncommColors.themeUserName()
        agentBubbleBg.selectedColor = IncommColors.themeAgentBubbleBg()
        agentNameFg.selectedColor = IncommColors.themeAgentName()
        commentFg.selectedColor = IncommColors.themeCommentFg()
        statusFg.selectedColor = IncommColors.themeStatusFg()
        dateCombo.selectedItem = DateStyle.RELATIVE
        maxWidthSpinner.value = 100
    }

    /** The RGB override for a picker, or null when it matches the theme default. */
    private fun overrideOf(panel: ColorPanel, themeDefault: Color): Int? =
        panel.selectedColor?.takeIf { it.rgb != themeDefault.rgb }?.rgb

    private fun labelOf(style: DateStyle): String = when (style) {
        DateStyle.RELATIVE -> "Relative"
        DateStyle.SHORT -> "Short"
        DateStyle.MEDIUM -> "Medium"
        DateStyle.LONG -> "Long"
        DateStyle.ISO -> "ISO"
    }

    private fun refreshOpenEditors() {
        for (project in ProjectManager.getInstance().openProjects) {
            if (project.isDisposed) continue
            project.getServiceIfCreated(IncommEditorTracker::class.java)?.refreshUi()
        }
    }
}
