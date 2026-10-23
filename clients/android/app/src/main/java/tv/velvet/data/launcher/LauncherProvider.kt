package tv.velvet.data.launcher

import tv.velvet.BuildConfig

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import tv.velvet.VelvetApp
import tv.velvet.data.categories.Category

/** Signature protected, read-only, bounded local snapshot. No network, tokens, or stream URLs. */
class LauncherProvider : ContentProvider() {
    override fun onCreate() = true
    override fun getType(uri: Uri) = "vnd.android.cursor.item/vnd.${BuildConfig.APPLICATION_ID}.launcher.snapshot"

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        require(uri.authority == "${BuildConfig.APPLICATION_ID}.launcher" && uri.path == "/snapshot" && uri.query == null && uri.fragment == null)
        require(selection == null && selectionArgs == null && sortOrder == null)
        require(projection == null || projection.toList() == listOf("snapshot"))
        val app = requireNotNull(context).applicationContext as VelvetApp
        val snapshot = runBlocking(Dispatchers.IO) {
            withTimeout(2_500) {
                val c = app.container
                val sports = c.launcherSportsRepository.snapshot()
                fun emptySnapshot() = LauncherSnapshot(games = sports.games, sportsUpdatedAt = sports.updatedAt,
                    sportsUnavailable = sports.unavailable, sportsTeams = sports.games.flatMap { listOf(it.homeTeam, it.awayTeam) }.distinctBy { it.key })
                val profileId = c.settingsRepository.activeProfileId.first()
                val profile = profileId?.let { c.database.profileDao().profileById(it) }?.takeUnless { it.deleted }
                    ?: return@withTimeout emptySnapshot()
                val featured = c.launcherFeaturedCache.read(profile.id)
                val cw = c.database.watchProgressDao().continueWatching(profile.id).first().take(20).map {
                    LauncherTitle(it.mediaId, it.type, it.title.take(300), launcherImage(it.posterUrl), launcherImage(it.backdropUrl),
                        year = it.year?.take(40), rating = it.rating, season = it.season, episode = it.episode,
                        episodeTitle = it.episodeTitle?.take(300), positionMs = it.positionMs.coerceAtLeast(0), durationMs = it.durationMs.coerceAtLeast(0))
                }
                val list = c.database.myListDao().myList(profile.id).first().take(24).map {
                    LauncherTitle(it.mediaId, it.type, it.title.take(300), launcherImage(it.posterUrl), launcherImage(it.backdropUrl),
                        year = it.year?.take(40), rating = it.rating)
                }
                val categories = (listOfNotNull(c.categoryRepository.halloween(profile.id).first()) +
                    c.categoryRepository.generated(profile.id).first()).take(9).map(Category::launcherCategory)
                // If the profile changed while reading, export no mixed-profile snapshot.
                if (c.settingsRepository.activeProfileId.first() != profile.id) emptySnapshot()
                else LauncherSnapshot(profile = LauncherProfile(profile.id, profile.name.take(100), profile.color),
                    continueWatching = cw, myList = list, featured = featured, categories = categories,
                    games = sports.games, sportsUpdatedAt = sports.updatedAt, sportsUnavailable = sports.unavailable,
                    sportsTeams = sports.games.flatMap { listOf(it.homeTeam, it.awayTeam) }.distinctBy { it.key })
            }
        }
        return MatrixCursor(arrayOf("snapshot"), 1).apply {
            addRow(arrayOf(Json.encodeToString(LauncherSnapshot.serializer(), snapshot)))
        }
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException("Read only")
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException("Read only")
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException("Read only")
}

private fun Category.launcherCategory() = LauncherCategory(id.take(200), title.take(300), items.take(12).map {
    LauncherTitle(it.mediaId, it.type, it.title.take(300), launcherImage(it.posterUrl), launcherImage(it.stillUrl ?: it.backdropUrl),
        year = it.year?.take(40), rating = it.rating, season = it.season, episode = it.episode, episodeTitle = it.episodeTitle?.take(300))
})
