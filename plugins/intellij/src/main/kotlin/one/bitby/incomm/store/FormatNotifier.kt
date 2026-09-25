package one.bitby.incomm.store

import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.project.Project
import java.util.concurrent.ConcurrentHashMap

/**
 * Tells the user once per (file, version) that the notes file was written by a
 * newer Incomm than this plugin understands, so the plugin will neither show nor
 * touch it until it is updated.
 */
internal object FormatNotifier {

    private const val GROUP_ID = "Incomm"
    private val shown = ConcurrentHashMap.newKeySet<String>()

    fun notify(project: Project, error: IncompatibleFormatException) {
        if (project.isDisposed) return
        if (!shown.add("${error.path}#${error.found}")) return
        NotificationGroupManager.getInstance().getNotificationGroup(GROUP_ID)
            .createNotification("Incomm needs an update", error.message ?: "", NotificationType.WARNING)
            .notify(project)
    }

    /** Forget what was announced, so a file that becomes incompatible again is announced again. */
    fun reset(path: String) {
        shown.removeIf { it.startsWith("$path#") }
    }
}
