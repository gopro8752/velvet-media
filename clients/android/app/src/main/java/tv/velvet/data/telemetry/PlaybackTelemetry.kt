package tv.velvet.data.telemetry

import android.content.Context
import android.os.Build
import android.os.SystemClock
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import tv.velvet.data.settings.SettingsRepository
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Counts observed wall time, never media position (which can jump during a seek). */
internal class PlaybackClock(private var lastMs: Long) {
    var state = "buffering"; private set
    var playedMs = 0L; private set
    var bufferedMs = 0L; private set
    fun sample(nowMs: Long, next: String) {
        // Missing samples mean suspension or a hung thread, not proven viewing.
        val delta = (nowMs - lastMs).coerceIn(0, 2_000)
        if (state == "playing") playedMs += delta
        if (state == "buffering") bufferedMs += delta
        lastMs = nowMs
        state = next
    }
}

/** Independent transport: telemetry cannot delay or fail playback. No provider URLs leave here. */
class PlaybackTelemetry(context: Context, private val settings: SettingsRepository) {
    data class Sample(val state: String, val positionMs: Long = 0)
    private val deviceName = runCatching { android.provider.Settings.Global.getString(context.contentResolver, "device_name") }.getOrNull()?.takeIf { it.isNotBlank() } ?: Build.MODEL
    private val appVersion = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "unknown"
    private val prefs = context.getSharedPreferences("playback_telemetry", Context.MODE_PRIVATE)
    private val deviceId = prefs.getString("device_id", null) ?: UUID.randomUUID().toString().also {
        prefs.edit().putString("device_id", it).apply()
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var session: JSONObject? = null
    private var clock: PlaybackClock? = null
    private var timer: Job? = null
    private var sequence = 0
    private var startedAt = 0L
    private var lastSent = 0L
    private var endpoint: String? = null
    private var token = ""
    private var sampler: (() -> Sample)? = null
    private var configJob: Job? = null

    fun start(kind: String, mediaId: String, title: String, season: Int? = null, episode: Int? = null,
              profileId: String? = null, sample: () -> Sample) {
        end()
        startedAt = SystemClock.elapsedRealtime()
        clock = PlaybackClock(startedAt)
        sampler = sample
        sequence = 0; lastSent = 0; endpoint = null
        val data = JSONObject().put("sessionId", UUID.randomUUID().toString()).put("deviceId", deviceId)
            .put("deviceName", deviceName).put("platform", "android").put("appVersion", appVersion)
            .put("kind", kind).put("mediaId", mediaId).put("title", title.take(500))
            .put("season", season).put("episode", episode).put("errorCount", 0).put("sourceSwitches", 0)
        session = data
        configJob = scope.launch {
            val config = runCatching { settings.settings.first() }.getOrNull() ?: return@launch
            // syncUrl is the explicitly configured Velvet backend, not an arbitrary stream add-on.
            if (!config.syncEnabled) return@launch
            val base = config.syncUrl.trimEnd('/').removeSuffix("/manifest.json")
            if (!(base.startsWith("https://") || base.startsWith("http://")) || session !== data) return@launch
            data.put("profileId", profileId ?: runCatching { settings.activeProfileId.first() }.getOrNull() ?: "default")
            if (session !== data) return@launch
            endpoint = "$base/telemetry/playback"; token = config.syncToken
            observe(force = true)
        }
        timer = scope.launch { while (isActive) { delay(1_000); observe() } }
    }
    fun observe(force: Boolean = false) {
        val c = clock ?: return
        val sample = sampler?.invoke() ?: return
        val now = SystemClock.elapsedRealtime()
        val changed = c.state != sample.state
        c.sample(now, sample.state)
        val data = session ?: return
        if (sample.state == "playing" && !data.has("startupMs")) data.put("startupMs", now - startedAt)
        data.put("positionMs", sample.positionMs.coerceAtLeast(0))
        if (force || changed || now - lastSent >= 15_000) send()
    }
    fun error() { session?.let { it.put("errorCount", it.optInt("errorCount") + 1) }; observe(true) }
    fun sourceSwitch() { session?.let { it.put("sourceSwitches", it.optInt("sourceSwitches") + 1) }; observe(true) }
    fun end() {
        timer?.cancel(); timer = null
        configJob?.cancel(); configJob = null
        clock?.let { it.sample(SystemClock.elapsedRealtime(), "ended"); send() }
        session = null; clock = null; sampler = null; endpoint = null
    }
    private fun send() {
        val data = session ?: return
        val c = clock ?: return
        val url = endpoint ?: return
        data.put("sequence", ++sequence).put("state", c.state).put("playedMs", c.playedMs)
            .put("bufferedMs", c.bufferedMs).put("timestampMs", System.currentTimeMillis())
        lastSent = SystemClock.elapsedRealtime()
        val request = runCatching { Request.Builder().url(url)
            .apply { if (token.isNotBlank()) header("Authorization", "Bearer $token") }
            .post(data.toString().toRequestBody("application/json".toMediaType())).build() }.getOrNull() ?: return
        client.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) = Unit
            override fun onResponse(call: Call, response: Response) { response.close() }
        })
    }
    companion object {
        private val client = OkHttpClient.Builder().callTimeout(5, TimeUnit.SECONDS)
            .connectTimeout(3, TimeUnit.SECONDS).readTimeout(3, TimeUnit.SECONDS)
            .followRedirects(false).followSslRedirects(false).build()
    }
}
