package dev.incomm.store

import com.intellij.util.messages.Topic

/**
 * Message-bus topic fired (on the project bus) whenever the in-memory notes
 * model changes — after a reload, mutation, or external file change. Editor
 * components and the explorer subscribe to refresh themselves.
 */
fun interface IncommNotesListener {
    fun notesChanged()

    companion object {
        @JvmField
        @Topic.ProjectLevel
        val TOPIC: Topic<IncommNotesListener> =
            Topic.create("incomm notes changed", IncommNotesListener::class.java)
    }
}
