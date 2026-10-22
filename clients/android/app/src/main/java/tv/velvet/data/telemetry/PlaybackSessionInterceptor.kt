package tv.velvet.data.telemetry

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Response

/** Network interceptor: re-check every redirect, not merely the initial request. */
internal class PlaybackSessionInterceptor(private val backendUrl: () -> String) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val safeRequest = if (allowsAttribution(backendUrl(), request.url)) request
            else request.newBuilder().removeHeader(HEADER).build()
        return chain.proceed(safeRequest)
    }

    companion object {
        const val HEADER = "X-Velvet-Playback-Session"
        internal fun allowsAttribution(configuredBackend: String, request: HttpUrl): Boolean {
            val backend = configuredBackend.toHttpUrlOrNull() ?: return false
            val parts = request.pathSegments
            return backend.scheme == request.scheme && backend.host == request.host && backend.port == request.port &&
                parts.size >= 2 && parts[parts.lastIndex - 1] == "stream" && parts.last().isNotBlank()
        }
    }
}
