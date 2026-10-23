package tv.velvet.ui.player

import org.junit.Assert.*
import org.junit.Test
import tv.velvet.data.streams.ExactRecoveryState
import tv.velvet.data.streams.ExactRepairState

class RecoveryDiagnosticsTest {
    @Test fun indexedVerifiedTimeIsShownWithoutExposingRawServerStatus() {
        val text = recoveryDiagnosticText(ExactRecoveryState(enabled = true,
            status = "unexpected private upstream detail", verifiedAheadSeconds = 45.125))
        assertEquals("Monitoring\n45.1 s verified ahead", text)
        assertFalse(text.contains("private"))
    }

    @Test fun repairPhaseAndDownloadUseFixedLabels() {
        val state = ExactRecoveryState(enabled = true, verifiedAheadSeconds = 60.0)
        assertTrue(recoveryDiagnosticText(state, ExactRepairState("ready", 1048576)).contains("PAR2 repair verified\nRepair budget used: 1.0 MiB"))
        assertFalse(recoveryDiagnosticText(state, ExactRepairState("private upstream detail", -1)).contains("private"))
    }

    @Test fun unknownOrInvalidTimeNeverLooksLikeVerifiedPlayback() {
        for (seconds in listOf(null, -1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            val text = recoveryDiagnosticText(ExactRecoveryState(enabled = true, verifiedAheadSeconds = seconds))
            assertTrue(text.contains("Verified time unavailable"))
        }
    }
}
