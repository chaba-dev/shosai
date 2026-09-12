package dev.shosai.shosai_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostOperationTest {
    @Test
    fun `configuration recreation transfers the pending operation`() {
        val operation = HostOperation<String>()
        operation.attach("old")
        assertTrue(operation.start("old", "result"))

        assertNull(operation.detach("old", recreating = true))
        assertNull(operation.attach("replacement"))

        assertEquals("result", operation.take("replacement"))
    }

    @Test
    fun `independent takeover settles the old operation and fences stale hosts`() {
        val operation = HostOperation<String>()
        operation.attach("old")
        assertTrue(operation.start("old", "old-result"))

        assertEquals("old-result", operation.attach("new"))
        assertNull(operation.detach("old", recreating = false))
        assertNull(operation.take("old"))
        assertTrue(operation.start("new", "new-result"))
        assertFalse(operation.start("new", "duplicate"))
        assertEquals("new-result", operation.take("new"))
    }
}
