package dev.shosai.shosai_flutter

/** Fences one retained operation across configuration recreation and independent host takeover. */
internal class HostOperation<Result> {
    private var host: String? = null
    private var awaitingRecreation = false
    private var pending: Result? = null

    @Synchronized
    fun attach(hostId: String): Result? {
        val displaced = if (host != null && host != hostId && !awaitingRecreation) {
            pending.also { pending = null }
        } else {
            null
        }
        host = hostId
        awaitingRecreation = false
        return displaced
    }

    @Synchronized
    fun detach(hostId: String, recreating: Boolean): Result? {
        if (host != hostId) return null
        host = null
        awaitingRecreation = recreating
        return if (recreating) null else pending.also { pending = null }
    }

    @Synchronized
    fun start(hostId: String, result: Result): Boolean {
        if (host != hostId || pending != null) return false
        pending = result
        return true
    }

    @Synchronized
    fun take(hostId: String): Result? {
        if (host != hostId) return null
        return pending.also { pending = null }
    }
}
