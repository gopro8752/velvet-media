package tv.velvet.data.local

import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import kotlinx.coroutines.flow.Flow

/**
 * Multi-profile note (v3): every watch-data row is namespaced by [profileId] (the
 * literal "default" for pre-profiles history). The (profileId, …natural key…) tuple
 * is the row identity, so list/read queries filter by the active profile while the
 * un-suffixed allProgress/allWatchedEpisodes/allEntries stay UNfiltered — sync needs
 * every profile's rows. profileId is always the LEADING column of each composite PK.
 */

/** The literal namespace pre-profiles history was migrated into; the bootstrap profile. */
const val DEFAULT_PROFILE_ID = "default"

/**
 * One row per movie / per show (a show's row always reflects the most recent episode
 * the user was watching). Drives the Continue Watching rail and resume positions.
 */
@Entity(tableName = "watch_progress", primaryKeys = ["profileId", "mediaId", "type"])
data class WatchProgressEntity(
    val profileId: String,
    val mediaId: Int,
    val type: String,            // "movie" | "show"
    val imdbId: String?,
    val title: String,
    val posterUrl: String?,
    val backdropUrl: String?,
    val season: Int?,            // null for movies
    val episode: Int?,
    val episodeTitle: String?,
    val positionMs: Long,
    val durationMs: Long,
    val updatedAt: Long,
    /** Known at Details/Player time; lets the Continue Watching card honor rule 1. */
    val year: String? = null,
    val rating: Double? = null,
)

@Entity(tableName = "watched_episodes", primaryKeys = ["profileId", "mediaId", "season", "episode"])
data class WatchedEpisodeEntity(
    val profileId: String,
    val mediaId: Int,
    val season: Int,
    val episode: Int,
    val watchedAt: Long,
)

@Entity(tableName = "my_list", primaryKeys = ["profileId", "mediaId", "type"])
data class MyListEntity(
    val profileId: String,
    val mediaId: Int,
    val type: String,
    val title: String,
    val posterUrl: String?,
    val backdropUrl: String?,
    val year: String?,
    val rating: Double?,
    val addedAt: Long,
)

/**
 * A viewer profile (e.g. "Alex", "Sam"). Syncs globally (LWW on [updatedAt]);
 * [deleted] is a tombstone. The active profile lives in DataStore, never here/synced.
 */
@Entity(tableName = "profiles", primaryKeys = ["id"])
data class ProfileEntity(
    val id: String,              // lowercased UUID; the bootstrap profile is "default"
    val name: String,
    val color: String,           // hex, e.g. "#8B7CF6"
    val createdAt: Long,
    val updatedAt: Long,
    val deleted: Boolean = false,
)

/**
 * Projection of "this profile has touched this title" — Home's discovery rows hide
 * anything already in the active profile's history. Room maps by column name.
 */
data class ProfileMediaKey(val mediaId: Int, val type: String)

@Dao
interface WatchProgressDao {
    @Query("SELECT * FROM watch_progress WHERE profileId = :profileId ORDER BY updatedAt DESC LIMIT 30")
    fun continueWatching(profileId: String): Flow<List<WatchProgressEntity>>

    /**
     * Every (mediaId, type) the profile has ANY progress row for — unbounded, unlike
     * [continueWatching]'s 30-row rail. Drives Home's "hide what he's already seen".
     */
    @Query("SELECT mediaId, type FROM watch_progress WHERE profileId = :profileId")
    fun progressKeys(profileId: String): Flow<List<ProfileMediaKey>>

    /** Show ids with at least one watched episode for this profile (history filter). */
    @Query("SELECT DISTINCT mediaId FROM watched_episodes WHERE profileId = :profileId")
    fun watchedShowIds(profileId: String): Flow<List<Int>>

    @Query("SELECT * FROM watch_progress WHERE profileId = :profileId AND mediaId = :mediaId AND type = :type")
    suspend fun progressFor(profileId: String, mediaId: Int, type: String): WatchProgressEntity?

    /** Every progress row across ALL profiles — sync full-push and pull reconciliation. */
    @Query("SELECT * FROM watch_progress")
    suspend fun allProgress(): List<WatchProgressEntity>

    /** Every watched mark across ALL profiles — sync full-push and pull reconciliation. */
    @Query("SELECT * FROM watched_episodes")
    suspend fun allWatchedEpisodes(): List<WatchedEpisodeEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(progress: WatchProgressEntity)

    @Query("DELETE FROM watch_progress WHERE profileId = :profileId AND mediaId = :mediaId AND type = :type")
    suspend fun remove(profileId: String, mediaId: Int, type: String)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun markWatched(episode: WatchedEpisodeEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun markWatchedAll(episodes: List<WatchedEpisodeEntity>)

    @Query("SELECT * FROM watched_episodes WHERE profileId = :profileId AND mediaId = :mediaId")
    fun watchedEpisodes(profileId: String, mediaId: Int): Flow<List<WatchedEpisodeEntity>>

    @Query("DELETE FROM watched_episodes WHERE profileId = :profileId AND mediaId = :mediaId AND season = :season AND episode = :episode")
    suspend fun unmarkWatched(profileId: String, mediaId: Int, season: Int, episode: Int)

    @Query("DELETE FROM watched_episodes WHERE profileId = :profileId AND mediaId = :mediaId AND season = :season")
    suspend fun clearWatchedSeason(profileId: String, mediaId: Int, season: Int)

    @Query("DELETE FROM watched_episodes WHERE profileId = :profileId AND mediaId = :mediaId")
    suspend fun clearWatchedFor(profileId: String, mediaId: Int)
}

@Dao
interface MyListDao {
    @Query("SELECT * FROM my_list WHERE profileId = :profileId ORDER BY addedAt DESC")
    fun myList(profileId: String): Flow<List<MyListEntity>>

    @Query("SELECT EXISTS(SELECT 1 FROM my_list WHERE profileId = :profileId AND mediaId = :mediaId AND type = :type)")
    fun isInList(profileId: String, mediaId: Int, type: String): Flow<Boolean>

    /** Every My List row across ALL profiles — sync full-push and pull reconciliation. */
    @Query("SELECT * FROM my_list")
    suspend fun allEntries(): List<MyListEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun add(entry: MyListEntity)

    @Query("DELETE FROM my_list WHERE profileId = :profileId AND mediaId = :mediaId AND type = :type")
    suspend fun remove(profileId: String, mediaId: Int, type: String)
}

@Dao
interface ProfileDao {
    /** Live, non-deleted profiles for the picker, oldest first (stable tile order). */
    @Query("SELECT * FROM profiles WHERE deleted = 0 ORDER BY createdAt ASC")
    fun profiles(): Flow<List<ProfileEntity>>

    @Query("SELECT * FROM profiles WHERE id = :id")
    suspend fun profileById(id: String): ProfileEntity?

    @Query("SELECT * FROM profiles WHERE deleted = 0 ORDER BY createdAt ASC")
    suspend fun liveProfiles(): List<ProfileEntity>

    /** Every profile row including tombstones — sync full-push and pull reconciliation. */
    @Query("SELECT * FROM profiles")
    suspend fun allProfiles(): List<ProfileEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(profile: ProfileEntity)
}

@Database(
    entities = [
        WatchProgressEntity::class,
        WatchedEpisodeEntity::class,
        MyListEntity::class,
        ProfileEntity::class,
    ],
    version = 3,
    exportSchema = false,
)
abstract class VelvetDatabase : RoomDatabase() {
    abstract fun watchProgressDao(): WatchProgressDao
    abstract fun myListDao(): MyListDao
    abstract fun profileDao(): ProfileDao

    companion object {
        /** v2: year + rating on watch_progress so Continue Watching cards can show them. */
        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE watch_progress ADD COLUMN year TEXT")
                db.execSQL("ALTER TABLE watch_progress ADD COLUMN rating REAL")
            }
        }

        /**
         * v3: profiles. profileId enters the PK of the 3 watch tables. SQLite can't
         * ALTER a PK, so each table is rebuilt (new schema + copy with profileId =
         * "default"), and a profiles table is added. Existing history is preserved
         * verbatim, tagged into the bootstrap "default" namespace.
         */
        val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                // ── watch_progress ──────────────────────────────────────────────
                db.execSQL(
                    """
                    CREATE TABLE watch_progress_new (
                        profileId TEXT NOT NULL,
                        mediaId INTEGER NOT NULL,
                        type TEXT NOT NULL,
                        imdbId TEXT,
                        title TEXT NOT NULL,
                        posterUrl TEXT,
                        backdropUrl TEXT,
                        season INTEGER,
                        episode INTEGER,
                        episodeTitle TEXT,
                        positionMs INTEGER NOT NULL,
                        durationMs INTEGER NOT NULL,
                        updatedAt INTEGER NOT NULL,
                        year TEXT,
                        rating REAL,
                        PRIMARY KEY(profileId, mediaId, type)
                    )
                    """.trimIndent()
                )
                db.execSQL(
                    """
                    INSERT INTO watch_progress_new
                        (profileId, mediaId, type, imdbId, title, posterUrl, backdropUrl,
                         season, episode, episodeTitle, positionMs, durationMs, updatedAt, year, rating)
                    SELECT '$DEFAULT_PROFILE_ID', mediaId, type, imdbId, title, posterUrl, backdropUrl,
                         season, episode, episodeTitle, positionMs, durationMs, updatedAt, year, rating
                    FROM watch_progress
                    """.trimIndent()
                )
                db.execSQL("DROP TABLE watch_progress")
                db.execSQL("ALTER TABLE watch_progress_new RENAME TO watch_progress")

                // ── watched_episodes ────────────────────────────────────────────
                db.execSQL(
                    """
                    CREATE TABLE watched_episodes_new (
                        profileId TEXT NOT NULL,
                        mediaId INTEGER NOT NULL,
                        season INTEGER NOT NULL,
                        episode INTEGER NOT NULL,
                        watchedAt INTEGER NOT NULL,
                        PRIMARY KEY(profileId, mediaId, season, episode)
                    )
                    """.trimIndent()
                )
                db.execSQL(
                    """
                    INSERT INTO watched_episodes_new
                        (profileId, mediaId, season, episode, watchedAt)
                    SELECT '$DEFAULT_PROFILE_ID', mediaId, season, episode, watchedAt
                    FROM watched_episodes
                    """.trimIndent()
                )
                db.execSQL("DROP TABLE watched_episodes")
                db.execSQL("ALTER TABLE watched_episodes_new RENAME TO watched_episodes")

                // ── my_list ─────────────────────────────────────────────────────
                db.execSQL(
                    """
                    CREATE TABLE my_list_new (
                        profileId TEXT NOT NULL,
                        mediaId INTEGER NOT NULL,
                        type TEXT NOT NULL,
                        title TEXT NOT NULL,
                        posterUrl TEXT,
                        backdropUrl TEXT,
                        year TEXT,
                        rating REAL,
                        addedAt INTEGER NOT NULL,
                        PRIMARY KEY(profileId, mediaId, type)
                    )
                    """.trimIndent()
                )
                db.execSQL(
                    """
                    INSERT INTO my_list_new
                        (profileId, mediaId, type, title, posterUrl, backdropUrl, year, rating, addedAt)
                    SELECT '$DEFAULT_PROFILE_ID', mediaId, type, title, posterUrl, backdropUrl, year, rating, addedAt
                    FROM my_list
                    """.trimIndent()
                )
                db.execSQL("DROP TABLE my_list")
                db.execSQL("ALTER TABLE my_list_new RENAME TO my_list")

                // ── profiles ────────────────────────────────────────────────────
                db.execSQL(
                    """
                    CREATE TABLE profiles (
                        id TEXT NOT NULL,
                        name TEXT NOT NULL,
                        color TEXT NOT NULL,
                        createdAt INTEGER NOT NULL,
                        updatedAt INTEGER NOT NULL,
                        deleted INTEGER NOT NULL DEFAULT 0,
                        PRIMARY KEY(id)
                    )
                    """.trimIndent()
                )
            }
        }
    }
}
