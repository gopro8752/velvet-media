package tv.velour.data.velvet

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

/** No backend credentials or stream URLs leave Velvet. The signed companion owns this contract. */
class VelvetRepository(context: Context) {
    private val app = context.applicationContext
    private val json = Json { ignoreUnknownKeys = true }
    @Volatile private var activeProfile: String? = null

    suspend fun snapshot(): VelvetSnapshot = withContext(Dispatchers.IO) {
        val provider = app.packageManager.resolveContentProvider(AUTHORITY, 0)
        if (provider == null) {
            val installed = runCatching { app.packageManager.getApplicationInfo(PACKAGE, 0) }.isSuccess
            return@withContext VelvetSnapshot(connection = if (installed) VelvetConnection.UPDATE_REQUIRED else VelvetConnection.NOT_INSTALLED)
        }
        try {
            val raw = app.contentResolver.query(SNAPSHOT_URI, arrayOf("snapshot"), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(cursor.getColumnIndexOrThrow("snapshot")) else null
            } ?: return@withContext VelvetSnapshot(connection = VelvetConnection.UNAVAILABLE)
            require(raw.length <= 750_000)
            val snapshot = json.decodeFromString(VelvetSnapshot.serializer(), raw)
            require(snapshot.version == 1)
            activeProfile = snapshot.profile?.id
            snapshot.copy(
                continueWatching = snapshot.continueWatching.filter { it.valid }.take(20),
                myList = snapshot.myList.filter { it.valid }.take(24),
                featured = snapshot.featured.filter { it.valid }.take(12),
                categories = snapshot.categories.take(9).map { it.copy(items = it.items.filter(VelvetTitle::valid).take(12)) },
                games = snapshot.games.filter { it.id.matches(Regex("(nba|mlb|nfl):[0-9]{1,20}")) && it.isToday() }.distinctBy { it.id }.take(100),
                sportsTeams = snapshot.sportsTeams.distinctBy { it.key }.take(100),
            )
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: SecurityException) { VelvetSnapshot(connection = VelvetConnection.UPDATE_REQUIRED) }
        catch (_: Exception) { VelvetSnapshot(connection = VelvetConnection.UNAVAILABLE) }
    }

    /** Active UI can refresh as soon as async schedule data arrives; polling remains a fallback. */
    fun observeChanges(): Flow<Unit> = callbackFlow {
        val observer = object : android.database.ContentObserver(android.os.Handler(android.os.Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { trySend(Unit) }
        }
        val registered = runCatching { app.contentResolver.registerContentObserver(SNAPSHOT_URI, false, observer); true }.getOrDefault(false)
        awaitClose { if (registered) runCatching { app.contentResolver.unregisterContentObserver(observer) } }
    }.conflate()

    /** Call from a user action. Never automatically plays a title on refresh/focus. */
    fun launch(action: VelvetAction): Boolean {
        val intent = Intent("tv.velvet.action.LAUNCHER").apply {
            component = ComponentName(PACKAGE, "tv.velvet.data.launcher.LauncherActivity")
            // Each tap must execute the protected trampoline. Reusing its former
            // task identity only foregrounds MainActivity and drops new extras.
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
            putExtra("profile", activeProfile)
            when (action) {
                VelvetAction.Home -> putExtra("destination", "home")
                VelvetAction.Search -> putExtra("destination", "search")
                VelvetAction.LiveTV -> putExtra("destination", "live")
                VelvetAction.LiveSports -> putExtra("destination", "sports")
                VelvetAction.CreateCategory -> putExtra("destination", "create")
                VelvetAction.Profiles -> putExtra("destination", "profiles")
                is VelvetAction.SportsGame -> {
                    putExtra("destination", "game")
                    putExtra("game", action.game.id)
                }
                is VelvetAction.Category -> {
                    putExtra("destination", "category")
                    putExtra("category", action.id)
                    putExtra("shuffle", action.shuffle)
                }
                is VelvetAction.Details -> putTitle("details", action.title)
                is VelvetAction.Resume -> putTitle("resume", action.title)
            }
        }
        return runCatching { app.startActivity(intent); true }.getOrElse {
            // An older Velvet can still be opened; do not pretend its title link played.
            if (action is VelvetAction.Resume || action is VelvetAction.Details || action is VelvetAction.Category || action is VelvetAction.SportsGame) false
            else openApp()
        }
    }

    fun openApp(): Boolean = runCatching {
        val intent = app.packageManager.getLeanbackLaunchIntentForPackage(PACKAGE)
            ?: app.packageManager.getLaunchIntentForPackage(PACKAGE) ?: return false
        app.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true
    }.getOrDefault(false)

    private fun Intent.putTitle(destination: String, title: VelvetTitle) {
        require(title.valid)
        putExtra("destination", destination)
        putExtra("mediaId", title.id)
        putExtra("type", title.type)
        title.season?.let { putExtra("season", it) }
        title.episode?.let { putExtra("episode", it) }
    }

    companion object {
        const val PACKAGE = "tv.velvet"
        const val AUTHORITY = "tv.velvet.launcher"
        val SNAPSHOT_URI: Uri = Uri.parse("content://$AUTHORITY/snapshot")
    }
}
