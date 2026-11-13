package tv.velvet.data.streams

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import tv.velvet.data.model.StreamOption

class MovieReleaseBlocksTest {
    private fun stream(url: String, title: String = "Movie.2160p-GROUP") =
        StreamOption(url, title, sourceName = "Velvet Backend", bingeGroup = "velvet-group")

    @Test fun velvetReleaseSurvivesRefreshedTokensBackendAddressAndMobileAudioAdapter() {
        val original = stream("https://backend.test/stream/0123456789abcdef?token=old")
        val key = original.movieReleaseKeyForBlocking()!!
        assertEquals("velvet:0123456789abcdef", key)
        assertTrue(stream("http://192.0.2.1:8799/stream/0123456789abcdef?token=new")
            .isMovieReleaseBlocked(listOf(key)))
        assertTrue(stream("https://backend.test/stream/0123456789abcdef/audio/0.wav?playbackSessionId=new")
            .isMovieReleaseBlocked(listOf(key)))
    }

    @Test fun anotherReleaseFromTheSameGroupAndSameDisplayTitleRemainsAvailable() {
        val first = stream("https://backend.test/stream/0123456789abcdef")
        val other = stream("https://backend.test/stream/0123456789abcdee")
        assertFalse(other.isMovieReleaseBlocked(listOf(first.movieReleaseKeyForBlocking()!!)))
    }

    @Test fun addonTokenRefreshKeepsIdentityButContentQueryIsPreserved() {
        val first = stream("https://addon.test/play?video=abc&token=old&expires=123")
        val key = first.movieReleaseKeyForBlocking()!!
        assertTrue(stream("https://addon.test/play?video=abc&token=new&expires=456")
            .isMovieReleaseBlocked(listOf(key)))
        assertFalse(stream("https://addon.test/play?video=other&token=new")
            .isMovieReleaseBlocked(listOf(key)))
        assertFalse(key.contains("addon.test"))
        assertEquals(68, key.length)
    }

    @Test fun noReleaseGroupOrReadableFilenameIsRequired() {
        val source = StreamOption("https://backend.test/stream/0123456789abcdef", "1080p", sourceName = "Addon")
        assertNotNull(source.movieReleaseKeyForBlocking())
        assertNull(source.copy(url = "not a playback URL").movieReleaseKeyForBlocking())
    }

    @Test fun blocksAreScopedToOneMovieAndResetRetainsOtherMovies() {
        val key = stream("https://backend.test/stream/0123456789abcdef").movieReleaseKeyForBlocking()!!
        val first = withBlockedMovieRelease(emptyMap(), "tt1", key)
        assertEquals(listOf(key), blockedMovieReleasesForMovie(first, "tt1"))
        assertTrue(blockedMovieReleasesForMovie(first, "tt2").isEmpty())
        assertEquals(first, withBlockedMovieRelease(first, "tt1", key))
        val both = withBlockedMovieRelease(first, "tt2", key)
        assertEquals(mapOf("tt2" to listOf(key)), withoutBlockedMovieReleases(both, "tt1"))
        assertEquals(first, withBlockedMovieRelease(first, "", key))
        assertEquals(first, withBlockedMovieRelease(first, "tt2", "https://secret.test/token"))
    }

    @Test fun durableIdentityRoundTripsWithoutSourceUrlsOrCredentials() {
        val key = stream("https://backend.test/stream/0123456789abcdef?token=credential").movieReleaseKeyForBlocking()!!
        val blocks = withBlockedMovieRelease(emptyMap(), "tt1", key)
        val serializer = MapSerializer(String.serializer(), ListSerializer(String.serializer()))
        val encoded = Json.encodeToString(serializer, blocks)
        assertFalse(encoded.contains("credential"))
        assertFalse(encoded.contains("backend.test"))
        assertEquals(blocks, Json.decodeFromString(serializer, encoded))
    }
}
