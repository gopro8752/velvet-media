package tv.velvet.data.tmdb

import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import tv.velvet.data.model.Episode

class EpisodeNavigationTest {
    private fun episode(season: Int, number: Int) = Episode(season, number, "Episode $number")

    @Test fun firstRegularEpisodeHasNoPreviousAndDoesNotEnterSpecials() = runBlocking {
        val requested = mutableListOf<Int>()
        assertNull(findPreviousEpisode(1, 1, listOf(0, 1, 2)) {
            requested += it
            listOf(episode(it, 12))
        })
        assertTrue(requested.isEmpty())
    }

    @Test fun sameSeasonUsesNearestExistingLowerEpisodeRegardlessOfResponseOrder() = runBlocking {
        val requested = mutableListOf<Int>()
        val result = findPreviousEpisode(2, 5, listOf(0, 1, 2)) {
            requested += it
            listOf(episode(2, 8), episode(2, 1), episode(2, 3), episode(1, 4), episode(2, 0))
        }
        assertEquals(episode(2, 3), result)
        assertEquals(listOf(2), requested)
    }

    @Test fun firstEpisodeUsesActualLastEpisodeOfPreviousSeason() = runBlocking {
        val requested = mutableListOf<Int>()
        val result = findPreviousEpisode(3, 1, listOf(1, 2, 3)) {
            requested += it
            listOf(episode(2, 4), episode(2, 12), episode(2, 10))
        }
        assertEquals(episode(2, 12), result)
        assertEquals(listOf(2), requested)
    }

    @Test fun emptySeasonAndDuplicateSeasonEntriesDoNotHideAnEarlierEpisode() = runBlocking {
        val requested = mutableListOf<Int>()
        val result = findPreviousEpisode(4, 1, listOf(1, 3, 0, 3, 4, -1, 2)) {
            requested += it
            if (it == 1) listOf(episode(1, 7)) else emptyList()
        }
        assertEquals(episode(1, 7), result)
        assertEquals(listOf(3, 2, 1), requested)
    }

    @Test fun successfullyEmptyEarlierSeasonsMeanThereIsNoPrevious() = runBlocking {
        assertNull(findPreviousEpisode(2, 1, listOf(0, 1, 2)) { emptyList() })
    }

    @Test fun specialsCanMoveWithinTheirOwnSeason() = runBlocking {
        assertEquals(episode(0, 2), findPreviousEpisode(0, 3, listOf(0, 1)) {
            listOf(episode(0, 1), episode(0, 2), episode(0, 3))
        })
        assertNull(findPreviousEpisode(0, 1, listOf(0, 1)) {
            fail("The first special must not resolve another season")
            emptyList()
        })
    }

    @Test fun invalidCoordinatesNeverFetchOrProducePlayback() = runBlocking {
        for ((season, episode) in listOf(-1 to 3, 1 to 0, 1 to -1)) {
            assertNull(findPreviousEpisode(season, episode, listOf(1, 2)) {
                fail("Invalid episode coordinates must not fetch metadata")
                emptyList()
            })
        }
    }

    @Test fun currentSeasonFailureDoesNotSkipToAnOlderSeason() = runBlocking {
        val requested = mutableListOf<Int>()
        val failure = IOException("metadata unavailable")
        try {
            findPreviousEpisode(3, 5, listOf(1, 2, 3)) {
                requested += it
                throw failure
            }
            fail("Metadata failure must propagate")
        } catch (actual: IOException) {
            assertSame(failure, actual)
        }
        assertEquals(listOf(3), requested)
    }

    @Test fun previousSeasonFailureDoesNotSkipPastItsUnknownLastEpisode() = runBlocking {
        val requested = mutableListOf<Int>()
        val failure = IOException("season unavailable")
        try {
            findPreviousEpisode(3, 1, listOf(1, 2, 3)) {
                requested += it
                if (it == 2) throw failure
                listOf(episode(1, 6))
            }
            fail("Metadata failure must propagate")
        } catch (actual: IOException) {
            assertSame(failure, actual)
        }
        assertEquals(listOf(2), requested)
    }

    @Test fun cancellationPropagatesWithoutFurtherSeasonReads() = runBlocking {
        val cancelled = CancellationException("player left")
        try {
            findPreviousEpisode(2, 1, listOf(1, 2)) { throw cancelled }
            fail("Cancellation must propagate")
        } catch (actual: CancellationException) {
            assertSame(cancelled, actual)
        }
    }
}
