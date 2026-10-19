package tv.velvet.data.streams

import org.junit.Assert.assertEquals
import org.junit.Test

class BackendStreamUrlTest {
    private val route = "/stream/0123456789abcdef"
    private val public = "https://velvet.example.test"
    private fun url(raw: String, source: String = public, backend: String = public) =
        backendStreamPlaybackUrl(raw, source, backend)

    @Test fun remoteBackendUsesConfiguredOriginAndPreservesOpaqueQuery() {
        assertEquals("$public$route?token=a%2Fb%2Bc&part=2", url("http://192.168.50.10:8800$route?token=a%2Fb%2Bc&part=2"))
        assertEquals("$public$route", url("http://127.0.0.1:8799$route"))
        assertEquals("$public$route", url("http://media-server.local:8800$route"))
    }

    @Test fun configuredProxyPrefixIsAppliedExactlyOnce() {
        val backend = "$public/velvet/v1"
        assertEquals("$backend$route?x=%2F", url("http://10.0.0.5:8799$route?x=%2F", backend, "$backend/manifest.json/"))
        assertEquals("$backend$route", url("http://10.0.0.5:8799/velvet/v1$route", "$backend/", backend))
        val unknownPrefix = "http://10.0.0.5:8799/other$route"
        assertEquals(unknownPrefix, url(unknownPrefix, backend, backend))
    }

    @Test fun existingLanInstallKeepsItsReachableAddress() {
        val lan = "http://192.168.50.10:8800"
        assertEquals("$lan$route", url("$lan$route", lan, lan))
        assertEquals("$lan$route", url("http://127.0.0.1:8799$route", lan, lan))
    }

    @Test fun publicProviderUrlsAreNeverRedirectedEvenWithMatchingPath() {
        for (host in listOf("cdn.example.test", "192.168.50.10.example.test", "172.32.1.1", "100.128.1.1", "8.8.8.8", "[2001:db8::1]")) {
            val external = "https://$host$route?signature=keep"
            assertEquals(external, url(external))
        }
        assertEquals("$public$route?signature=keep", url("$public$route?signature=keep"))
    }

    @Test fun otherConfiguredAddonsCannotBeRebasedToVelvet() {
        val raw = "http://192.168.50.20:9000$route"
        for (source in listOf("https://addon.example.test", "$public/another-addon", "http://velvet.example.test", "$public:8443")) {
            assertEquals(raw, url(raw, source))
        }
        assertEquals(raw, url(raw, public, ""))
    }

    @Test fun onlyExactRegisteredStreamsAreEligible() {
        for (path in listOf("/movie.mkv", "/stream/movie/tt123.json", "/stream/abc", "$route/health", "$route/", "/stream/0123456789abcdef00", "/stream/%30123456789abcdef", "/live/streams/0123456789abcdef/index.m3u8")) {
            val raw = "http://192.168.50.10:8800$path"
            assertEquals(raw, url(raw))
        }
    }

    @Test fun ipv6LanAndOverlayAddressesUseConfiguredOrigin() {
        for (host in listOf("[::1]", "[fd01:1234::1]", "[fe80::1234]", "100.64.0.1", "172.16.4.2", "172.31.255.254", "169.254.1.1")) {
            assertEquals("$public$route", url("http://$host:8799$route"))
        }
    }

    @Test fun credentialsMalformedOrUntrustedBaseStayUntouched() {
        val raw = "http://192.168.50.10:8800$route"
        for (base in listOf("invalid", "ftp://velvet.example.test", "$public?auth=other", "$public#other", "https://name:password@velvet.example.test")) {
            assertEquals(raw, url(raw, base, base))
        }
        val credentialed = "http://name:password@192.168.50.10:8800$route"
        assertEquals(credentialed, url(credentialed))
        assertEquals("not a url", url("not a url"))
    }
}
