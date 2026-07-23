package dev.incomm

import dev.incomm.model.AUTHOR_AGENT
import dev.incomm.model.AUTHOR_USER
import dev.incomm.model.Note
import dev.incomm.model.NotesFile
import dev.incomm.store.NotesStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class NotesStoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun parsesSharedSampleFixture() {
        val sample = File(AnchoringTest.fixturesDir("."), "notes.sample.json")
        val root = tmp.newFolder("proj")
        File(root, ".incomm").mkdirs()
        File(root, ".incomm/notes.json").writeText(sample.readText())

        val store = NotesStore(root.toPath())
        val file = store.load()

        assertEquals(1, file.version)
        assertEquals(3, file.notes.size)

        val n0 = file.find("c7f3a1b2")!!
        assertEquals("src/app/main.go", n0.file)
        assertEquals(12, n0.startLine)
        assertEquals(AUTHOR_USER, n0.author)
        assertEquals(1, n0.replies.size)
        assertEquals(AUTHOR_AGENT, n0.replies[0].author)

        assertTrue(file.find("d4e5f6a7")!!.resolved)
        assertTrue(file.find("e8f9a0b1")!!.orphaned)
    }

    @Test
    fun saveLoadRoundTripAtomic() {
        val root = tmp.newFolder("proj2")
        val store = NotesStore(root.toPath())

        // Missing file loads empty.
        assertTrue(store.load().notes.isEmpty())

        val f = NotesFile()
        f.notes.add(Note(id = "x1", file = "a.kt", startLine = 3, endLine = 3, author = AUTHOR_USER))
        store.save(f)

        // Only notes.json remains — no stray temp files.
        val leftovers = File(root, ".incomm").listFiles()!!.map { it.name }
        assertEquals(listOf("notes.json"), leftovers)

        val loaded = store.load()
        assertEquals(1, loaded.notes.size)
        assertEquals("x1", loaded.notes[0].id)
        assertNotNull(loaded.notes[0].replies)

        assertTrue(store.clear())
        assertFalse(File(root, ".incomm/notes.json").exists())
    }

    @Test
    fun relFileUsesPosixSeparators() {
        val root = tmp.newFolder("proj3")
        val store = NotesStore(root.toPath())
        val nested = File(root, "src/app/main.kt")
        assertEquals("src/app/main.kt", store.relFile(nested.toPath()))
    }

    @Test
    fun findAndRemove() {
        val f = NotesFile()
        f.notes.add(Note(id = "a"))
        f.notes.add(Note(id = "b"))
        assertNotNull(f.find("a"))
        assertTrue(f.remove("a"))
        assertNull(f.find("a"))
        assertFalse(f.remove("missing"))
    }
}
