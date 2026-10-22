package tv.velvet

import org.junit.Assert.*
import org.junit.Test

class BuildIdentityTest {
    @Test fun betaUsesSeparateInstallIdentity() {
        if (BuildConfig.RECOVERY_BETA) {
            assertEquals("tv.velvet.beta", BuildConfig.APPLICATION_ID)
            assertTrue(BuildConfig.VERSION_NAME.endsWith("-beta"))
        } else {
            assertEquals("tv.velvet", BuildConfig.APPLICATION_ID)
            assertFalse(BuildConfig.VERSION_NAME.endsWith("-beta"))
        }
    }
}
