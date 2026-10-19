import Foundation
import Combine
import SwiftData
import UIKit

/// Watch-state sync client for the velvet-sync server (~/velvet-sync/server.py)
/// — the same last-write-wins store the Shield talks to, so progress, watched
/// history and My List stay identical across devices.
///
/// Semantics (identical on both platforms):
/// - PUSH: every local mutation enqueues the affected full row(s); deletions are
///   tombstones (deleted=true, updatedAt=now). Debounced ~1.5s; on network
///   failure the in-memory queue is kept and retried on the next trigger.
/// - PULL: on launch, on foreground, every 60s while foregrounded, and after a
///   successful push. GET /state?since=<cursor>; a remote row is applied only if
///   its updatedAt beats the local row's own timestamp (progress: updatedAt,
///   watched: watchedAt, mylist: addedAt); tombstones delete the local row.
///   The cursor advances to serverNow only after a fully-successful apply.
/// - FIRST ENABLE / URL CHANGE: cursor resets to 0 → full push of ALL local rows
///   (stored timestamps) then a since=0 pull. This is how the Shield's existing
///   history floods onto the phone.
/// - Disabled or empty URL → fully inert. Failures are silent-but-logged; sync
///   must never break local behavior.

// MARK: - Wire DTOs (server.py camelCase JSON)

/// One progress row on the wire. `positionMs`/`durationMs` are NOT NULL in the
/// server schema, so they're non-optional here — tombstones must carry them too
/// (an explicit JSON null would violate the column constraint server-side).
/// `profileId` is the row's owning profile namespace; (profileId, mediaId, type)
/// is the wire identity. Defaulted on decode so pre-profiles responses still
/// parse (those rows were migrated server-side to "default").
struct SyncProgressRow: Codable {
    var mediaId: Int
    var type: String              // "movie" | "show"
    var profileId: String = "default"
    var imdbId: String?
    var title: String?
    var posterUrl: String?
    var backdropUrl: String?
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var positionMs: Int64
    var durationMs: Int64
    var year: String?
    var rating: Double?
    var updatedAt: Int64          // ms epoch — the LWW key
    var deleted: Bool

    // Member-wise init (the custom decoder below suppresses the synthesized one).
    init(mediaId: Int, type: String, profileId: String = "default", imdbId: String?,
         title: String?, posterUrl: String?, backdropUrl: String?, season: Int?,
         episode: Int?, episodeTitle: String?, positionMs: Int64, durationMs: Int64,
         year: String?, rating: Double?, updatedAt: Int64, deleted: Bool) {
        self.mediaId = mediaId; self.type = type; self.profileId = profileId
        self.imdbId = imdbId; self.title = title; self.posterUrl = posterUrl
        self.backdropUrl = backdropUrl; self.season = season; self.episode = episode
        self.episodeTitle = episodeTitle; self.positionMs = positionMs
        self.durationMs = durationMs; self.year = year; self.rating = rating
        self.updatedAt = updatedAt; self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaId = try c.decode(Int.self, forKey: .mediaId)
        type = try c.decode(String.self, forKey: .type)
        // Defaulted: a pre-profiles server omits it (rows migrated to "default").
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? "default"
        imdbId = try c.decodeIfPresent(String.self, forKey: .imdbId)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        posterUrl = try c.decodeIfPresent(String.self, forKey: .posterUrl)
        backdropUrl = try c.decodeIfPresent(String.self, forKey: .backdropUrl)
        season = try c.decodeIfPresent(Int.self, forKey: .season)
        episode = try c.decodeIfPresent(Int.self, forKey: .episode)
        episodeTitle = try c.decodeIfPresent(String.self, forKey: .episodeTitle)
        positionMs = try c.decode(Int64.self, forKey: .positionMs)
        durationMs = try c.decode(Int64.self, forKey: .durationMs)
        year = try c.decodeIfPresent(String.self, forKey: .year)
        rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        updatedAt = try c.decode(Int64.self, forKey: .updatedAt)
        deleted = try c.decode(Bool.self, forKey: .deleted)
    }
}

struct SyncWatchedRow: Codable {
    var mediaId: Int
    var profileId: String = "default"
    var season: Int
    var episode: Int
    var watchedAt: Int64          // ms epoch (NOT NULL server-side)
    var updatedAt: Int64
    var deleted: Bool

    init(mediaId: Int, profileId: String = "default", season: Int, episode: Int,
         watchedAt: Int64, updatedAt: Int64, deleted: Bool) {
        self.mediaId = mediaId; self.profileId = profileId; self.season = season
        self.episode = episode; self.watchedAt = watchedAt
        self.updatedAt = updatedAt; self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaId = try c.decode(Int.self, forKey: .mediaId)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? "default"
        season = try c.decode(Int.self, forKey: .season)
        episode = try c.decode(Int.self, forKey: .episode)
        watchedAt = try c.decode(Int64.self, forKey: .watchedAt)
        updatedAt = try c.decode(Int64.self, forKey: .updatedAt)
        deleted = try c.decode(Bool.self, forKey: .deleted)
    }
}

struct SyncMyListRow: Codable {
    var mediaId: Int
    var type: String
    var profileId: String = "default"
    var title: String?
    var posterUrl: String?
    var backdropUrl: String?
    var year: String?
    var rating: Double?
    var addedAt: Int64            // ms epoch (NOT NULL server-side)
    var updatedAt: Int64
    var deleted: Bool

    init(mediaId: Int, type: String, profileId: String = "default", title: String?,
         posterUrl: String?, backdropUrl: String?, year: String?, rating: Double?,
         addedAt: Int64, updatedAt: Int64, deleted: Bool) {
        self.mediaId = mediaId; self.type = type; self.profileId = profileId
        self.title = title; self.posterUrl = posterUrl; self.backdropUrl = backdropUrl
        self.year = year; self.rating = rating; self.addedAt = addedAt
        self.updatedAt = updatedAt; self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaId = try c.decode(Int.self, forKey: .mediaId)
        type = try c.decode(String.self, forKey: .type)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? "default"
        title = try c.decodeIfPresent(String.self, forKey: .title)
        posterUrl = try c.decodeIfPresent(String.self, forKey: .posterUrl)
        backdropUrl = try c.decodeIfPresent(String.self, forKey: .backdropUrl)
        year = try c.decodeIfPresent(String.self, forKey: .year)
        rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        addedAt = try c.decode(Int64.self, forKey: .addedAt)
        updatedAt = try c.decode(Int64.self, forKey: .updatedAt)
        deleted = try c.decode(Bool.self, forKey: .deleted)
    }
}

/// A viewer profile on the wire (server `profiles` table). Global — no profile
/// filter; LWW on `updatedAt`; `deleted` is the tombstone.
struct SyncProfileRow: Codable {
    var id: String
    var name: String
    var color: String
    var createdAt: Int64          // ms epoch
    var updatedAt: Int64          // ms epoch — the LWW key
    var deleted: Bool
}

struct SyncStateResponse: Codable {
    var serverNow: Int64
    var profiles: [SyncProfileRow] = []
    var progress: [SyncProgressRow]
    var watched: [SyncWatchedRow]
    var mylist: [SyncMyListRow]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverNow = try c.decode(Int64.self, forKey: .serverNow)
        // Defaulted: a pre-profiles server omits the profiles array entirely.
        profiles = try c.decodeIfPresent([SyncProfileRow].self, forKey: .profiles) ?? []
        progress = try c.decode([SyncProgressRow].self, forKey: .progress)
        watched = try c.decode([SyncWatchedRow].self, forKey: .watched)
        mylist = try c.decode([SyncMyListRow].self, forKey: .mylist)
    }
}

struct SyncPushBody: Codable {
    var profiles: [SyncProfileRow]
    var progress: [SyncProgressRow]
    var watched: [SyncWatchedRow]
    var mylist: [SyncMyListRow]
}

struct SyncPushResponse: Codable {
    var serverNow: Int64
    var applied: Int
}

// MARK: - Pre-deletion snapshots

/// Plain value copy of a WatchProgress row. PlaybackStore captures one BEFORE
/// context.delete — a deleted @Model must never be read again — so the
/// tombstone can carry the full row payload.
struct ProgressSnapshot {
    let mediaId: Int
    let typeKey: String
    let profileId: String
    let imdbId: String?
    let title: String
    let posterUrl: String?
    let backdropUrl: String?
    let season: Int?
    let episode: Int?
    let episodeTitle: String?
    let positionMs: Int64
    let durationMs: Int64
    let year: String?
    let rating: Double?

    init(_ row: WatchProgress) {
        mediaId = row.mediaId
        typeKey = row.typeKey
        profileId = row.profileId
        imdbId = row.imdbId
        title = row.title
        posterUrl = row.posterUrl
        backdropUrl = row.backdropUrl
        season = row.season
        episode = row.episode
        episodeTitle = row.episodeTitle
        positionMs = row.positionMs
        durationMs = row.durationMs
        year = row.year
        rating = row.rating
    }
}

/// Same idea for MyListItem rows.
struct MyListSnapshot {
    let mediaId: Int
    let typeKey: String
    let profileId: String
    let title: String
    let posterUrl: String?
    let backdropUrl: String?
    let year: String?
    let rating: Double?
    let addedAt: Date

    init(_ row: MyListItem) {
        mediaId = row.mediaId
        typeKey = row.typeKey
        profileId = row.profileId
        title = row.title
        posterUrl = row.posterUrl
        backdropUrl = row.backdropUrl
        year = row.year
        rating = row.rating
        addedAt = row.addedAt
    }
}

enum SyncError: Error {
    case badUrl
    case http(Int)
}

// MARK: - Engine

@MainActor
final class SyncEngine {
    private let playback: PlaybackStore
    private let settings: SettingsStore
    /// Wired by AppContainer after both objects exist (weak — no init cycle).
    /// Profiles sync globally; pulled profile rows are applied here and the store
    /// is refreshed so the picker / active-profile selection stay current.
    weak var profileStore: ProfileStore?
    private var cancellables: Set<AnyCancellable> = []

    /// Pending push queue, keyed per row so rapid re-mutations coalesce to the
    /// newest payload. In-memory only by design — a lost queue is healed by the
    /// next cursor-0 full reconcile (and the server rejects stale rows anyway).
    private var pendingProgress: [String: SyncProgressRow] = [:]
    private var pendingWatched: [String: SyncWatchedRow] = [:]
    private var pendingMyList: [String: SyncMyListRow] = [:]
    private var pendingProfiles: [String: SyncProfileRow] = [:]

    private var debounceTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var syncInFlight = false

    /// Pull cadence (spec §2, reader side): 20s while the user is actually
    /// LOOKING at Continue Watching, 60s everywhere else (incl. the player).
    private static let homeIntervalNanos: UInt64 = 20_000_000_000
    private static let idleIntervalNanos: UInt64 = 60_000_000_000
    /// Home is the visible tab (set by HomeView's appear/disappear + scenePhase).
    private var homeVisible = false
    /// The player cover is up — its own 60s cadence wins over Home's 20s.
    private var playerActive = false
    /// Interval the running ticker was started with, so startTicker() stays
    /// idempotent but still restarts when the cadence actually changes.
    private var tickerIntervalNanos: UInt64 = 0

    /// False while the launch/foreground sync is still running. The player waits
    /// on this (bounded) before reading a resume position so a position written
    /// on another device wins over the stale local row (spec §2, player side).
    private var launchSyncSettled = true

    /// Background-task handle for the backgrounding flush + the player's
    /// dismiss flush — without it iOS can suspend the app mid-request and the
    /// phone → TV hand-off silently never lands (spec §2, writer side).
    private var bgFlushTaskId: UIBackgroundTaskIdentifier = .invalid
    /// Outstanding flushes sharing the single background-task assertion.
    private var bgFlushRefs = 0
    /// Bumped every time the assertion is torn down (refcount hit zero OR iOS
    /// expired it). Each begin/end pair carries the generation it opened under,
    /// so a flush whose network call returns AFTER an expiration can't decrement
    /// — and therefore can't end — the assertion a newer flush has since taken.
    private var bgFlushGeneration: UInt64 = 0

    init(playback: PlaybackStore, settings: SettingsStore) {
        self.playback = playback
        self.settings = settings

        // First-enable / URL-change → reset the cursor so the next sync does the
        // full push + since=0 pull. NOTE: @Published fires on willSet, so use
        // the closure's value, never the (still-old) property, for the toggle.
        settings.$syncEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.settings.syncCursor = 0
                    self.syncNow()
                } else {
                    self.debounceTask?.cancel()
                    self.pendingProgress.removeAll()
                    self.pendingWatched.removeAll()
                    self.pendingMyList.removeAll()
                    self.pendingProfiles.removeAll()
                    self.settings.lastSyncStatus = ""
                }
            }
            .store(in: &cancellables)

        settings.$syncUrl
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, self.settings.syncEnabled else { return }
                self.settings.syncCursor = 0
                self.syncNow()
            }
            .store(in: &cancellables)
    }

    /// Disabled or empty URL → every entry point below is a no-op.
    private var isActive: Bool {
        settings.syncEnabled && !SettingsStore.normalizeBaseUrl(settings.syncUrl).isEmpty
    }

    // MARK: mutation notifications (called by PlaybackStore AFTER the local write)

    func recordProgress(_ row: WatchProgress) {
        guard isActive else { return }
        pendingProgress[progressKey(row.profileId, row.mediaId, row.typeKey)] = SyncProgressRow(
            mediaId: row.mediaId, type: row.typeKey, profileId: row.profileId,
            imdbId: row.imdbId, title: row.title,
            posterUrl: row.posterUrl, backdropUrl: row.backdropUrl, season: row.season,
            episode: row.episode, episodeTitle: row.episodeTitle, positionMs: row.positionMs,
            durationMs: row.durationMs, year: row.year, rating: row.rating,
            updatedAt: ms(row.updatedAt), deleted: false)
        scheduleDebouncedPush()
    }

    func recordProgressRemoved(_ s: ProgressSnapshot) {
        guard isActive else { return }
        pendingProgress[progressKey(s.profileId, s.mediaId, s.typeKey)] = SyncProgressRow(
            mediaId: s.mediaId, type: s.typeKey, profileId: s.profileId,
            imdbId: s.imdbId, title: s.title,
            posterUrl: s.posterUrl, backdropUrl: s.backdropUrl, season: s.season,
            episode: s.episode, episodeTitle: s.episodeTitle, positionMs: s.positionMs,
            durationMs: s.durationMs, year: s.year, rating: s.rating,
            updatedAt: nowMs(), deleted: true)
        scheduleDebouncedPush()
    }

    func recordWatched(mediaId: Int, season: Int, episode: Int, watchedAt: Date, profileId: String) {
        guard isActive else { return }
        let ts = ms(watchedAt)
        pendingWatched[watchedKey(profileId, mediaId, season, episode)] = SyncWatchedRow(
            mediaId: mediaId, profileId: profileId, season: season, episode: episode,
            watchedAt: ts, updatedAt: ts, deleted: false)
        scheduleDebouncedPush()
    }

    func recordWatchedRemoved(mediaId: Int, season: Int, episode: Int, watchedAt: Date, profileId: String) {
        guard isActive else { return }
        pendingWatched[watchedKey(profileId, mediaId, season, episode)] = SyncWatchedRow(
            mediaId: mediaId, profileId: profileId, season: season, episode: episode,
            watchedAt: ms(watchedAt), updatedAt: nowMs(), deleted: true)
        scheduleDebouncedPush()
    }

    func recordMyListAdded(_ row: MyListItem) {
        guard isActive else { return }
        let ts = ms(row.addedAt)
        pendingMyList[progressKey(row.profileId, row.mediaId, row.typeKey)] = SyncMyListRow(
            mediaId: row.mediaId, type: row.typeKey, profileId: row.profileId, title: row.title,
            posterUrl: row.posterUrl, backdropUrl: row.backdropUrl,
            year: row.year, rating: row.rating,
            addedAt: ts, updatedAt: ts, deleted: false)
        scheduleDebouncedPush()
    }

    func recordMyListRemoved(_ s: MyListSnapshot) {
        guard isActive else { return }
        pendingMyList[progressKey(s.profileId, s.mediaId, s.typeKey)] = SyncMyListRow(
            mediaId: s.mediaId, type: s.typeKey, profileId: s.profileId, title: s.title,
            posterUrl: s.posterUrl, backdropUrl: s.backdropUrl,
            year: s.year, rating: s.rating,
            addedAt: ms(s.addedAt), updatedAt: nowMs(), deleted: true)
        scheduleDebouncedPush()
    }

    /// Profile create / rename / delete (tombstone). The Profile's own
    /// `updatedAt` is the LWW key; ProfileStore stamps it to `now` before this.
    func recordProfile(_ row: Profile) {
        guard isActive else { return }
        pendingProfiles[row.id] = SyncProfileRow(
            id: row.id, name: row.name, color: row.color,
            createdAt: ms(row.createdAt), updatedAt: ms(row.updatedAt), deleted: row.deleted)
        scheduleDebouncedPush()
    }

    // MARK: lifecycle triggers

    /// Launch + scene becomes active: start the ticker and sync immediately.
    /// Idempotent — onAppear and the scenePhase change can both fire at launch.
    func onAppForegrounded() {
        startTicker()
        guard isActive else {
            launchSyncSettled = true
            return
        }
        launchSyncSettled = false
        Task { [weak self] in
            await self?.performSync()
            self?.launchSyncSettled = true
        }
    }

    func onAppBackgrounded() {
        tickerTask?.cancel()
        tickerTask = nil
        tickerIntervalNanos = 0
        // Flush anything still debouncing inside a background-task assertion:
        // without it iOS can suspend the app mid-request and the position the
        // TV is about to read never leaves the phone.
        flushNow()
    }

    /// Manual / programmatic full sync: push pending (queueing a full reconcile
    /// first when the cursor is 0), then pull.
    func syncNow() {
        Task { [weak self] in await self?.performSync() }
    }

    /// Push everything pending RIGHT NOW — no debounce — inside a background
    /// task so the request survives the app being backgrounded mid-flight
    /// (spec §2, writer side). Used by backgrounding AND by the player's
    /// dismiss/exit progress save, the write that the hand-off depends on.
    func flushNow() {
        guard isActive else { return }
        debounceTask?.cancel()
        let token = beginBackgroundFlush()
        Task { [weak self] in
            await self?.flushPush()
            self?.endBackgroundFlush(token)
        }
    }

    /// Hold the background-task assertion across work that happens BEFORE the
    /// push is even enqueued. The player's dismiss/background save writes the
    /// row asynchronously (and may round-trip TMDB for the next episode) before
    /// it can call `flushNow()`; without an assertion held from the call site,
    /// iOS can suspend the app during that window and neither the local row nor
    /// the push lands — the exact hand-off failure spec §2 exists to kill.
    /// Returns nil when sync is inert; pass the token back to `endFlushWindow`.
    func beginFlushWindow() -> UInt64? {
        guard isActive else { return nil }
        return beginBackgroundFlush()
    }

    func endFlushWindow(_ token: UInt64?) {
        guard let token else { return }
        endBackgroundFlush(token)
    }

    /// Home became / stopped being the thing on screen. Drives the 20s-vs-60s
    /// pull cadence and pulls immediately on arrival (spec §2, reader side).
    func setHomeVisible(_ visible: Bool) {
        guard homeVisible != visible else { return }
        homeVisible = visible
        applyCadence()
        if visible { pullNow() }
    }

    /// The player cover is up (60s cadence — the phone isn't looking at
    /// Continue Watching while it's playing).
    func setPlayerActive(_ active: Bool) {
        guard playerActive != active else { return }
        playerActive = active
        applyCadence()
    }

    /// Cheap cursor-based delta pull for "the user is about to LOOK at Continue
    /// Watching". NEVER resets the cursor and never triggers a full reconcile —
    /// except when the cursor is still 0 (first enable / URL change), where the
    /// full push-then-pull is the only correct behavior.
    func pullNow() {
        guard isActive else { return }
        if settings.syncCursor == 0 {
            syncNow()
            return
        }
        Task { [weak self] in await self?.performPullOnly() }
    }

    /// Wait (bounded, polled) for the launch/foreground sync to finish so the
    /// player reads progress from a settled store instead of a stale snapshot.
    /// Returns immediately when sync is inert or already settled.
    func awaitPullSettled(timeoutMs: Int = 2_000) async {
        guard isActive else { return }
        var waited = 0
        while (!launchSyncSettled || syncInFlight) && waited < timeoutMs {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 100
        }
    }

    // MARK: background-task assertion

    /// Returns the generation this flush opened under — `endBackgroundFlush`
    /// only acts on a matching one.
    @discardableResult
    private func beginBackgroundFlush() -> UInt64 {
        bgFlushRefs += 1
        guard bgFlushTaskId == .invalid else { return bgFlushGeneration }
        bgFlushTaskId = UIApplication.shared.beginBackgroundTask(withName: "velvet.sync.flush") { [weak self] in
            // UIKit calls the expiration handler on the main thread.
            MainActor.assumeIsolated { self?.expireBackgroundFlush() }
        }
        return bgFlushGeneration
    }

    private func endBackgroundFlush(_ generation: UInt64) {
        // A stale flush (its generation was retired by an expiration, or by the
        // refcount already reaching zero) must not decrement the refcount a
        // LATER flush is relying on — that would end the assertion protecting a
        // push still in flight.
        guard generation == bgFlushGeneration else { return }
        guard bgFlushRefs > 0 else { return }
        bgFlushRefs -= 1
        guard bgFlushRefs == 0 else { return }
        expireBackgroundFlush()
    }

    private func expireBackgroundFlush() {
        bgFlushRefs = 0
        bgFlushGeneration &+= 1
        guard bgFlushTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgFlushTaskId)
        bgFlushTaskId = .invalid
    }

    // MARK: internals

    private func scheduleDebouncedPush() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            await self?.performSync()
        }
    }

    /// 20s while Home is the visible surface, 60s otherwise. Idempotent: only
    /// restarts when the cadence actually changed (or nothing is running).
    private var cadenceNanos: UInt64 {
        (homeVisible && !playerActive) ? Self.homeIntervalNanos : Self.idleIntervalNanos
    }

    private func startTicker() {
        let interval = cadenceNanos
        if tickerTask != nil && tickerIntervalNanos == interval { return }
        tickerTask?.cancel()
        tickerIntervalNanos = interval
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                await self?.performSync()
            }
        }
    }

    /// Re-time the ticker after a visibility change — but never resurrect it
    /// while backgrounded (onAppBackgrounded cancelled it on purpose).
    private func applyCadence() {
        guard tickerTask != nil else { return }
        startTicker()
    }

    /// One sync pass: (optional full-reconcile enqueue) → push → pull. Single-
    /// flight; an overlapping trigger is dropped — its rows stay queued and the
    /// next trigger (≤60s away while foregrounded) picks them up.
    private func performSync() async {
        guard isActive, !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false }

        // Cursor 0 = first enable, URL change, or an interrupted first sync —
        // queue EVERY local row (stored timestamps) so both sides converge.
        if settings.syncCursor == 0 { enqueueAllLocalRows() }

        let pushed = await flushPush()
        let pulled = await pull()
        let time = Date.now.formatted(date: .omitted, time: .shortened)
        switch (pushed, pulled) {
        case let (p?, a?):
            settings.lastSyncStatus = "Synced \(time) · sent \(p), applied \(a)"
        case (nil, _):
            settings.lastSyncStatus = "Push failed \(time) — will retry"
        default:
            settings.lastSyncStatus = "Pull failed \(time) — will retry"
        }
    }

    /// Reader-side delta pass: pull ONLY (no full-reconcile enqueue, no cursor
    /// reset) — the cheap "is there a newer position from the phone/TV?" check
    /// fired when Home appears and on every 20s Home tick.
    private func performPullOnly() async {
        guard isActive, !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false }

        let applied = await pull()
        let time = Date.now.formatted(date: .omitted, time: .shortened)
        if let applied {
            settings.lastSyncStatus = "Synced \(time) · applied \(applied)"
        } else {
            settings.lastSyncStatus = "Pull failed \(time) — will retry"
        }
    }

    /// POST /push with everything pending. Returns the row count sent (0 when
    /// idle) or nil on failure — the queue is kept for retry-on-next-trigger.
    @discardableResult
    private func flushPush() async -> Int? {
        guard isActive else { return nil }
        if pendingProgress.isEmpty && pendingWatched.isEmpty
            && pendingMyList.isEmpty && pendingProfiles.isEmpty { return 0 }
        let sentProgress = pendingProgress
        let sentWatched = pendingWatched
        let sentMyList = pendingMyList
        let sentProfiles = pendingProfiles
        do {
            let body = SyncPushBody(
                profiles: Array(sentProfiles.values),
                progress: Array(sentProgress.values),
                watched: Array(sentWatched.values),
                mylist: Array(sentMyList.values))
            let request = try makeRequest(path: "/push", method: "POST", body: JSONEncoder().encode(body))
            let _: SyncPushResponse = try await send(request)
            // Drop only what we sent — rows re-enqueued with a newer updatedAt
            // during the network await stay queued for the next batch.
            for (key, row) in sentProgress where pendingProgress[key]?.updatedAt == row.updatedAt {
                pendingProgress[key] = nil
            }
            for (key, row) in sentWatched where pendingWatched[key]?.updatedAt == row.updatedAt {
                pendingWatched[key] = nil
            }
            for (key, row) in sentMyList where pendingMyList[key]?.updatedAt == row.updatedAt {
                pendingMyList[key] = nil
            }
            for (key, row) in sentProfiles where pendingProfiles[key]?.updatedAt == row.updatedAt {
                pendingProfiles[key] = nil
            }
            return sentProgress.count + sentWatched.count + sentMyList.count + sentProfiles.count
        } catch {
            print("[sync] push failed: \(error)")
            return nil
        }
    }

    /// GET /state?since=<cursor> and apply. Returns rows applied, nil on failure.
    /// The cursor advances to serverNow ONLY after a fully-successful apply.
    private func pull() async -> Int? {
        guard isActive else { return nil }
        do {
            let request = try makeRequest(path: "/state", query: "since=\(settings.syncCursor)")
            let state: SyncStateResponse = try await send(request)
            let applied = try applyState(state)
            settings.syncCursor = state.serverNow
            // Spec §1b: self-heal duplicate profiles after EVERY successful
            // pull, then push the merge so every device converges on it.
            if healDuplicateProfiles() {
                await flushPush()
            }
            return applied
        } catch {
            print("[sync] pull failed: \(error)")
            return nil
        }
    }

    /// LWW apply: a remote row wins only if its updatedAt beats the local row's
    /// own timestamp (progress: updatedAt; watched: watchedAt; mylist: addedAt).
    /// Applied rows keep the REMOTE timestamp locally so comparisons stay
    /// stable and re-pushing them is a server-side no-op. Writes go straight to
    /// the model context — never through PlaybackStore's mutators — so pulls
    /// can't echo back into the push queue.
    private func applyState(_ state: SyncStateResponse) throws -> Int {
        let context = playback.context
        var applied = 0
        var profilesChanged = false
        /// Name of THIS device's active profile at the moment a remote tombstone
        /// removed it. Spec §1b: the merging device repoints itself, but a device
        /// that only receives the merge must resolve the same-named keeper here —
        /// otherwise `reconcileActiveProfile()` silently drops the viewer into the
        /// oldest profile (someone else's lists).
        var vanishedActiveNameKey: String?

        // Profiles first (global, LWW on updatedAt; tombstone = delete locally).
        // A profile NOT present locally just appears (so one made on the phone
        // shows on the TV).
        for row in state.profiles {
            let local = localProfile(id: row.id)
            if let local, ms(local.updatedAt) >= row.updatedAt { continue }
            if row.deleted, row.id == settings.activeProfileId {
                // Prefer the name the row carries; fall back to the local copy
                // (a rename could have ridden along with the tombstone).
                let key = ProfileStore.nameKey(row.name)
                vanishedActiveNameKey = key.isEmpty
                    ? local.map { ProfileStore.nameKey($0.name) }
                    : key
            }
            if let local {
                local.name = row.name
                local.color = row.color
                local.createdAt = date(row.createdAt)
                local.updatedAt = date(row.updatedAt)
                local.deleted = row.deleted
            } else {
                context.insert(Profile(
                    id: row.id, name: row.name, color: row.color,
                    createdAt: date(row.createdAt), updatedAt: date(row.updatedAt),
                    deleted: row.deleted))
            }
            applied += 1
            profilesChanged = true
        }

        // Data rows: local lookup is keyed by (profileId, …) — UNfiltered by the
        // active profile, since every profile's rows arrive here.
        for row in state.progress {
            let local = localProgress(profileId: row.profileId, mediaId: row.mediaId, typeKey: row.type)
            if let local, ms(local.updatedAt) >= row.updatedAt { continue }
            if row.deleted {
                if let local { context.delete(local); applied += 1 }
            } else if let local {
                local.imdbId = row.imdbId
                local.title = row.title ?? local.title
                local.posterUrl = row.posterUrl
                local.backdropUrl = row.backdropUrl
                local.season = row.season
                local.episode = row.episode
                local.episodeTitle = row.episodeTitle
                local.positionMs = row.positionMs
                local.durationMs = row.durationMs
                local.year = row.year
                local.rating = row.rating
                local.updatedAt = date(row.updatedAt)
                applied += 1
            } else {
                context.insert(WatchProgress(
                    mediaId: row.mediaId, typeKey: row.type, profileId: row.profileId,
                    imdbId: row.imdbId,
                    title: row.title ?? "", posterUrl: row.posterUrl,
                    backdropUrl: row.backdropUrl, season: row.season,
                    episode: row.episode, episodeTitle: row.episodeTitle,
                    positionMs: row.positionMs, durationMs: row.durationMs,
                    updatedAt: date(row.updatedAt), year: row.year, rating: row.rating))
                applied += 1
            }
        }

        for row in state.watched {
            let local = localWatched(profileId: row.profileId, mediaId: row.mediaId,
                                     season: row.season, episode: row.episode)
            if let local, ms(local.watchedAt) >= row.updatedAt { continue }
            if row.deleted {
                if let local { context.delete(local); applied += 1 }
            } else if let local {
                local.watchedAt = date(row.watchedAt)
                applied += 1
            } else {
                context.insert(WatchedEpisode(
                    mediaId: row.mediaId, profileId: row.profileId,
                    season: row.season, episode: row.episode,
                    watchedAt: date(row.watchedAt)))
                applied += 1
            }
        }

        for row in state.mylist {
            let local = localMyList(profileId: row.profileId, mediaId: row.mediaId, typeKey: row.type)
            if let local, ms(local.addedAt) >= row.updatedAt { continue }
            if row.deleted {
                if let local { context.delete(local); applied += 1 }
            } else if let local {
                local.title = row.title ?? local.title
                local.posterUrl = row.posterUrl
                local.backdropUrl = row.backdropUrl
                local.year = row.year
                local.rating = row.rating
                local.addedAt = date(row.addedAt)
                applied += 1
            } else {
                context.insert(MyListItem(
                    mediaId: row.mediaId, typeKey: row.type, profileId: row.profileId,
                    title: row.title ?? "",
                    posterUrl: row.posterUrl, backdropUrl: row.backdropUrl,
                    year: row.year, rating: row.rating, addedAt: date(row.addedAt)))
                applied += 1
            }
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        // Refresh the @Published profile list + keep the active selection valid
        // (a remote tombstone may have removed the active profile here).
        if profilesChanged {
            profileStore?.refresh()
            profileStore?.reconcileActiveProfile(preferredNameKey: vanishedActiveNameKey)
        }
        return applied
    }

    /// Full reconcile: queue every local row with its STORED timestamp. The
    /// server's LWW rejects anything it already has at >= that timestamp, so
    /// this is cheap to repeat. Never clobbers a newer pending entry (e.g. a
    /// tombstone enqueued moments ago).
    private func enqueueAllLocalRows() {
        let context = playback.context
        // ALL profiles (incl. tombstoned — the server LWW-merges them) and ALL
        // rows across ALL profiles. These fetches are deliberately UNfiltered.
        for row in (try? context.fetch(FetchDescriptor<Profile>())) ?? [] {
            let ts = ms(row.updatedAt)
            if let pending = pendingProfiles[row.id], pending.updatedAt >= ts { continue }
            pendingProfiles[row.id] = SyncProfileRow(
                id: row.id, name: row.name, color: row.color,
                createdAt: ms(row.createdAt), updatedAt: ts, deleted: row.deleted)
        }
        for row in (try? context.fetch(FetchDescriptor<WatchProgress>())) ?? [] {
            let key = progressKey(row.profileId, row.mediaId, row.typeKey)
            let ts = ms(row.updatedAt)
            if let pending = pendingProgress[key], pending.updatedAt >= ts { continue }
            pendingProgress[key] = SyncProgressRow(
                mediaId: row.mediaId, type: row.typeKey, profileId: row.profileId,
                imdbId: row.imdbId, title: row.title,
                posterUrl: row.posterUrl, backdropUrl: row.backdropUrl, season: row.season,
                episode: row.episode, episodeTitle: row.episodeTitle, positionMs: row.positionMs,
                durationMs: row.durationMs, year: row.year, rating: row.rating,
                updatedAt: ts, deleted: false)
        }
        for row in (try? context.fetch(FetchDescriptor<WatchedEpisode>())) ?? [] {
            let key = watchedKey(row.profileId, row.mediaId, row.season, row.episode)
            let ts = ms(row.watchedAt)
            if let pending = pendingWatched[key], pending.updatedAt >= ts { continue }
            pendingWatched[key] = SyncWatchedRow(
                mediaId: row.mediaId, profileId: row.profileId, season: row.season, episode: row.episode,
                watchedAt: ts, updatedAt: ts, deleted: false)
        }
        for row in (try? context.fetch(FetchDescriptor<MyListItem>())) ?? [] {
            let key = progressKey(row.profileId, row.mediaId, row.typeKey)
            let ts = ms(row.addedAt)
            if let pending = pendingMyList[key], pending.updatedAt >= ts { continue }
            pendingMyList[key] = SyncMyListRow(
                mediaId: row.mediaId, type: row.typeKey, profileId: row.profileId, title: row.title,
                posterUrl: row.posterUrl, backdropUrl: row.backdropUrl,
                year: row.year, rating: row.rating,
                addedAt: ts, updatedAt: ts, deleted: false)
        }
    }

    // MARK: - §1b self-heal: duplicate profile merge

    /// Wire rows produced by a merge, enqueued only AFTER the local write is
    /// safely committed (a rolled-back merge must not push tombstones for rows
    /// that still exist locally).
    private struct MergePayload {
        var progress: [SyncProgressRow] = []
        var watched: [SyncWatchedRow] = []
        var mylist: [SyncMyListRow] = []
        var profiles: [SyncProfileRow] = []

        var isEmpty: Bool {
            progress.isEmpty && watched.isEmpty && mylist.isEmpty && profiles.isEmpty
        }
    }

    /// Keeper-side rows touched during one merge group. Two losers can carry the
    /// same title, and a freshly inserted row is not guaranteed to come back
    /// from an unsaved fetch — so remember what we created/updated instead of
    /// re-querying and inserting a second copy.
    private struct MergeCaches {
        var progress: [String: WatchProgress] = [:]
        var watched: [String: WatchedEpisode] = [:]
        var mylist: [String: MyListItem] = [:]
    }

    /// Runs after every successful PULL. Two devices that created the same
    /// profile name before sync merged them leave two live rows with different
    /// UUIDs (exactly the duplicate "Taylor" case). Collapse them the same way
    /// on every device:
    ///   - KEEP the smallest `createdAt` (tie → lexicographically smallest id);
    ///     `"default"` is ALWAYS the keeper when it's one of the duplicates.
    ///   - Re-tag every non-deleted watch row from a loser onto the keeper,
    ///     carrying the row's OWN timestamp so LWW keeps the freshest copy when
    ///     the keeper already has that title, then tombstone the original.
    ///   - Tombstone the losing profile, repoint the active profile if it was a
    ///     loser, and enqueue the whole lot so every device converges.
    /// Returns true when anything merged (the caller then pushes).
    @discardableResult
    private func healDuplicateProfiles() -> Bool {
        let context = playback.context
        // ALL profiles, not just live ones: the tombstoned duplicates are what
        // the stranded-row sweep below keys off.
        let allProfiles = (try? context.fetch(FetchDescriptor<Profile>())) ?? []
        let live = allProfiles.filter { !$0.deleted }

        var groups: [String: [Profile]] = [:]
        for row in live {
            let key = ProfileStore.nameKey(row.name)
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(row)
        }

        var payload = MergePayload()
        var repointActiveTo: String?
        for (_, group) in groups where group.count > 1 {
            // "default" is never merged away — it's the migrated namespace every
            // pre-profiles watch row still carries.
            let keeper = keeperOf(group)
            var caches = MergeCaches()
            for loser in group where loser.id != keeper.id {
                mergeWatchRows(from: loser.id, into: keeper.id,
                               payload: &payload, caches: &caches)
                loser.deleted = true
                loser.updatedAt = .now
                payload.profiles.append(SyncProfileRow(
                    id: loser.id, name: loser.name, color: loser.color,
                    createdAt: ms(loser.createdAt), updatedAt: ms(loser.updatedAt),
                    deleted: true))
                if settings.activeProfileId == loser.id { repointActiveTo = keeper.id }
                print("[sync] merged duplicate profile '\(loser.name)' \(loser.id) → \(keeper.id)")
            }
        }

        // Second pass: rows that arrive AFTER the duplicate was already
        // tombstoned (device B wrote them offline under the loser and pushed
        // once device A had merged) land in a namespace no UI queries and no
        // live-duplicate pass can ever see again. Re-tag them onto the same-name
        // survivor. Deliberately narrow: a tombstoned profile with NO live
        // same-name profile is a real user deletion, whose orphaned rows are
        // meant to stay put (ProfileStore.delete) — never folded into "default".
        // `live` is re-derived: the first pass just tombstoned its losers, and
        // they must not read as survivors here.
        healStrandedWatchRows(allProfiles: allProfiles,
                              live: allProfiles.filter { !$0.deleted },
                              payload: &payload)

        if payload.isEmpty { return false }

        do {
            try context.save()
        } catch {
            context.rollback()
            print("[sync] duplicate-profile merge rolled back: \(error)")
            return false
        }

        // Enqueue only after the local write committed. Never clobber a pending
        // entry that is already newer (same rule as enqueueAllLocalRows).
        for row in payload.progress {
            let key = progressKey(row.profileId, row.mediaId, row.type)
            if let pending = pendingProgress[key], pending.updatedAt > row.updatedAt { continue }
            pendingProgress[key] = row
        }
        for row in payload.watched {
            let key = watchedKey(row.profileId, row.mediaId, row.season, row.episode)
            if let pending = pendingWatched[key], pending.updatedAt > row.updatedAt { continue }
            pendingWatched[key] = row
        }
        for row in payload.mylist {
            let key = progressKey(row.profileId, row.mediaId, row.type)
            if let pending = pendingMyList[key], pending.updatedAt > row.updatedAt { continue }
            pendingMyList[key] = row
        }
        for row in payload.profiles {
            if let pending = pendingProfiles[row.id], pending.updatedAt > row.updatedAt { continue }
            pendingProfiles[row.id] = row
        }
        if let repointActiveTo { settings.activeProfileId = repointActiveTo }
        profileStore?.refresh()
        profileStore?.reconcileActiveProfile()
        return true
    }

    /// The survivor of a same-name group: `"default"` always, else the smallest
    /// `createdAt`, tie-broken by the lexicographically smallest id (spec §1b).
    private func keeperOf(_ group: [Profile]) -> Profile {
        group.first { $0.id == ProfileStore.defaultId }
            ?? group.sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
            }[0]
    }

    /// Re-tag watch rows still carrying a TOMBSTONED duplicate profile's id onto
    /// that name's live keeper. Cheap: it derives its work list purely from the
    /// profile table and touches the row tables only for ids that actually have
    /// a same-name survivor, so the common case does no row fetches at all.
    private func healStrandedWatchRows(allProfiles: [Profile], live: [Profile],
                                       payload: inout MergePayload) {
        guard !live.isEmpty else { return }
        var liveByName: [String: [Profile]] = [:]
        for row in live {
            let key = ProfileStore.nameKey(row.name)
            guard !key.isEmpty else { continue }
            liveByName[key, default: []].append(row)
        }
        guard !liveByName.isEmpty else { return }

        // orphan profile id -> keeper id, resolved by name only.
        var targets: [(loser: String, keeper: String, name: String)] = []
        for row in allProfiles where row.deleted {
            let key = ProfileStore.nameKey(row.name)
            guard !key.isEmpty, let matches = liveByName[key] else { continue }
            let keeper = keeperOf(matches)
            guard keeper.id != row.id else { continue }
            // Only a MERGE loser, never a delete-then-recreate. A duplicate's
            // keeper is by definition the older row; if the live namesake was
            // created AFTER the tombstone, the user deleted a profile and later
            // made a new one with the same name — that new profile must not
            // inherit the old one's history.
            guard keeper.createdAt <= row.createdAt else { continue }
            targets.append((loser: row.id, keeper: keeper.id, name: row.name))
        }
        guard !targets.isEmpty else { return }

        // Two orphans can map to the same keeper and carry the same title —
        // share one cache per keeper so the second doesn't insert a duplicate.
        var caches: [String: MergeCaches] = [:]
        for target in targets.sorted(by: { $0.loser < $1.loser }) {
            var cache = caches[target.keeper] ?? MergeCaches()
            let before = payload.progress.count + payload.watched.count + payload.mylist.count
            mergeWatchRows(from: target.loser, into: target.keeper,
                           payload: &payload, caches: &cache)
            caches[target.keeper] = cache
            if payload.progress.count + payload.watched.count + payload.mylist.count > before {
                print("[sync] re-tagged stranded rows from tombstoned profile "
                      + "'\(target.name)' \(target.loser) → \(target.keeper)")
            }
        }
    }

    /// Move every watch row (progress / watched / mylist) off `loserId` onto
    /// `keeperId`. Each row keeps its own timestamp so the keeper ends up with
    /// the freshest copy of a title both profiles have; the original row is
    /// deleted locally and tombstoned on the wire.
    private func mergeWatchRows(from loserId: String, into keeperId: String,
                                payload: inout MergePayload,
                                caches: inout MergeCaches) {
        let context = playback.context

        // --- progress ---
        let progressRows = (try? context.fetch(FetchDescriptor<WatchProgress>(
            predicate: #Predicate { $0.profileId == loserId }))) ?? []
        for row in progressRows {
            let rowTs = ms(row.updatedAt)
            let cacheKey = "\(row.mediaId)|\(row.typeKey)"
            if let keeperRow = caches.progress[cacheKey]
                ?? localProgress(profileId: keeperId, mediaId: row.mediaId, typeKey: row.typeKey) {
                caches.progress[cacheKey] = keeperRow
                if rowTs > ms(keeperRow.updatedAt) {
                    keeperRow.imdbId = row.imdbId
                    keeperRow.title = row.title
                    keeperRow.posterUrl = row.posterUrl
                    keeperRow.backdropUrl = row.backdropUrl
                    keeperRow.season = row.season
                    keeperRow.episode = row.episode
                    keeperRow.episodeTitle = row.episodeTitle
                    keeperRow.positionMs = row.positionMs
                    keeperRow.durationMs = row.durationMs
                    keeperRow.year = row.year
                    keeperRow.rating = row.rating
                    keeperRow.updatedAt = row.updatedAt
                    payload.progress.append(wireProgress(keeperRow, updatedAt: rowTs, deleted: false))
                }
            } else {
                let copy = WatchProgress(
                    mediaId: row.mediaId, typeKey: row.typeKey, profileId: keeperId,
                    imdbId: row.imdbId, title: row.title, posterUrl: row.posterUrl,
                    backdropUrl: row.backdropUrl, season: row.season, episode: row.episode,
                    episodeTitle: row.episodeTitle, positionMs: row.positionMs,
                    durationMs: row.durationMs, updatedAt: row.updatedAt,
                    year: row.year, rating: row.rating)
                context.insert(copy)
                caches.progress[cacheKey] = copy
                payload.progress.append(wireProgress(copy, updatedAt: rowTs, deleted: false))
            }
            // Tombstone built from the row's values BEFORE it is deleted.
            payload.progress.append(wireProgress(row, updatedAt: nowMs(), deleted: true))
            context.delete(row)
        }

        // --- watched episodes ---
        let watchedRows = (try? context.fetch(FetchDescriptor<WatchedEpisode>(
            predicate: #Predicate { $0.profileId == loserId }))) ?? []
        for row in watchedRows {
            let rowTs = ms(row.watchedAt)
            let cacheKey = "\(row.mediaId)|\(row.season)|\(row.episode)"
            if let keeperRow = caches.watched[cacheKey]
                ?? localWatched(profileId: keeperId, mediaId: row.mediaId,
                                season: row.season, episode: row.episode) {
                caches.watched[cacheKey] = keeperRow
                if rowTs > ms(keeperRow.watchedAt) {
                    keeperRow.watchedAt = row.watchedAt
                    payload.watched.append(SyncWatchedRow(
                        mediaId: row.mediaId, profileId: keeperId, season: row.season,
                        episode: row.episode, watchedAt: rowTs, updatedAt: rowTs, deleted: false))
                }
            } else {
                let copy = WatchedEpisode(
                    mediaId: row.mediaId, profileId: keeperId, season: row.season,
                    episode: row.episode, watchedAt: row.watchedAt)
                context.insert(copy)
                caches.watched[cacheKey] = copy
                payload.watched.append(SyncWatchedRow(
                    mediaId: row.mediaId, profileId: keeperId, season: row.season,
                    episode: row.episode, watchedAt: rowTs, updatedAt: rowTs, deleted: false))
            }
            payload.watched.append(SyncWatchedRow(
                mediaId: row.mediaId, profileId: loserId, season: row.season,
                episode: row.episode, watchedAt: rowTs, updatedAt: nowMs(), deleted: true))
            context.delete(row)
        }

        // --- my list ---
        let listRows = (try? context.fetch(FetchDescriptor<MyListItem>(
            predicate: #Predicate { $0.profileId == loserId }))) ?? []
        for row in listRows {
            let rowTs = ms(row.addedAt)
            let cacheKey = "\(row.mediaId)|\(row.typeKey)"
            if let keeperRow = caches.mylist[cacheKey]
                ?? localMyList(profileId: keeperId, mediaId: row.mediaId, typeKey: row.typeKey) {
                caches.mylist[cacheKey] = keeperRow
                if rowTs > ms(keeperRow.addedAt) {
                    keeperRow.title = row.title
                    keeperRow.posterUrl = row.posterUrl
                    keeperRow.backdropUrl = row.backdropUrl
                    keeperRow.year = row.year
                    keeperRow.rating = row.rating
                    keeperRow.addedAt = row.addedAt
                    payload.mylist.append(wireMyList(keeperRow, updatedAt: rowTs, deleted: false))
                }
            } else {
                let copy = MyListItem(
                    mediaId: row.mediaId, typeKey: row.typeKey, profileId: keeperId,
                    title: row.title, posterUrl: row.posterUrl, backdropUrl: row.backdropUrl,
                    year: row.year, rating: row.rating, addedAt: row.addedAt)
                context.insert(copy)
                caches.mylist[cacheKey] = copy
                payload.mylist.append(wireMyList(copy, updatedAt: rowTs, deleted: false))
            }
            payload.mylist.append(wireMyList(row, updatedAt: nowMs(), deleted: true))
            context.delete(row)
        }
    }

    private func wireProgress(_ row: WatchProgress, updatedAt: Int64, deleted: Bool) -> SyncProgressRow {
        SyncProgressRow(
            mediaId: row.mediaId, type: row.typeKey, profileId: row.profileId,
            imdbId: row.imdbId, title: row.title, posterUrl: row.posterUrl,
            backdropUrl: row.backdropUrl, season: row.season, episode: row.episode,
            episodeTitle: row.episodeTitle, positionMs: row.positionMs,
            durationMs: row.durationMs, year: row.year, rating: row.rating,
            updatedAt: updatedAt, deleted: deleted)
    }

    private func wireMyList(_ row: MyListItem, updatedAt: Int64, deleted: Bool) -> SyncMyListRow {
        SyncMyListRow(
            mediaId: row.mediaId, type: row.typeKey, profileId: row.profileId,
            title: row.title, posterUrl: row.posterUrl, backdropUrl: row.backdropUrl,
            year: row.year, rating: row.rating, addedAt: ms(row.addedAt),
            updatedAt: updatedAt, deleted: deleted)
    }

    // MARK: local fetch helpers (same try?-flattening pattern as PlaybackStore)

    /// Profile-keyed, UNfiltered by active profile — sync reconciliation must
    /// see every profile's rows. These mirror PlaybackStore's lookups but take
    /// the wire row's own profileId instead of the active one.

    private func localProgress(profileId: String, mediaId: Int, typeKey: String) -> WatchProgress? {
        var d = FetchDescriptor<WatchProgress>(
            predicate: #Predicate { $0.mediaId == mediaId && $0.typeKey == typeKey && $0.profileId == profileId }
        )
        d.fetchLimit = 1
        return try? playback.context.fetch(d).first
    }

    private func localWatched(profileId: String, mediaId: Int, season: Int, episode: Int) -> WatchedEpisode? {
        var d = FetchDescriptor<WatchedEpisode>(
            predicate: #Predicate { $0.mediaId == mediaId && $0.season == season && $0.episode == episode && $0.profileId == profileId }
        )
        d.fetchLimit = 1
        return try? playback.context.fetch(d).first
    }

    private func localMyList(profileId: String, mediaId: Int, typeKey: String) -> MyListItem? {
        var d = FetchDescriptor<MyListItem>(
            predicate: #Predicate { $0.mediaId == mediaId && $0.typeKey == typeKey && $0.profileId == profileId }
        )
        d.fetchLimit = 1
        return try? playback.context.fetch(d).first
    }

    private func localProfile(id: String) -> Profile? {
        var d = FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? playback.context.fetch(d).first
    }

    // MARK: HTTP

    private func makeRequest(path: String, query: String? = nil,
                             method: String = "GET", body: Data? = nil) throws -> URLRequest {
        var urlString = SettingsStore.normalizeBaseUrl(settings.syncUrl) + path
        if let query { urlString += "?" + query }
        guard let url = URL(string: urlString) else { throw SyncError.badUrl }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let token = settings.syncToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: small helpers

    private func progressKey(_ profileId: String, _ mediaId: Int, _ type: String) -> String {
        "\(profileId)|\(mediaId)|\(type)"
    }
    private func watchedKey(_ profileId: String, _ mediaId: Int, _ season: Int, _ episode: Int) -> String {
        "\(profileId)|\(mediaId)|\(season)|\(episode)"
    }
    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    private func nowMs() -> Int64 { ms(.now) }
}
