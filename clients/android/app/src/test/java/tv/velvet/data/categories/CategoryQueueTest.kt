package tv.velvet.data.categories

import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import tv.velvet.data.model.MediaType
import tv.velvet.data.model.PlayTarget

class CategoryQueueTest {
    private val a = CategoryItem(10, "show", "Show A", season = 1, episode = 1)
    private val b = CategoryItem(20, "show", "Show B", season = 1, episode = 1)
    private val c = CategoryItem(30, "movie", "Movie C")
    private fun session(items: List<CategoryItem> = listOf(a, b, c)) =
        CategoryQueueSession("session", "profile-a", "Channel", items)

    @Test fun countdownUsesMediaTimeAndDoesNotAdvanceWhilePaused() {
        val queue = session()
        assertNull(categoryQueueCountdownSeconds(0, 1_200_000))
        assertEquals(40, categoryQueueCountdownSeconds(1_160_000, 1_200_000))
        repeat(50) { assertEquals(32, categoryQueueCountdownSeconds(1_168_000, 1_200_000)) }
        assertEquals(0, queue.cursor)
        assertEquals(0, categoryQueueCountdownSeconds(1_200_000, 1_200_000))
        // Even a zero countdown only describes position; the end event owns advancement.
        assertEquals(0, queue.cursor)
        val ended = advanceCategoryQueue(queue, queue.id, 0, false)!!
        assertNull(advanceCategoryQueue(ended.session, queue.id, 0, false))
    }

    @Test fun crossesShowsEvenWhenEpisodeNumbersMatch() {
        val result = advanceCategoryQueue(session(), "session", 0, false)!!
        assertEquals(PlayTarget(20, MediaType.SHOW, 1, 1, "session", 1), result.next)
        assertNull(advanceCategoryQueue(result.session, "session", 0, false))
        assertNull(advanceCategoryQueue(result.session, "stale-session", 1, false))
    }

    @Test fun shuffleOrderCanMoveBackwardsWithinSameShowAndRepeatsInTheSameOrder() {
        val queue = session(listOf(a.copy(episode = 3), a))
        val advanced = advanceCategoryQueue(queue, queue.id, 0, false)!!
        assertEquals(1, advanced.next!!.episode)
        val planned = advanced.session.nextTarget()
        val wrapped = advanceCategoryQueue(advanced.session, queue.id, 1, false)!!
        assertFalse(wrapped.session.finished)
        assertEquals(planned, wrapped.next)
        assertEquals(3, wrapped.next!!.episode)
        assertEquals(0, wrapped.next.queueIndex)
        assertNotEquals(queue.id, wrapped.session.id)
        assertEquals(queue.items, wrapped.session.items)
        val nextPass = advanceCategoryQueue(wrapped.session, wrapped.session.id, 0, false)!!
        assertEquals(1, nextPass.next!!.episode)
        // Cursor zero means a different immutable item generation in the new pass.
        assertNull(advanceCategoryQueue(wrapped.session, queue.id, 0, false))
        assertNull(advanceCategoryQueue(wrapped.session, queue.id, 1, false))
        assertFalse(wrapped.session.matches(queue.profileId, queue.target()!!))
    }

    @Test fun singleMovieRepeatsWithFreshIdentityAndStablePrefetchTarget() {
        var queue = session(listOf(c))
        val ids = mutableSetOf(queue.id)
        repeat(8) {
            val oldTarget = queue.target()!!
            val restored = Json.decodeFromString(CategoryQueueSession.serializer(),
                Json.encodeToString(CategoryQueueSession.serializer(), queue))
            val planned = queue.nextTarget()
            assertEquals(planned, restored.nextTarget())
            val advanced = advanceCategoryQueue(restored, queue.id, 0, false)!!
            assertEquals(planned, advanced.next)
            assertEquals(c.mediaId, advanced.next!!.mediaId)
            assertEquals(MediaType.MOVIE, advanced.next.type)
            assertEquals(0, advanced.next.queueIndex)
            assertTrue(ids.add(advanced.session.id))
            assertFalse(advanced.session.matches(queue.profileId, oldTarget))
            assertNull(advanceCategoryQueue(advanced.session, oldTarget.queueSessionId!!, 0, false))
            queue = advanced.session
        }
    }

    @Test fun failureLimitSurvivesSingleItemWrapAndSuccessfulPlaybackResetsIt() {
        val queue = session(listOf(c))
        val first = advanceCategoryQueue(queue, queue.id, 0, true)!!
        val second = advanceCategoryQueue(first.session, first.session.id, 0, true)!!
        assertEquals(2, second.session.failures)
        val blocked = advanceCategoryQueue(second.session, second.session.id, 0, true)!!
        assertTrue(blocked.stoppedForFailures)
        assertEquals(second.session.id, blocked.session.id)
        assertNull(blocked.next)
        assertEquals(3, blocked.session.failures)
        val success = advanceCategoryQueue(second.session, second.session.id, 0, false)!!
        assertEquals(0, success.session.failures)
        assertNull(success.session.notice)
        val nextFailure = advanceCategoryQueue(success.session, success.session.id, 0, true)!!
        assertEquals(1, nextFailure.session.failures)
        assertFalse(nextFailure.stoppedForFailures)
    }

    @Test fun emptyMalformedOrExpiredQueuesNeverPlanOrAdvance() {
        val invalid = listOf(
            session(emptyList()), session().copy(cursor = -1), session().copy(cursor = 3),
            session().copy(id = ""), session().copy(profileId = ""), session().copy(failures = -1),
            session().copy(finished = true), session(listOf(a.copy(episode = null))),
            session(listOf(a.copy(episode = 0))), session(listOf(c.copy(season = 1, episode = 1))),
        )
        invalid.forEach { queue ->
            assertNull(queue.target())
            assertNull(queue.nextTarget())
            assertNull(queue.previousTarget())
            assertNull(advanceCategoryQueue(queue, queue.id, queue.cursor, false))
            assertNull(advanceCategoryQueue(queue, queue.id, queue.cursor, true))
            assertNull(previousCategoryQueue(queue, queue.id, queue.cursor))
        }
        // A corrupt next item cannot be turned into an arbitrary show-level playback.
        val badNext = session(listOf(a, b.copy(season = null, episode = null)))
        assertNotNull(badNext.target())
        assertNull(badNext.nextTarget())
        assertNull(advanceCategoryQueue(badNext, badNext.id, 0, false))
    }

    @Test fun previousUsesPersistedShuffleOrderInsteadOfEpisodeNumbers() {
        val queue = session(listOf(a.copy(episode = 9), a, b)).copy(cursor = 1)
        val planned = queue.previousTarget()
        val moved = previousCategoryQueue(queue, queue.id, queue.cursor)!!
        assertEquals(planned, moved.next)
        assertEquals(9, moved.next!!.episode)
        assertEquals(0, moved.next.queueIndex)
        assertEquals(queue.items, moved.session.items)
        assertNotEquals(queue.id, moved.session.id)
        assertNull(moved.session.previousTarget())
    }

    @Test fun previousCrossesShowsAndMoviesWithoutLeavingTheQueue() {
        val queue = session(listOf(c, b, a)).copy(cursor = 2)
        val show = previousCategoryQueue(queue, queue.id, queue.cursor)!!
        assertEquals(b.mediaId, show.next!!.mediaId)
        assertEquals(MediaType.SHOW, show.next.type)
        val movie = previousCategoryQueue(show.session, show.session.id, show.session.cursor)!!
        assertEquals(c.mediaId, movie.next!!.mediaId)
        assertEquals(MediaType.MOVIE, movie.next.type)
        assertNull(movie.next.season)
        assertEquals(movie.session.id, movie.next.queueSessionId)
    }

    @Test fun previousCannotWrapBeforeTheFirstItemOrInventPriorPassHistory() {
        val first = session()
        assertNull(first.previousTarget())
        assertNull(previousCategoryQueue(first, first.id, 0))
        val last = first.copy(cursor = first.items.lastIndex)
        val wrapped = advanceCategoryQueue(last, last.id, last.cursor, false)!!.session
        assertNull(wrapped.previousTarget())
        assertNull(previousCategoryQueue(wrapped, wrapped.id, 0))
        assertNull(session(listOf(c)).previousTarget())
    }

    @Test fun previousInvalidatesOldTargetsAndClearsForwardFailureState() {
        val first = session()
        val originalTarget = first.target()!!
        val current = first.copy(cursor = 1, failures = 3, notice = "old failure")
        val moved = previousCategoryQueue(current, current.id, current.cursor)!!
        assertEquals(0, moved.session.failures)
        assertNull(moved.session.notice)
        assertFalse(moved.session.matches(first.profileId, originalTarget))
        assertNull(advanceCategoryQueue(moved.session, first.id, 0, false))
        assertNull(previousCategoryQueue(moved.session, current.id, current.cursor))
        assertNull(previousCategoryQueue(current, "old-session", current.cursor))
        assertNull(previousCategoryQueue(current, current.id, 0))
    }

    @Test fun previousPlanSurvivesPersistenceAndRejectsAnInvalidPriorItem() {
        val queue = session().copy(cursor = 2)
        val restored = Json.decodeFromString(CategoryQueueSession.serializer(),
            Json.encodeToString(CategoryQueueSession.serializer(), queue))
        assertEquals(queue.previousTarget(), restored.previousTarget())
        val invalidPrevious = session(listOf(a.copy(season = null, episode = null), b)).copy(cursor = 1)
        assertNotNull(invalidPrevious.target())
        assertNull(invalidPrevious.previousTarget())
        assertNull(previousCategoryQueue(invalidPrevious, invalidPrevious.id, invalidPrevious.cursor))
    }

    @Test fun thirdConsecutiveUnavailableItemStopsAndManualNextCanContinue() {
        val queue = session(listOf(a, b, c, a.copy(episode = 2)))
        val first = advanceCategoryQueue(queue, queue.id, 0, true)!!
        assertEquals(1, first.session.failures)
        assertTrue(first.session.notice!!.contains("Show A"))
        val second = advanceCategoryQueue(first.session, queue.id, 1, true)!!
        val blocked = advanceCategoryQueue(second.session, queue.id, 2, true)!!
        assertTrue(blocked.stoppedForFailures)
        assertNull(blocked.next)
        assertEquals(2, blocked.session.cursor)
        assertFalse(blocked.session.finished)
        val manual = advanceCategoryQueue(blocked.session, queue.id, 2, false)!!
        assertEquals(3, manual.next!!.queueIndex)
        assertEquals(0, manual.session.failures)
    }

    @Test fun queueCannotBeClaimedByAnotherProfileOrAnotherPlaybackIdentity() {
        val queue = session()
        val target = queue.target()!!
        assertTrue(queue.matches("profile-a", target))
        assertFalse(queue.matches("profile-b", target))
        assertFalse(queue.matches("profile-a", target.copy(mediaId = 20)))
        assertFalse(queue.matches("profile-a", target.copy(episode = 2)))
        assertFalse(queue.copy(finished = true).matches("profile-a", target))
    }

    @Test fun persistedQueueRetainsCursorAndExactExpandedOrder() {
        val queue = session(listOf(b, c, a.copy(episode = 3))).copy(cursor = 1)
        val json = Json
        val restored = json.decodeFromString(CategoryQueueSession.serializer(),
            json.encodeToString(CategoryQueueSession.serializer(), queue))
        assertEquals(queue, restored)
        assertEquals(PlayTarget(30, MediaType.MOVIE, queueSessionId = "session", queueIndex = 1), restored.target())
        assertEquals(10, advanceCategoryQueue(restored, restored.id, 1, false)!!.next!!.mediaId)
    }
}
