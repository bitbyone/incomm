package one.bitby.incomm

import org.junit.Test
import com.intellij.ui.components.JBTextArea

class JBTextAreaTest {
    @Test
    fun test() {
        val area = JBTextArea("this is a very long text that goes on and on and on and on without any line breaks").apply {
            lineWrap = true
            wrapStyleWord = true
            rows = 0
            columns = 0
        }
        println("Preferred size: ${area.preferredSize}")
    }
}
