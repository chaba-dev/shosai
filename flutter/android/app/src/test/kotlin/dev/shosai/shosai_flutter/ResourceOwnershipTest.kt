package dev.shosai.shosai_flutter

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ResourceOwnershipTest {
    @Test
    fun `cache discovery cannot replace a live resource lease`() {
        val ownership = ResourceOwnership()
        val live = File("live")
        ownership.register("token", live, "engine")

        ownership.restore("token", File("stale-cache-entry"))

        assertTrue(ownership.beginUse("engine", "token"))
        assertEquals(live, ownership.requestRelease("token")!!.file)
    }

    @Test
    fun `recreation reclaims delivered resources but preserves active consumers`() {
        val ownership = ResourceOwnership()
        val delivered = File("delivered")
        val consuming = File("consuming")
        ownership.register("delivered", delivered, "old-engine")
        ownership.register("consuming", consuming, "old-engine")
        assertTrue(ownership.beginUse("old-engine", "consuming"))

        val immediatelyRetryable = ownership.abandonOwner("old-engine")

        assertEquals(listOf("delivered"), immediatelyRetryable.map { it.first })
        assertEquals(2, ownership.pendingCount())
        assertEquals(listOf("delivered"), ownership.retryable().map { it.first })
        assertFalse(ownership.beginUse("old-engine", "delivered"))

        val released = ownership.requestRelease("consuming")!!
        ownership.removed("consuming", released)
        assertEquals(1, ownership.pendingCount())
    }

    @Test
    fun `failed cleanup remains owned until a later successful removal`() {
        val ownership = ResourceOwnership()
        val resource = File("pending")
        ownership.restore("pending", resource)

        assertEquals(resource, ownership.requestRelease("pending")!!.file)
        assertEquals(1, ownership.pendingCount())
        assertEquals(listOf("pending"), ownership.retryable().map { it.first })

        ownership.removed("pending", ownership.requestRelease("pending")!!)
        assertEquals(0, ownership.pendingCount())
        assertTrue(ownership.retryable().isEmpty())
    }
}
