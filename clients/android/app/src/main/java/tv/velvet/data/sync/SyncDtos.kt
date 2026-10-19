package tv.velvet.data.sync

import kotlinx.serialization.Serializable
import tv.velvet.data.local.MyListEntity
import tv.velvet.data.local.ProfileEntity
import tv.velvet.data.local.WatchProgressEntity
import tv.velvet.data.local.WatchedEpisodeEntity

/**
 * Wire rows for the velvet-sync server (see velvet-sync/server.py). camelCase field
 * names match the server's column-name camelization 1:1. Tombstones travel as the
 * same row shape with deleted=true — value fields may then be absent/null, so every
 * non-key field is defaulted.
 *
 * Multi-profile: the 3 data rows carry [profileId]; the (profileId, …natural key…)
 * tuple is the row identity. Profiles sync as their own [SyncProfileRow] (global; LWW).
 */

@Serializable
data class SyncProgressRow(
    val profileId: String,
    val mediaId: Int,
    val type: String,                 // "movie" | "show"
    val imdbId: String? = null,
    val title: String? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val episodeTitle: String? = null,
    val positionMs: Long = 0L,
    val durationMs: Long = 0L,
    val year: String? = null,
    val rating: Double? = null,
    val updatedAt: Long,
    val deleted: Boolean = false,
)

@Serializable
data class SyncWatchedRow(
    val profileId: String,
    val mediaId: Int,
    val season: Int,
    val episode: Int,
    val watchedAt: Long = 0L,
    val updatedAt: Long,
    val deleted: Boolean = false,
)

@Serializable
data class SyncMyListRow(
    val profileId: String,
    val mediaId: Int,
    val type: String,
    val title: String? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val year: String? = null,
    val rating: Double? = null,
    val addedAt: Long = 0L,
    val updatedAt: Long,
    val deleted: Boolean = false,
)

/** Global profile wire row: {id, name, color, createdAt, updatedAt, deleted}. */
@Serializable
data class SyncProfileRow(
    val id: String,
    val name: String? = null,
    val color: String? = null,
    val createdAt: Long = 0L,
    val updatedAt: Long,
    val deleted: Boolean = false,
)

/** POST /push body. */
@Serializable
data class SyncPushBody(
    val profiles: List<SyncProfileRow> = emptyList(),
    val progress: List<SyncProgressRow> = emptyList(),
    val watched: List<SyncWatchedRow> = emptyList(),
    val mylist: List<SyncMyListRow> = emptyList(),
)

/** POST /push response. */
@Serializable
data class SyncPushResponse(
    val serverNow: Long,
    val applied: Int = 0,
)

/** GET /state response. */
@Serializable
data class SyncStateResponse(
    val serverNow: Long,
    val profiles: List<SyncProfileRow> = emptyList(),
    val progress: List<SyncProgressRow> = emptyList(),
    val watched: List<SyncWatchedRow> = emptyList(),
    val mylist: List<SyncMyListRow> = emptyList(),
)

// ── entity <-> wire mapping (1:1; wire updatedAt = the entity's own timestamp) ──

internal fun WatchProgressEntity.toSyncRow() = SyncProgressRow(
    profileId = profileId,
    mediaId = mediaId,
    type = type,
    imdbId = imdbId,
    title = title,
    posterUrl = posterUrl,
    backdropUrl = backdropUrl,
    season = season,
    episode = episode,
    episodeTitle = episodeTitle,
    positionMs = positionMs,
    durationMs = durationMs,
    year = year,
    rating = rating,
    updatedAt = updatedAt,
)

internal fun SyncProgressRow.toEntity() = WatchProgressEntity(
    profileId = profileId,
    mediaId = mediaId,
    type = type,
    imdbId = imdbId,
    title = title.orEmpty(),
    posterUrl = posterUrl,
    backdropUrl = backdropUrl,
    season = season,
    episode = episode,
    episodeTitle = episodeTitle,
    positionMs = positionMs,
    durationMs = durationMs,
    updatedAt = updatedAt,
    year = year,
    rating = rating,
)

internal fun WatchedEpisodeEntity.toSyncRow() = SyncWatchedRow(
    profileId = profileId,
    mediaId = mediaId,
    season = season,
    episode = episode,
    watchedAt = watchedAt,
    updatedAt = watchedAt,
)

internal fun SyncWatchedRow.toEntity() = WatchedEpisodeEntity(
    profileId = profileId,
    mediaId = mediaId,
    season = season,
    episode = episode,
    // A row pushed without watchedAt still needs a sane local timestamp for LWW.
    watchedAt = if (watchedAt > 0L) watchedAt else updatedAt,
)

internal fun MyListEntity.toSyncRow() = SyncMyListRow(
    profileId = profileId,
    mediaId = mediaId,
    type = type,
    title = title,
    posterUrl = posterUrl,
    backdropUrl = backdropUrl,
    year = year,
    rating = rating,
    addedAt = addedAt,
    updatedAt = addedAt,
)

internal fun SyncMyListRow.toEntity() = MyListEntity(
    profileId = profileId,
    mediaId = mediaId,
    type = type,
    title = title.orEmpty(),
    posterUrl = posterUrl,
    backdropUrl = backdropUrl,
    year = year,
    rating = rating,
    addedAt = if (addedAt > 0L) addedAt else updatedAt,
)

internal fun ProfileEntity.toSyncRow() = SyncProfileRow(
    id = id,
    name = name,
    color = color,
    createdAt = createdAt,
    updatedAt = updatedAt,
    deleted = deleted,
)

internal fun SyncProfileRow.toEntity() = ProfileEntity(
    id = id,
    name = name.orEmpty(),
    color = color.orEmpty(),
    createdAt = createdAt,
    updatedAt = updatedAt,
    deleted = deleted,
)
