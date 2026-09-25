package one.bitby.incomm

import one.bitby.incomm.model.AUTHOR_AGENT
import one.bitby.incomm.model.AUTHOR_USER
import one.bitby.incomm.model.Note
import one.bitby.incomm.model.NotesFile
import one.bitby.incomm.model.SCHEMA_VERSION
import one.bitby.incomm.store.IncompatibleFormatException
import one.bitby.incomm.store.NotesStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
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

    private fun storeWith(fixture: String, name: String): Pair<NotesStore, File> {
        val root = tmp.newFolder(name)
        File(root, ".incomm").mkdirs()
        val target = File(root, ".incomm/notes.json")
        target.writeText(File(AnchoringTest.fixturesDir("."), fixture).readText())
        return NotesStore(root.toPath()) to target
    }

    @Test
    fun aNewerFormatIsRefusedEvenWhenItsShapeIsUnreadable() {
        // notes.future.json has a "notes" object where an array is expected, so a
        // plain decode would fail: it must still be reported as a version problem.
        val (store, target) = storeWith("notes.future.json", "future")
        val before = target.readText()

        val e = assertThrows(IncompatibleFormatException::class.java) { store.load() }
        assertEquals(99, e.found)
        assertEquals(SCHEMA_VERSION, e.supported)
        assertTrue(e.message!!.contains(".incomm/notes.json is format v99"))
        assertTrue(e.message!!.contains("understands up to v2"))
        assertEquals("refusing must leave the file untouched", before, target.readText())
    }

    @Test
    fun aV1FileLoadsAndIsStampedWithTheCurrentVersionOnSave() {
        val (store, target) = storeWith("notes.sample.json", "v1")
        val loaded = store.load()
        assertEquals(1, loaded.version)
        assertEquals(3, loaded.notes.size)

        store.save(loaded)
        assertEquals(SCHEMA_VERSION, store.load().version)
        assertTrue(target.readText().contains("\"version\": $SCHEMA_VERSION"))
    }

    @Test
    fun savingWritesTheDefaultAudienceOnEveryNoteAndReply() {
        val (store, target) = storeWith("notes.sample.json", "explicit")
        val loaded = store.load()
        // The v1 fixture has no audience anywhere; it is read as agent...
        assertTrue(loaded.notes.all { it.audience == "agent" && it.replies.all { r -> r.audience == "agent" } })

        store.save(loaded)
        // ...and now says so in the file: one field per note and per reply.
        val text = target.readText()
        val replies = loaded.notes.sumOf { it.replies.size }
        assertEquals(loaded.notes.size + replies, Regex("\"audience\": \"agent\"").findAll(text).count())
    }

    @Test
    fun aV2FileRoundTripsAudienceAndSource() {
        val (store, target) = storeWith("notes.v2.sample.json", "v2")
        val loaded = store.load()
        val imported = loaded.find("a1000002")!!
        assertEquals("agent+external", imported.audience)
        assertEquals(501L, imported.source!!.id)
        assertEquals("9f8e7d6c5b4a", imported.source!!.thread)
        // The fixture leaves it out; absent is read as agent.
        assertEquals("agent", loaded.find("a1000001")!!.audience)
        assertEquals("external", loaded.find("a1000001")!!.replies[0].audience)

        store.save(loaded)
        val again = store.load()
        assertEquals("agent+external", again.find("a1000002")!!.audience)
        assertEquals(502L, again.find("a1000002")!!.replies[0].source!!.id)
        assertEquals("private", again.find("a1000003")!!.audience)
        assertEquals("agent", again.find("a1000003")!!.replies[0].audience)
        val text = target.readText()
        // The default is written out, not left for the reader to guess; an unset source stays out.
        assertTrue(text.substringAfter("\"a1000001\"").substringBefore("\"a1000002\"").contains("\"audience\": \"agent\""))
        assertFalse(text.substringAfter("\"a1000001\"").substringBefore("\"a1000002\"").contains("\"source\""))
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
