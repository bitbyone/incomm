package dev.incomm.ui

import com.intellij.openapi.util.IconLoader

/** Plugin icons loaded from `/icons`. */
object IncommIcons {
    @JvmField val COMMENT = IconLoader.getIcon("/icons/comment.svg", IncommIcons::class.java)
    @JvmField val COMMENT_RESOLVED = IconLoader.getIcon("/icons/commentResolved.svg", IncommIcons::class.java)
    @JvmField val COMMENT_ORPHANED = IconLoader.getIcon("/icons/commentOrphaned.svg", IncommIcons::class.java)
    @JvmField val ADD_COMMENT = IconLoader.getIcon("/icons/addComment.svg", IncommIcons::class.java)
    @JvmField val EDIT_COMMENT = IconLoader.getIcon("/icons/editComment.svg", IncommIcons::class.java)
    @JvmField val DELETE_COMMENT = IconLoader.getIcon("/icons/deleteComment.svg", IncommIcons::class.java)
    @JvmField val REPLY = IconLoader.getIcon("/icons/reply.svg", IncommIcons::class.java)
    @JvmField val CHECK = IconLoader.getIcon("/icons/check.svg", IncommIcons::class.java)
    @JvmField val CANCEL = IconLoader.getIcon("/icons/cross.svg", IncommIcons::class.java)
}
