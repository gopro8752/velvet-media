import Foundation
import SwiftData

/// SwiftData models mirroring the Android Room schema (data/local/VelvetDatabase.kt).
/// iOS 17 SwiftData has no unique constraints — PlaybackStore enforces
/// one-row-per-(profileId,mediaId,type) by fetch-then-update.
///
/// Multi-profile: every watch row carries a `profileId` (default `"default"` —
/// the migrated namespace). The (profileId, …key…) tuple is the row identity.
/// Adding a property with a default value is a SwiftData lightweight migration:
/// existing rows materialize as profileId == "default", preserving local history.

@Model
final class WatchProgress {
    var mediaId: Int
    var typeKey: String            // "movie" | "show"
    /// Owning profile namespace; defaults to "default" (lightweight migration).
    var profileId: String = "default"
    var imdbId: String?
    var title: String
    var posterUrl: String?
    var backdropUrl: String?
    var season: Int?               // nil for movies; for shows, the episode being watched
    var episode: Int?
    var episodeTitle: String?
    var positionMs: Int64
    var durationMs: Int64
    var updatedAt: Date
    var year: String?
    var rating: Double?

    init(mediaId: Int, typeKey: String, profileId: String = "default",
         imdbId: String?, title: String,
         posterUrl: String?, backdropUrl: String?, season: Int?, episode: Int?,
         episodeTitle: String?, positionMs: Int64, durationMs: Int64,
         updatedAt: Date = .now, year: String?, rating: Double?) {
        self.mediaId = mediaId
        self.typeKey = typeKey
        self.profileId = profileId
        self.imdbId = imdbId
        self.title = title
        self.posterUrl = posterUrl
        self.backdropUrl = backdropUrl
        self.season = season
        self.episode = episode
        self.episodeTitle = episodeTitle
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.updatedAt = updatedAt
        self.year = year
        self.rating = rating
    }
}

@Model
final class WatchedEpisode {
    var mediaId: Int
    /// Owning profile namespace; defaults to "default" (lightweight migration).
    var profileId: String = "default"
    var season: Int
    var episode: Int
    var watchedAt: Date

    init(mediaId: Int, profileId: String = "default",
         season: Int, episode: Int, watchedAt: Date = .now) {
        self.mediaId = mediaId
        self.profileId = profileId
        self.season = season
        self.episode = episode
        self.watchedAt = watchedAt
    }
}

@Model
final class MyListItem {
    var mediaId: Int
    var typeKey: String
    /// Owning profile namespace; defaults to "default" (lightweight migration).
    var profileId: String = "default"
    var title: String
    var posterUrl: String?
    var backdropUrl: String?
    var year: String?
    var rating: Double?
    var addedAt: Date

    init(mediaId: Int, typeKey: String, profileId: String = "default",
         title: String, posterUrl: String?,
         backdropUrl: String?, year: String?, rating: Double?, addedAt: Date = .now) {
        self.mediaId = mediaId
        self.typeKey = typeKey
        self.profileId = profileId
        self.title = title
        self.posterUrl = posterUrl
        self.backdropUrl = backdropUrl
        self.year = year
        self.rating = rating
        self.addedAt = addedAt
    }
}

/// A viewer profile (e.g. "Alex", "Sarah"). Global — syncs to every device
/// (LWW on `updatedAt`, tombstone via `deleted`). The active profile per device
/// is NOT here — it lives in SettingsStore / UserDefaults.
///
/// `id` is a lowercased UUID; the migrated namespace is the literal "default".
@Model
final class Profile: Identifiable {
    /// Stable namespace id. Uniqueness is enforced by fetch-then-update in
    /// ProfileStore / SyncEngine (same no-unique-constraint pattern as the watch
    /// tables above) — keeps lightweight migration of the existing store safe.
    var id: String
    var name: String
    var color: String              // hex like "#8B7CF6"
    var createdAt: Date
    var updatedAt: Date
    var deleted: Bool

    init(id: String, name: String, color: String,
         createdAt: Date = .now, updatedAt: Date = .now, deleted: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deleted = deleted
    }
}

/// Main-actor convenience wrapper over the model context for code that isn't a
/// SwiftUI view (the player, context-menu actions). Views use @Query directly.
///
/// Every list read filters `WHERE profileId == activeProfileId`; every mutation
/// writes the active profile's id. The active profile flows in through
/// `activeProfileId` — a closure wired by AppContainer to read
/// SettingsStore.activeProfileId, so switching profiles is a pure re-filter with
/// no re-injection. Sync-reconciliation fetches (in SyncEngine) stay UNfiltered.
@MainActor
final class PlaybackStore {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    /// Resolves the active profile id at call time. Defaults to "default" until
    /// AppContainer wires it to SettingsStore.activeProfileId.
    var activeProfileId: () -> String = { "default" }

    /// Watch-state sync, wired by AppContainer AFTER both objects exist (the
    /// engine holds this store strongly; weak here avoids the cycle and lets
    /// the store work standalone). Every mutation below notifies the engine
    /// with the affected rows after the local write — no-ops when nil or when
    /// sync is disabled, and never affects local behavior.
    weak var syncEngine: SyncEngine?

    init(container: ModelContainer) {
        self.container = container
    }

    /// Snapshot of the active profile for the current call — read once so a
    /// single mutation can't straddle a mid-call profile switch.
    private var profile: String { activeProfileId() }

    // MARK: sync hand-off helpers

    /// Push everything pending RIGHT NOW instead of waiting out the debounce —
    /// used by the player's dismiss/exit save so the phone → TV hand-off row is
    /// on the server before iOS suspends the app (spec §2, writer side).
    func flushSyncNow() {
        syncEngine?.flushNow()
    }

    /// Take the sync background-task assertion NOW, for a caller whose write
    /// happens asynchronously before it can call `flushSyncNow()` (the player's
    /// dismiss/background save). Without it the persist itself runs unprotected
    /// and iOS can suspend the app mid-write. Returns nil when sync is inert;
    /// hand the token back to `endSyncFlushWindow` when the push is enqueued.
    func beginSyncFlushWindow() -> UInt64? {
        syncEngine?.beginFlushWindow()
    }

    func endSyncFlushWindow(_ token: UInt64?) {
        syncEngine?.endFlushWindow(token)
    }

    /// Wait (bounded) for the launch/foreground pull to settle before reading a
    /// resume position, so playback starts from the freshest cross-device
    /// position rather than a stale local row (spec §2, player side). No-op when
    /// sync is off or already settled.
    func awaitSyncSettled(timeoutMs: Int = 2_000) async {
        guard let engine = syncEngine else { return }
        await engine.awaitPullSettled(timeoutMs: timeoutMs)
    }

    // MARK: discovery filtering

    /// Keys ("type:id") that the Home DISCOVERY rows must hide for the active
    /// profile (spec §4c/d): anything with a resume row, any show with at least
    /// one watched episode, and everything already on My List (which has its own
    /// rail earlier in the display order). Continue Watching / My List
    /// themselves are unaffected — they read their own @Query.
    func discoveryHiddenKeys() -> Set<String> {
        let pid = profile
        var keys = Set<String>()
        let progress = (try? context.fetch(FetchDescriptor<WatchProgress>(
            predicate: #Predicate { $0.profileId == pid }))) ?? []
        for row in progress { keys.insert("\(row.typeKey):\(row.mediaId)") }
        let watched = (try? context.fetch(FetchDescriptor<WatchedEpisode>(
            predicate: #Predicate { $0.profileId == pid }))) ?? []
        let showKey = MediaType.show.rawValue
        for row in watched { keys.insert("\(showKey):\(row.mediaId)") }
        let list = (try? context.fetch(FetchDescriptor<MyListItem>(
            predicate: #Predicate { $0.profileId == pid }))) ?? []
        for row in list { keys.insert("\(row.typeKey):\(row.mediaId)") }
        return keys
    }

    // MARK: watch progress

    func progress(mediaId: Int, typeKey: String) -> WatchProgress? {
        let pid = profile
        var d = FetchDescriptor<WatchProgress>(
            predicate: #Predicate { $0.mediaId == mediaId && $0.typeKey == typeKey && $0.profileId == pid }
        )
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    /// Upsert: one progress row per (profile, mediaId, typeKey); shows keep only
    /// the most recent episode's position (same semantics as the Android schema).
    func upsertProgress(mediaId: Int, typeKey: String, imdbId: String?, title: String,
                        posterUrl: String?, backdropUrl: String?, season: Int?, episode: Int?,
                        episodeTitle: String?, positionMs: Int64, durationMs: Int64,
                        year: String?, rating: Double?) {
        let pid = profile
        let row: WatchProgress
        if let existing = progress(mediaId: mediaId, typeKey: typeKey) {
            existing.imdbId = imdbId
            existing.title = title
            existing.posterUrl = posterUrl
            existing.backdropUrl = backdropUrl
            existing.season = season
            existing.episode = episode
            existing.episodeTitle = episodeTitle
            existing.positionMs = positionMs
            existing.durationMs = durationMs
            existing.updatedAt = .now
            existing.year = year
            existing.rating = rating
            row = existing
        } else {
            row = WatchProgress(
                mediaId: mediaId, typeKey: typeKey, profileId: pid, imdbId: imdbId, title: title,
                posterUrl: posterUrl, backdropUrl: backdropUrl, season: season,
                episode: episode, episodeTitle: episodeTitle, positionMs: positionMs,
                durationMs: durationMs, year: year, rating: rating)
            context.insert(row)
        }
        try? context.save()
        syncEngine?.recordProgress(row)
    }

    func removeProgress(mediaId: Int, typeKey: String) {
        guard let row = progress(mediaId: mediaId, typeKey: typeKey) else { return }
        let snapshot = ProgressSnapshot(row)   // capture BEFORE delete — deleted models must not be read
        context.delete(row)
        try? context.save()
        syncEngine?.recordProgressRemoved(snapshot)
    }

    // MARK: watched episodes

    func isWatched(mediaId: Int, season: Int, episode: Int) -> Bool {
        let pid = profile
        var d = FetchDescriptor<WatchedEpisode>(
            predicate: #Predicate { $0.mediaId == mediaId && $0.season == season && $0.episode == episode && $0.profileId == pid }
        )
        d.fetchLimit = 1
        return ((try? context.fetch(d).first) ?? nil) != nil
    }

    func watchedEpisodes(mediaId: Int) -> [WatchedEpisode] {
        let pid = profile
        let d = FetchDescriptor<WatchedEpisode>(predicate: #Predicate { $0.mediaId == mediaId && $0.profileId == pid })
        return (try? context.fetch(d)) ?? []
    }

    func markWatched(mediaId: Int, season: Int, episode: Int) {
        guard !isWatched(mediaId: mediaId, season: season, episode: episode) else { return }
        let row = WatchedEpisode(mediaId: mediaId, profileId: profile, season: season, episode: episode)
        context.insert(row)
        try? context.save()
        syncEngine?.recordWatched(mediaId: mediaId, season: season, episode: episode, watchedAt: row.watchedAt, profileId: row.profileId)
    }

    func markWatchedAll(mediaId: Int, episodes: [(season: Int, episode: Int)]) {
        let pid = profile
        var inserted: [WatchedEpisode] = []
        for e in episodes where !isWatched(mediaId: mediaId, season: e.season, episode: e.episode) {
            let row = WatchedEpisode(mediaId: mediaId, profileId: pid, season: e.season, episode: e.episode)
            context.insert(row)
            inserted.append(row)
        }
        try? context.save()
        for row in inserted {
            syncEngine?.recordWatched(mediaId: mediaId, season: row.season, episode: row.episode, watchedAt: row.watchedAt, profileId: row.profileId)
        }
    }

    func unmarkWatched(mediaId: Int, season: Int, episode: Int) {
        let pid = profile
        let d = FetchDescriptor<WatchedEpisode>(
            predicate: #Predicate { $0.mediaId == mediaId && $0.season == season && $0.episode == episode && $0.profileId == pid }
        )
        let rows = (try? context.fetch(d)) ?? []
        // Capture identity BEFORE deleting so tombstones can be emitted.
        let snapshots = rows.map { (season: $0.season, episode: $0.episode, watchedAt: $0.watchedAt, profileId: $0.profileId) }
        for row in rows { context.delete(row) }
        try? context.save()
        for s in snapshots {
            syncEngine?.recordWatchedRemoved(mediaId: mediaId, season: s.season, episode: s.episode, watchedAt: s.watchedAt, profileId: s.profileId)
        }
    }

    func clearWatchedSeason(mediaId: Int, season: Int) {
        let pid = profile
        let d = FetchDescriptor<WatchedEpisode>(
            predicate: #Predicate { $0.mediaId == mediaId && $0.season == season && $0.profileId == pid }
        )
        let rows = (try? context.fetch(d)) ?? []
        let snapshots = rows.map { (season: $0.season, episode: $0.episode, watchedAt: $0.watchedAt, profileId: $0.profileId) }
        for row in rows { context.delete(row) }
        try? context.save()
        for s in snapshots {
            syncEngine?.recordWatchedRemoved(mediaId: mediaId, season: s.season, episode: s.episode, watchedAt: s.watchedAt, profileId: s.profileId)
        }
    }

    func clearWatchedFor(mediaId: Int) {
        let pid = profile
        let d = FetchDescriptor<WatchedEpisode>(predicate: #Predicate { $0.mediaId == mediaId && $0.profileId == pid })
        let rows = (try? context.fetch(d)) ?? []
        let snapshots = rows.map { (season: $0.season, episode: $0.episode, watchedAt: $0.watchedAt, profileId: $0.profileId) }
        for row in rows { context.delete(row) }
        try? context.save()
        for s in snapshots {
            syncEngine?.recordWatchedRemoved(mediaId: mediaId, season: s.season, episode: s.episode, watchedAt: s.watchedAt, profileId: s.profileId)
        }
    }

    // MARK: my list

    func isInMyList(mediaId: Int, typeKey: String) -> Bool {
        let pid = profile
        var d = FetchDescriptor<MyListItem>(
            predicate: #Predicate { $0.mediaId == mediaId && $0.typeKey == typeKey && $0.profileId == pid }
        )
        d.fetchLimit = 1
        return ((try? context.fetch(d).first) ?? nil) != nil
    }

    func toggleMyList(_ item: MediaItem) {
        let pid = profile
        let mediaId = item.id
        let typeKey = item.type.rawValue
        let d = FetchDescriptor<MyListItem>(
            predicate: #Predicate { $0.mediaId == mediaId && $0.typeKey == typeKey && $0.profileId == pid }
        )
        if let existing = (try? context.fetch(d))?.first {
            let snapshot = MyListSnapshot(existing)   // capture BEFORE delete
            context.delete(existing)
            try? context.save()
            syncEngine?.recordMyListRemoved(snapshot)
        } else {
            let row = MyListItem(
                mediaId: item.id, typeKey: item.type.rawValue, profileId: pid, title: item.title,
                posterUrl: item.posterUrl?.absoluteString,
                backdropUrl: item.backdropUrl?.absoluteString,
                year: item.year, rating: item.rating)
            context.insert(row)
            try? context.save()
            syncEngine?.recordMyListAdded(row)
        }
    }
}
