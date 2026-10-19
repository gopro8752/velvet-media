package tv.velvet.data.categories

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import tv.velvet.data.local.DEFAULT_PROFILE_ID

class HalloweenProfileOwnershipTest {
    private val halloween = Category(HALLOWEEN_CATEGORY_ID, "Monstober & Nick Halloween",
        listOf(CategoryItem(5371, "show", "iCarly", season = 1, episode = 7)))

    @Test fun legacyCollectionIsVisibleOnlyToOriginalProfile() = runBlocking {
        val cache = MutableStateFlow<Category?>(halloween)
        val profile = MutableStateFlow<String?>(DEFAULT_PROFILE_ID)
        val visible = cache.halloweenForProfile(profile)
        assertEquals(halloween, visible.first())
        profile.value = "craig-profile-id"
        assertNull(visible.first())
        profile.value = null
        assertNull(visible.first())
        profile.value = DEFAULT_PROFILE_ID
        assertEquals(halloween, visible.first())
        // Switching does not delete or rewrite the original cached collection.
        assertEquals(halloween, cache.value)
    }

    @Test fun lateCacheRefreshDoesNotExposeCollectionAfterProfileSwitch() = runBlocking {
        val cache = MutableStateFlow<Category?>(null)
        val profile = MutableStateFlow<String?>(DEFAULT_PROFILE_ID)
        val visible = cache.halloweenForProfile(profile)
        assertNull(visible.first())
        profile.value = "craig-profile-id"
        cache.value = halloween
        assertNull(visible.first())
        assertFalse(ownsHalloweenCategory(profile.value)) // no loading or retry rail either
        assertFalse(ownsHalloweenCategory(null))
        profile.value = DEFAULT_PROFILE_ID
        assertTrue(ownsHalloweenCategory(profile.value))
        assertEquals(halloween, visible.first())
    }

    @Test fun categoryDeepLinksAndQueuesRequireOwnerButOrdinaryCategoriesStillWork() {
        assertTrue(canAccessCategory(DEFAULT_PROFILE_ID, HALLOWEEN_CATEGORY_ID))
        assertFalse(canAccessCategory("craig-profile-id", HALLOWEEN_CATEGORY_ID))
        assertFalse(canAccessCategory(null, HALLOWEEN_CATEGORY_ID))
        assertFalse(canAccessCategory("", "generated-id"))
        assertTrue(canAccessCategory("craig-profile-id", "generated-id"))
    }
}
