package tv.velvet.data.streams

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import tv.velvet.data.model.StreamOption
import java.security.MessageDigest
import java.util.Locale

private val velvetReleasePath = Regex("(?:^|/)stream/([0-9a-f]{16})(?:/audio/[0-9]+\\.wav)?$")
private val credentialQueryNames = setOf(
    "token", "access_token", "auth", "authorization", "signature", "sig", "expires",
    "policy", "key-pair-id", "playbacksessionid",
)

/**
 * Block one release, never every movie from its release group. Velvet's content-derived
 * SID survives refreshed authorization, LAN/public URLs and the mobile audio adapter.
 * For other addons preserve content query parameters, removing only known credentials;
 * hash the remaining URL so secrets/URLs are never saved in the block preferences.
 */
fun StreamOption.movieReleaseKeyForBlocking(): String? {
    val parsed = url.toHttpUrlOrNull() ?: return null
    velvetReleasePath.find(parsed.encodedPath)?.let { return "velvet:${it.groupValues[1]}" }
    val canonical = parsed.newBuilder().username("").password("").fragment(null).apply {
        parsed.queryParameterNames.filter { it.lowercase(Locale.ROOT) in credentialQueryNames }
            .forEach(::removeAllQueryParameters)
    }.build().toString()
    val digest = MessageDigest.getInstance("SHA-256").digest(canonical.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
    return "url:$digest"
}

fun StreamOption.isMovieReleaseBlocked(keys: Collection<String>): Boolean =
    movieReleaseKeyForBlocking()?.let { it in keys } == true

fun blockedMovieReleasesForMovie(blocks: Map<String, List<String>>, imdbId: String?): List<String> =
    imdbId?.trim()?.takeIf(String::isNotEmpty)?.let { blocks[it] }.orEmpty()

internal fun withBlockedMovieRelease(
    blocks: Map<String, List<String>>, imdbId: String, key: String,
): Map<String, List<String>> {
    val movie = imdbId.trim().takeIf(String::isNotEmpty) ?: return blocks
    if (!key.matches(Regex("(?:velvet:[0-9a-f]{16}|url:[0-9a-f]{64})"))) return blocks
    return blocks + (movie to (blocks[movie].orEmpty() + key).distinct())
}

internal fun withoutBlockedMovieReleases(blocks: Map<String, List<String>>, imdbId: String) =
    blocks - imdbId.trim()
