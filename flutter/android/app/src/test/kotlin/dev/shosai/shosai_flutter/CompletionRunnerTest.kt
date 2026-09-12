package dev.shosai.shosai_flutter

import java.io.File
import java.util.ArrayDeque
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CompletionRunnerTest {
    @Test
    fun `release debt precedes off-thread work and completes exactly once afterward`() {
        val worker = QueuedExecutor()
        val completion = QueuedExecutor()
        val runner = CompletionRunner(worker, completion)
        val ownership = ResourceOwnership()
        ownership.restore("token", File("resource"))
        val resource = ownership.requestRelease("token")!!
        var completions = 0

        runner.run(
            work = {
                assertEquals(1, ownership.pendingCount())
                false
            },
            complete = { removed ->
                assertTrue(!removed)
                completions += 1
            },
        )

        assertEquals(1, ownership.pendingCount())
        assertEquals(0, completions)
        worker.runNext()
        assertEquals(0, completions)
        completion.runNext()
        assertEquals(1, completions)
        assertEquals(resource, ownership.requestRelease("token"))
    }
}

private class QueuedExecutor : Executor {
    private val tasks = ArrayDeque<Runnable>()

    override fun execute(command: Runnable) {
        tasks.addLast(command)
    }

    fun runNext() {
        tasks.removeFirst().run()
    }
}
