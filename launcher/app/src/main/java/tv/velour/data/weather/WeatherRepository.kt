package tv.velour.data.weather

import android.os.SystemClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import tv.velour.core.PlaceResult
import tv.velour.core.WeatherSnapshot
import java.io.IOException
import java.net.URLEncoder
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resumeWithException

class WeatherRepository {

    private val client = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS)
        .build()

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    private class CachedWeather(
        val lat: Double,
        val lon: Double,
        val at: Long,
        val snapshot: WeatherSnapshot,
    )

    private val cacheMutex = Mutex()
    private var cached: CachedWeather? = null

    /** open-meteo.com/v1/forecast?current_weather=true; null on any failure; 30-min in-memory cache. */
    suspend fun current(lat: Double, lon: Double): WeatherSnapshot? = cacheMutex.withLock {
        val now = SystemClock.elapsedRealtime()
        cached?.let { c ->
            if (c.lat == lat && c.lon == lon && now - c.at < CACHE_TTL_MS) return c.snapshot
        }
        fetchCurrent(lat, lon)?.also { cached = CachedWeather(lat, lon, now, it) }
    }

    /** geocoding-api.open-meteo.com/v1/search?name=&count=8; empty on failure. */
    suspend fun searchPlaces(query: String): List<PlaceResult> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return emptyList()
        return runCatching {
            val url = "https://geocoding-api.open-meteo.com/v1/search" +
                "?name=${URLEncoder.encode(trimmed, "UTF-8")}&count=8&language=en&format=json"
            val dto = json.decodeFromString(GeocodingResponse.serializer(), get(url))
            dto.results.orEmpty().map { place ->
                PlaceResult(
                    name = place.name,
                    region = listOfNotNull(place.admin1, place.country)
                        .filter { it.isNotBlank() }
                        .joinToString(", "),
                    lat = place.latitude,
                    lon = place.longitude,
                )
            }
        }.getOrElse { e ->
            if (e is CancellationException) throw e
            emptyList()
        }
    }

    // ---- internals -------------------------------------------------------------------------

    private suspend fun fetchCurrent(lat: Double, lon: Double): WeatherSnapshot? = runCatching {
        val url = "https://api.open-meteo.com/v1/forecast" +
            "?latitude=$lat&longitude=$lon&current_weather=true"
        val dto = json.decodeFromString(ForecastResponse.serializer(), get(url))
        dto.currentWeather?.let { cw ->
            WeatherSnapshot(
                tempC = cw.temperature,
                conditionCode = cw.weatherCode,
                conditionLabel = wmoLabel(cw.weatherCode),
                isNight = cw.isDay == 0,
            )
        }
    }.getOrElse { e ->
        if (e is CancellationException) throw e
        null
    }

    private suspend fun get(url: String): String = withContext(Dispatchers.IO) {
        client.await(Request.Builder().url(url).build()).use { response ->
            if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
            response.body?.string() ?: throw IOException("empty body")
        }
    }

    /** WMO weather code → display label (DESIGN.md mapping). */
    private fun wmoLabel(code: Int): String = when (code) {
        0 -> "Clear"
        1, 2 -> "Partly cloudy"
        3 -> "Overcast"
        45, 48 -> "Fog"
        in 51..57 -> "Drizzle"
        in 61..67, in 80..82 -> "Rain"
        in 71..77, in 85..86 -> "Snow"
        in 95..99 -> "Thunderstorm"
        else -> "Cloudy"
    }

    private companion object {
        const val CACHE_TTL_MS = 30L * 60L * 1000L
    }
}

/**
 * Truly-cancellable OkHttp call (mirrors velvet's HttpAwait): cancelling the coroutine
 * cancels the socket, and a response that loses the race against cancellation is closed
 * instead of leaking its pooled connection.
 */
private suspend fun OkHttpClient.await(request: Request): Response =
    suspendCancellableCoroutine { continuation ->
        val call = newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                // Resuming a cancelled continuation is a no-op, so this is race-free.
                continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                continuation.resume(response) { _, _, _ -> response.close() }
            }
        })
    }

// ---- Open-Meteo DTOs (lenient; ignoreUnknownKeys) -----------------------------------------

@Serializable
private data class ForecastResponse(
    @SerialName("current_weather") val currentWeather: CurrentWeatherDto? = null,
)

@Serializable
private data class CurrentWeatherDto(
    @SerialName("temperature") val temperature: Double = 0.0,
    @SerialName("weathercode") val weatherCode: Int = 0,
    @SerialName("is_day") val isDay: Int = 1,
)

@Serializable
private data class GeocodingResponse(
    val results: List<GeoPlaceDto>? = null,
)

@Serializable
private data class GeoPlaceDto(
    val name: String = "",
    val latitude: Double = 0.0,
    val longitude: Double = 0.0,
    val admin1: String? = null,
    val country: String? = null,
)
