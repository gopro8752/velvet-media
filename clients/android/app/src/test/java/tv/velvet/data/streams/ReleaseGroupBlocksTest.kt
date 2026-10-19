package tv.velvet.data.streams

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import tv.velvet.data.model.StreamOption

class ReleaseGroupBlocksTest {
    private fun stream(group: String?, title: String = "Show.S01E01.1080p-WRONG", source: String = "Velvet Backend") =
        StreamOption("https://stream.test/file", title, sourceName = source, bingeGroup = group)

    @Test fun exactSourceMetadataIdentifiesTheGroupAcrossEpisodes() {
        val group = stream("velvet-tsrg").releaseGroupForBlocking()!!
        assertEquals(ReleaseGroup("velvet-tsrg", "tsrg"), group)
        assertTrue(stream("velvet-tsrg", "Show.S07E03.2160p-TSRG").isReleaseGroupBlocked(listOf(group)))
        assertFalse(stream("velvet-other").isReleaseGroupBlocked(listOf(group)))
    }

    @Test fun customAddonKeysKeepTheirOwnCasePunctuationAndMeaning() {
        val group = stream("  addon/Release:X|1080p  ").releaseGroupForBlocking()!!
        assertEquals("addon/Release:X|1080p", group.key)
        assertEquals(group.key, group.label)
        assertTrue(stream("addon/Release:X|1080p").isReleaseGroupBlocked(listOf(group)))
        assertFalse(stream("addon/release:x|1080p").isReleaseGroupBlocked(listOf(group)))
        assertFalse(stream("other-addon/Release:X|1080p").isReleaseGroupBlocked(listOf(group)))
    }

    @Test fun unknownMetadataNeverFabricatesAGroupFromAddonNameOrFilename() {
        assertNull(stream(null, "Show.S01E01.1080p-TSRG", "TSRG").releaseGroupForBlocking())
        assertNull(stream(" ").releaseGroupForBlocking())
        assertNull(stream("velvet-").releaseGroupForBlocking())
        assertNull(stream("velvet-unknown").releaseGroupForBlocking())
        assertNull(stream("velvet-mkv").releaseGroupForBlocking())
        assertNull(stream("velvet-x265").releaseGroupForBlocking())
        assertFalse(stream(null).isReleaseGroupBlocked(listOf(ReleaseGroup("velvet-tsrg", "tsrg"))))
    }

    @Test fun unsafeMetadataDoesNotBecomeAVisibleActionOrPersistentKey() {
        assertNull(stream("group\nsecond line").releaseGroupForBlocking())
        assertNull(stream("x".repeat(513)).releaseGroupForBlocking())
    }

    @Test fun blockingOneShowNeverBlocksTheSameGroupOnAnotherShow() {
        val group = stream("velvet-tsrg").releaseGroupForBlocking()!!
        val map = withBlockedReleaseGroup(emptyMap(), "tt123", group)
        assertTrue(stream("velvet-tsrg").isReleaseGroupBlocked(blockedReleaseGroupsForShow(map, "tt123")))
        assertFalse(stream("velvet-tsrg").isReleaseGroupBlocked(blockedReleaseGroupsForShow(map, "tt456")))
        assertEquals(emptyList<ReleaseGroup>(), blockedReleaseGroupsForShow(map, null))
    }

    @Test fun repeatBlockIsIdempotentAndIndependentEditsRetainOtherShows() {
        val first = ReleaseGroup("velvet-first", "first")
        val second = ReleaseGroup("custom-Second", "custom-Second")
        val initial = withBlockedReleaseGroup(emptyMap(), "tt1", first)
        assertEquals(initial, withBlockedReleaseGroup(initial, "tt1", first))
        val updated = withBlockedReleaseGroup(initial, "tt2", second)
        assertEquals(listOf(first), updated["tt1"])
        assertEquals(listOf(second), updated["tt2"])
        assertEquals(updated, withBlockedReleaseGroup(updated, " ", first))
        assertEquals(updated, withBlockedReleaseGroup(updated, "tt1", ReleaseGroup("", "made up")))
    }

    @Test fun unblockingOnlyRemovesTheChosenShowAndGroupAndDropsEmptyEntry() {
        val first = ReleaseGroup("velvet-first", "first")
        val second = ReleaseGroup("velvet-second", "second")
        var blocks = mapOf("tt1" to listOf(first, second), "tt2" to listOf(first))
        blocks = withoutBlockedReleaseGroup(blocks, "tt1", first.key)
        assertEquals(listOf(second), blocks["tt1"])
        assertEquals(listOf(first), blocks["tt2"])
        blocks = withoutBlockedReleaseGroup(blocks, "tt1", second.key)
        assertFalse(blocks.containsKey("tt1"))
        assertEquals(listOf(first), blocks["tt2"])
    }

    @Test fun storedIdentityAndLabelsSurviveSerializationAcrossSessions() {
        val serializer = MapSerializer(String.serializer(), ListSerializer(ReleaseGroup.serializer()))
        val blocks = mapOf("tt1" to listOf(ReleaseGroup("custom/Group:HDR", "custom/Group:HDR")))
        val decoded = Json.decodeFromString(serializer, Json.encodeToString(serializer, blocks))
        assertEquals(blocks, decoded)
        assertTrue(stream("custom/Group:HDR").isReleaseGroupBlocked(decoded.getValue("tt1")))
    }
}
