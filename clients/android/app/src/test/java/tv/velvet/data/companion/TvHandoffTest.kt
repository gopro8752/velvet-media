package tv.velvet.data.companion

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

class TvHandoffTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val requestId = "30000000-0000-0000-0000-000000000001"
    private val deviceId = "10000000-0000-0000-0000-000000000001"
    private val sessionId = "20000000-0000-0000-0000-000000000001"

    // Wire shape returned by the Rust endpoint, including server-only fields.
    private fun response(positionMs: Long = 2_345) = """{
        "protocolVersion":2,
        "handoff":{
            "id":"$requestId","profileId":"phone-profile","mediaId":7,"type":"show",
            "season":2,"episode":9,"positionMs":$positionMs,"title":"Episode title",
            "sourceHint":{"title":"Release A","sourceName":"Velvet","bingeGroup":"Cut A","streamId":"0123456789abcdef"},
            "playbackPath":"/stream/0123456789abcdef",
            "expiresAt":1791960000000
        }
    }"""

    private fun handoff(positionMs: Long = 2_345): TvHandoff =
        json.decodeFromString(response(positionMs).let { json.parseToJsonElement(it).jsonObject.getValue("handoff").toString() })

    @Test fun `real v2 payload preserves sender identity position and release hint`() {
        val value = handoff()
        assertEquals(requestId, value.id)
        assertEquals("phone-profile", value.profileId)
        assertEquals(7, value.mediaId)
        assertEquals("show", value.type)
        assertEquals(2, value.season)
        assertEquals(9, value.episode)
        assertEquals(2_345L, value.positionMs)
        assertEquals(HandoffSourceHint("Release A", "Velvet", "Cut A", "0123456789abcdef"), value.sourceHint)
        assertEquals("/stream/0123456789abcdef", exactHandoffPath(value))
    }

    @Test fun `zero position and optional movie fields survive decoding`() {
        assertEquals(0L, handoff(0).positionMs)
        val movie: TvHandoff = json.decodeFromString("""{
            "id":"$requestId","profileId":"p","mediaId":11,"type":"movie",
            "season":null,"episode":null,"positionMs":0,"sourceHint":null,"expiresAt":1791960000000
        }""")
        assertNull(movie.season)
        assertNull(movie.episode)
        assertNull(movie.sourceHint)
        assertEquals(0L, movie.positionMs)
    }

    @Test fun `claim and cancellation acknowledgements cannot be decoded as started`() {
        for (state in listOf("pending", "claimed", "cancelled", "expired", "failed")) {
            val receipt: ReceiverAckResult = json.decodeFromString("""{
                "protocolVersion":2,"accepted":false,
                "status":{"protocolVersion":2,"id":"$requestId","state":"$state",
                    "targetName":"Example TV","expiresAt":1791960000000,"error":null}
            }""")
            assertFalse(receipt.accepted)
            assertEquals(requestId, receipt.status.id)
            assertEquals(state, receipt.status.state)
            assertNotEquals("started", receipt.status.state)
        }
        val receipt: ReceiverAckResult = json.decodeFromString("""{
            "protocolVersion":2,"accepted":true,
            "status":{"protocolVersion":2,"id":"$requestId","state":"started","expiresAt":1791960000000}
        }""")
        assertTrue(receipt.accepted)
        assertEquals("started", receipt.status.state)
    }

    @Test fun `presence encodes exact session sequence and unavailable state`() {
        val value = ReceiverPresence(deviceId, sessionId, "Example TV", "tv-profile", 123_456_789_012L, false)
        val wire = json.parseToJsonElement(json.encodeToString(value)).jsonObject
        assertEquals(setOf("deviceId", "sessionId", "name", "profileId", "sequence", "available"), wire.keys)
        assertEquals(value, json.decodeFromString<ReceiverPresence>(wire.toString()))
    }

    @Test fun `first seconds and credits positions remain eligible without resume heuristics`() {
        for (position in listOf(0L, 2_345L, 29_999L, 7_199_000L)) {
            assertTrue("position=$position", handoffPlaybackReached(position, position, playing = true, seekPending = false))
        }
    }

    @Test fun `loaded paused seeking and wrong-position playback cannot acknowledge transfer`() {
        assertFalse(handoffPlaybackReached(120_000, 120_000, playing = false, seekPending = false))
        assertFalse(handoffPlaybackReached(120_000, 120_000, playing = true, seekPending = true))
        assertFalse(handoffPlaybackReached(0, 120_000, playing = true, seekPending = false))
        assertFalse(handoffPlaybackReached(117_999, 120_000, playing = true, seekPending = false))
        assertFalse(handoffPlaybackReached(135_001, 120_000, playing = true, seekPending = false))
        assertTrue(handoffPlaybackReached(120_500, 120_000, playing = true, seekPending = false))
    }

    @Test fun `focus and foreground session invalidate a received handoff immediately`() {
        val session = TvHandoffSession()
        val lease = HandoffLease(handoff(), deviceId, sessionId)
        var foreground = true
        session.visible = { foreground }
        session.sessionId = sessionId
        session.register(lease)
        assertSame(lease, session.get(requestId))
        assertTrue(session.isEligible(lease))
        foreground = false
        assertFalse(session.isEligible(lease))
        foreground = true
        session.sessionId = null
        assertFalse(session.isEligible(lease))
        session.sessionId = "20000000-0000-0000-0000-000000000002"
        assertFalse(session.isEligible(lease))
    }

    @Test fun `completed or process-restored routes cannot retrieve a prior lease`() {
        val lease = HandoffLease(handoff(), deviceId, sessionId)
        val session = TvHandoffSession()
        session.register(lease)
        session.forget(requestId)
        assertNull(session.get(requestId))
        assertNull(session.get(null))
        assertNull(TvHandoffSession().get(requestId))
    }

    @Test fun `exact stream rejects alternate origins queries paths and mismatched identifiers`() {
        val value = handoff()
        for (path in listOf("https://evil.test/stream/0123456789abcdef", "//evil.test/stream/0123456789abcdef",
                "/stream/0123456789abcdef?token=secret", "/stream/0123456789abcdef/other", "/stream/fedcba9876543210")) {
            assertNull(path, exactHandoffPath(value.copy(playbackPath = path)))
        }
        for (id in listOf("../other", "0123456789ABCDEF", "", "0123456789abcdef?token=secret")) {
            assertNull(exactHandoffPath(value.copy(sourceHint = value.sourceHint!!.copy(streamId = id))))
        }
    }

    @Test fun `legacy metadata-only requests cannot silently resolve a different stream`() {
        val value = handoff()
        assertNull(exactHandoffPath(value.copy(playbackPath = null)))
        assertNull(exactHandoffPath(value.copy(sourceHint = value.sourceHint!!.copy(streamId = null))))
        assertNull(exactHandoffPath(value.copy(sourceHint = null)))
    }
}
