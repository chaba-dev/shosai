package dev.shosai.shosai_flutter

import java.util.concurrent.Executor

/** Runs blocking provider work away from the platform thread and posts one completion. */
internal class CompletionRunner(
    private val worker: Executor,
    private val completion: Executor,
) {
    fun <Value> run(work: () -> Value, complete: (Value) -> Unit) {
        worker.execute {
            val value = work()
            completion.execute { complete(value) }
        }
    }
}
