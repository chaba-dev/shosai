package dev.shosai.shosai_flutter

/** Publishes release debt before scheduling deletion and completes after the attempt. */
internal class ResourceReleaser(
    private val ownership: ResourceOwnership,
    private val runner: CompletionRunner,
    private val delete: (ProviderResource) -> Boolean,
) {
    fun release(token: String, complete: (Boolean) -> Unit) {
        val resource = ownership.requestRelease(token)
        if (resource == null) {
            complete(true)
            return
        }
        runner.run(
            work = {
                val removed = delete(resource)
                if (removed) ownership.removed(token, resource)
                removed
            },
            complete = complete,
        )
    }
}
