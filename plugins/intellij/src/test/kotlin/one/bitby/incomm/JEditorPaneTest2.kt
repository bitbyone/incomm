package one.bitby.incomm

import org.junit.Test
import javax.swing.JEditorPane
import java.awt.Dimension

class JEditorPaneTest2 {
    @Test
    fun test() {
        val pane = object : JEditorPane("text/html", "<html><body>hello</body></html>") {
            override fun getPreferredSize(): Dimension {
                var w = width
                if (w <= 0 && parent != null && parent.width > 0) {
                    w = parent.width
                }
                if (w > 0) {
                    val view = (ui as? javax.swing.plaf.basic.BasicTextUI)?.getRootView(this)
                    if (view != null) {
                        view.setSize((w - insets.left - insets.right).toFloat(), Float.MAX_VALUE)
                        return Dimension(w, view.getPreferredSpan(javax.swing.text.View.Y_AXIS).toInt() + insets.top + insets.bottom)
                    }
                }
                return super.getPreferredSize()
            }
        }
        println("Success: ${pane.preferredSize}")
    }
}
