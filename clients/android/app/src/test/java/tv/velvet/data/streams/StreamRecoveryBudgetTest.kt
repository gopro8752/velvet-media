package tv.velvet.data.streams

import org.junit.Assert.*
import org.junit.Test

class StreamRecoveryBudgetTest {
    @Test fun fourConsecutiveFailuresRemainBoundedButHealthyPlaybackRenewsThem() {
        val budget = StreamRecoveryBudget()
        budget.sourceChanged()
        repeat(4) { assertTrue(budget.tryAutomaticSwitch()) }
        assertFalse(budget.tryAutomaticSwitch())
        for (time in 0L..29_000L step 1_000) assertFalse(budget.observe(time, 100_000 + time, true))
        assertEquals(4, budget.automaticAttempts)
        assertTrue(budget.observe(30_000, 130_000, true))
        assertEquals(0, budget.automaticAttempts)
        assertTrue(budget.tryAutomaticSwitch())
    }

    @Test fun readyOrFrozenPositionCannotRenewTheBudget() {
        val budget = StreamRecoveryBudget(); budget.sourceChanged(); budget.tryAutomaticSwitch()
        for (time in 0L..100_000L step 1_000) budget.observe(time, 60_000, true)
        assertEquals(1, budget.automaticAttempts)
        assertFalse(budget.sourceEstablished)
    }

    @Test fun pausesSeeksAndSuspendedSamplesBreakTheHealthyRun() {
        val budget = StreamRecoveryBudget(); budget.sourceChanged(); budget.tryAutomaticSwitch()
        for (time in 0L..20_000L step 1_000) budget.observe(time, time, true)
        budget.observe(21_000, 20_000, false)
        for (time in 22_000L..40_000L step 1_000) budget.observe(time, time, true)
        assertEquals(1, budget.automaticAttempts)
        budget.interrupt() // Explicit seek.
        budget.observe(41_000, 100_000, true)
        budget.observe(100_000, 160_000, true) // No inferred minute of healthy playback.
        assertEquals(1, budget.automaticAttempts)
    }

    @Test fun sourceGenerationPreventsOldCallbacksBorrowingNewPlayback() {
        val budget = StreamRecoveryBudget(); val old = budget.sourceChanged()
        budget.observe(0, 0, true); budget.observe(1000, 1000, true)
        assertTrue(budget.isEstablished(old))
        val next = budget.sourceChanged()
        assertFalse(budget.isEstablished(next))
        budget.observe(2000, 0, true); budget.observe(3000, 1000, true)
        assertTrue(budget.isEstablished(next))
        assertFalse(budget.isEstablished(old))
        assertFalse(budget.allowInPlaceRetry(old, 3000))
        assertEquals(0L, budget.retryUntilMs)
    }

    @Test fun repeatedErrorsCannotExtendAnInPlaceRetryWindow() {
        val budget = StreamRecoveryBudget(); val generation = budget.sourceChanged()
        budget.observe(0, 0, true); budget.observe(1000, 1000, true)
        assertTrue(budget.allowInPlaceRetry(generation, 2000))
        assertTrue(budget.allowInPlaceRetry(generation, 16_999))
        assertFalse(budget.allowInPlaceRetry(generation, 17_000))
        assertEquals(17_000L, budget.retryUntilMs)
    }
}
