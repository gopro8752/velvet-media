import Foundation
import Combine

/// Per-row loading state. Failed / loaded-empty rows collapse silently in the UI.
/// Note: TmdbRepository's error contract returns [] on failure, so an empty result
/// maps to `.failed` (same collapsed UI either way, and Retry can refetch it).
/// DELIBERATE divergence from Android, where rowItems() never throws so a total
/// TMDB outage leaves a silent blank Home (its homeUnavailable state is dead
/// code): classifying [] as .failed lets allRowsFailed drive the full-screen
/// "Can't reach TMDB" retry. Cost: a genuinely-empty-but-successful discover
/// row is refetched on Retry — harmless.
enum RowState {
    case loading
    case loaded([MediaItem])
    case failed
}

/// One Continue Watching rail entry, ready to render and to resume playback.
/// Mirrors the Android ContinueWatchingUi mapping from WatchProgressEntity.
struct ContinueWatchingEntry: Identifiable {
    let item: MediaItem
    let progressFraction: Double
    let label: String              // "S2 E4 · 23m left" / "48m left" / "Resume"
    let target: PlayTarget

    var id: String { "\(item.type.rawValue):\(item.id)" }

    init?(progress: WatchProgress) {
        guard let type = MediaType(rawValue: progress.typeKey) else { return nil }
        item = MediaItem(
            id: progress.mediaId,
            type: type,
            title: progress.title,
            year: progress.year,
            posterUrl: progress.posterUrl.flatMap(URL.init(string:)),
            backdropUrl: progress.backdropUrl.flatMap(URL.init(string:)),
            logoUrl: nil,
            rating: progress.rating,
            overview: nil,
            genres: [],
            runtimeMinutes: nil,
            imdbId: progress.imdbId,
            rankInRow: nil
        )
        progressFraction = progress.durationMs > 0
            ? min(max(Double(progress.positionMs) / Double(progress.durationMs), 0), 1)
            : 0
        label = Self.progressLabel(
            type: type, season: progress.season, episode: progress.episode,
            positionMs: progress.positionMs, durationMs: progress.durationMs
        )
        target = PlayTarget(
            mediaId: progress.mediaId, type: type,
            season: progress.season, episode: progress.episode
        )
    }

    /// Exact port of the Android progressLabel(): "S2 E4 · 23m left", "1h 5m left",
    /// "2h left", "Almost done", or bare "Resume" when the duration is unknown.
    static func progressLabel(
        type: MediaType, season: Int?, episode: Int?,
        positionMs: Int64, durationMs: Int64
    ) -> String {
        let left: String
        if durationMs <= 0 {
            left = "Resume"
        } else {
            let remainingMs = max(durationMs - positionMs, 0)
            let minutesLeft = Int(ceil(Double(remainingMs) / 60_000.0))
            if minutesLeft >= 60 && minutesLeft % 60 == 0 {
                left = "\(minutesLeft / 60)h left"
            } else if minutesLeft >= 60 {
                left = "\(minutesLeft / 60)h \(minutesLeft % 60)m left"
            } else if minutesLeft >= 1 {
                left = "\(minutesLeft)m left"
            } else {
                left = "Almost done"
            }
        }
        if type == .show, let season, let episode {
            return "S\(season) E\(episode) · \(left)"
        }
        return left
    }
}

/// Home view model — a touch-first port of the Android ui/home/HomeViewModel.kt.
/// Owns the TMDB rows (independent per-row loading), the hero rotation (14s tick
/// through the featured pool, pruning items whose enriched details say
/// digitallyAvailable == false), and the context-menu actions. Continue Watching
/// and My List come from @Query in the view; this VM only maps/acts on them.
@MainActor
final class HomeViewModel: ObservableObject {

    /// Resolved row specs in display order (settings.rowOrder, or allRows when empty).
    @Published private(set) var tmdbRows: [RowSpec] = []
    /// Each row loads independently; the map fills in as fetches finish.
    @Published private(set) var rowStates: [String: RowState] = [:]
    /// The billboard item, lazily enriched with details() (logo, runtime, genres).
    @Published private(set) var hero: MediaItem?
    @Published private(set) var halloweenCategory: HomeCategory?
    @Published private(set) var halloweenLoading = false
    @Published private(set) var generatedCategories: [HomeCategory] = []
    @Published private(set) var isGeneratingCategory = false
    @Published var categoryError: String?
    private let companion: CompanionApi
    private var halloweenTask: Task<Void, Never>?
    private var categoryTask: Task<Void, Never>?
    private var lastHalloweenFetch: Date?

    private let tmdb: TmdbRepository
    private let playback: PlaybackStore
    /// Kept so Home can re-resolve the row order on appear — the seasonal
    /// windows are evaluated against the DEVICE-LOCAL date, which can roll over
    /// while the app sits in the background.
    private let settings: SettingsStore

    /// Raw fetched items per row id, BEFORE cross-row dedupe / history
    /// filtering. nil = not fetched yet; [] = failed or genuinely empty (the
    /// TmdbRepository error contract collapses both). `rowStates` is derived
    /// from this in display order, so late-arriving rows can never win an item
    /// away from a row above them.
    private var rawRows: [String: [MediaItem]] = [:]
    /// Rows with a fetch in flight — dedupes concurrent fetch kicks now that
    /// `rowStates` is derived rather than authoritative.
    private var inFlightRows = Set<String>()
    /// "type:id" keys the DISCOVERY rows hide (spec §4d): the active profile's
    /// watch history (any progress row, any watched episode) plus everything
    /// already on My List, which has its own rail above them.
    private var hiddenKeys = Set<String>()

    /// Hero details enrichment cache: "type:id" -> full MediaDetails so the
    /// rotation never refetches an item it has seen.
    private var detailsCache: [String: MediaDetails] = [:]
    /// "type:id" keys discovered (via details enrichment) to be not digitally
    /// available — theater-only movies with nothing on usenet to stream. The
    /// rotation must never tease them, so they are pruned from the featured pool.
    private var unavailableHeroKeys = Set<String>()
    private var rotationTick = 0
    private var currentHeroKey: String?
    private var heroTask: Task<Void, Never>?
    private var rotationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// 14s — long enough to actually read the overview (same as Android).
    private static let heroRotationNanos: UInt64 = 14_000_000_000

    init(tmdb: TmdbRepository, settings: SettingsStore, playback: PlaybackStore, companion: CompanionApi) {
        self.tmdb = tmdb
        self.playback = playback
        self.settings = settings
        self.companion = companion
        halloweenCategory = HomeCategoryCache.halloween()
        generatedCategories = HomeCategoryCache.categories(profile: playback.activeProfileId())
        refreshHalloween()

        hiddenKeys = playback.discoveryHiddenKeys()
        applyRowOrder(settings.rowOrder)
        // React to row-order changes from Settings; fetch each new row independently.
        settings.$rowOrder
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] order in
                Task { @MainActor in self?.applyRowOrder(order) }
            }
            .store(in: &cancellables)
        // The explicit-disable set is the other half of the row membership rule
        // (see resolveSpecs) — a change there must re-resolve too.
        settings.$disabledRowIds
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.applyRowOrder(self.settings.rowOrder)
                }
            }
            .store(in: &cancellables)

        // Idle featured rotation: advance every 14s while there is something to
        // rotate through.
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: HomeViewModel.heroRotationNanos)
                guard let self, !Task.isCancelled else { return }
                self.advanceRotation()
            }
        }
    }

    deinit {
        rotationTask?.cancel()
        heroTask?.cancel()
        halloweenTask?.cancel()
        categoryTask?.cancel()
    }

    // MARK: - Derived state

    /// True when every TMDB row FETCH failed. Deliberately reads the raw fetch
    /// results, not `rowStates`: a Home where every row merely deduped/filtered
    /// itself empty is not a TMDB outage and must not show the retry screen.
    var allRowsFailed: Bool {
        guard !tmdbRows.isEmpty else { return false }
        return tmdbRows.allSatisfy { rawRows[$0.id]?.isEmpty ?? false }
    }

    // MARK: - Intents

    /// Play: movies → plain target (player resolves resume position); shows →
    /// saved season/episode from watch progress, else nil/nil (player resolves
    /// the next unwatched episode).
    func playTarget(for item: MediaItem) -> PlayTarget {
        switch item.type {
        case .movie:
            return PlayTarget(mediaId: item.id, type: .movie, season: nil, episode: nil)
        case .show:
            let progress = playback.progress(mediaId: item.id, typeKey: MediaType.show.rawValue)
            return PlayTarget(
                mediaId: item.id, type: .show,
                season: progress?.season, episode: progress?.episode
            )
        }
    }

    /// Restart from the beginning: drop the saved resume position, then hand back
    /// the same target — the movie, or (for shows) the exact episode the entry was on.
    func startOver(_ entry: ContinueWatchingEntry) -> PlayTarget {
        playback.removeProgress(mediaId: entry.item.id, typeKey: entry.item.type.rawValue)
        return entry.target
    }

    /// Drop the item's Continue Watching entry (resume position); watched marks stay.
    func removeFromContinueWatching(_ item: MediaItem) {
        playback.removeProgress(mediaId: item.id, typeKey: item.type.rawValue)
    }

    /// Nuke all watch state for the item: the resume entry, plus (for shows) every
    /// per-episode watched mark — the show plays from S1E1 like new.
    func clearAllProgress(_ item: MediaItem) {
        playback.removeProgress(mediaId: item.id, typeKey: item.type.rawValue)
        if item.type == .show {
            playback.clearWatchedFor(mediaId: item.id)
        }
    }

    func isInMyList(_ item: MediaItem) -> Bool {
        playback.isInMyList(mediaId: item.id, typeKey: item.type.rawValue)
    }

    /// Add/remove the item from My List — shared by the hero button and context menus.
    func toggleMyList(_ item: MediaItem) {
        playback.toggleMyList(item)
    }

    /// Remove the item from My List (the My List rail's destructive action).
    func removeFromMyList(_ item: MediaItem) {
        if isInMyList(item) {
            playback.toggleMyList(item)
        }
    }

    /// Re-fetch every row whose fetch failed (the "Can't reach TMDB" Retry).
    func retryFailedRows() {
        refreshHalloween(force: true)
        for spec in tmdbRows where (rawRows[spec.id]?.isEmpty ?? false) {
            rawRows[spec.id] = nil
            if inFlightRows.insert(spec.id).inserted { fetchRow(spec.id) }
        }
        recomputeRowStates()
    }

    /// Home came on screen (tab switch, app foreground, profile switch): re-read
    /// what the active profile has already seen and re-evaluate the seasonal
    /// windows against today's date.
    func onHomeAppear() {
        reloadProfileCategories()
        refreshHalloween()
        applyRowOrder(settings.rowOrder)
        refreshHiddenKeys()
    }

    func reloadProfileCategories() {
        categoryError = nil
        generatedCategories = HomeCategoryCache.categories(profile: playback.activeProfileId())
    }

    func refreshHalloween(force: Bool = false) {
        guard halloweenTask == nil else { return }
        if !force, let lastHalloweenFetch, Date().timeIntervalSince(lastHalloweenFetch) < 1_800 { return }
        halloweenLoading = halloweenCategory == nil
        halloweenTask = Task { [weak self] in
            guard let self else { return }
            defer { self.halloweenLoading = false; self.halloweenTask = nil }
            if let category = await self.companion.halloweenCategory(), !Task.isCancelled {
                self.halloweenCategory = category
                HomeCategoryCache.saveHalloween(category)
                self.lastHalloweenFetch = Date()
            }
        }
    }

    func createCategory(prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 500, !isGeneratingCategory else { return }
        let profile = playback.activeProfileId()
        categoryError = nil
        isGeneratingCategory = true
        categoryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isGeneratingCategory = false; self.categoryTask = nil }
            do {
                let category = try await self.companion.generateCategory(prompt: prompt)
                guard !Task.isCancelled else { return }
                var categories = HomeCategoryCache.categories(profile: profile)
                categories.removeAll { $0.id == category.id }
                categories.insert(category, at: 0)
                HomeCategoryCache.save(categories, profile: profile)
                if self.playback.activeProfileId() == profile { self.reloadProfileCategories() }
            } catch is CancellationError {
                return
            } catch {
                if self.playback.activeProfileId() == profile { self.categoryError = error.localizedDescription }
            }
        }
    }

    func removeCategory(_ id: String) {
        generatedCategories.removeAll { $0.id == id }
        HomeCategoryCache.save(generatedCategories, profile: playback.activeProfileId())
    }

    /// Re-read the active profile's history + My List keys and rebuild the rows
    /// if they changed (spec §4d). Called when Home appears, when the active
    /// profile switches, and after pull-to-refresh — deliberately NOT on every
    /// local mutation, so a card can't vanish out from under the finger that
    /// just added it to My List.
    func refreshHiddenKeys() {
        let keys = playback.discoveryHiddenKeys()
        guard keys != hiddenKeys else { return }
        hiddenKeys = keys
        recomputeRowStates()
        recomputeHero()
    }

    /// Pull-to-refresh: refetch every row in parallel. Rows that were showing
    /// content keep it if the refetch comes back empty — never dead-end on a
    /// transient failure mid-browse.
    func refresh() async {
        refreshHalloween(force: true)
        let specs = tmdbRows
        let tmdb = self.tmdb
        guard !specs.isEmpty else { return }
        let results = await withTaskGroup(
            of: (String, [MediaItem]).self,
            returning: [(String, [MediaItem])].self
        ) { group in
            for spec in specs {
                let rowId = spec.id
                group.addTask { (rowId, await tmdb.rowItems(rowId: rowId, page: 1)) }
            }
            var collected: [(String, [MediaItem])] = []
            for await pair in group { collected.append(pair) }
            return collected
        }
        for (rowId, items) in results {
            applyFetched(rowId: rowId, items: items, keepExistingOnFailure: true)
        }
        refreshHiddenKeys()
        recomputeRowStates()
        recomputeHero()
    }

    // MARK: - Local-rail mapping helpers

    static func mediaItem(from row: MyListItem) -> MediaItem? {
        guard let type = MediaType(rawValue: row.typeKey) else { return nil }
        return MediaItem(
            id: row.mediaId,
            type: type,
            title: row.title,
            year: row.year,
            posterUrl: row.posterUrl.flatMap(URL.init(string:)),
            backdropUrl: row.backdropUrl.flatMap(URL.init(string:)),
            logoUrl: nil,
            rating: row.rating,
            overview: nil,
            genres: [],
            runtimeMinutes: nil,
            imdbId: nil,
            rankInRow: nil
        )
    }

    // MARK: - Internals

    private func applyRowOrder(_ order: [String]) {
        let specs = resolveSpecs(order)
        if tmdbRows != specs { tmdbRows = specs }
        for spec in tmdbRows where rawRows[spec.id] == nil {
            if inFlightRows.insert(spec.id).inserted { fetchRow(spec.id) }
        }
        recomputeRowStates()
        recomputeHero()
    }

    /// Display order for this device, today (spec §4f/g):
    /// - the user's stored order (already migrated `trending_movies` →
    ///   `popular_now` by SettingsStore), or every row in default order;
    /// - seasonal rows OUT of their window are hidden entirely;
    /// - seasonal rows IN their window are hoisted to the top, so they land
    ///   right after Continue Watching / My List and ahead of the general
    ///   discovery funnel.
    /// A stored order can never express "keep this seasonal row" for a row that
    /// was OUT of season when it was written — Settings materializes the enabled
    /// set from today's date, so editing anything in October drops Thanksgiving,
    /// Christmas, New Year's and Valentine's from the order entirely. Absence is
    /// therefore NOT a hide: a seasonal row missing from the order is re-added
    /// unless the user explicitly switched it off (`settings.disabledRowIds`).
    private func resolveSpecs(_ order: [String]) -> [RowSpec] {
        let all = tmdb.allRows
        let seasonalIds = Set(tmdb.seasonalRowIds())
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var base: [RowSpec]
        if order.isEmpty {
            base = all
        } else {
            base = order.compactMap { byId[$0] }
            let present = Set(order)
            let disabled = Set(settings.disabledRowIds)
            base += all.filter {
                seasonalIds.contains($0.id)
                    && !present.contains($0.id)
                    && !disabled.contains($0.id)
            }
        }
        // A persisted order can carry the same id twice (hand-edited defaults,
        // an interrupted migration); duplicate RowSpecs would collide in ForEach.
        var seenIds = Set<String>()
        base = base.filter { seenIds.insert($0.id).inserted }

        let seasonal = base.filter { seasonalIds.contains($0.id) && tmdb.isSeasonalRowActive($0.id) }
        let rest = base.filter { !seasonalIds.contains($0.id) }
        return seasonal + rest
    }

    private func fetchRow(_ rowId: String) {
        Task { [weak self] in
            guard let self else { return }
            let items = await self.tmdb.rowItems(rowId: rowId, page: 1)
            self.inFlightRows.remove(rowId)
            self.applyFetched(rowId: rowId, items: items, keepExistingOnFailure: false)
        }
    }

    private func applyFetched(rowId: String, items: [MediaItem], keepExistingOnFailure: Bool) {
        if items.isEmpty, keepExistingOnFailure,
           let old = rawRows[rowId], !old.isEmpty {
            return
        }
        rawRows[rowId] = items
        recomputeRowStates()
        recomputeHero()
    }

    /// Rebuild every row's rendered state from the raw fetches, walking rows in
    /// DISPLAY order so cross-row dedupe is deterministic no matter which fetch
    /// finished first (spec §4c): an item already shown in an earlier row is
    /// suppressed here, as is anything in the active profile's history (§4d).
    /// A row that empties out collapses, exactly like a failed one.
    private func recomputeRowStates() {
        var seen = Set<String>()
        var states: [String: RowState] = [:]
        for spec in tmdbRows {
            guard let items = rawRows[spec.id] else {
                states[spec.id] = .loading
                continue
            }
            if items.isEmpty {
                states[spec.id] = .failed
                continue
            }
            var kept: [MediaItem] = []
            for item in items {
                let key = heroKey(for: item)
                if seen.contains(key) || hiddenKeys.contains(key) { continue }
                seen.insert(key)
                kept.append(item)
            }
            // Top 10 numerals must stay 1…n after dedupe removes entries.
            if spec.style == .top10 {
                for index in kept.indices { kept[index].rankInRow = index + 1 }
            }
            states[spec.id] = .loaded(kept)
        }
        rowStates = states
    }

    // MARK: Hero rotation

    /// Items the idle hero rotates through: the first non-empty loaded row, minus
    /// known not-digitally-available items, capped at 10. While the highest-priority
    /// row is still loading, wait for it (empty pool) instead of flashing a lower row.
    private var featuredPool: [MediaItem] {
        for spec in tmdbRows {
            guard let state = rowStates[spec.id] else { return [] }
            switch state {
            case .loaded(let items):
                let candidates = items.filter { !unavailableHeroKeys.contains(heroKey(for: $0)) }
                if !candidates.isEmpty {
                    return Array(candidates.prefix(10))
                }
                // empty / fully unavailable row — fall through to the next one
            case .failed:
                continue
            case .loading:
                return []
            }
        }
        return []
    }

    private func advanceRotation() {
        if featuredPool.count > 1 {
            rotationTick += 1
            recomputeHero()
        }
    }

    private func recomputeHero() {
        let pool = featuredPool
        guard !pool.isEmpty else {
            if hero != nil { hero = nil }
            currentHeroKey = nil
            return
        }
        let base = pool[rotationTick % pool.count]
        let key = heroKey(for: base)
        // Same item as currently featured (pool merely refreshed around it) — keep
        // the enriched hero as is instead of restarting enrichment / flickering.
        guard key != currentHeroKey else { return }
        currentHeroKey = key
        setHero(base: base, key: key)
    }

    private func setHero(base: MediaItem, key: String) {
        heroTask?.cancel()
        if let cached = detailsCache[key] {
            if !cached.digitallyAvailable {
                // Known-unavailable item reached the rotation (cache warmed before
                // the pool pruned it) — never feature it; marking it shrinks the
                // pool, which advances the rotation to the next candidate.
                markHeroUnavailable(key)
                return
            }
            hero = mergeHero(base, cached.item)
            return
        }
        hero = base
        let tmdb = self.tmdb
        heroTask = Task { [weak self] in
            let details = try? await tmdb.details(id: base.id, type: base.type)
            guard let self, !Task.isCancelled, let details else { return }
            self.detailsCache[key] = details
            if !details.digitallyAvailable {
                self.markHeroUnavailable(key)
            } else if self.currentHeroKey == key {
                self.hero = self.mergeHero(base, details.item)
            }
            // Enrichment failure: keep showing the un-enriched hero; nothing else to do.
        }
    }

    private func heroKey(for item: MediaItem) -> String {
        "\(item.type.rawValue):\(item.id)"
    }

    private func markHeroUnavailable(_ key: String) {
        unavailableHeroKeys.insert(key)
        recomputeHero()
    }

    /// Prefer row data for imagery (no backdrop flicker), details data for the rest.
    private func mergeHero(_ base: MediaItem, _ enriched: MediaItem) -> MediaItem {
        MediaItem(
            id: base.id,
            type: base.type,
            title: enriched.title.isEmpty ? base.title : enriched.title,
            year: base.year ?? enriched.year,
            posterUrl: base.posterUrl ?? enriched.posterUrl,
            backdropUrl: base.backdropUrl ?? enriched.backdropUrl,
            logoUrl: enriched.logoUrl ?? base.logoUrl,
            rating: base.rating ?? enriched.rating,
            overview: base.overview ?? enriched.overview,
            genres: enriched.genres.isEmpty ? base.genres : enriched.genres,
            runtimeMinutes: enriched.runtimeMinutes ?? base.runtimeMinutes,
            imdbId: enriched.imdbId ?? base.imdbId,
            rankInRow: base.rankInRow
        )
    }
}
