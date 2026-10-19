package tv.velvet.data.categories

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import tv.velvet.data.model.MediaType
import tv.velvet.data.model.PlayTarget

class CategoryTest {
    @Test fun movieStoryOrderSurvivesResponsePersistenceQueuePayloadAndRepeatedPlaybackPasses() {
        // Intentionally differs from release-year order: the client must not re-sort.
        val response = """{
            "id":"story-order", "title":"Story order", "items":[
                {"mediaId":101,"type":"movie","title":"The Prequel","year":"1999"},
                {"mediaId":102,"type":"movie","title":"The Original","year":"1977"},
                {"mediaId":103,"type":"movie","title":"The Sequel","year":"1980"}
            ]
        }"""
        val category = Json.decodeFromString(Category.serializer(), response).validated()
        val codec = ListSerializer(Category.serializer())
        val saved = Json.decodeFromString(codec, Json.encodeToString(codec, listOf(category))).single()
        val body = saved.queueBody(shuffle = false)
        assertEquals(listOf(101, 102, 103), body.items.map { it.mediaId })
        assertTrue(body.items.all { it.type == "movie" && it.season == null && it.episode == null })
        assertFalse(body.shuffle)

        var session = CategoryQueueSession("movie-session", "viewer", saved.title, saved.items)
        val seen = mutableListOf<Int>()
        repeat(saved.items.size * 2) {
            val target = session.target()!!
            assertEquals(MediaType.MOVIE, target.type)
            assertNull(target.season)
            assertNull(target.episode)
            seen.add(target.mediaId)
            session = advanceCategoryQueue(session, session.id, session.cursor, false)!!.session
        }
        assertEquals(listOf(101, 102, 103, 101, 102, 103), seen)
        assertEquals(101, session.target()!!.mediaId)
        assertNotEquals("movie-session", session.id)
    }

    @Test fun generatedEpisodeCategoryWithoutYearsSurvivesSavedRowsRoundTrip() {
        val response = """{
            "id":"generated-episodes", "title":"Halloween episodes", "items":[
                {"mediaId":10,"type":"show","title":"Show A","season":2,"episode":13,
                    "episodeTitle":"Spooky Night","stillUrl":"episode-a.jpg"},
                {"mediaId":10,"type":"show","title":"Show A","season":1,"episode":4,
                    "episodeTitle":"Halloween Party","stillUrl":"episode-b.jpg"}
            ]
        }"""
        val category = Json.decodeFromString(Category.serializer(), response).validated()
        val codec = ListSerializer(Category.serializer())
        val restored = Json.decodeFromString(codec, Json.encodeToString(codec, listOf(category))).single().validated()
        assertEquals(category, restored)
        assertEquals(2, restored.items.size)
        assertTrue(restored.items.all { it.year == null })
        assertEquals(listOf(PlayTarget(10, MediaType.SHOW, 2, 13), PlayTarget(10, MediaType.SHOW, 1, 4)),
            restored.items.map { it.playTarget() })
        assertEquals(listOf("Spooky Night", "Halloween Party"), restored.items.map { it.episodeTitle })
    }

    @Test fun playAllAndShuffleSendOnlySelectedEpisodeSeedsInTheirOriginalOrder() {
        val category = Category("generated", "Halloween episodes", listOf(
            CategoryItem(10, "show", "Show A", season = 2, episode = 13),
            CategoryItem(20, "show", "Show B", season = 1, episode = 9),
            CategoryItem(10, "show", "Show A", season = 1, episode = 4),
        ))
        val expected = listOf(QueueSeed(10, "show", 2, 13), QueueSeed(20, "show", 1, 9), QueueSeed(10, "show", 1, 4))
        for (shuffle in listOf(false, true)) {
            val body = category.queueBody(shuffle)
            val decoded = Json.decodeFromString(QueueBody.serializer(), Json.encodeToString(QueueBody.serializer(), body))
            assertEquals(expected, decoded.items)
            assertEquals(shuffle, decoded.shuffle)
            assertTrue(decoded.items.all { it.season != null && it.episode != null })
        }
    }

    @Test fun halloweenCardsKeepEpisodeIdentityAndStill() {
        val first = CategoryItem(5371, "show", "iCarly", season = 1, episode = 7,
            episodeTitle = "iScream on Halloween", backdropUrl = "show.jpg", stillUrl = "episode.jpg")
        val second = first.copy(episode = 8, episodeTitle = "Another episode")
        val category = Category("halloween", "Halloween", listOf(first, second, first)).validated()
        assertEquals(2, category.items.size)
        assertEquals(PlayTarget(5371, MediaType.SHOW, 1, 7), first.playTarget())
        assertEquals("episode.jpg", first.mediaItem().backdropUrl)
        assertEquals("iCarly", first.mediaItem().title)
    }

    @Test fun partialEpisodeTargetsCannotSilentlyPlayWrongEpisode() {
        val base = CategoryItem(5371, "show", "iCarly")
        val items = listOf(base, base.copy(season = 1), base.copy(episode = 7),
            base.copy(season = 1, episode = 0), base.copy(type = "movie", season = 1, episode = 1),
            base.copy(type = "unknown"), base.copy(mediaId = -1))
        assertEquals(listOf(base), Category("id", "Title", items).validated().items)
        assertEquals(PlayTarget(5371, MediaType.SHOW), base.playTarget())
    }
}
