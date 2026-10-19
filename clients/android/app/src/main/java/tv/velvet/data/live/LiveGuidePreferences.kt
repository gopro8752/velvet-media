package tv.velvet.data.live

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import tv.velvet.data.settings.SettingsRepository
import java.security.MessageDigest

private val Context.liveGuideStore by preferencesDataStore(name = "velvet_live_guide")

/** Channel favorites belong to the viewer and server; no provider credentials are stored here. */
class LiveGuidePreferences(context: Context, settings: SettingsRepository) {
    private val store = context.applicationContext.liveGuideStore
    private val scope = combine(settings.settings, settings.activeProfileId) { config, profile ->
        val identity = config.backendUrl.trim().trimEnd('/') + "\n" + (profile ?: "default")
        val digest = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray()).joinToString("") { "%02x".format(it) }
        stringSetPreferencesKey("favorites_$digest")
    }
    @OptIn(ExperimentalCoroutinesApi::class)
    val favoriteIds = scope.flatMapLatest { key -> store.data.map { it[key].orEmpty() } }
    suspend fun toggle(channelId: String) {
        val key = scope.first()
        store.edit { prefs ->
            val current = prefs[key].orEmpty()
            prefs[key] = if (channelId in current) current - channelId else current + channelId
        }
    }
}
