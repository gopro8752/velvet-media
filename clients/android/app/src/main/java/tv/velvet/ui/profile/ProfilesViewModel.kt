package tv.velvet.ui.profile

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import tv.velvet.data.local.ProfileEntity
import tv.velvet.data.profile.ProfileWriteResult
import tv.velvet.di.AppContainer

/** Snapshot the picker renders: the live profiles + which one is active. */
data class ProfilesUiState(
    val loading: Boolean = true,
    val profiles: List<ProfileEntity> = emptyList(),
    val activeProfileId: String? = null,
) {
    val canDelete: Boolean get() = profiles.size > 1
}

class ProfilesViewModel(container: AppContainer) : ViewModel() {

    private val repo = container.profilesRepository

    val state: StateFlow<ProfilesUiState> =
        combine(repo.profiles, repo.activeProfileId) { profiles, active ->
            ProfilesUiState(loading = false, profiles = profiles, activeProfileId = active)
        }.stateIn(viewModelScope, SharingStarted.Eagerly, ProfilesUiState())

    /** Persist the chosen profile as active (per-device). No re-sync — UI re-filters. */
    fun selectProfile(id: String) {
        viewModelScope.launch { repo.setActive(id) }
    }

    /**
     * Create a profile. [onResult] fires on the main thread with the outcome so the
     * dialog can stay open and show "A profile named 'X' already exists." inline
     * instead of silently minting a duplicate.
     */
    fun createProfile(name: String, onResult: (ProfileWriteResult) -> Unit = {}) {
        viewModelScope.launch { onResult(repo.createProfile(name)) }
    }

    /** Rename a profile; same inline-error contract as [createProfile]. */
    fun renameProfile(id: String, name: String, onResult: (ProfileWriteResult) -> Unit = {}) {
        viewModelScope.launch { onResult(repo.renameProfile(id, name)) }
    }

    fun deleteProfile(id: String) {
        viewModelScope.launch { repo.deleteProfile(id) }
    }
}
