import Foundation
import SwiftData

/// Details screen view model — a port of the Android DetailsViewModel.kt
/// (~/velvet/app/src/main/java/tv/velvet/ui/details/DetailsViewModel.kt).
///
/// Division of labor vs Android: Room Flows become SwiftData @Query in
/// DetailsView, so the watched set / resume progress / My List membership are
/// observed by the VIEW and the play-button state is recomputed there via the
/// pure `resolvePlayState`. The VM owns the async work: details fetch, the
/// per-season episode cache, and every watched/progress mutation (all of which
/// land in the shared main-context PlaybackStore so @Query re-emits on its own).
@MainActor
final class DetailsViewModel: ObservableObject {

    /// (season, episode) identity — Android's `Pair<Int, Int>` watched keys.
    struct EpisodeKey: Hashable {
        let season: Int
        let episode: Int
    }

    /// What the primary button says and plays — Android's playLabel/playTarget/
    /// showStartOver trio out of recomputePlayState().
    struct PlayState {
        let label: String
        let target: PlayTarget
        let showStartOver: Bool
    }

    let item: MediaItem
    private let tmdb: TmdbRepository
    private let playback: PlaybackStore
    private let streams: StreamRepository
    private let settings: SettingsStore

    @Published private(set) var loading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var details: MediaDetails?
    @Published private(set) var selectedSeason: Int?
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var episodesLoading = false

    /// Episodes already fetched, by season number — avoids refetching when
    /// chip-hopping. Only non-empty (successful) results are cached so a
    /// transient failure isn't sticky for the screen's lifetime.
    private var episodeCache: [Int: [Episode]] = [:]
    private var hasStartedLoad = false
    /// One pre-warm per details open — load() can run again via Retry, and the
    /// backend only needs the signal once.
    private var prewarmFired = false

    init(item: MediaItem, tmdb: TmdbRepository, playback: PlaybackStore,
         streams: StreamRepository, settings: SettingsStore) {
        self.item = item
        self.tmdb = tmdb
        self.playback = playback
        self.streams = streams
        self.settings = settings
    }

    // MARK: - loading

    /// Called from .task — loads exactly once per screen instance (returning
    /// from the player or a deeper Details push must not refetch).
    func loadIfNeeded() async {
        guard !hasStartedLoad else { return }
        hasStartedLoad = true
        await load()
    }

    /// details() THROWS (per the TmdbRepository contract) → error state with
    /// Retry. On success, shows pick their initial season chip: the season the
    /// play button targets (resume episode or next unwatched), falling back to
    /// the first real (>= 1) season, then to whatever season exists (specials).
    func load() async {
        loading = true
        errorMessage = nil
        do {
            let loaded = try await tmdb.details(id: item.id, type: item.type)
            details = loaded
            loading = false
            if item.type == .show, selectedSeason == nil {
                let snapshot = currentPlayState(details: loaded)
                let initialSeason = snapshot.target.season
                    ?? loaded.seasons.first(where: { $0.number >= 1 })?.number
                    ?? loaded.seasons.first?.number
                if let initialSeason {
                    selectSeason(initialSeason)
                }
            }
            prewarmTopStream(loaded)
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            loading = false
            let message = error.localizedDescription
            errorMessage = message.isEmpty ? "Couldn't load details right now." : message
        }
    }

    // MARK: - backend pre-warm

    /// Opening a details page is the strongest "about to press Play" signal the
    /// app has, and the backend pre-warms its top candidate whenever
    /// `/stream/{kind}/{id}.json` is fetched — so fire the exact stream-list
    /// request Play would issue (series: the episode the Play button targets;
    /// movies: the movie) the moment details land. By the time the user actually
    /// presses Play, the backend has already assembled/queued the best release
    /// and the player's own fetch hits a warm cache instead of a cold resolver.
    ///
    /// Fire-and-forget by design: detached so it never blocks the details
    /// screen, result ignored (the player refetches on Play — this call exists
    /// purely for its server-side side effect), and `streams()` never throws.
    /// Skipped entirely when no stream source is configured — there is no
    /// backend to warm, so the fetch would be pure wasted radio.
    private func prewarmTopStream(_ details: MediaDetails) {
        guard !prewarmFired else { return }
        guard settings.streamSources.contains(where: \.enabled) else { return }
        // Same stream-key rule as the player: imdb when known, else the tmdb
        // pseudo-id the backend resolves by title (day-one titles lack imdb).
        let imdbId: String
        if let realImdb = details.item.imdbId, !realImdb.isEmpty {
            imdbId = realImdb
        } else {
            imdbId = "tmdb:\(details.item.id)"
        }
        prewarmFired = true
        // Resolve the Play target NOW, on the main actor, with the same
        // progress/watched snapshot the button uses — the detached task then
        // carries only value types (plus the Sendable repo) off-actor.
        let target = currentPlayState(details: details).target
        let repo = streams
        Task.detached(priority: .utility) {
            _ = await repo.streams(imdbId: imdbId, type: target.type,
                                   season: target.season, episode: target.episode)
        }
    }

    // MARK: - seasons / episodes

    func selectSeason(_ season: Int) {
        if let cached = episodeCache[season] {
            selectedSeason = season
            episodes = cached
            episodesLoading = false
            return
        }
        if selectedSeason == season && episodesLoading { return }
        selectedSeason = season
        episodes = []
        episodesLoading = true
        Task { [weak self] in
            guard let self else { return }
            let fetched = await self.tmdb.episodes(showId: self.item.id, season: season)
            // Chip-hopped away while fetching — stale result, drop it.
            guard self.selectedSeason == season else { return }
            if !fetched.isEmpty { self.episodeCache[season] = fetched }
            self.episodes = fetched
            self.episodesLoading = false
        }
    }

    /// Episodes for one season: cache first (selectSeason fills it), then
    /// network. Nil = failed or empty — callers treat that season as
    /// best-effort skipped (Android's runCatching-per-season equivalent;
    /// the iOS episodes() maps failures to [] instead of throwing).
    private func episodesForSeason(_ seasonNumber: Int) async -> [Episode]? {
        if let cached = episodeCache[seasonNumber] { return cached }
        let fetched = await tmdb.episodes(showId: item.id, season: seasonNumber)
        guard !fetched.isEmpty else { return nil }
        episodeCache[seasonNumber] = fetched
        return fetched
    }

    // MARK: - context-menu actions (writes land in SwiftData → @Query re-emits)

    func markEpisodeWatched(_ episode: Episode) {
        playback.markWatched(mediaId: item.id, season: episode.season, episode: episode.number)
    }

    func unmarkEpisodeWatched(_ episode: Episode) {
        playback.unmarkWatched(mediaId: item.id, season: episode.season, episode: episode.number)
    }

    /// "Mark all up to here watched": every episode of every real season BEFORE
    /// this episode's season, plus episodes 1..N of its own season, in one batch
    /// write. Earlier seasons are fetched on demand; a season whose fetch fails
    /// is skipped (best effort) while the rest still get marked.
    func markWatchedUpTo(_ episode: Episode) {
        guard let details else { return }
        let earlierSeasons = details.seasons
            .filter { $0.number >= 1 && $0.number < episode.season }
            .sorted { $0.number < $1.number }
        Task { [weak self] in
            guard let self else { return }
            var entries: [(season: Int, episode: Int)] = []
            for season in earlierSeasons {
                if let eps = await self.episodesForSeason(season.number) {
                    entries += eps.map { (season: $0.season, episode: $0.number) }
                }
            }
            // The long-pressed row came from a loaded list, so this is normally
            // a cache hit; if not, fall back to plain 1..N episode numbers.
            if let currentSeason = await self.episodesForSeason(episode.season) {
                entries += currentSeason
                    .filter { $0.number <= episode.number }
                    .map { (season: $0.season, episode: $0.number) }
            } else if episode.number >= 1 {
                entries += (1...episode.number).map { (season: episode.season, episode: $0) }
            }
            if !entries.isEmpty {
                self.playback.markWatchedAll(mediaId: self.item.id, episodes: entries)
            }
        }
    }

    func markSeasonWatched(_ seasonNumber: Int) {
        Task { [weak self] in
            guard let self else { return }
            guard let eps = await self.episodesForSeason(seasonNumber), !eps.isEmpty else { return }
            self.playback.markWatchedAll(
                mediaId: self.item.id,
                episodes: eps.map { (season: $0.season, episode: $0.number) }
            )
        }
    }

    func clearSeasonHistory(_ seasonNumber: Int) {
        playback.clearWatchedSeason(mediaId: item.id, season: seasonNumber)
    }

    /// Shows only: drop the saved resume position (the menu offers this only
    /// when the long-pressed episode IS the in-progress one).
    func clearEpisodeProgress() {
        playback.removeProgress(mediaId: item.id, typeKey: item.type.rawValue)
    }

    // MARK: - my list

    func toggleMyList() {
        guard let details else { return }
        playback.toggleMyList(details.item)
    }

    /// My List membership / toggle for a More Like This card (not the details
    /// title itself). Read lazily when the context menu opens — the iOS
    /// equivalent of Android's resolveInMyList-before-sheet.
    func isInMyList(_ candidate: MediaItem) -> Bool {
        playback.isInMyList(mediaId: candidate.id, typeKey: candidate.type.rawValue)
    }

    func toggleMyList(for candidate: MediaItem) {
        playback.toggleMyList(candidate)
    }

    // MARK: - start over

    /// Movies only: clear the saved resume position, then hand back a fresh
    /// PlayTarget so the caller can present the player from 0:00.
    func startOverTarget() -> PlayTarget {
        playback.removeProgress(mediaId: item.id, typeKey: item.type.rawValue)
        return PlayTarget(mediaId: item.id, type: item.type, season: nil, episode: nil)
    }

    // MARK: - play-state resolution (pure; the view feeds it live @Query data)

    /// Snapshot variant used during load() for the initial season selection.
    func currentPlayState(details: MediaDetails) -> PlayState {
        let progress = playback.progress(mediaId: item.id, typeKey: item.type.rawValue)
        let watched = Set(playback.watchedEpisodes(mediaId: item.id)
            .map { EpisodeKey(season: $0.season, episode: $0.episode) })
        return Self.resolvePlayState(details: details, progress: progress, watched: watched)
    }

    /// EXACT Android recomputePlayState() logic:
    /// - movie with progress → "Resume · 48m left" + Start Over
    /// - movie fresh        → "Play"
    /// - show with progress → "Resume S2 E4 · 23m left"
    /// - show fresh         → "Play S1 E1" (next unwatched across seasons)
    static func resolvePlayState(
        details: MediaDetails,
        progress: WatchProgress?,
        watched: Set<EpisodeKey>
    ) -> PlayState {
        let id = details.item.id
        switch details.item.type {
        case .movie:
            if let progress, let left = minutesLeftLabel(progress) {
                return PlayState(
                    label: "Resume · \(left)",
                    target: PlayTarget(mediaId: id, type: .movie, season: nil, episode: nil),
                    showStartOver: true
                )
            }
            return PlayState(
                label: "Play",
                target: PlayTarget(mediaId: id, type: .movie, season: nil, episode: nil),
                showStartOver: false
            )
        case .show:
            if let progress, let season = progress.season, let episode = progress.episode {
                let left = minutesLeftLabel(progress).map { " · \($0)" } ?? ""
                return PlayState(
                    label: "Resume S\(season) E\(episode)\(left)",
                    target: PlayTarget(mediaId: id, type: .show, season: season, episode: episode),
                    showStartOver: false
                )
            }
            let next = nextUnwatched(details: details, watched: watched)
            return PlayState(
                label: "Play S\(next.season) E\(next.episode)",
                target: PlayTarget(mediaId: id, type: .show, season: next.season, episode: next.episode),
                showStartOver: false
            )
        }
    }

    /// First episode not in the watched set, scanning seasons in order
    /// (specials/season 0 skipped). Fresh show or everything watched → S1 E1.
    static func nextUnwatched(
        details: MediaDetails,
        watched: Set<EpisodeKey>
    ) -> (season: Int, episode: Int) {
        let seasons = details.seasons.filter { $0.number >= 1 }.sorted { $0.number < $1.number }
        for season in seasons where season.episodeCount > 0 {
            for ep in 1...season.episodeCount
            where !watched.contains(EpisodeKey(season: season.number, episode: ep)) {
                return (season.number, ep)
            }
        }
        return (seasons.first?.number ?? 1, 1)
    }

    /// "48m left" / "1h 12m left" — nil when there is no usable progress.
    static func minutesLeftLabel(_ progress: WatchProgress) -> String? {
        guard progress.durationMs > 0, progress.positionMs > 0 else { return nil }
        let minutes = max(1, Int((progress.durationMs - progress.positionMs) / 60_000))
        return "\(DetailsFormat.runtime(minutes)) left"
    }
}

// MARK: - shared formatting (port of the Kotlin file-level helpers)

/// Namespaced so it can't collide with other screens' helpers.
@MainActor
enum DetailsFormat {
    /// 95 → "1h 35m", 60 → "1h", 48 → "48m".
    static func runtime(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    private static let airDateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let airDateDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// "2024-03-01" → "Mar 1, 2024" (raw string on parse failure).
    static func airDate(_ raw: String) -> String {
        guard let date = airDateParser.date(from: raw) else { return raw }
        return airDateDisplay.string(from: date)
    }

    /// "1 Season" / "5 Seasons" — counts real (>= 1) seasons, falling back to
    /// the raw season count for shows with only specials.
    static func seasonCount(_ seasons: [Season]) -> String? {
        let real = seasons.filter { $0.number >= 1 }.count
        let count = real > 0 ? real : seasons.count
        guard count > 0 else { return nil }
        return count == 1 ? "1 Season" : "\(count) Seasons"
    }
}
