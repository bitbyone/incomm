package dev.incomm.ui

import com.intellij.openapi.editor.colors.EditorColors
import com.intellij.openapi.editor.colors.EditorColorsScheme
import com.intellij.ui.ColorUtil
import com.intellij.ui.JBColor
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import dev.incomm.model.AUTHOR_AGENT
import dev.incomm.settings.IncommSettings
import java.awt.Color

/**
 * The single source of truth for every colour incomm paints. By default nothing
 * here is a hard-coded RGB value: every colour is resolved from the running IDE
 * theme — the semantic [JBUI.CurrentTheme.Banner] palette, the active editor
 * scheme and standard UI helpers — so the plugin always matches the user's
 * light/dark theme. The user may override individual colours in *Settings |
 * Tools | Incomm*; those overrides ([IncommSettings]) win when set.
 *
 * Semantic mapping of the theme defaults:
 *  - the human's messages read as *info* (blue), the agent's as *success* (green);
 *  - an **orphaned** note is an *error* (red), a **resolved** note is *success*
 *    (green) and an **open** note is *info* (blue).
 */
object IncommColors {

    private val settings: IncommSettings.State get() = IncommSettings.getInstance().data

    // ---- theme defaults (used when no user override is set) ----------------

    fun themeUserBubbleBg(): Color = bubbleTint(JBUI.CurrentTheme.Banner.INFO_BORDER_COLOR)
    fun themeAgentBubbleBg(): Color = bubbleTint(JBUI.CurrentTheme.Banner.SUCCESS_BORDER_COLOR)
    fun themeUserName(): Color = JBUI.CurrentTheme.Link.Foreground.ENABLED
    fun themeAgentName(): Color {
        // SUCCESS_BORDER_COLOR can be low-contrast on the success background in
        // dark themes. Mix toward the label foreground for reliable readability.
        val base = JBUI.CurrentTheme.Banner.SUCCESS_BORDER_COLOR
        return ColorUtil.mix(base, UIUtil.getLabelForeground(), 0.45)
    }
    fun themeCommentFg(): Color = UIUtil.getLabelForeground()
    fun themeStatusFg(): Color = UIUtil.getContextHelpForeground()

    /** True when the IDE is on a light theme (panel background is light). */
    private fun isLight(): Boolean = !ColorUtil.isDark(UIUtil.getPanelBackground())

    /**
     * A bubble background: the panel surface tinted toward [accent]. The
     * semantic Banner backgrounds are almost white in light themes and blend
     * into the surface, so we tint more strongly (esp. in light themes) for a
     * clearly visible, still-subtle card.
     */
    private fun bubbleTint(accent: Color): Color {
        val surface = UIUtil.getPanelBackground()
        return ColorUtil.mix(surface, accent, if (isLight()) 0.16 else 0.13)
    }

    // ---- thread bubbles (author-coded; user-overridable) -------------------

    fun bubbleBg(author: String): Color =
        if (author == AUTHOR_AGENT) pick(settings.agentBubbleBg, themeAgentBubbleBg())
        else pick(settings.userBubbleBg, themeUserBubbleBg())

    fun bubbleAccent(author: String): Color =
        if (author == AUTHOR_AGENT) pick(settings.agentNameFg, themeAgentName())
        else pick(settings.userNameFg, themeUserName())

    /** Hover state: the bubble tinted slightly toward its own accent. */
    fun bubbleBgHover(author: String): Color =
        ColorUtil.mix(bubbleBg(author), bubbleAccent(author), 0.12)

    /** Comment body text colour. */
    val commentFg: Color get() = pick(settings.commentFg, themeCommentFg())

    /** Muted secondary text (timestamps, locations, state labels). */
    val muted: Color get() = pick(settings.statusFg, themeStatusFg())

    private fun pick(override: Int?, default: Color): Color =
        override?.let { JBColor(Color(it), Color(it)) } ?: default

    // ---- note-state accents (gutter band) ----------------------------------

    val stateOrphaned: Color get() = JBUI.CurrentTheme.Banner.ERROR_BORDER_COLOR
    val stateResolved: Color get() = JBUI.CurrentTheme.Banner.SUCCESS_BORDER_COLOR
    val stateOpen: Color get() = JBUI.CurrentTheme.Banner.INFO_BORDER_COLOR

    // ---- explorer list row backgrounds -------------------------------------

    val orphanedRowBg: Color get() = rowTint(stateOrphaned, selected = false)
    val resolvedRowBg: Color get() = rowTint(stateResolved, selected = false)
    val orphanedRowBgSelected: Color get() = rowTint(stateOrphaned, selected = true)
    val resolvedRowBgSelected: Color get() = rowTint(stateResolved, selected = true)

    /** A list-row background tinted toward [accent], stronger when [selected]. */
    private fun rowTint(accent: Color, selected: Boolean): Color {
        val surface = UIUtil.getListBackground()
        val amount = when {
            selected && isLight() -> 0.34
            selected -> 0.30
            isLight() -> 0.15
            else -> 0.13
        }
        return ColorUtil.mix(surface, accent, amount)
    }

    /**
     * The colour the editor paints under the caret's line; preview snippets use
     * it to highlight a note's line(s) exactly like the active editor line.
     */
    fun caretRow(scheme: EditorColorsScheme): Color =
        scheme.getColor(EditorColors.CARET_ROW_COLOR) ?: JBUI.CurrentTheme.Banner.INFO_BACKGROUND
}
