import Foundation
import Combine
import SwiftData

/// Owns the viewer-profile store: the live profile list for the picker / top-bar
/// avatar, profile CRUD (create / rename / delete-as-tombstone), the auto-color
/// palette, and first-run bootstrap. Profiles are GLOBAL — they sync to every
/// device (SyncEngine), unlike the active-profile selection (SettingsStore).
///
/// CRUD writes the local Profile store, then notifies SyncEngine so the change
/// rides the next push. Pulled remote profile rows are applied by SyncEngine
/// straight to the model context (LWW); it then calls `refresh()` here so the
/// @Published list and the active-profile reconciliation stay current.
@MainActor
final class ProfileStore: ObservableObject {
    /// Auto-assign palette — pick the next unused color on create (spec order).
    static let palette: [String] = [
        "#8B7CF6", "#46D369", "#F5C76B", "#E0506A",
        "#5BC0EB", "#E08A3C", "#B07CF6", "#5AD1C0",
    ]
    /// The migrated namespace + first-run default id (literal, never a UUID).
    static let defaultId = "default"
    static let defaultColor = "#8B7CF6"

    /// Non-deleted profiles, oldest first — drives the picker grid and the
    /// active-profile reconciliation. @Published so views react live.
    @Published private(set) var profiles: [Profile] = []

    private let container: ModelContainer
    private let settings: SettingsStore
    private var context: ModelContext { container.mainContext }

    /// Set by AppContainer after both objects exist (weak — symmetric with the
    /// PlaybackStore ↔ SyncEngine wiring; no init cycle, works standalone).
    weak var syncEngine: SyncEngine?

    init(container: ModelContainer, settings: SettingsStore) {
        self.container = container
        self.settings = settings
        refresh()
    }

    // MARK: - queries

    /// Reload the @Published list from the store (non-deleted, oldest first).
    func refresh() {
        let d = FetchDescriptor<Profile>(
            predicate: #Predicate { $0.deleted == false },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        profiles = (try? context.fetch(d)) ?? []
    }

    var enabledCount: Int { profiles.count }

    func profile(id: String) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// Case-insensitive, whitespace-trimmed name comparison — the single
    /// definition of "same profile name" used by the creation/rename guard AND
    /// by the post-pull self-heal merge (spec §1a/b).
    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The existing non-deleted profile using this name, ignoring `excludingId`
    /// (the profile being renamed). nil = the name is free.
    func profileNamed(_ name: String, excludingId: String? = nil) -> Profile? {
        let key = Self.nameKey(name)
        guard !key.isEmpty else { return nil }
        return profiles.first { $0.id != excludingId && Self.nameKey($0.name) == key }
    }

    /// Spec §1a: a name already taken by another non-deleted profile is
    /// rejected — the sheet shows the error inline and stays open.
    func isNameTaken(_ name: String, excludingId: String? = nil) -> Bool {
        profileNamed(name, excludingId: excludingId) != nil
    }

    /// The active profile object, or nil when none is selected / it was deleted.
    var activeProfile: Profile? {
        guard let id = settings.activeProfileId else { return nil }
        return profile(id: id)
    }

    // MARK: - first run / reconciliation

    /// First launch bootstrap (spec §40-50): if no non-deleted profile exists,
    /// create {id:"default", name:"Me", color:#8B7CF6}. Set activeProfileId to
    /// "default" when unset. Existing watch rows are already tagged "default",
    /// so the user's history shows immediately. Idempotent.
    func ensureFirstRun() {
        if profiles.isEmpty {
            let now = Date.now
            let row = Profile(id: Self.defaultId, name: "Me", color: Self.defaultColor,
                              createdAt: now, updatedAt: now, deleted: false)
            context.insert(row)
            try? context.save()
            refresh()
            syncEngine?.recordProfile(row)
        }
        if settings.activeProfileId == nil {
            settings.activeProfileId = Self.defaultId
        }
    }

    /// Keep activeProfileId pointing at a live profile. Called after a sync pull
    /// may have tombstoned the active profile on another device.
    ///
    /// `preferredNameKey` is the `nameKey` of the profile that just vanished.
    /// It matters for spec §1b: the device that PERFORMS a duplicate merge
    /// repoints its active profile to the keeper itself, but a device that
    /// merely RECEIVES the merge only ever sees "my active profile's row is
    /// gone". Falling straight back to `profiles.first` would drop that viewer
    /// into the OLDEST profile — i.e. into someone else's lists — instead of
    /// into the same-named survivor their rows were just merged onto.
    func reconcileActiveProfile(preferredNameKey: String? = nil) {
        if profiles.isEmpty {
            ensureFirstRun()
            return
        }
        if let id = settings.activeProfileId, profiles.contains(where: { $0.id == id }) {
            return
        }
        // Same-name survivor first (the merge keeper), using the same keeper
        // rule as the merge: "default" always wins, else smallest createdAt,
        // tie-broken by lexicographically smallest id.
        if let key = preferredNameKey, !key.isEmpty {
            let matches = profiles.filter { Self.nameKey($0.name) == key }
            let keeper = matches.first { $0.id == Self.defaultId }
                ?? matches.sorted { lhs, rhs in
                    lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
                }.first
            if let keeper {
                settings.activeProfileId = keeper.id
                return
            }
        }
        // Active profile vanished (deleted elsewhere) — fall back to the oldest.
        settings.activeProfileId = profiles.first?.id
    }

    // MARK: - mutations (write local, then enqueue to sync)

    /// Create a profile with the given name and the next unused palette color.
    /// Returns the new profile's id, or nil when the name collides with an
    /// existing non-deleted profile (spec §1a — two devices creating "Taylor"
    /// minutes apart is exactly what produced the duplicate pair). The caller
    /// (AddProfileSheet) surfaces the rejection inline and stays open.
    @discardableResult
    func create(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "Profile \(profiles.count + 1)" : trimmed
        guard !isNameTaken(displayName) else { return nil }
        let id = UUID().uuidString.lowercased()
        let now = Date.now
        let row = Profile(id: id, name: displayName, color: nextColor(),
                          createdAt: now, updatedAt: now, deleted: false)
        context.insert(row)
        try? context.save()
        refresh()
        syncEngine?.recordProfile(row)
        return id
    }

    /// Rename a profile. Returns false when the new name is empty or already
    /// belongs to another non-deleted profile (spec §1a — the same guard as
    /// create, excluding the profile being renamed). A no-op rename to the
    /// profile's own current name succeeds silently.
    @discardableResult
    func rename(id: String, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let row = profile(id: id) else { return false }
        guard !isNameTaken(trimmed, excludingId: id) else { return false }
        guard row.name != trimmed else { return true }
        row.name = trimmed
        row.updatedAt = .now
        try? context.save()
        refresh()
        syncEngine?.recordProfile(row)
        return true
    }

    /// True when this profile can be deleted — never the last remaining one.
    func canDelete(id: String) -> Bool {
        profiles.count > 1 && profiles.contains { $0.id == id }
    }

    /// Tombstone a profile (deleted = true, updatedAt = now). Its orphaned watch
    /// rows are left in place (never shown; cheap; avoids a delete storm). If the
    /// deleted profile was active, the active selection falls back to another.
    func delete(id: String) {
        guard canDelete(id: id), let row = profile(id: id) else { return }
        row.deleted = true
        row.updatedAt = .now
        try? context.save()
        refresh()
        syncEngine?.recordProfile(row)
        if settings.activeProfileId == id {
            // Don't silently drop the user into another person's lists — fall back
            // to a live profile but re-present the picker so they explicitly
            // re-choose who's watching (matches the spec's delete flow).
            settings.activeProfileId = profiles.first?.id
            settings.profileChosenThisLaunch = false
            settings.profilePickerRequested = true
        }
    }

    // MARK: - selection

    /// Selecting a profile: set the active id + mark chosen-this-launch, clear any
    /// on-demand request → the gate closes and Home shows the chosen profile.
    func select(id: String) {
        settings.activeProfileId = id
        settings.profileChosenThisLaunch = true
        settings.profilePickerRequested = false
    }

    // MARK: - colors

    /// Next palette color not currently in use; cycles back through the palette
    /// (by usage count) once every entry is taken.
    func nextColor() -> String {
        let used = Set(profiles.map { $0.color.lowercased() })
        if let free = Self.palette.first(where: { !used.contains($0.lowercased()) }) {
            return free
        }
        // All taken — pick the least-used palette entry deterministically.
        var counts: [String: Int] = [:]
        for p in profiles { counts[p.color.lowercased(), default: 0] += 1 }
        return Self.palette.min { counts[$0.lowercased(), default: 0] < counts[$1.lowercased(), default: 0] }
            ?? Self.defaultColor
    }
}

// MARK: - Profile presentation helpers

extension Profile {
    /// First initial of the name, uppercased, for the circular avatar.
    var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

extension String {
    /// Parse a "#RRGGBB" hex profile color into a UInt32 for Color(hex:).
    /// Falls back to the default accent if malformed.
    var profileColorHex: UInt32 {
        var s = trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return 0x8B7CF6 }
        return value
    }
}
