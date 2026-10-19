package tv.velvet.data.tmdb

import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import tv.velvet.data.settings.VelvetSettings
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class TmdbMetadataRequestTest {
    private val settings = VelvetSettings(
        tmdbApiKey = "local-key-that-must-stay-local",
        streamSources = emptyList(),
        rowOrder = emptyList(),
        autoplayNext = true,
        autoplayCountdownSecs = 8,
        preferredQuality = "2160p",
        tunneledPlayback = false,
        backendUrl = "https://backend.example.test/velvet/",
        syncToken = " app-token ",
    )

    @Test fun backendOwnsCredentialsAndPreservesEndpointAndDiscoveryQuery() {
        val request = tmdbMetadataRequest(settings, "discover/movie", mapOf(
            "with_genres" to "28|12", "page" to "2", "api_key" to "injected-key",
            "API_KEY" to "another-key", "access_token" to "upstream-token",
        ))
        assertEquals("https", request.url.scheme)
        assertEquals("backend.example.test", request.url.host)
        assertEquals("/velvet/metadata/tmdb/discover/movie", request.url.encodedPath)
        assertEquals("28|12", request.url.queryParameter("with_genres"))
        assertEquals("2", request.url.queryParameter("page"))
        assertEquals("en-US", request.url.queryParameter("language"))
        assertEquals("Bearer app-token", request.header("Authorization"))
        assertNull(request.url.queryParameter("api_key"))
        assertNull(request.url.queryParameter("API_KEY"))
        assertNull(request.url.queryParameter("access_token"))
        assertFalse(request.url.toString().contains(settings.tmdbApiKey))
        assertFalse(request.url.toString().contains("app-token"))
    }

    @Test fun settingsChangesRouteTheNextRequestToTheNewBackendWithItsCurrentToken() {
        val first = tmdbMetadataRequest(settings, "tv/123/season/2", emptyMap())
        val next = tmdbMetadataRequest(settings.copy(
            backendUrl = "http://media-server.local:8799",
            syncToken = "replacement-token",
            tmdbApiKey = "",
        ), "search/multi", mapOf("query" to "A & B", "language" to "fr-FR"))
        assertEquals("backend.example.test", first.url.host)
        assertEquals("media-server.local", next.url.host)
        assertEquals("/metadata/tmdb/search/multi", next.url.encodedPath)
        assertEquals("A & B", next.url.queryParameter("query"))
        assertEquals(listOf("fr-FR"), next.url.queryParameterValues("language"))
        assertEquals("Bearer replacement-token", next.header("Authorization"))
        assertNull(next.url.queryParameter("api_key"))
    }

    @Test fun publicBackendNeedsNeitherADeviceKeyNorAnAuthHeader() {
        val request = tmdbMetadataRequest(settings.copy(tmdbApiKey = "", syncToken = ""),
            "movie/123", mapOf("append_to_response" to "external_ids,images"))
        assertNull(request.header("Authorization"))
        assertNull(request.url.queryParameter("api_key"))
        assertEquals("external_ids,images", request.url.queryParameter("append_to_response"))
    }

    @Test fun standaloneBrowsingUsesOnlyTheExplicitLocalKeyAndNeverTheBackendToken() {
        val request = tmdbMetadataRequest(settings.copy(backendUrl = ""), "movie/123", emptyMap())
        assertEquals("api.themoviedb.org", request.url.host)
        assertEquals("/3/movie/123", request.url.encodedPath)
        assertEquals(settings.tmdbApiKey, request.url.queryParameter("api_key"))
        assertNull(request.header("Authorization"))
        assertThrows(IOException::class.java) {
            tmdbMetadataRequest(settings.copy(backendUrl = "", tmdbApiKey = ""), "movie/123", emptyMap())
        }
    }

    @Test fun invalidConfiguredBackendCannotFallBackToTheLocalKey() {
        for (backend in listOf("invalid", "ftp://example.test", "https://user:secret@example.test",
            "https://example.test?api_key=secret", "https://example.test#fragment")) {
            assertThrows(IOException::class.java) {
                tmdbMetadataRequest(settings.copy(backendUrl = backend), "movie/123", emptyMap())
            }
        }
    }

    @Test fun onlyRelativeMetadataPathsAreAccepted() {
        for (path in listOf("https://other.example.test/movie", "../movie/123", "movie/123?api_key=secret", "")) {
            assertThrows(IllegalArgumentException::class.java) {
                tmdbMetadataRequest(settings, path, emptyMap())
            }
        }
    }

    @Test fun serverRedirectsCannotBypassTheBackendOrForwardItsToken() {
        val destinationCalls = AtomicInteger()
        val originToken = AtomicReference<String>()
        val destination = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val origin = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val servers = Executors.newFixedThreadPool(2)
        servers.submit {
            destination.accept().use { socket ->
                socket.readRequestHeaders()
                destinationCalls.incrementAndGet()
                socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
            }
        }
        val originResponse = servers.submit {
            origin.accept().use { socket ->
                originToken.set(socket.readRequestHeaders()
                    .first { it.startsWith("Authorization:", ignoreCase = true) }
                    .substringAfter(':').trim())
                socket.getOutputStream().write((
                    "HTTP/1.1 302 Found\r\n" +
                        "Location: http://127.0.0.1:${destination.localPort}/movie/123\r\n" +
                        "Content-Length: 0\r\nConnection: close\r\n\r\n"
                    ).toByteArray())
            }
        }
        try {
            val request = tmdbMetadataRequest(settings.copy(
                backendUrl = "http://127.0.0.1:${origin.localPort}",
            ), "movie/123", emptyMap())
            tmdbMetadataClient(OkHttpClient()).newCall(request).execute().use { response ->
                assertEquals(302, response.code)
            }
            originResponse.get(5, TimeUnit.SECONDS)
            assertEquals("Bearer app-token", originToken.get())
            assertEquals(0, destinationCalls.get())
        } finally {
            origin.close()
            destination.close()
            servers.shutdownNow()
        }
    }

    private fun Socket.readRequestHeaders(): List<String> {
        soTimeout = 5_000
        val reader = getInputStream().bufferedReader()
        return generateSequence { reader.readLine() }.takeWhile { it.isNotEmpty() }.toList()
    }
}
