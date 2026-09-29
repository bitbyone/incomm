package one.bitby.incomm

import one.bitby.incomm.model.AUDIENCE_AGENT
import one.bitby.incomm.model.AUDIENCE_BOTH
import one.bitby.incomm.model.AUDIENCE_EXTERNAL
import one.bitby.incomm.model.AUDIENCE_PRIVATE
import one.bitby.incomm.model.AUTHOR_AGENT
import one.bitby.incomm.model.AUTHOR_USER
import one.bitby.incomm.model.Audience
import one.bitby.incomm.model.Note
import one.bitby.incomm.model.Reply
import one.bitby.incomm.model.Source
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The audience logic the bubbles use; pure, so it runs without an IDE. */
class AudienceTest {

    @Test
    fun `the toggle steps agent, agent + external, external, private and back`() {
        assertEquals(AUDIENCE_BOTH, Audience.next(null))
        assertEquals(AUDIENCE_BOTH, Audience.next(AUDIENCE_AGENT))
        assertEquals(AUDIENCE_EXTERNAL, Audience.next(AUDIENCE_BOTH))
        assertEquals(AUDIENCE_PRIVATE, Audience.next(AUDIENCE_EXTERNAL))
        assertEquals(AUDIENCE_AGENT, Audience.next(AUDIENCE_PRIVATE))
    }

    @Test
    fun `absent means agent and an unknown value is private`() {
        assertEquals(AUDIENCE_AGENT, Audience.normalize(null))
        assertEquals(AUDIENCE_AGENT, Audience.normalize(""))
        assertEquals(AUDIENCE_PRIVATE, Audience.normalize("team"))
        // An unknown value is never shown as shared, and the toggle continues from private.
        assertEquals(AUDIENCE_AGENT, Audience.next("team"))
    }

    @Test
    fun `the default is stored as absent`() {
        assertEquals(AUDIENCE_AGENT, Audience.stored(AUDIENCE_AGENT))
        assertEquals(AUDIENCE_BOTH, Audience.stored(AUDIENCE_BOTH))
        assertEquals(AUDIENCE_PRIVATE, Audience.stored(AUDIENCE_PRIVATE))
    }

    @Test
    fun `everything under a private root is private whatever it stores`() {
        assertEquals(AUDIENCE_PRIVATE, Audience.effective(AUDIENCE_PRIVATE, AUDIENCE_BOTH))
        assertEquals(AUDIENCE_PRIVATE, Audience.effective(AUDIENCE_PRIVATE, null))
        assertEquals(AUDIENCE_PRIVATE, Audience.effective("team", AUDIENCE_EXTERNAL))
        assertEquals(AUDIENCE_BOTH, Audience.effective(null, AUDIENCE_BOTH))
        assertEquals(AUDIENCE_PRIVATE, Audience.effective(AUDIENCE_BOTH, AUDIENCE_PRIVATE))
        assertEquals(AUDIENCE_AGENT, Audience.effective(AUDIENCE_EXTERNAL, null))
    }

    @Test
    fun `which audiences include the agent and the forge`() {
        assertTrue(Audience.includesExternal(AUDIENCE_EXTERNAL))
        assertTrue(Audience.includesExternal(AUDIENCE_BOTH))
        assertFalse(Audience.includesExternal(null))
        assertFalse(Audience.includesExternal(AUDIENCE_PRIVATE))
        assertTrue(Audience.includesAgent(null))
        assertTrue(Audience.includesAgent(AUDIENCE_BOTH))
        assertFalse(Audience.includesAgent(AUDIENCE_EXTERNAL))
        assertFalse(Audience.includesAgent(AUDIENCE_PRIVATE))
    }

    @Test
    fun `every comment has a badge, and one that includes external says whether it was published`() {
        assertEquals("agent", Audience.badge(null, AUDIENCE_AGENT))
        assertEquals("agent", Audience.badge(Source(id = 1), AUDIENCE_AGENT))
        assertEquals("private", Audience.badge(null, AUDIENCE_PRIVATE))
        assertEquals("private", Audience.badge(Source(id = 1), AUDIENCE_PRIVATE))
        assertEquals("external · not published", Audience.badge(null, AUDIENCE_EXTERNAL))
        assertEquals("agent + external · not published", Audience.badge(null, AUDIENCE_BOTH))
        assertEquals("agent + external · published", Audience.badge(Source(url = "https://f/x", id = 7), AUDIENCE_BOTH))
        assertEquals("external · published", Audience.badge(Source(id = 7), AUDIENCE_EXTERNAL))
    }

    @Test
    fun `the tooltip says what a click does and why a reply reads private`() {
        assertEquals("Audience: agent - click to change to agent + external", Audience.tooltip(null, AUDIENCE_AGENT))
        assertEquals("Audience: private - click to change to agent", Audience.tooltip(AUDIENCE_PRIVATE, AUDIENCE_PRIVATE))
        assertEquals(
            "Audience: private (its thread is private) - click to change to external",
            Audience.tooltip(AUDIENCE_BOTH, AUDIENCE_PRIVATE),
        )
    }

    @Test
    fun `a new reply starts with the audience of its root`() {
        assertEquals(AUDIENCE_BOTH, Audience.inheritedByReply(AUDIENCE_BOTH))
        assertEquals(AUDIENCE_EXTERNAL, Audience.inheritedByReply(AUDIENCE_EXTERNAL))
        assertEquals(AUDIENCE_PRIVATE, Audience.inheritedByReply(AUDIENCE_PRIVATE))
        assertEquals(AUDIENCE_AGENT, Audience.inheritedByReply(AUDIENCE_AGENT))
        assertEquals("a root that says nothing is agent", AUDIENCE_AGENT, Audience.inheritedByReply(null))
        assertEquals(AUDIENCE_AGENT, Audience.inheritedByReply(""))
    }

    @Test
    fun `a private root shows every reply as private and restoring gives their own back`() {
        val stored = listOf(AUDIENCE_AGENT, AUDIENCE_BOTH, AUDIENCE_EXTERNAL, AUDIENCE_PRIVATE, null)
        for (own in stored) {
            assertEquals("under a private root", AUDIENCE_PRIVATE, Audience.effective(AUDIENCE_PRIVATE, own))
            // Nothing was rewritten, so a root that is no longer private restores each one.
            assertEquals(Audience.normalize(own), Audience.effective(AUDIENCE_BOTH, own))
            assertEquals(Audience.normalize(own), Audience.effective(AUDIENCE_AGENT, own))
        }
    }

    @Test
    fun `a published comment only flips between agent + external and external`() {
        val note = Note(
            id = "n1", audience = AUDIENCE_AGENT,
            replies = mutableListOf(
                Reply(id = "r1", audience = AUDIENCE_BOTH, source = Source(id = 501)),
                Reply(id = "r2", audience = AUDIENCE_AGENT),
            ),
        )
        val published = Audience.cycleFor(note, "r1")
        assertEquals(listOf(AUDIENCE_BOTH, AUDIENCE_EXTERNAL), published)
        assertEquals(AUDIENCE_EXTERNAL, Audience.next(AUDIENCE_BOTH, published))
        assertEquals(AUDIENCE_BOTH, Audience.next(AUDIENCE_EXTERNAL, published))
        assertEquals(AUDIENCE_EXTERNAL, Audience.previous(AUDIENCE_BOTH, published))
        assertEquals("an older file's agent moves on into the cycle", AUDIENCE_BOTH, Audience.next(AUDIENCE_AGENT, published))
        assertFalse(Audience.allowed(note, "r1", AUDIENCE_AGENT))
        assertFalse(Audience.allowed(note, "r1", AUDIENCE_PRIVATE))

        // The root may be anything but private: that would hide the published reply.
        assertEquals(listOf(AUDIENCE_AGENT, AUDIENCE_BOTH, AUDIENCE_EXTERNAL), Audience.cycleFor(note, null))
        assertEquals(AUDIENCE_AGENT, Audience.next(AUDIENCE_EXTERNAL, Audience.cycleFor(note, null)))
        // An unpublished reply keeps the full cycle.
        assertEquals(Audience.CYCLE, Audience.cycleFor(note, "r2"))
        assertEquals(listOf(Audience.CYCLE.take(3), published, Audience.CYCLE), Audience.rows(note).map { it.cycle })

        // The root published itself.
        assertEquals(published, Audience.cycleFor(Note(id = "n2", source = Source(url = "https://f/x")), null))
        assertEquals(
            "Audience: agent + external - click to change to external",
            Audience.tooltip(AUDIENCE_BOTH, AUDIENCE_BOTH, published),
        )
    }

    @Test
    fun `a bubble is the agent's colour for the agent, and says who sees your own`() {
        for (a in Audience.CYCLE) assertEquals("the author wins", AUTHOR_AGENT, Audience.tone(AUTHOR_AGENT, a))
        assertEquals(AUTHOR_USER, Audience.tone(AUTHOR_USER, AUDIENCE_AGENT))
        assertEquals("absent is agent", AUTHOR_USER, Audience.tone(AUTHOR_USER, null))
        assertEquals(AUDIENCE_EXTERNAL, Audience.tone(AUTHOR_USER, AUDIENCE_BOTH))
        assertEquals(AUDIENCE_EXTERNAL, Audience.tone(AUTHOR_USER, AUDIENCE_EXTERNAL))
        assertEquals(AUDIENCE_PRIVATE, Audience.tone(AUTHOR_USER, AUDIENCE_PRIVATE))
        assertEquals("an unknown audience is private", AUDIENCE_PRIVATE, Audience.tone(AUTHOR_USER, "team"))
    }

    @Test
    fun `previous undoes next and wraps round`() {
        for (a in Audience.CYCLE) assertEquals(a, Audience.previous(Audience.next(a)))
        assertEquals(AUDIENCE_PRIVATE, Audience.previous(null))
        assertEquals(AUDIENCE_AGENT, Audience.previous(AUDIENCE_BOTH))
        assertEquals("an unknown value counts as private", AUDIENCE_EXTERNAL, Audience.previous("team"))
    }

    @Test
    fun `the dialog lists the root then each reply with what it stores`() {
        val note = Note(
            id = "n1", author = AUTHOR_USER, authorTitle = "Jan", content = "root",
            audience = AUDIENCE_PRIVATE, source = Source(id = 1),
            replies = mutableListOf(
                Reply(id = "r1", author = AUTHOR_AGENT, content = "answer", audience = AUDIENCE_BOTH),
                Reply(id = "r2", author = AUTHOR_USER, content = "mine", audience = AUDIENCE_PRIVATE),
                Reply(id = "r3", author = AUTHOR_AGENT, content = "old", audience = null),
            ),
        )
        val rows = Audience.rows(note)
        assertEquals(listOf(null, "r1", "r2", "r3"), rows.map { it.replyId })
        assertEquals(listOf(AUDIENCE_PRIVATE, AUDIENCE_BOTH, AUDIENCE_PRIVATE, AUDIENCE_AGENT), rows.map { it.audience })
        assertEquals(
            "a reply is private through its root unless it is private itself",
            listOf(false, true, false, true),
            rows.map { it.inherited },
        )
        assertEquals(listOf(true, false, false, false), rows.map { it.published })
        assertEquals("root", rows[0].content)

        note.audience = AUDIENCE_EXTERNAL
        assertTrue(Audience.rows(note).none { it.inherited })
    }
}
