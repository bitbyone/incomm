package dev.incomm.store

import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.project.Project
import dev.incomm.model.AUTHOR_AGENT
import dev.incomm.model.Note
import dev.incomm.model.NotesFile
import dev.incomm.ui.IncommNavigator

/**
 * Fires balloon notifications when new agent-authored content (threads or
 * replies) appears from an external change (the CLI / agent writing the notes
 * file). Each notification shows the filename and a trimmed content preview;
 * clicking it navigates to the note's line.
 */
internal object AgentNotifier {

    private const val GROUP_ID = "Incomm"
    private const val MAX_PREVIEW = 80

    /**
     * Describes a single piece of new agent content detected during a diff.
     *
     * @param file      project-root-relative path (e.g. `"src/app/main.go"`)
     * @param startLine 1-based line the note anchors to
     * @param content   the agent's message text
     * @param isReply   `true` if this is a reply on an existing thread
     */
    data class AgentNews(
        val file: String,
        val startLine: Int,
        val content: String,
        val isReply: Boolean,
    )

    /**
     * Compare [old] and [new] models and return every new agent-authored comment
     * or reply that appeared in [new] but was absent in [old].
     */
    fun diff(old: NotesFile, new: NotesFile): List<AgentNews> {
        val result = mutableListOf<AgentNews>()

        val oldNoteIds = HashSet<String>(old.notes.size)
        val oldReplyIds = HashMap<String, HashSet<String>>(old.notes.size)
        for (note in old.notes) {
            oldNoteIds.add(note.id)
            oldReplyIds[note.id] = note.replies.mapTo(HashSet()) { it.id }
        }

        for (note in new.notes) {
            if (note.id !in oldNoteIds) {
                // Entirely new note
                if (note.author == AUTHOR_AGENT) {
                    result.add(AgentNews(note.file, note.startLine, note.content, false))
                }
                continue
            }
            // Existing note: check for new agent replies
            val knownReplies = oldReplyIds[note.id] ?: continue
            for (reply in note.replies) {
                if (reply.id !in knownReplies && reply.author == AUTHOR_AGENT) {
                    result.add(AgentNews(note.file, note.startLine, reply.content, true))
                }
            }
        }
        return result
    }

    /**
     * Show a balloon notification for each piece of [news]. Clicking the
     * notification navigates to the note's file and line.
     */
    fun notify(project: Project, news: List<AgentNews>) {
        if (news.isEmpty() || project.isDisposed) return
        val group = NotificationGroupManager.getInstance().getNotificationGroup(GROUP_ID)

        for (item in news) {
            val fileName = item.file.substringAfterLast('/')
            val preview = trimContent(item.content)
            val kind = if (item.isReply) "replied" else "commented"
            val title = "Agent $kind in $fileName:${item.startLine}"

            val notification = group.createNotification(
                title,
                preview,
                NotificationType.INFORMATION,
            )
            notification.setIcon(dev.incomm.ui.IncommIcons.COMMENT)

            // Click → navigate to the line.
            val file = item.file
            val line = item.startLine
            notification.addAction(object : com.intellij.notification.NotificationAction("Go to line") {
                override fun actionPerformed(
                    e: com.intellij.openapi.actionSystem.AnActionEvent,
                    notification: com.intellij.notification.Notification,
                ) {
                    // Build a minimal Note just for navigation.
                    val nav = Note(file = file, startLine = line, endLine = line)
                    IncommNavigator.open(project, nav)
                    notification.expire()
                }
            })

            notification.notify(project)
        }
    }

    /** Trim content to [MAX_PREVIEW] characters, collapsing newlines to spaces. */
    private fun trimContent(content: String): String {
        val flat = content.replace('\n', ' ').replace('\r', ' ').trim()
        return if (flat.length <= MAX_PREVIEW) flat
        else flat.take(MAX_PREVIEW - 3) + "..."
    }
}
