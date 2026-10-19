package tv.velvet.di

import android.content.Context
import androidx.room.Room
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import okhttp3.Dispatcher
import okhttp3.OkHttpClient
import tv.velvet.data.categories.CategoryQueueStore
import tv.velvet.data.categories.CategoryRepository
import tv.velvet.data.companion.CompanionApi
import tv.velvet.data.companion.TvHandoffApi
import tv.velvet.data.companion.TvHandoffSession
import tv.velvet.data.local.VelvetDatabase
import tv.velvet.data.live.LiveRepository
import tv.velvet.data.sports.SportsRepository
import tv.velvet.data.profile.ProfilesRepository
import tv.velvet.data.settings.SettingsRepository
import tv.velvet.data.streams.StreamRecoveryApi
import tv.velvet.data.streams.StreamRepository
import tv.velvet.data.streams.StreamRepositoryImpl
import tv.velvet.data.sync.SyncEngine
import tv.velvet.data.tmdb.TmdbRepository
import tv.velvet.data.tmdb.TmdbRepositoryImpl
import java.util.concurrent.TimeUnit

/** Manual DI — one instance per app, reachable via VelvetApp.container. */
class AppContainer(context: Context) {

    val json: Json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }

    /**
     * Shared client. The raised per-host ceiling matters: every TMDB call goes through
     * OkHttp's enqueue path (see HttpAwait), so the default maxRequestsPerHost = 5 was a
     * hard cap on concurrency against api.themoviedb.org. With v1.2.0's cross-row dedupe
     * every row below the first unresolved one waits, and the default head row is
     * top10_today — 1 trending call plus up to 15 uncached details() lookups, i.e. 16
     * requests through 5 slots while the whole page shimmers behind it. 20 lets the head
     * row finish in one round instead of four. It is a ceiling, not a target: nothing here
     * issues more requests than it did before, and maxRequests (64) still bounds the total.
     */
    val okHttpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .dispatcher(Dispatcher().apply { maxRequestsPerHost = 20 })
        .build()

    val settingsRepository = SettingsRepository(context, json)

    val database: VelvetDatabase = Room.databaseBuilder(
        context, VelvetDatabase::class.java, "velvet.db"
    )
        .addMigrations(VelvetDatabase.MIGRATION_1_2, VelvetDatabase.MIGRATION_2_3)
        .fallbackToDestructiveMigration()
        .build()

    val tmdbRepository: TmdbRepository = TmdbRepositoryImpl(okHttpClient, json, settingsRepository)

    val streamRepository: StreamRepository = StreamRepositoryImpl(okHttpClient, json, settingsRepository)

    val streamRecoveryApi = StreamRecoveryApi(okHttpClient, settingsRepository, json)

    val launcherFeaturedCache = tv.velvet.data.launcher.LauncherFeaturedCache(context)

    val categoryQueueStore = CategoryQueueStore(context, settingsRepository, json)

    val categoryRepository = CategoryRepository(context, settingsRepository, okHttpClient, json)

    val liveRepository = LiveRepository(settingsRepository, okHttpClient, json)
    val sportsRepository = SportsRepository(settingsRepository, okHttpClient, json)
    val launcherSportsRepository = tv.velvet.data.launcher.LauncherSportsRepository(context, okHttpClient, sportsRepository)

    /** Watch-state sync — singleton with its own IO scope; inert until enabled in Settings. */
    val syncEngine: SyncEngine = SyncEngine(database, settingsRepository, okHttpClient, json)

    /** Skip-intro markers + throw-to-TV handoffs (velvet-sync server; inert when sync is off). */
    val companionApi: CompanionApi = CompanionApi(okHttpClient, settingsRepository, json)
    val tvHandoffApi = TvHandoffApi(okHttpClient, settingsRepository, json)
    val tvHandoffSession = TvHandoffSession()

    /** Viewer profiles — CRUD, auto-color, active-profile selection, first-run bootstrap. */
    val profilesRepository: ProfilesRepository =
        ProfilesRepository(database.profileDao(), settingsRepository, syncEngine)

    /** App-lifetime scope for one-shot startup work (the profile bootstrap). */
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    init {
        // First-run hook: guarantee a {id:"default", name:"Me"} profile + an active
        // selection before any screen reads them. Idempotent on later launches.
        appScope.launch {
            runCatching { settingsRepository.clearLegacySleepMarker() }
            runCatching { profilesRepository.ensureBootstrap() }
        }
    }
}
