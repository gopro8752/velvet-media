import SwiftUI
import SwiftData

/// Dependency container, injected through the environment. Mirrors the Android
/// AppContainer: one instance per app, created in VelvetApp.
@MainActor
final class AppContainer: ObservableObject {
    let settings: SettingsStore
    let tmdb: TmdbRepository
    let streams: StreamRepository
    let playback: PlaybackStore
    let profiles: ProfileStore
    let sync: SyncEngine
    let companion: CompanionApi
    let liveTV: LiveTVClient
    let liveSports: LiveSportsClient

    init(modelContainer: ModelContainer) {
        HomeCategoryCache.removeRetiredLegacyCategory()
        let settings = SettingsStore()
        self.settings = settings
        self.tmdb = TmdbClient(settings: settings)
        self.streams = StreamClient(settings: settings)
        // Skip-intro + throw-to-TV endpoints on the sync server; inert while
        // sync is off, so it needs no wiring beyond the settings it reads.
        self.companion = CompanionApi(settings: settings)
        self.liveTV = LiveTVClient {
            let source = settings.streamSources.first { $0.enabled }?.baseUrl ?? settings.syncUrl
            return LiveConnection(baseUrl: SettingsStore.normalizeBaseUrl(source),
                                  syncUrl: SettingsStore.normalizeBaseUrl(settings.syncUrl),
                                  token: settings.syncToken)
        }
        self.liveSports = LiveSportsClient {
            let source = settings.streamSources.first { $0.enabled }?.baseUrl ?? settings.syncUrl
            return LiveConnection(baseUrl: SettingsStore.normalizeBaseUrl(source),
                                  syncUrl: SettingsStore.normalizeBaseUrl(settings.syncUrl), token: settings.syncToken)
        }
        let playback = PlaybackStore(container: modelContainer)
        self.playback = playback
        // The active profile flows into every PlaybackStore query/mutation here;
        // switching profiles is a pure re-filter (activeProfileId is read at call
        // time). Falls back to the migrated "default" namespace until selected.
        playback.activeProfileId = { [weak settings] in
            settings?.activeProfileId ?? ProfileStore.defaultId
        }
        let profiles = ProfileStore(container: modelContainer, settings: settings)
        self.profiles = profiles
        let sync = SyncEngine(playback: playback, settings: settings)
        self.sync = sync
        // Wired after construction — the stores hold the engine weakly, so no
        // init needs another to exist first (no init cycle).
        playback.syncEngine = sync
        profiles.syncEngine = sync
        sync.profileStore = profiles
        // First-run: ensure the {id:"default", name:"Me"} profile exists and the
        // active profile is set. Existing watch rows are already tagged "default".
        profiles.ensureFirstRun()
    }
}
