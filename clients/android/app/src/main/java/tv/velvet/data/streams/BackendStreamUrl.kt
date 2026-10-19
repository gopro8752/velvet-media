package tv.velvet.data.streams

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * A remotely reached Velvet backend can still advertise its configured LAN address.
 * Registered streams belong to that same backend, so use the address this device
 * successfully queried. Other add-ons, public CDNs and non-stream paths stay intact.
 */
internal fun backendStreamPlaybackUrl(raw: String, queriedSource: String, configuredBackend: String): String {
    val backend = backendBase(configuredBackend) ?: return raw
    val source = backendBase(queriedSource) ?: return raw
    if (source != backend) return raw
    val advertised = raw.toHttpUrlOrNull() ?: return raw
    if (advertised.username.isNotEmpty() || advertised.password.isNotEmpty() ||
        !isLanHost(advertised.host)) return raw

    val prefix = backend.encodedPath.trimEnd('/')
    // Accept only the backend's opaque registered-stream route, either rooted or
    // already carrying this device's configured reverse-proxy prefix.
    val route = advertised.encodedPath.let { path ->
        when {
            registeredStreamPath.matches(path) -> path
            prefix.isNotEmpty() && path.startsWith("$prefix/") -> path.removePrefix(prefix)
            else -> return raw
        }
    }
    if (!registeredStreamPath.matches(route)) return raw
    return backend.newBuilder()
        .encodedPath(prefix + route)
        .encodedQuery(advertised.encodedQuery)
        .encodedFragment(advertised.encodedFragment)
        .build().toString()
}

private val registeredStreamPath = Regex("/stream/[0-9a-f]{16}")

private fun backendBase(raw: String): HttpUrl? {
    val clean = raw.trim().trimEnd('/').removeSuffix("/manifest.json").trimEnd('/')
    val url = clean.toHttpUrlOrNull() ?: return null
    if (url.username.isNotEmpty() || url.password.isNotEmpty() || url.query != null || url.fragment != null) return null
    return url
}

/** Literal address checks only: no DNS lookup or assumption about a public host. */
private fun isLanHost(host: String): Boolean {
    if (host == "localhost" || host.endsWith(".localhost") || host.endsWith(".local") ||
        host == "::1" || host == "::" || host == "0.0.0.0") return true
    if (':' in host) {
        val first = host.substringBefore(':').toIntOrNull(16) ?: return false
        return first in 0xfc00..0xfdff || first in 0xfe80..0xfebf
    }
    val octets = host.split('.').map { it.toIntOrNull() ?: return false }
    if (octets.size != 4 || octets.any { it !in 0..255 }) return false
    return octets[0] == 10 || octets[0] == 127 ||
        (octets[0] == 172 && octets[1] in 16..31) ||
        (octets[0] == 192 && octets[1] == 168) ||
        (octets[0] == 169 && octets[1] == 254) ||
        (octets[0] == 100 && octets[1] in 64..127)
}
