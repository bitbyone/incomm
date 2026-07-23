package dev.incomm

import com.intellij.testFramework.fixtures.BasePlatformTestCase
import dev.incomm.model.AUTHOR_AGENT
import dev.incomm.model.AUTHOR_USER
import dev.incomm.model.Note
import dev.incomm.model.nowUtc
import dev.incomm.store.NotesService
import dev.incomm.store.NotesStore
import java.nio.file.Paths

/**
 * Exercises the runtime-wired [NotesService] (project base path resolution,
 * in-memory model, mutations, and disk persistence) in a headless IDE.
 */
class NotesServiceTest : BasePlatformTestCase() {

    override fun setUp() {
        super.setUp()
        // The light project (and its on-disk notes.json) is reused across test
        // methods; start each test from a clean slate. Merge-on-write persistence
        // would otherwise fold a previous test's leftover notes back in.
        val service = NotesService.getInstance(project)
        service.clearAll()
        service.flushWrites()
    }

    fun testAddResolveReplyRemoveInMemory() {
        val service = NotesService.getInstance(project)
        val lines = listOf("alpha", "beta", "gamma")

        val note = service.addNote("foo.txt", 2, 2, "please fix beta", AUTHOR_USER, lines)
        assertNotNull(service.find(note.id))
        assertEquals(1, service.allNotes().size)
        assertEquals("beta", service.find(note.id)!!.anchor.startPrefix)

        service.addReply(note.id, "done", AUTHOR_AGENT)
        assertEquals(1, service.find(note.id)!!.replies.size)

        service.setResolved(note.id, true)
        assertTrue(service.find(note.id)!!.resolved)

        assertTrue(service.removeNote(note.id))
        assertTrue(service.isEmpty())
    }

    fun testReplyEditAndRemove() {
        val service = NotesService.getInstance(project)
        val note = service.addNote("f.txt", 1, 1, "c", AUTHOR_USER, listOf("a"))
        service.addReply(note.id, "r1", AUTHOR_AGENT)
        val rid = service.find(note.id)!!.replies[0].id

        service.updateReply(note.id, rid, "r1-edited")
        assertEquals("r1-edited", service.find(note.id)!!.replies[0].content)

        service.removeReply(note.id, rid)
        assertTrue(service.find(note.id)!!.replies.isEmpty())

        service.updateContent(note.id, "c-edited")
        assertEquals("c-edited", service.find(note.id)!!.content)

        service.removeNote(note.id)
    }

    fun testThreadComponentBuildsWithoutError() {
        val service = NotesService.getInstance(project)
        val note = service.addNote("t.txt", 1, 1, "hello", AUTHOR_USER, listOf("a"))
        service.addReply(note.id, "world", AUTHOR_AGENT)

        var deleted = false
        val component = dev.incomm.ui.NoteThreadComponent(
            project, note.id, onChanged = {}, onNoteDeleted = { deleted = true },
        )
        assertFalse("note exists, so component should render", deleted)
        assertTrue("component should have children", component.componentCount > 0)

        service.removeNote(note.id)
    }

    fun testRemoveNotesForFile() {
        val service = NotesService.getInstance(project)
        service.addNote("a.txt", 1, 1, "one", AUTHOR_USER, listOf("x"))
        service.addNote("a.txt", 2, 2, "two", AUTHOR_USER, listOf("x", "y"))
        service.addNote("b.txt", 1, 1, "other", AUTHOR_USER, listOf("x"))

        val removed = service.removeNotesForFile("a.txt")
        assertEquals(2, removed)
        assertTrue(service.notesForFile("a.txt").isEmpty())
        assertEquals("b.txt notes untouched", 1, service.notesForFile("b.txt").size)

        assertEquals("removing a file with no notes is a no-op", 0, service.removeNotesForFile("a.txt"))

        service.clearAll()
    }

    fun testPersistsToDiskAndReloads() {
        val base = project.basePath
        if (base == null) {
            // No base path in this fixture; in-memory behavior is covered above.
            return
        }
        val service = NotesService.getInstance(project)
        val note = service.addNote("bar.txt", 1, 1, "hello", AUTHOR_USER, listOf("hello world"))
        service.flushWrites()

        val store = NotesStore(Paths.get(base))
        val reloaded = store.load()
        assertEquals(1, reloaded.notes.size)
        assertEquals(note.id, reloaded.notes[0].id)
        assertEquals("hello", reloaded.notes[0].content)

        // clean up disk artifact so it doesn't leak between tests
        service.clearAll()
        service.flushWrites()
    }

    /**
     * Critical: a plugin write must NOT clobber notes the agent added to
     * notes.json externally (previously the whole in-memory model was written
     * over the file, deleting agent comments). Merge-on-write must preserve them.
     */
    fun testExternalAgentNoteSurvivesPluginWrite() {
        val base = project.basePath ?: return
        val service = NotesService.getInstance(project)
        val store = NotesStore(Paths.get(base))

        val userNote = service.addNote("app.txt", 1, 1, "user comment", AUTHOR_USER, listOf("code"))
        service.flushWrites()

        // Agent writes a brand-new note straight to notes.json; plugin is unaware.
        val onDisk = store.load()
        onDisk.notes.add(
            Note(
                id = "agent0001", file = "app.txt", startLine = 2, endLine = 2,
                content = "agent comment", author = AUTHOR_AGENT,
                createdAt = nowUtc(), updatedAt = nowUtc(),
            ),
        )
        store.save(onDisk)

        // Plugin writes again WITHOUT reloading — must merge, not clobber.
        service.setResolved(userNote.id, true)
        service.flushWrites()

        val reloaded = store.load()
        val ids = reloaded.notes.map { it.id }.toSet()
        assertTrue("user note kept", userNote.id in ids)
        assertTrue("agent note preserved", "agent0001" in ids)
        assertEquals(2, reloaded.notes.size)

        service.clearAll()
        service.flushWrites()
    }

    /** A note deleted in the plugin must not be resurrected by merge-on-write. */
    fun testLocalDeleteNotResurrected() {
        val base = project.basePath ?: return
        val service = NotesService.getInstance(project)
        val store = NotesStore(Paths.get(base))

        val note = service.addNote("d.txt", 1, 1, "temp", AUTHOR_USER, listOf("x"))
        service.flushWrites()
        assertEquals(1, store.load().notes.size)

        assertTrue(service.removeNote(note.id))
        service.flushWrites()

        assertTrue("deleted note stays deleted on disk", store.load().notes.isEmpty())
        assertTrue(service.isEmpty())

        service.clearAll()
        service.flushWrites()
    }
}
