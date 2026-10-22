package tv.velvet.data.telemetry

import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

class PlaybackSessionInterceptorTest {
    @Test fun attributionRequiresTheConfiguredOriginAndAnActualStreamRoute() {
        val backend = "https://backend.example/prefix/manifest.json"
        assertTrue(PlaybackSessionInterceptor.allowsAttribution(backend,
            "https://backend.example/prefix/stream/123?token=opaque".toHttpUrl()))
        for (url in listOf("http://backend.example/stream/123", "https://backend.example:444/stream/123",
            "https://cdn.example/stream/123", "https://backend.example/tmdb/movie/123",
            "https://backend.example/stream/123/health", "https://backend.example/stream/")) {
            assertFalse(url, PlaybackSessionInterceptor.allowsAttribution(backend, url.toHttpUrl()))
        }
    }

    @Test fun crossOriginRedirectNeverReceivesTheWatchIdentity() {
        val receivedFirst = CompletableFuture<String>()
        val receivedRedirect = CompletableFuture<String>()
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { origin ->
            ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { redirected ->
                val source = "http://127.0.0.1:${origin.localPort}"
                val target = "http://127.0.0.1:${redirected.localPort}/stream/destination"
                fun serve(server: ServerSocket, received: CompletableFuture<String>, response: String) = Thread {
                    try {
                        server.soTimeout = 5_000
                        server.accept().use { socket ->
                            socket.soTimeout = 5_000
                            val reader = socket.getInputStream().bufferedReader()
                            val headers = buildString {
                                while (true) {
                                    val line = reader.readLine() ?: break
                                    if (line.isEmpty()) break
                                    appendLine(line)
                                }
                            }
                            received.complete(headers)
                            socket.getOutputStream().write(response.toByteArray())
                        }
                    } catch (error: Throwable) { received.completeExceptionally(error) }
                }.apply { isDaemon = true; start() }
                val first = serve(origin, receivedFirst,
                    "HTTP/1.1 302 Found\r\nLocation: $target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                val second = serve(redirected, receivedRedirect,
                    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                val client = OkHttpClient.Builder().callTimeout(5, TimeUnit.SECONDS)
                    .addNetworkInterceptor(PlaybackSessionInterceptor { source }).build()
                client.newCall(Request.Builder().url("$source/stream/original")
                    .header(PlaybackSessionInterceptor.HEADER, "private-watch-id").build()).execute().use {
                    assertEquals(200, it.code)
                }
                assertTrue(receivedFirst.get(5, TimeUnit.SECONDS).contains("private-watch-id"))
                assertFalse(receivedRedirect.get(5, TimeUnit.SECONDS).contains("private-watch-id"))
                first.join(1000); second.join(1000)
                client.connectionPool.evictAll()
                client.dispatcher.executorService.shutdown()
            }
        }
    }
}
