package dev.shosai.shosai_flutter

import java.io.File

internal data class ProviderResource(
    val file: File,
    val ownerId: String,
    var inUse: Boolean = false,
)

/** Tracks native cleanup ownership independently of any Activity or Flutter engine. */
internal class ResourceOwnership {
    private val resources = mutableMapOf<String, ProviderResource>()
    private val pendingCleanup = mutableSetOf<String>()

    @Synchronized
    fun restore(token: String, file: File) {
        if (resources.containsKey(token)) return
        resources[token] = ProviderResource(file, "")
        pendingCleanup.add(token)
    }

    @Synchronized
    fun register(token: String, file: File, ownerId: String) {
        resources[token] = ProviderResource(file, ownerId)
    }

    @Synchronized
    fun beginUse(ownerId: String, token: String): Boolean {
        val resource = resources[token] ?: return false
        if (resource.ownerId != ownerId || pendingCleanup.contains(token)) return false
        resource.inUse = true
        return true
    }

    @Synchronized
    fun requestRelease(token: String): ProviderResource? {
        val resource = resources[token] ?: return null
        resource.inUse = false
        pendingCleanup.add(token)
        return resource
    }

    @Synchronized
    fun abandonOwner(ownerId: String): List<Pair<String, ProviderResource>> =
        resources
            .filterValues { it.ownerId == ownerId }
            .map { (token, resource) ->
                pendingCleanup.add(token)
                token to resource
            }
            .filter { (_, resource) -> !resource.inUse }

    @Synchronized
    fun retryable(): List<Pair<String, ProviderResource>> =
        pendingCleanup.mapNotNull { token ->
            resources[token]
                ?.takeUnless { it.inUse }
                ?.let { token to it }
        }

    @Synchronized
    fun removed(token: String, resource: ProviderResource) {
        if (resources[token] == resource) {
            resources.remove(token)
            pendingCleanup.remove(token)
        }
    }

    @Synchronized
    fun pendingCount(): Int = pendingCleanup.size
}
