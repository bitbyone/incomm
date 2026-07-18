package dev.incomm

import com.intellij.openapi.application.WriteAction
import com.intellij.openapi.editor.impl.DocumentMarkupModel
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import com.intellij.util.ui.UIUtil
import dev.incomm.anchor.Anchoring
import dev.incomm.actions.CaretNote
import dev.incomm.editor.IncommEditorTracker
import dev.incomm.model.AUTHOR_AGENT
import dev.incomm.model.AUTHOR_USER
import dev.incomm.store.IncommPaths
import dev.incomm.store.NotesService
import dev.incomm.ui.AddPlusGutterIconRenderer
import dev.incomm.ui.NoteGutterIconRenderer
import java.nio.file.Files
import java.nio.file.Paths

/** Ground-truth checks that editor visuals actually attach. */
class EditorIntegrationTest : BasePlatformTestCase() {

    private fun openOnDisk(name: String, text: String): VirtualFile {
        val baseDir = Paths.get(project.basePath!!)
        Files.createDirectories(baseDir)
        val file = baseDir.resolve(name)
        Files.writeString(file, text)
        val vf = WriteAction.computeAndWait<VirtualFile?, RuntimeException> {
            LocalFileSystem.getInstance().refreshAndFindFileByNioFile(file)
        }
        assertNotNull("virtual file should resolve", vf)
        myFixture.openFileInEditor(vf!!)
        return vf
    }

    fun testInlineCardShowsForCommentWithoutReplies() {
        val vf = openOnDisk("sample.txt", "line1\nline2\nline3\nline4\n")
        val editor = myFixture.editor
        val rel = IncommPaths.relPath(project, vf)
        assertEquals("sample.txt", rel)

        val service = NotesService.getInstance(project)
        service.addNote(rel!!, 2, 2, "look at line 2", AUTHOR_USER, Anchoring.splitLines(editor.document.text))

        IncommEditorTracker.getInstance(project).start()
        UIUtil.dispatchAllInvocationEvents()

        val markup = DocumentMarkupModel.forDocument(editor.document, project, true)
        val gutterIcons = markup.allHighlighters.count { it.gutterIconRenderer is NoteGutterIconRenderer }
        assertTrue("expected a note gutter icon, found $gutterIcons", gutterIcons >= 1)

        // The whole point: a comment with NO replies still renders inline.
        val inlays = editor.inlayModel.getBlockElementsInRange(0, editor.document.textLength)
        assertEquals("expected exactly one inline card", 1, inlays.size)

        service.clearAll()
        service.flushWrites()
    }

    fun testPlusAffordanceOnCaretLine() {
        val vf = openOnDisk("plus.txt", "aaa\nbbb\nccc\n")
        val editor = myFixture.editor
        assertNotNull(IncommPaths.relPath(project, vf))

        IncommEditorTracker.getInstance(project).start()
        editor.caretModel.moveToLogicalPosition(com.intellij.openapi.editor.LogicalPosition(0, 0))
        UIUtil.dispatchAllInvocationEvents()

        val plus = editor.markupModel.allHighlighters.count { it.gutterIconRenderer is AddPlusGutterIconRenderer }
        assertTrue("expected a '+' affordance on the caret line, found $plus", plus >= 1)
    }

    fun testToggleHidesInlaysKeepsGutter() {
        val vf = openOnDisk("toggle.txt", "a\nb\nc\n")
        val editor = myFixture.editor
        val rel = IncommPaths.relPath(project, vf)!!
        val service = NotesService.getInstance(project)
        service.addNote(rel, 2, 2, "note", AUTHOR_USER, Anchoring.splitLines(editor.document.text))

        val tracker = IncommEditorTracker.getInstance(project)
        tracker.start()
        UIUtil.dispatchAllInvocationEvents()

        fun inlayCount() = editor.inlayModel.getBlockElementsInRange(0, editor.document.textLength).size
        fun gutterCount() = DocumentMarkupModel.forDocument(editor.document, project, true)
            .allHighlighters.count { it.gutterIconRenderer is NoteGutterIconRenderer }

        assertEquals(1, inlayCount())
        assertTrue(gutterCount() >= 1)

        tracker.toggleInlaysVisible()
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("inline cards hidden", 0, inlayCount())
        assertTrue("gutter icons stay", gutterCount() >= 1)

        tracker.toggleInlaysVisible()
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("inline cards shown again", 1, inlayCount())

        service.clearAll()
        service.flushWrites()
    }

    fun testCaretNoteLookupForLineActions() {
        val vf = openOnDisk("multi.txt", "l1\nl2\nl3\nl4\nl5\n")
        val editor = myFixture.editor
        val rel = IncommPaths.relPath(project, vf)!!

        val service = NotesService.getInstance(project)
        service.addNote(rel, 2, 4, "range comment", AUTHOR_USER, Anchoring.splitLines(editor.document.text))
        IncommEditorTracker.getInstance(project).start()
        UIUtil.dispatchAllInvocationEvents()

        // A multi-line note (lines 2-4) is found when the caret is inside the range.
        editor.caretModel.moveToLogicalPosition(com.intellij.openapi.editor.LogicalPosition(2, 0)) // line 3
        assertNotNull("caret inside range should find the note", CaretNote.of(project, editor))
        editor.caretModel.moveToLogicalPosition(com.intellij.openapi.editor.LogicalPosition(0, 0)) // line 1
        assertNull("caret outside range should find nothing", CaretNote.of(project, editor))

        val inlays = editor.inlayModel.getBlockElementsInRange(0, editor.document.textLength)
        assertEquals("one inline card for the multi-line note", 1, inlays.size)

        service.clearAll()
        service.flushWrites()
    }

    fun testCaretInRangeLightsGutterBand() {
        val vf = openOnDisk("band.txt", "a\nb\nc\nd\ne\n")
        val editor = myFixture.editor
        val rel = IncommPaths.relPath(project, vf)!!

        val service = NotesService.getInstance(project)
        service.addNote(rel, 2, 4, "range", AUTHOR_USER, Anchoring.splitLines(editor.document.text))
        IncommEditorTracker.getInstance(project).start()
        UIUtil.dispatchAllInvocationEvents()

        fun bandCount() = editor.markupModel.allHighlighters.count { it.lineMarkerRenderer != null }

        // Caret inside the range (line 3) lights a gutter band.
        editor.caretModel.moveToLogicalPosition(com.intellij.openapi.editor.LogicalPosition(2, 0))
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("band while caret is in range", 1, bandCount())

        // Caret outside the range (line 1) removes it.
        editor.caretModel.moveToLogicalPosition(com.intellij.openapi.editor.LogicalPosition(0, 0))
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("no band while caret is out of range", 0, bandCount())

        service.clearAll()
        service.flushWrites()
    }

    fun testInlineReplyEmbedsEditorThenClearsOnRebuild() {
        val vf = openOnDisk("reply.txt", "a\nb\nc\n")
        val editor = myFixture.editor
        val rel = IncommPaths.relPath(project, vf)!!

        val service = NotesService.getInstance(project)
        service.addNote(rel, 2, 2, "note", AUTHOR_USER, Anchoring.splitLines(editor.document.text))
        val tracker = IncommEditorTracker.getInstance(project)
        tracker.start()
        UIUtil.dispatchAllInvocationEvents()

        fun blocks() = editor.inlayModel.getBlockElementsInRange(0, editor.document.textLength).size
        val noteId = service.notesForFile(rel).first().id
        assertEquals("card only", 1, blocks())

        // Reply action embeds an editable entry directly in the card area.
        tracker.startInlineReply(editor, noteId)
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("card + inline reply editor", 2, blocks())

        // Saving (a notes change) rebuilds the card and discards the reply editor.
        service.addReply(noteId, "hi", AUTHOR_USER)
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("reply editor gone after rebuild", 1, blocks())

        service.clearAll()
        service.flushWrites()
    }

    fun testInlineAddEmbedsComposerThenCreatesNote() {
        val vf = openOnDisk("add.txt", "a\nb\nc\n")
        val editor = myFixture.editor
        val rel = IncommPaths.relPath(project, vf)!!

        val service = NotesService.getInstance(project)
        val tracker = IncommEditorTracker.getInstance(project)
        tracker.start()
        UIUtil.dispatchAllInvocationEvents()

        fun blocks() = editor.inlayModel.getBlockElementsInRange(0, editor.document.textLength).size
        assertEquals("nothing yet", 0, blocks())

        // Add action embeds an inline composer (no dialog).
        tracker.startInlineAdd(editor, 2, 2)
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("inline composer embedded", 1, blocks())

        // Saving creates the note; the composer is replaced by the note's card.
        service.addNote(rel, 2, 2, "hello", AUTHOR_USER, Anchoring.splitLines(editor.document.text))
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("composer replaced by card", 1, blocks())
        assertEquals(1, service.notesForFile(rel).size)

        service.clearAll()
        service.flushWrites()
    }

    fun testGutterToggleHidesSingleThread() {
        val vf = openOnDisk("hide.txt", "a\nb\nc\n")
        val editor = myFixture.editor
        val rel = IncommPaths.relPath(project, vf)!!

        val service = NotesService.getInstance(project)
        service.addNote(rel, 2, 2, "n", AUTHOR_USER, Anchoring.splitLines(editor.document.text))
        val tracker = IncommEditorTracker.getInstance(project)
        tracker.start()
        UIUtil.dispatchAllInvocationEvents()

        fun blocks() = editor.inlayModel.getBlockElementsInRange(0, editor.document.textLength).size
        fun gutter() = DocumentMarkupModel.forDocument(editor.document, project, true)
            .allHighlighters.count { it.gutterIconRenderer is NoteGutterIconRenderer }
        val noteId = service.notesForFile(rel).first().id

        assertEquals(1, blocks())
        assertTrue(gutter() >= 1)

        tracker.toggleNoteHidden(noteId)
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("thread card hidden", 0, blocks())
        assertTrue("gutter icon stays", gutter() >= 1)

        tracker.toggleNoteHidden(noteId)
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("thread card back", 1, blocks())

        service.clearAll()
        service.flushWrites()
    }

    fun testResolveHidesThread() {
        val vf = openOnDisk("resolve.txt", "a\nb\nc\n")
        val editor = myFixture.editor
        val rel = IncommPaths.relPath(project, vf)!!

        val service = NotesService.getInstance(project)
        service.addNote(rel, 2, 2, "n", AUTHOR_USER, Anchoring.splitLines(editor.document.text))
        val tracker = IncommEditorTracker.getInstance(project)
        tracker.start()
        UIUtil.dispatchAllInvocationEvents()
        val noteId = service.notesForFile(rel).first().id

        fun blocks() = editor.inlayModel.getBlockElementsInRange(0, editor.document.textLength).size
        fun gutter() = DocumentMarkupModel.forDocument(editor.document, project, true)
            .allHighlighters.count { it.gutterIconRenderer is NoteGutterIconRenderer }
        assertEquals(1, blocks())

        // Resolving collapses (hides) the thread's card, like the resolve button.
        tracker.setNoteHidden(noteId, true)
        service.setResolved(noteId, true)
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("resolved thread hidden", 0, blocks())
        assertTrue("gutter icon stays", gutter() >= 1)

        service.clearAll()
        service.flushWrites()
    }

    fun testToggleResolvedHidesOnlyResolved() {
        val vf = openOnDisk("res.txt", "a\nb\nc\nd\n")
        val editor = myFixture.editor
        val rel = IncommPaths.relPath(project, vf)!!

        val service = NotesService.getInstance(project)
        service.addNote(rel, 1, 1, "open one", AUTHOR_USER, Anchoring.splitLines(editor.document.text))
        service.addNote(rel, 3, 3, "resolved one", AUTHOR_USER, Anchoring.splitLines(editor.document.text))
        val resolvedId = service.notesForFile(rel).first { it.startLine == 3 }.id
        service.setResolved(resolvedId, true)

        val tracker = IncommEditorTracker.getInstance(project)
        tracker.start()
        UIUtil.dispatchAllInvocationEvents()

        fun blocks() = editor.inlayModel.getBlockElementsInRange(0, editor.document.textLength).size
        assertEquals("both cards visible", 2, blocks())
        assertTrue(tracker.anyResolvedVisible())

        tracker.setResolvedHidden(true)
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("only the open card remains", 1, blocks())
        assertFalse(tracker.anyResolvedVisible())

        tracker.setResolvedHidden(false)
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("resolved card back", 2, blocks())

        service.clearAll()
        service.flushWrites()
    }

    fun testEditRevealsHiddenCard() {
        val vf = openOnDisk("edit.txt", "a\nb\nc\n")
        val editor = myFixture.editor
        val rel = IncommPaths.relPath(project, vf)!!

        val service = NotesService.getInstance(project)
        service.addNote(rel, 2, 2, "mine", AUTHOR_USER, Anchoring.splitLines(editor.document.text))
        val tracker = IncommEditorTracker.getInstance(project)
        tracker.start()
        UIUtil.dispatchAllInvocationEvents()
        val noteId = service.notesForFile(rel).first().id

        fun blocks() = editor.inlayModel.getBlockElementsInRange(0, editor.document.textLength).size
        assertEquals(1, blocks())

        tracker.toggleNoteHidden(noteId)
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("card hidden", 0, blocks())

        // Editing a hidden thread reveals its card first.
        tracker.startInlineEdit(editor, noteId)
        UIUtil.dispatchAllInvocationEvents()
        assertEquals("edit revealed the card", 1, blocks())

        service.clearAll()
        service.flushWrites()
    }

    fun testSetNoteResolvedHidesAndReopenShows() {
        val vf = openOnDisk("rr.txt", "a\nb\nc\n")
        val editor = myFixture.editor
        val rel = IncommPaths.relPath(project, vf)!!

        val service = NotesService.getInstance(project)
        service.addNote(rel, 2, 2, "n", AUTHOR_USER, Anchoring.splitLines(editor.document.text))
        val tracker = IncommEditorTracker.getInstance(project)
        tracker.start()
        UIUtil.dispatchAllInvocationEvents()
        val noteId = service.notesForFile(rel).first().id

        fun blocks() = editor.inlayModel.getBlockElementsInRange(0, editor.document.textLength).size
        assertEquals(1, blocks())

        tracker.setNoteResolved(noteId, true)
        UIUtil.dispatchAllInvocationEvents()
        assertTrue("note is resolved", service.find(noteId)!!.resolved)
        assertEquals("resolving hides the card", 0, blocks())

        tracker.setNoteResolved(noteId, false)
        UIUtil.dispatchAllInvocationEvents()
        assertFalse("note is reopened", service.find(noteId)!!.resolved)
        assertEquals("reopening shows the card", 1, blocks())

        service.clearAll()
        service.flushWrites()
    }
}
