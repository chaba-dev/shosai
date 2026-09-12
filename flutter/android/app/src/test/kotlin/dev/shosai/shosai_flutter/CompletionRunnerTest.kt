package dev.shosai.shosai_flutter

import java.io.File
import java.util.ArrayDeque
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CompletionRunnerTest {
    @Test
    fun `resource release publishes debt before off-thread deletion and completes once`() {
        val worker = QueuedExecutor()
        val completion = QueuedExecutor()
        val runner = CompletionRunner(worker, completion)
        val ownership = ResourceOwnership()
        ownership.register("token", File("resource"), "owner")
        var completions = 0
        val releaser = ResourceReleaser(ownership, runner) { false }

        releaser.release("token") { removed ->
            assertTrue(!removed)
            completions += 1
        }

        assertEquals(1, ownership.pendingCount())
        assertEquals(0, completions)
        assertEquals(1, worker.size)
        worker.runNext()
        assertEquals(0, completions)
        assertEquals(0, worker.size)
        assertEquals(1, completion.size)
        completion.runNext()
        assertEquals(1, completions)
        assertEquals(0, completion.size)
        assertEquals(1, ownership.pendingCount())
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

    val size: Int
        get() = tasks.size
}
