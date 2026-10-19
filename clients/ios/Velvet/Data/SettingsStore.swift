import Foundation
import Combine

/// UserDefaults-backed settings, mirroring the Android SettingsRepository —
/// same defaults, same semantics. ObservableObject so views react live.
@MainActor
final class SettingsStore: ObservableObject {
    // Standalone discovery only. A configured backend owns its metadata key.
    static let defaultTmdbKey = ""

    @Published var tmdbApiKey: String { didSet { defaults.set(tmdbApiKey, forKey: "tmdb_api_key") } }
    @Published var streamSources: [StreamSourceConfig] { didSet { persistSources() } }
    /// Ordered, enabled row ids for Home. Empty = default order from TmdbRepository.allRows.
    /// Read through `RowIdMigration.apply` on load — v1.2 renamed `trending_movies`
    /// to `popular_now` and a persisted order must follow the rename in place.
    @Published var rowOrder: [String] { didSet { defaults.set(rowOrder, forKey: "row_order") } }
    /// Row ids the user EXPLICITLY switched off in Settings → Home Rows.
    ///
    /// `rowOrder` alone cannot express this for seasonal rows: one that is out
    /// of season is simply absent from the order the moment it gets written, so
    /// "absent" and "deliberately hidden" are indistinguishable. Without this
    /// set, a single Settings edit made in October (when only Halloween is in
    /// season) permanently suppresses Thanksgiving, Christmas, New Year's and
    /// Valentine's — they are never in the stored order again and nothing ever
    /// re-adds them (spec §4f).
    @Published var disabledRowIds: [String] { didSet { defaults.set(disabledRowIds, forKey: "disabled_row_ids") } }
    @Published var autoplayNext: Bool { didSet { defaults.set(autoplayNext, forKey: "autoplay_next") } }
    @Published var autoplayCountdownSecs: Int { didSet { defaults.set(autoplayCountdownSecs, forKey: "autoplay_countdown") } }
    @Published var preferredQuality: String { didSet { defaults.set(preferredQuality, forKey: "preferred_quality") } } // "2160p" | "1080p" | "720p"
    /// VLC hardware decoding — default on; the toggle exists for codec edge cases.
    @Published var hardwareDecoding: Bool { didSet { defaults.set(hardwareDecoding, forKey: "hardware_decoding") } }

    // MARK: watch-state sync (velvet-sync server)

    @Published var syncEnabled: Bool { didSet { defaults.set(syncEnabled, forKey: "sync_enabled") } }
    /// Base URL of the velvet-sync server, no trailing slash. Empty = sync inert.
    @Published var syncUrl: String { didSet { defaults.set(syncUrl, forKey: "sync_url") } }
    /// Optional bearer token (server's SYNC_TOKEN). Empty = no Authorization header.
    @Published var syncToken: String { didSet { defaults.set(syncToken, forKey: "sync_token") } }
    /// Human-readable result of the most recent sync attempt, for the Settings
    /// status line. Session-only — deliberately NOT persisted.
    @Published var lastSyncStatus: String = ""

    // MARK: active profile (per device — NEVER synced)

    /// The profile whose watch data is shown on this device. Persisted to
    /// UserDefaults `active_profile_id`. @Published so profile-scoped @Query
    /// views re-render the instant it changes (filter in a computed property or
    /// rebuild the query via .id(activeProfileId)). nil = no profile chosen yet
    /// (first run, before the default is created).
    @Published var activeProfileId: String? {
        didSet { defaults.set(activeProfileId, forKey: "active_profile_id") }
    }
    /// True once a profile has been chosen (or auto-selected) this app launch.
    /// Session-only — deliberately NOT persisted, so the "Who's watching?" picker
    /// can re-show on a cold launch per the gating rule. Cold start = false.
    @Published var profileChosenThisLaunch: Bool = false
    /// Set true to force the picker open on demand (the Home top-bar avatar),
    /// independent of the launch gating rule — so it works even with a single
    /// profile. Session-only; cleared when a profile is selected.
    @Published var profilePickerRequested: Bool = false

    // MARK: sticky release group (per show — a manual stream pick wins)

    /// Device-local exclusions. Publishing occurs after the synchronous preference
    /// writes so a block and removal of its conflicting sticky pick are observed together.
    @Published private(set) var blockedReleaseGroups: [String: [ReleaseGroup]]
    private static let blockedGroupsKey = "blocked_release_groups_by_show_json"

    /// imdbId -> bingeGroup of the stream the user MANUALLY picked for that
    /// show. Owner rule: "if I manually pick a stream after one autopicked and
    /// had issues, stay with that release group for that whole show" — a hand
    /// pick is a verdict on the release chain (the autopicked group stuttered,
    /// had baked-in ads, wrong audio, …), so every later episode should start
    /// from the same group when it exists. When an episode has no release in
    /// the group (or it fails), autopick falls through to best-quality as if
    /// this map were empty — quality beats loyalty for a missing episode.
    /// Not @Published: nothing in the UI renders it; the player reads it at
    /// autopick time. Stored as one flat dictionary (like the Android
    /// preferences map) — a handful of shows, not a database.
    func stickyReleaseGroup(imdbId: String) -> String? {
        guard let group = (defaults.dictionary(forKey: "sticky_release_groups") as? [String: String])?[imdbId]
        else { return nil }
        guard !blockedGroups(imdbId: imdbId).contains(where: { $0.key == group.trimmingCharacters(in: .whitespacesAndNewlines) })
        else { return nil }
        return group
    }

    func setStickyReleaseGroup(imdbId: String, bingeGroup: String) {
        guard !blockedGroups(imdbId: imdbId).contains(where: { $0.key == bingeGroup.trimmingCharacters(in: .whitespacesAndNewlines) })
        else { return }
        var map = defaults.dictionary(forKey: "sticky_release_groups") as? [String: String] ?? [:]
        map[imdbId] = bingeGroup
        defaults.set(map, forKey: "sticky_release_groups")
    }

    func clearStickyReleaseGroup(imdbId: String) {
        var map = defaults.dictionary(forKey: "sticky_release_groups") as? [String: String] ?? [:]
        map.removeValue(forKey: imdbId.trimmingCharacters(in: .whitespacesAndNewlines))
        defaults.set(map, forKey: "sticky_release_groups")
    }

    func blockedGroups(imdbId: String?) -> [ReleaseGroup] {
        guard let show = imdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !show.isEmpty else { return [] }
        return blockedReleaseGroups[show] ?? []
    }

    /// No suspension between preference writes: another MainActor reader cannot
    /// see a new block with its previous sticky choice. Blocks always win on read,
    /// including if a process stopped between UserDefaults' two durable writes.
    @discardableResult
    func blockReleaseGroup(imdbId: String, group: ReleaseGroup) -> Bool {
        let show = imdbId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !show.isEmpty, let safeGroup = ReleaseGroupBlocks.group(bingeGroup: group.key) else { return false }
        var updated = blockedReleaseGroups
        updated[show] = (updated[show] ?? []).filter { $0.key != safeGroup.key } + [safeGroup]
        guard let encoded = try? JSONEncoder().encode(updated) else { return false }
        defaults.set(encoded, forKey: Self.blockedGroupsKey)
        if let sticky = (defaults.dictionary(forKey: "sticky_release_groups") as? [String: String])?[show],
           updated[show]?.contains(where: { $0.key == sticky.trimmingCharacters(in: .whitespacesAndNewlines) }) == true {
            clearStickyReleaseGroup(imdbId: show)
        }
        blockedReleaseGroups = updated
        return true
    }

    @discardableResult
    func unblockReleaseGroup(imdbId: String, groupKey: String) -> Bool {
        let show = imdbId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !show.isEmpty else { return false }
        var updated = blockedReleaseGroups
        let remaining = (updated[show] ?? []).filter { $0.key != groupKey }
        if remaining.isEmpty { updated.removeValue(forKey: show) }
        else { updated[show] = remaining }
        guard let encoded = try? JSONEncoder().encode(updated) else { return false }
        if updated.isEmpty { defaults.removeObject(forKey: Self.blockedGroupsKey) }
        else { defaults.set(encoded, forKey: Self.blockedGroupsKey) }
        blockedReleaseGroups = updated
        return true
    }

    /// Pull cursor: the serverNow of the last fully-applied /state response.
    /// 0 = never fully reconciled — SyncEngine then does a full push of all
    /// local rows followed by a since=0 pull. SyncEngine-internal; not @Published
    /// because nothing in the UI reacts to it.
    var syncCursor: Int64 {
        get { defaults.object(forKey: "sync_cursor") as? Int64 ?? 0 }
        set { defaults.set(newValue, forKey: "sync_cursor") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.blockedGroupsKey),
           let groups = try? JSONDecoder().decode([String: [ReleaseGroup]].self, from: data) {
            blockedReleaseGroups = groups
        } else {
            blockedReleaseGroups = [:]
        }
        // Retire the old idle-watching prompt without changing any preferences.
        defaults.removeObject(forKey: "doze_marker_json")
        tmdbApiKey = defaults.string(forKey: "tmdb_api_key") ?? Self.defaultTmdbKey
        if let data = defaults.data(forKey: "stream_sources"),
           let sources = try? JSONDecoder().decode([StreamSourceConfig].self, from: data) {
            streamSources = sources
        } else {
            streamSources = []
        }
        // Spec §4g: `trending_movies` → `popular_now` is a RENAME. A stored order
        // keeps the position; the migrated value is written straight back so the
        // swap happens exactly once (property observers don't fire in init).
        let storedOrder = defaults.stringArray(forKey: "row_order") ?? []
        let migratedOrder = RowIdMigration.apply(storedOrder)
        if migratedOrder != storedOrder {
            defaults.set(migratedOrder, forKey: "row_order")
        }
        rowOrder = migratedOrder
        // Same rename table applies to the explicit-disable set.
        let storedDisabled = defaults.stringArray(forKey: "disabled_row_ids") ?? []
        let migratedDisabled = RowIdMigration.apply(storedDisabled)
        if migratedDisabled != storedDisabled {
            defaults.set(migratedDisabled, forKey: "disabled_row_ids")
        }
        disabledRowIds = migratedDisabled
        autoplayNext = defaults.object(forKey: "autoplay_next") as? Bool ?? true
        autoplayCountdownSecs = defaults.object(forKey: "autoplay_countdown") as? Int ?? 8
        preferredQuality = defaults.string(forKey: "preferred_quality") ?? "2160p"
        hardwareDecoding = defaults.object(forKey: "hardware_decoding") as? Bool ?? true
        syncEnabled = defaults.object(forKey: "sync_enabled") as? Bool ?? false
        syncUrl = defaults.string(forKey: "sync_url") ?? ""
        syncToken = defaults.string(forKey: "sync_token") ?? ""
        activeProfileId = defaults.string(forKey: "active_profile_id")
    }

    // MARK: unified backend URL

    /// The single origin that powers BOTH stream resolution and watch-state sync:
    /// the monolith backend serves the Stremio endpoints and the sync API on one
    /// host/port. Reads the (single) installed stream source, falling back to the
    /// sync URL so a device that only ever had a sync URL still shows something.
    var backendUrl: String {
        streamSources.first?.baseUrl ?? syncUrl
    }

    /// Point the whole app at one backend: install it as the sole stream source,
    /// use it as the sync server, and turn sync on — so the user types one URL
    /// instead of two. Mirrors the Android SettingsRepository.setBackendUrl.
    func setBackendUrl(_ raw: String) {
        let base = Self.normalizeBaseUrl(raw)
        guard !base.isEmpty else {
            streamSources = []
            syncUrl = ""
            return
        }
        streamSources = [StreamSourceConfig(name: "Velvet Backend", baseUrl: base, enabled: true)]
        syncUrl = base
        syncEnabled = true
    }

    /// Accepts pasted ".../manifest.json" URLs and trailing slashes.
    static func normalizeBaseUrl(_ raw: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/manifest.json") { base.removeLast("/manifest.json".count) }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    private func persistSources() {
        if let data = try? JSONEncoder().encode(streamSources) {
            defaults.set(data, forKey: "stream_sources")
        }
    }
}
