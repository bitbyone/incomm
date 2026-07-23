package dev.incomm.editor

import com.intellij.openapi.fileEditor.FileEditorManager
import com.intellij.openapi.fileEditor.FileEditorManagerListener
import com.intellij.openapi.vfs.VirtualFile

/**
 * Belt-and-suspenders: make sure the editor tracker is running as soon as any
 * file is opened, independent of the post-startup activity. [IncommEditorTracker.start]
 * is idempotent, so calling it repeatedly is safe.
 */
class IncommFileEditorListener : FileEditorManagerListener {
    override fun fileOpened(source: FileEditorManager, file: VirtualFile) {
        IncommEditorTracker.getInstance(source.project).start()
    }
}
