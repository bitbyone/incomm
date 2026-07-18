package dev.incomm.ui

import com.intellij.openapi.editor.colors.EditorColors
import com.intellij.openapi.editor.colors.EditorColorsScheme
import com.intellij.ui.ColorUtil
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import dev.incomm.model.AUTHOR_AGENT
import java.awt.Color

/**
 * The single source of truth for every colour incomm paints. Nothing here is a
 * hard-coded RGB value: every colour is resolved from the running IDE theme —
 * the semantic [JBUI.CurrentTheme.Banner] palette, the active editor scheme and
 * standard UI helpers — so the plugin always matches the user's light/dark theme.
 *
 * Semantic mapping:
 *  - the human's messages read as *info* (blue), the agent's as *success* (green);
 *  - an **orphaned** note is an *error* (red), a **resolved** note is *success*
 *    (green) and an **open** note is *info* (blue).
 */
object IncommColors {

    // ---- thread bubbles (author-coded) -------------------------------------

    fun bubbleBg(author: String): Color =
        if (author == AUTHOR_AGENT) JBUI.CurrentTheme.Banner.SUCCESS_BACKGROUND
        else JBUI.CurrentTheme.Banner.INFO_BACKGROUND

    fun bubbleAccent(author: String): Color =
        if (author == AUTHOR_AGENT) JBUI.CurrentTheme.Banner.SUCCESS_BORDER_COLOR
        else JBUI.CurrentTheme.Banner.INFO_BORDER_COLOR

    /** Hover state: the bubble tinted slightly toward its own accent. */
    fun bubbleBgHover(author: String): Color =
        ColorUtil.mix(bubbleBg(author), bubbleAccent(author), 0.12)

    /** Muted secondary text (timestamps, locations, state labels). */
    val muted: Color get() = UIUtil.getContextHelpForeground()

    // ---- note-state accents (gutter band) ----------------------------------

    val stateOrphaned: Color get() = JBUI.CurrentTheme.Banner.ERROR_BORDER_COLOR
    val stateResolved: Color get() = JBUI.CurrentTheme.Banner.SUCCESS_BORDER_COLOR
    val stateOpen: Color get() = JBUI.CurrentTheme.Banner.INFO_BORDER_COLOR

    // ---- explorer list row backgrounds -------------------------------------

    val orphanedRowBg: Color get() = JBUI.CurrentTheme.Banner.ERROR_BACKGROUND
    val resolvedRowBg: Color get() = JBUI.CurrentTheme.Banner.SUCCESS_BACKGROUND
    val orphanedRowBgSelected: Color get() = JBUI.CurrentTheme.Banner.ERROR_BORDER_COLOR
    val resolvedRowBgSelected: Color get() = JBUI.CurrentTheme.Banner.SUCCESS_BORDER_COLOR

    /**
     * The colour the editor paints under the caret's line; preview snippets use
     * it to highlight a note's line(s) exactly like the active editor line.
     */
    fun caretRow(scheme: EditorColorsScheme): Color =
        scheme.getColor(EditorColors.CARET_ROW_COLOR) ?: JBUI.CurrentTheme.Banner.INFO_BACKGROUND
}
