package tv.velvet.data.launcher

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.first
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import tv.velvet.data.model.MediaItem
import java.security.MessageDigest

private val Context.launcherStore by preferencesDataStore("launcher_featured")

/** A small, per-profile display cache filled by normal Velvet browsing, never by a binder request. */
class LauncherFeaturedCache(private val context: Context) {
    private val json = Json { ignoreUnknownKeys = true }
    private fun key(profile: String) = stringPreferencesKey("profile_" + MessageDigest.getInstance("SHA-256")
        .digest(profile.toByteArray()).joinToString("") { "%02x".format(it) })
    suspend fun read(profile: String): List<LauncherTitle> = context.launcherStore.data.first()[key(profile)]?.let {
        runCatching { json.decodeFromString(ListSerializer(LauncherTitle.serializer()), it) }.getOrNull()
    }.orEmpty().take(12)

    suspend fun remember(profile: String, items: List<MediaItem>) {
        if (items.isEmpty()) return
        context.launcherStore.edit { prefs ->
            val old = prefs[key(profile)]?.let {
                runCatching { json.decodeFromString(ListSerializer(LauncherTitle.serializer()), it) }.getOrNull()
            }.orEmpty()
            val incoming = items.map(MediaItem::launcherTitle)
            // Enriched logos/overviews win over a subsequent unenriched row emission.
            val merged = (incoming + old).distinctBy { "${it.type}:${it.id}" }.take(12).map { item ->
                val previous = old.firstOrNull { it.id == item.id && it.type == item.type }
                item.copy(logoUrl = item.logoUrl ?: previous?.logoUrl, overview = item.overview ?: previous?.overview)
            }
            prefs[key(profile)] = json.encodeToString(ListSerializer(LauncherTitle.serializer()), merged)
        }
    }
}
