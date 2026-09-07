package one.bitby.incomm

import one.bitby.incomm.model.*
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame

class ScratchTest2 {
    @Test
    fun testDeepCopyEquals() {
        val note = Note(id="1", author="agent")
        note.replies.add(Reply(id="r1", author="user"))
        val copy1 = note.deepCopy()
        val copy2 = note.deepCopy()
        assertEquals(copy1, copy2)
        assertNotSame(copy1, copy2)
    }
}
