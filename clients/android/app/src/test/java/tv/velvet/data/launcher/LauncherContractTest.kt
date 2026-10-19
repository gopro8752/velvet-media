package tv.velvet.data.launcher

import org.junit.Assert.*
import org.junit.Test
import tv.velvet.data.model.MediaItem
import tv.velvet.data.model.MediaType
import kotlinx.serialization.json.Json

class LauncherContractTest {
    @Test fun `resume requires current profile and exact media identity`() {
        val request = LauncherRequest.validated("resume", "default", 1434, "show", 1, 5)!!
        assertEquals(1434, request.mediaId)
        assertEquals(1, request.season)
        assertEquals(5, request.episode)
        assertNull(LauncherRequest.validated("resume", null, 1434, "show", 1, 5))
        assertNull(LauncherRequest.validated("resume", "default", -1, "show", 1, 5))
        assertNull(LauncherRequest.validated("resume", "default", 1434, "anything", 1, 5))
        assertNull(LauncherRequest.validated("resume", "default", 1434, "movie", 1, 5))
        assertNull(LauncherRequest.validated("resume", "default", 1434, "show", 1, null))
        assertNull(LauncherRequest.validated("resume", "default", 1434, "show", -1, 5))
        assertNull(LauncherRequest.validated("resume", "default", 1434, "show", 1, 0))
    }

    @Test fun `destinations cannot inject routes or smuggle media into tab links`() {
        for (destination in listOf("home", "search", "live", "sports", "create", "profiles")) {
            assertNotNull(LauncherRequest.validated(destination, null))
            assertNull(LauncherRequest.validated(destination, "default", 42, "movie"))
            assertNull(LauncherRequest.validated(destination, "default", category = "other"))
        }
        for (destination in listOf("player/movie/42", "https://example.com/stream", "", "home?resume=42")) {
            assertNull(LauncherRequest.validated(destination, "default"))
        }
    }

    @Test fun `category actions preserve ordered or shuffled intent and require profile`() {
        val ordered = LauncherRequest.validated("category", "default", category = "halloween")!!
        val shuffled = LauncherRequest.validated("category", "default", category = "halloween", shuffle = true)!!
        assertFalse(ordered.shuffle)
        assertTrue(shuffled.shuffle)
        assertNotEquals(ordered.id, shuffled.id)
        assertNull(LauncherRequest.validated("category", null, category = "halloween"))
        assertNull(LauncherRequest.validated("category", "default", category = ""))
        assertNull(LauncherRequest.validated("category", "default", category = "x".repeat(201)))
    }

    @Test fun `public metadata cannot export playback identity or image credentials`() {
        val item = MediaItem(42, MediaType.MOVIE, "Movie", posterUrl = "https://image.tmdb.org/t/p/w500/poster.jpg",
            backdropUrl = "https://secret:password@image.tmdb.org/t/p/w1280/backdrop.jpg",
            logoUrl = "https://image.tmdb.org/t/p/w500/logo.png?api_key=secret", imdbId = "tt1234567")
        val title = item.launcherTitle()
        assertNotNull(title.posterUrl)
        assertNull(title.backdropUrl)
        assertNull(title.logoUrl)
        val encoded = Json.encodeToString(LauncherTitle.serializer(), title)
        assertFalse(encoded.contains("password"))
        assertFalse(encoded.contains("secret"))
        assertFalse(encoded.contains("tt1234567"))
        assertFalse(encoded.contains("imdbId"))
        assertNull(launcherImage("file:///data/data/tv.velvet/settings"))
        assertNull(launcherImage("https://image.tmdb.org.attacker.test/t/p/image.jpg"))
        assertNull(launcherImage("http://image.tmdb.org/t/p/image.jpg"))
        assertNull(launcherImage("https://image.tmdb.org/t/p/image.jpg#token"))
    }

    @Test fun `only incoming Home handles create during a navigation crossfade`() {
        val create = LauncherRequest.validated("create", "default")!!
        val pending = LauncherHomeRequest("incoming-home", create)
        assertNull(pending.forEntry("outgoing-home"))
        assertNull(pending.forEntry("search"))
        assertEquals(create, pending.forEntry("incoming-home"))
    }

    @Test fun `consuming old navigation cannot erase a newer request`() {
        val older = LauncherRequest.validated("home", null)!!
        val newer = LauncherRequest.validated("search", null)!!
        LauncherNavigation.submit(older)
        LauncherNavigation.submit(newer)
        LauncherNavigation.consume(older.id)
        assertEquals(newer.id, LauncherNavigation.request.value?.id)
        LauncherNavigation.consume(newer.id)
        assertNull(LauncherNavigation.request.value)
    }
}
