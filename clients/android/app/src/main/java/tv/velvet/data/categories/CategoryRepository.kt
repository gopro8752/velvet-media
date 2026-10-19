package tv.velvet.data.categories

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import tv.velvet.data.model.MediaItem
import tv.velvet.data.model.MediaType
import tv.velvet.data.model.PlayTarget
import tv.velvet.data.net.await
import tv.velvet.data.settings.SettingsRepository
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

private val Context.categoryStore by preferencesDataStore(name = "velvet_categories")

@Serializable
data class CategoryItem(
    val mediaId: Int,
    val type: String,
    val title: String,
    val year: String? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val imdbId: String? = null,
    val rating: Double? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val episodeTitle: String? = null,
    val stillUrl: String? = null,
) {
    val key get() = "$type:$mediaId:$season:$episode"
    val valid get() = mediaId > 0 && type in setOf("movie", "show") && title.isNotBlank() &&
        ((season == null && episode == null) ||
            (type == "show" && season != null && season >= 0 && episode != null && episode > 0))
    fun mediaItem() = MediaItem(mediaId, MediaType.fromKey(type), title, year,
        posterUrl, stillUrl ?: backdropUrl, rating = rating, imdbId = imdbId)
    fun playTarget() = PlayTarget(mediaId, MediaType.fromKey(type), season, episode)
}

@Serializable
data class Category(val id: String, val title: String, val items: List<CategoryItem>) {
    fun validated() = copy(items = items.filter { it.valid }.distinctBy { it.key })
}

@Serializable internal data class QueueSeed(val mediaId: Int, val type: String, val season: Int?, val episode: Int?)
@Serializable internal data class QueueBody(val title: String, val items: List<QueueSeed>, val shuffle: Boolean)
/** Preserve explicit episode coordinates; the server expands only show-level seeds. */
internal fun Category.queueBody(shuffle: Boolean) = QueueBody(title,
    items.map { QueueSeed(it.mediaId, it.type, it.season, it.episode) }, shuffle)

@Serializable private data class GenerateBody(val prompt: String)
@Serializable private data class CategoryError(val error: String = "Couldn't create this category. Try again.")

/** Saved categories are private to a viewer. The shared Halloween rail is cached separately. */
class CategoryRepository(
    private val context: Context,
    private val settings: SettingsRepository,
    client: OkHttpClient,
    private val json: Json,
) {
    private val client = client.newBuilder().callTimeout(150, TimeUnit.SECONDS)
        .readTimeout(150, TimeUnit.SECONDS).build()
    private val halloweenKey = stringPreferencesKey("halloween")
    val halloween = context.categoryStore.data.map { preferences ->
        preferences[halloweenKey]?.let { runCatching { json.decodeFromString(Category.serializer(), it).validated() }.getOrNull() }
    }
    private fun profileKey(profile: String) = stringPreferencesKey("generated_" +
        MessageDigest.getInstance("SHA-256").digest(profile.toByteArray())
            .joinToString("") { "%02x".format(it) })
    fun generated(profile: String) = context.categoryStore.data.map { preferences ->
        decodeList(preferences[profileKey(profile)])
    }
    private fun decodeList(raw: String?) = raw?.let {
        runCatching { json.decodeFromString(ListSerializer(Category.serializer()), it).map(Category::validated) }.getOrNull()
    } ?: emptyList()

    suspend fun refreshHalloween() {
        val category = request("/catalog/halloween").validated()
        // Keep a useful cached rail through upstream failures/empty catalog responses.
        require(category.items.isNotEmpty()) { "Halloween episodes aren't available yet." }
        context.categoryStore.edit {
            it[halloweenKey] = json.encodeToString(Category.serializer(), category)
        }
    }

    suspend fun generate(profile: String, prompt: String): Category {
        require(prompt.trim().length in 3..500) { "Describe a category in 3–500 characters." }
        val category = request("/categories/generate", prompt.trim()).validated()
        require(category.items.isNotEmpty()) { "No matching titles found. Try a different description." }
        context.categoryStore.edit { preferences ->
            val key = profileKey(profile)
            val rows = (listOf(category) + decodeList(preferences[key]).filterNot { it.id == category.id }).take(8)
            preferences[key] = json.encodeToString(ListSerializer(Category.serializer()), rows)
        }
        return category
    }

    suspend fun remove(profile: String, id: String) {
        context.categoryStore.edit { preferences ->
            val key = profileKey(profile)
            preferences[key] = json.encodeToString(ListSerializer(Category.serializer()),
                decodeList(preferences[key]).filterNot { it.id == id })
        }
    }

    suspend fun expandQueue(category: Category, shuffle: Boolean): Category = request("/categories/queue", queue =
        category.queueBody(shuffle)).validated()

    private suspend fun request(path: String, prompt: String? = null, queue: QueueBody? = null): Category = withContext(Dispatchers.IO) {
        val config = settings.settings.first()
        val base = config.backendUrl.ifBlank { config.streamSources.firstOrNull { it.enabled }?.baseUrl.orEmpty() }
            .trim().trimEnd('/').removeSuffix("/manifest.json")
        val baseUrl = base.toHttpUrlOrNull() ?: error("Connect Velvet Backend in Settings first.")
        val request = Request.Builder().url(base.trimEnd('/') + path)
        val sync = config.syncUrl.toHttpUrlOrNull()
        if (sync != null && sync.scheme == baseUrl.scheme && sync.host == baseUrl.host && sync.port == baseUrl.port && config.syncToken.isNotBlank()) {
            request.header("Authorization", "Bearer ${config.syncToken.trim()}")
        }
        if (queue != null) request.post(json.encodeToString(QueueBody.serializer(), queue)
            .toRequestBody("application/json".toMediaType()))
        if (prompt != null) request.post(json.encodeToString(GenerateBody.serializer(), GenerateBody(prompt))
            .toRequestBody("application/json".toMediaType()))
        client.await(request.build()).use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                val message = runCatching { json.decodeFromString(CategoryError.serializer(), body).error }.getOrNull()
                error(message?.take(240) ?: "Velvet couldn't load this category. Try again.")
            }
            json.decodeFromString(Category.serializer(), body)
        }
    }
}
