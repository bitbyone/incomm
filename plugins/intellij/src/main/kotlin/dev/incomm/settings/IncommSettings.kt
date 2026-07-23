package dev.incomm.settings

import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage
import com.intellij.openapi.components.service
import java.text.DateFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Date
import java.util.Locale

/** How comment timestamps are rendered. */
enum class DateStyle { RELATIVE, SHORT, MEDIUM, LONG, ISO }

/**
 * Application-level, persisted incomm settings: user-chosen colour overrides for
 * the comment UI and the timestamp format. Every colour override is nullable —
 * `null` means "follow the current IDE theme" (the default), so a fresh install
 * looks exactly like the theme-derived palette in [dev.incomm.ui.IncommColors].
 */
@Service(Service.Level.APP)
@State(name = "IncommSettings", storages = [Storage("incomm.xml")])
class IncommSettings : PersistentStateComponent<IncommSettings.State> {

    /** Colour fields are nullable RGB ints; null = follow the IDE theme. */
    class State {
        var userBubbleBg: Int? = null
        var agentBubbleBg: Int? = null
        var userNameFg: Int? = null
        var agentNameFg: Int? = null
        var commentFg: Int? = null
        var statusFg: Int? = null
        var dateStyle: DateStyle = DateStyle.RELATIVE
        /** Max inline card width in editor-font characters (0 = unlimited). */
        var maxCardWidthChars: Int = 100
    }

    private var myState = State()

    override fun getState(): State = myState

    override fun loadState(state: State) {
        myState = state
    }

    /** The live, mutable state (read by the colour layer and the settings UI). */
    val data: State get() = myState

    /** Render an RFC3339 / ISO-8601 UTC timestamp per the chosen [DateStyle]. */
    fun formatTimestamp(iso: String): String {
        val instant = try {
            Instant.parse(iso)
        } catch (e: Exception) {
            return iso.replace('T', ' ').removeSuffix("Z")
        }
        return render(instant, myState.dateStyle)
    }

    companion object {
        private val ISO_LOCAL: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

        fun getInstance(): IncommSettings = service()

        /** A sample rendering of [style] (for "an hour ago") to label the combo box. */
        fun sample(style: DateStyle): String = render(Instant.now().minusSeconds(3600), style)

        private fun render(instant: Instant, style: DateStyle): String {
            val locale = Locale.getDefault()
            return when (style) {
                DateStyle.RELATIVE -> relative(instant)
                DateStyle.SHORT -> dateTime(instant, DateFormat.SHORT, locale)
                DateStyle.MEDIUM -> dateTime(instant, DateFormat.MEDIUM, locale)
                DateStyle.LONG -> dateTime(instant, DateFormat.LONG, locale)
                DateStyle.ISO -> ISO_LOCAL.format(instant.atZone(ZoneId.systemDefault()))
            }
        }

        private fun dateTime(instant: Instant, style: Int, locale: Locale): String =
            DateFormat.getDateTimeInstance(style, DateFormat.SHORT, locale).format(Date.from(instant))

        private fun relative(instant: Instant): String {
            val secs = ChronoUnit.SECONDS.between(instant, Instant.now())
            if (secs < 0) return "just now"
            return when {
                secs < 45 -> "just now"
                secs < 90 -> "a minute ago"
                secs < 3600 -> "${secs / 60} minutes ago"
                secs < 5400 -> "an hour ago"
                secs < 86400 -> "${secs / 3600} hours ago"
                secs < 172800 -> "yesterday"
                secs < 2592000 -> "${secs / 86400} days ago"
                else -> DateFormat.getDateInstance(DateFormat.MEDIUM, Locale.getDefault()).format(Date.from(instant))
            }
        }
    }
}
