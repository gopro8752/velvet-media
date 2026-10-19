package tv.velvet.data.profile

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import tv.velvet.data.local.DEFAULT_PROFILE_ID
import tv.velvet.data.local.ProfileDao
import tv.velvet.data.local.ProfileEntity
import tv.velvet.data.settings.SettingsRepository
import tv.velvet.data.sync.SyncEngine
import java.util.UUID

/**
 * Outcome of a profile create/rename. [NameTaken] is rendered inline in the
 * Add/Rename dialog — nothing is written and the dialog stays open.
 */
sealed interface ProfileWriteResult {
    data class Success(val id: String) : ProfileWriteResult

    /** A live profile already uses this name (case-insensitive, trimmed). */
    data class NameTaken(val name: String) : ProfileWriteResult

    /** Blank name, or the profile being renamed vanished (deleted on another device). */
    data object InvalidName : ProfileWriteResult
}

/**
 * Profile CRUD + the per-device active-profile selection. Owns the create/rename/
 * delete dance (local write first, then enqueue the wire row for sync — sync can
 * never break the local write), the auto-color palette, and the first-run bootstrap.
 *
 * Delete is a tombstone on the profile row ONLY: orphaned watch rows are left in
 * place (never shown for a hidden profile; cheap; avoids a cross-table delete storm).
 * The last remaining live profile can't be deleted.
 *
 * Names are unique across live profiles (case-insensitive, trimmed): two devices
 * creating "Alex" before a sync completes must not leave duplicate profiles
 * alive forever. Creation/rename reject a collision here; SyncEngine's post-pull
 * self-heal merges any duplicates that still slip through a concurrent create.
 */
class ProfilesRepository(
    private val profileDao: ProfileDao,
    private val settingsRepository: SettingsRepository,
    private val syncEngine: SyncEngine,
) {
    /** Live (non-deleted) profiles, oldest first — the picker's source of truth. */
    val profiles: Flow<List<ProfileEntity>> = profileDao.profiles()

    /** The active profile id for this device; null until chosen/bootstrapped. */
    val activeProfileId: Flow<String?> = settingsRepository.activeProfileId

    companion object {
        /** Auto-assign the next unused entry on create (spec palette, in order). */
        val COLOR_PALETTE = listOf(
            "#8B7CF6", "#46D369", "#F5C76B", "#E0506A",
            "#5BC0EB", "#E08A3C", "#B07CF6", "#5AD1C0",
        )

        const val BOOTSTRAP_NAME = "Me"
    }

    /**
     * First-run bootstrap: when no live profiles exist, create the migrated
     * {id:"default", name:"Me", color:#8B7CF6} namespace so existing local history
     * (already tagged "default") shows immediately. Sets active_profile_id="default"
     * only when unset. Idempotent — safe to call on every launch.
     */
    suspend fun ensureBootstrap() {
        val live = profileDao.liveProfiles()
        if (live.isEmpty()) {
            val now = System.currentTimeMillis()
            val existing = profileDao.profileById(DEFAULT_PROFILE_ID)
            // Revive a tombstoned default rather than minting a parallel one.
            val profile = ProfileEntity(
                id = DEFAULT_PROFILE_ID,
                name = existing?.name?.takeIf { it.isNotBlank() } ?: BOOTSTRAP_NAME,
                color = existing?.color?.takeIf { it.isNotBlank() } ?: COLOR_PALETTE.first(),
                createdAt = existing?.createdAt ?: now,
                updatedAt = now,
                deleted = false,
            )
            profileDao.upsert(profile)
            syncEngine.recordProfileUpsert(profile)
        }
        if (activeProfileSnapshot() == null) {
            settingsRepository.setActiveProfileId(DEFAULT_PROFILE_ID)
        }
    }

    /**
     * Create a new profile with an auto-assigned color, then select it.
     * Rejected with [ProfileWriteResult.NameTaken] when a live profile already
     * carries that name (case-insensitive, trimmed) — nothing is written.
     */
    suspend fun createProfile(name: String): ProfileWriteResult {
        val trimmed = name.trim()
        if (trimmed.isBlank()) return ProfileWriteResult.InvalidName
        if (nameTaken(trimmed, excludingId = null)) return ProfileWriteResult.NameTaken(trimmed)
        val id = UUID.randomUUID().toString().lowercase()
        val now = System.currentTimeMillis()
        val profile = ProfileEntity(
            id = id,
            name = trimmed,
            color = nextColor(),
            createdAt = now,
            updatedAt = now,
            deleted = false,
        )
        profileDao.upsert(profile)
        syncEngine.recordProfileUpsert(profile)
        settingsRepository.setActiveProfileId(id)
        return ProfileWriteResult.Success(id)
    }

    /**
     * Rename a profile (keeps id/color/createdAt; bumps updatedAt for LWW). The
     * uniqueness check excludes the profile being renamed, so re-casing its own
     * name (e.g. "Alex" to "ALEX") is allowed.
     */
    suspend fun renameProfile(id: String, name: String): ProfileWriteResult {
        val trimmed = name.trim()
        if (trimmed.isBlank()) return ProfileWriteResult.InvalidName
        val existing = profileDao.profileById(id) ?: return ProfileWriteResult.InvalidName
        if (nameTaken(trimmed, excludingId = id)) return ProfileWriteResult.NameTaken(trimmed)
        val updated = existing.copy(name = trimmed, updatedAt = System.currentTimeMillis())
        profileDao.upsert(updated)
        syncEngine.recordProfileUpsert(updated)
        return ProfileWriteResult.Success(id)
    }

    /** True when a live profile other than [excludingId] already uses [name]. */
    suspend fun nameTaken(name: String, excludingId: String? = null): Boolean {
        val needle = name.trim()
        if (needle.isBlank()) return false
        return profileDao.liveProfiles().any {
            it.id != excludingId && it.name.trim().equals(needle, ignoreCase = true)
        }
    }

    /**
     * Tombstone a profile. Refuses to delete the last live profile. When the deleted
     * profile was active, the active selection falls back to another live profile.
     * Returns true when the delete happened.
     */
    suspend fun deleteProfile(id: String): Boolean {
        val live = profileDao.liveProfiles()
        if (live.size <= 1) return false
        val existing = profileDao.profileById(id) ?: return false
        val tombstone = existing.copy(deleted = true, updatedAt = System.currentTimeMillis())
        profileDao.upsert(tombstone)
        syncEngine.recordProfileDelete(id)
        if (activeProfileSnapshot() == id) {
            live.firstOrNull { it.id != id }?.let { settingsRepository.setActiveProfileId(it.id) }
        }
        return true
    }

    /** Persist the per-device active profile. Switching triggers no re-sync — UI re-filters. */
    suspend fun setActive(id: String) = settingsRepository.setActiveProfileId(id)

    /** The next palette color not already in use by a live profile (wraps when exhausted). */
    private suspend fun nextColor(): String {
        val used = profileDao.liveProfiles().map { it.color.lowercase() }.toSet()
        return COLOR_PALETTE.firstOrNull { it.lowercase() !in used } ?: COLOR_PALETTE.first()
    }

    private suspend fun activeProfileSnapshot(): String? =
        runCatching { settingsRepository.activeProfileId.first() }.getOrNull()
}
