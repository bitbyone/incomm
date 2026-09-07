package one.bitby.incomm

import com.google.gson.GsonBuilder
import one.bitby.incomm.model.*
import org.junit.Test
import org.junit.Assert.assertEquals
import java.nio.file.Paths
import kotlin.io.path.readText

class ScratchTest {
    @Test
    fun testGson() {
        val gson = GsonBuilder().setPrettyPrinting().disableHtmlEscaping().create()
        val text = Paths.get("/Users/toby/workspace/bitbyone/incomm/.incomm/notes_main.json").readText()
        val parsed1 = gson.fromJson(text, NotesFile::class.java).normalize()
        val saved = gson.toJson(parsed1) + "\n"
        val parsed2 = gson.fromJson(saved, NotesFile::class.java).normalize()
        
        assertEquals(parsed1, parsed2)
    }
}
